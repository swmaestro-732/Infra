#!/usr/bin/env python3
"""AWS 호출 없이 실제 user_data를 렌더링·실행해 비밀값 전달과 fail-closed를 확인한다."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = ROOT / "terraform/modules/crawler/templates/user_data.sh.tftpl"
VALUES = {
    "aws_region": "ap-northeast-2",
    "ecr_repository_url": "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/chilsami-crawler",
    "environment": "prod",
    "enabled": True,
    "queue_url": "https://sqs.ap-northeast-2.amazonaws.com/123456789012/chilsami-crawl-results",
    "db_url": "jdbc:postgresql://chilsami-rds-reader.abcdefghijkl.ap-northeast-2.rds.amazonaws.com:5432/chilsami",
    "db_secret_id": "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:chilsami/crawler/db-AbCdEf",
    "apify_secret_id": "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:chilsami/crawler/apify-token-AbCdEf",
    "claude_secret_id": "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:chilsami/crawler/claude-code-oauth-token-AbCdEf",
    "kakao_secret_id": "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:chilsami/crawler/kakao-api-key-AbCdEf",
    "media_bucket": "chilsami-media-ap-northeast-2",
    "cdn_base_url": "https://d123456789abcd.cloudfront.net",
    "log_group": "/chilsami/crawler",
}
TOKEN = "token with spaces $dollar 'quote' \"double\" \\backslash"


class BootstrapTest(unittest.TestCase):
    def test_prod_bootstrap(self):
        self.check_bootstrap(VALUES)

    def test_dev_bootstrap(self):
        values = {key: value.replace("chilsami/crawler", "chilsami-dev/crawler").replace("chilsami-crawler", "chilsami-dev-crawler")
                  if isinstance(value, str) else value for key, value in VALUES.items()}
        values.update(environment="dev", enabled=False,
                      db_url="jdbc:postgresql://10.0.40.123:5432/chilsami_dev",
                      queue_url=VALUES["queue_url"].replace("chilsami-crawl", "chilsami-dev-crawl"))
        self.check_bootstrap(values)

    def check_bootstrap(self, values):
        self.assertTrue(TEMPLATE.exists(), "크롤러 user_data가 필요합니다")
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            expression = f"jsonencode(templatefile({json.dumps(str(TEMPLATE))}, {json.dumps(values)}))"
            rendered = subprocess.run(
                ["terraform", "console"], cwd=temp, input=expression,
                text=True, capture_output=True, check=True,
            )
            script = json.loads(json.loads(rendered.stdout))
            size = len(script.encode())
            self.assertLess(size, 16384)
            print(f"{values['environment']} fixture user_data: {size} bytes / 16384")
            subprocess.run(["bash", "-n"], input=script, text=True, check=True)
            subprocess.run(["shellcheck", "-s", "bash", "-"], input=script, text=True, check=True)
            stub = temp / "stub"
            stub.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if name == "dnf":
    # AL2023 공식 패키지 이름: awscli-2 (awscli2 는 존재하지 않음).
    if set(args) - {"install", "-y", "docker", "jq", "awscli-2"}:
        sys.exit("Unknown AL2023 package")
elif name == "aws":
    if args[0] == "ecr":
        print("ecr-test-token")
    else:
        secret = args[args.index("--secret-id") + 1]
        value = json.dumps({"password": os.environ["TEST_TOKEN"]}) if "/db-" in secret else os.environ["TEST_TOKEN"]
        print(json.dumps({"SecretString": "" if secret == os.environ.get("EMPTY_SECRET") else value}))
elif name == "docker" and args[0] == "login":
    sys.stdin.read()
elif name == "docker" and args[0] == "run":
    keys = [args[i + 1] for i, arg in enumerate(args) if arg == "--env"]
    pathlib.Path(os.environ["CAPTURE"]).write_text(json.dumps({"args": args, "env": {k: os.environ[k] for k in keys}}))
''')
            stub.chmod(0o755)
            for name in ("aws", "docker", "dnf", "systemctl", "sleep"):
                (temp / name).symlink_to(stub)
            capture = temp / "capture.json"
            env = dict(os.environ, PATH=f"{temp}:{os.environ['PATH']}", TEST_TOKEN=TOKEN, CAPTURE=str(capture))
            result = subprocess.run(["bash"], input=script, text=True, capture_output=True, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            run = json.loads(capture.read_text())
            for key in ("CRAWLER_DB_PASSWORD", "APIFY_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "KAKAO_API_KEY"):
                self.assertEqual(run["env"][key], TOKEN)
            self.assertEqual(run["env"]["CRAWLER_DB_USER"], "crawler_ro")
            self.assertEqual(run["args"][run["args"].index("--stop-timeout") + 1], "45")
            self.assertEqual(run["env"]["CRAWLER_ENABLED"], str(values["enabled"]).lower())
            self.assertEqual(run["env"]["CRAWLER_DB_URL"], values["db_url"])
            for key, source in {"SPRING_PROFILES_ACTIVE": "environment", "SQS_CRAWL_RESULTS_QUEUE_URL": "queue_url",
                                "CRAWLER_MEDIA_BUCKET": "media_bucket", "CRAWLER_CDN_BASE_URL": "cdn_base_url", "AWS_REGION": "aws_region"}.items():
                self.assertEqual(run["env"][key], values[source])
            self.assertNotIn(TOKEN, json.dumps(run["args"]) + result.stdout + result.stderr)
            capture.unlink()
            for key in ("db_secret_id", "apify_secret_id", "claude_secret_id", "kakao_secret_id"):
                with self.subTest(empty=key):
                    failed = subprocess.run(["bash"], input=script, text=True, capture_output=True, env=dict(env, EMPTY_SECRET=values[key]))
                    self.assertNotEqual(failed.returncode, 0)
                    self.assertFalse(capture.exists(), "빈 시크릿으로 컨테이너를 기동하면 안 됩니다")
                    self.assertNotIn(TOKEN, failed.stdout + failed.stderr)


class ProvisionInputTest(unittest.TestCase):
    def test_credentials_are_validated_before_sql(self):
        script = (ROOT / "scripts/crawler/provision-db-role.sh").read_text()
        code = script.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        master = {"username": "chilsami", "dbname": "chilsami", "writer_host": "writer.example",
                  "port": 5432, "password": "admin:back\\slash"}
        crawler = {"username": "crawler_ro", "password": "A1" * 16}
        with tempfile.TemporaryDirectory() as directory:
            temp = Path(directory)
            (temp / "master.json").write_text(json.dumps(master))
            (temp / "crawler.json").write_text(json.dumps(crawler))
            result = subprocess.run(["python3", "-I", "-", directory, "15432"],
                                    input="import os; os.umask(0o077)\n" + code, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("admin\\:back\\\\slash", (temp / "admin.pgpass").read_text())
            self.assertEqual((temp / "role.sql").stat().st_mode & 0o777, 0o600)
            self.assertIn("ALTER ROLE crawler_ro LOGIN PASSWORD", (temp / "role.sql").read_text())
            self.assertNotIn(crawler["password"], result.stdout + result.stderr)
            (temp / "role.sql").unlink()
            for invalid in ("", "quote'" + "A" * 26, "A" * 31 + "\n"):
                with self.subTest(invalid_password=bool(invalid)):
                    (temp / "crawler.json").write_text(json.dumps(dict(crawler, password=invalid)))
                    rejected = subprocess.run(["python3", "-I", "-", directory, "15432"],
                                              input=code, text=True, capture_output=True)
                    self.assertNotEqual(rejected.returncode, 0)
                    self.assertFalse((temp / "role.sql").exists())


if __name__ == "__main__":
    unittest.main()
