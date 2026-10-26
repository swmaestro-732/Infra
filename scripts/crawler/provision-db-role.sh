#!/usr/bin/env bash
# Flyway V18 이 만든 NOLOGIN crawler_ro 에 로그인 비밀번호만 설정한다(권한/테이블은 Flyway 소유).
# DocumentDB SCRUM-688 과 동일하게 관리자의 SSM 터널로 실행. 크롤러에는 master 시크릿 권한이 없다.
# 사용: AWS_PROFILE=chilsami bash scripts/crawler/provision-db-role.sh prod|dev
set +x
set -euo pipefail
umask 077

ENVIRONMENT="${1:-prod}"
case "$ENVIRONMENT" in
  prod)
    MASTER_SECRET_ID="chilsami/rds/credentials"
    CRAWLER_SECRET_ID="chilsami/crawler/db"
    JUMP_NAME_TAG="chilsami-app"
    ;;
  dev)
    MASTER_SECRET_ID="chilsami/dev/db/credentials"
    CRAWLER_SECRET_ID="chilsami-dev/crawler/db"
    JUMP_NAME_TAG="chilsami-dev-app"
    ;;
  *) echo "사용법: $0 prod|dev" >&2; exit 1 ;;
esac
export AWS_PROFILE="${AWS_PROFILE:-chilsami}" AWS_REGION="${AWS_REGION:-ap-northeast-2}"
LOCAL_PORT="${LOCAL_PORT:-15432}"
if ! [[ "$LOCAL_PORT" =~ ^[0-9]{4,5}$ ]] || ((10#$LOCAL_PORT < 1024 || 10#$LOCAL_PORT > 65535)); then
  echo "LOCAL_PORT 는 1024~65535 정수여야 합니다." >&2
  exit 1
fi

for command in aws jq psql python3 curl session-manager-plugin; do
  command -v "$command" >/dev/null || { echo "필요한 명령 없음: $command" >&2; exit 1; }
done

PF=""
WORK=$(mktemp -d)
cleanup() {
  if [ -n "$PF" ]; then
    pkill -P "$PF" 2>/dev/null || true
    kill "$PF" 2>/dev/null || true
    wait "$PF" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$LOCAL_PORT") 2>/dev/null; }
if port_open; then
  echo "로컬 포트 $LOCAL_PORT 사용 중 — 다른 터널에 접속하지 않도록 중단합니다." >&2
  exit 1
fi

echo "[1/4] $ENVIRONMENT 관리자·crawler_ro 시크릿 로드 (값은 출력하지 않음)"
aws secretsmanager get-secret-value --secret-id "$MASTER_SECRET_ID" --query SecretString --output text >"$WORK/master.json"
aws secretsmanager get-secret-value --secret-id "$CRAWLER_SECRET_ID" --query SecretString --output text >"$WORK/crawler.json"

# 비밀번호는 argv/환경변수 대신 0600 pgpass·SQL 파일로 전달하고 종료 시 삭제한다.
# 식별자·호스트·비밀번호 형식을 먼저 검사해 libpq 옵션/SQL/pgpass 삽입을 막는다.
python3 -I - "$WORK" "$LOCAL_PORT" <<'PY'
import json, pathlib, re, sys
work = pathlib.Path(sys.argv[1])
master = json.loads((work / "master.json").read_text())
crawler = json.loads((work / "crawler.json").read_text())
assert crawler.get("username") == "crawler_ro", "crawler_ro 시크릿이 아닙니다"
assert re.fullmatch(r"[A-Za-z0-9]{32}", crawler["password"]), "random_password 형식이 아닙니다"
for key in ("username", "dbname"):
    assert re.fullmatch(r"[A-Za-z0-9_]+", master[key]), "DB 식별자 형식 오류"
assert re.fullmatch(r"[A-Za-z0-9.-]+", master["writer_host"]), "writer 호스트 형식 오류"
assert master["port"] == 5432, "DB 포트 불일치"
assert isinstance(master["password"], str) and master["password"], "관리자 비밀번호 없음"
assert not any(c in master["password"] for c in "\r\n\0"), "pgpass 제어문자 금지"
for name, user, password in (("admin", master["username"], master["password"]), ("crawler", "crawler_ro", crawler["password"])):
    escaped = password.replace("\\", "\\\\").replace(":", "\\:")
    (work / f"{name}.pgpass").write_text(f"*:{sys.argv[2]}:{master['dbname']}:{user}:{escaped}\n")
(work / "role.sql").write_text("""BEGIN;
SET password_encryption = 'scram-sha-256';
DO $$ BEGIN
  IF pg_is_in_recovery() THEN RAISE EXCEPTION 'writer 에서만 실행하세요'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'crawler_ro') THEN
    RAISE EXCEPTION 'Backend Flyway V18 을 먼저 적용하세요';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'crawler_ro'
    AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)) THEN
    RAISE EXCEPTION 'crawler_ro 권한이 예상과 다릅니다';
  END IF;
END $$;
ALTER ROLE crawler_ro LOGIN PASSWORD '""" + crawler["password"] + "';\nCOMMIT;\n")
PY

export PGHOST PGHOSTADDR=127.0.0.1 PGPORT="$LOCAL_PORT" PGDATABASE PGUSER PGSSLMODE PGCONNECT_TIMEOUT=10
PGHOST=$(jq -er .writer_host "$WORK/master.json")
PGDATABASE=$(jq -er .dbname "$WORK/master.json")
PGUSER=$(jq -er .username "$WORK/master.json")
TUNNEL_HOST="$PGHOST"
if [ "$ENVIRONMENT" = prod ]; then
  # host 는 writer DNS, hostaddr 는 localhost: SSM 경유에도 TLS 호스트명까지 검증한다.
  curl -fsS 'https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem' -o "$WORK/ca.pem"
  export PGSSLROOTCERT="$WORK/ca.pem"
  PGSSLMODE=verify-full
else
  # dev Postgres 는 TLS 미구성. 암호화된 SSM 터널의 끝을 같은 호스트의 loopback 으로 고정한다.
  TUNNEL_HOST=127.0.0.1
  PGSSLMODE=disable
fi

echo "[2/4] $JUMP_NAME_TAG 경유로 writer 에 SSM 터널 연결"
JUMP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$JUMP_NAME_TAG" 'Name=instance-state-name,Values=running' \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[[ "$JUMP" =~ ^i-[a-f0-9]+$ ]] || { echo "점프 호스트를 찾지 못했습니다." >&2; exit 1; }
PARAMETERS=$(jq -cn --arg host "$TUNNEL_HOST" --arg port "$LOCAL_PORT" \
  '{host:[$host],portNumber:["5432"],localPortNumber:[$port]}')
aws ssm start-session --target "$JUMP" --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "$PARAMETERS" >"$WORK/ssm.log" 2>&1 &
PF=$!
for _ in $(seq 1 30); do
  kill -0 "$PF" 2>/dev/null || { cat "$WORK/ssm.log" >&2; exit 1; }
  port_open && break
  sleep 1
done
if ! port_open || ! kill -0 "$PF" 2>/dev/null; then
  echo "SSM 터널 준비 실패" >&2
  exit 1
fi

echo "[3/4] crawler_ro LOGIN 설정 (재실행 가능, 기존 읽기 권한 유지)"
PGPASSFILE="$WORK/admin.pgpass" psql -X --no-password --set=ON_ERROR_STOP=1 --set=ECHO=none --quiet --file="$WORK/role.sql"

echo "[4/4] 새 비밀번호로 로그인 검증"
LOGIN=$(PGPASSFILE="$WORK/crawler.pgpass" PGUSER=crawler_ro psql -X --no-password --set=ON_ERROR_STOP=1 -Atc 'SELECT current_user;')
[ "$LOGIN" = crawler_ro ] || { echo "crawler_ro 로그인 검증 실패" >&2; exit 1; }
echo "완료. prod Reader 반영을 확인하고 크롤러 ASG 를 refresh 하세요."
