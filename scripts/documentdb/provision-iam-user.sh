#!/usr/bin/env bash
#
# 앱용 DocumentDB IAM 인증 유저 프로비저닝 — MONGODB-AWS (SCRUM-688)
# ─────────────────────────────────────────────────────────────────────────────
# DocumentDB 는 앱 EC2 의 인스턴스 역할(ARN)로 password-less 접속한다(MONGODB-AWS). 그러려면 클러스터의
# $external DB 에 "이 역할 = readWrite 유저" 를 1회 등록해야 한다(db.createUser). 이건 AWS API 가 아니라
# 클러스터 내부 명령이고, 클러스터는 VPC 프라이빗이라 CI/로컬에서 직접 못 닿는다 — 앱 EC2 를 점프 호스트로
# 한 SSM 터널 경유로 master 로 접속해 등록한다(opensearch provision-dev-fgac.sh 와 동일 패턴).
#
# 보안:
#   - master 자격증명은 argv(ps 노출)·환경변수(/proc/<pid>/environ 노출) 대신 0600 권한 임시 JS 파일로
#     mongosh 에 전달하고(--file) 종료 시 삭제한다(opensearch provision 의 curl -K 와 동일 취지).
#     같은 사용자/root 는 그 파일에도 접근 가능하나, 1회성 실행 + 관리자 로컬 권한 전제라 노출 범위는 제한적.
#     (master 비번은 random_password special=false → 영숫자라 URI/JS 문자열에 안전.)
#   - TLS 는 유지한다. 터널은 localhost 로 연결되지만 인증서는 Amazon global CA 번들로 검증하고(tlsCAFile),
#     호스트명만 터널 특성상 불일치하므로 tlsAllowInvalidHostnames 로 호스트명 검증만 생략('-k'=검증전체생략 아님).
#   - 앱 EC2 인스턴스 역할에는 master 시크릿 read 를 주지 않는다(최소권한, SCRUM-686 #4). 이 스크립트는
#     master 시크릿 read 권한이 있는 관리자(chilsami)가 자기 머신에서 1회 실행한다.
#
# 멱등: 유저가 없으면 createUser, 있으면 updateUser 로 role 을 원하는 상태로 덮어쓴다. 여러 번 돌려도 안전.
#   비번 없는 IAM 유저라 회전이 없어 사실상 한 번만 돌리면 끝(역할/권한 변경·클러스터 재생성 시에만 재실행).
#
# 사전조건:
#   - AWS_PROFILE 이 master 시크릿 read + iam get-role 가능해야 함(관리자 chilsami).
#       aws sso login --profile chilsami
#   - 로컬에 mongosh(MONGODB-AWS 지원 버전), session-manager-plugin, curl, python3 설치.
#       brew install mongosh   # 미설치 시
# 사용: AWS_PROFILE=chilsami ./provision-iam-user.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-chilsami}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
LOCAL_PORT="${LOCAL_PORT:-27017}"
JUMP_NAME_TAG="${JUMP_NAME_TAG:-chilsami-app}"            # 클러스터 27017 에 닿는 running 인스턴스(점프 호스트)
APP_ROLE_NAME="${APP_ROLE_NAME:-chilsami-ec2-role}"       # $external 유저로 등록할 앱 인스턴스 역할
DOCDB_SECRET_ID="${DOCDB_SECRET_ID:-chilsami/docdb/credentials}"
DOCDB_DB="${DOCDB_DB:-chat}"                              # 앱이 readWrite 할 DB
CA_URL="https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"
export AWS_PROFILE AWS_REGION

PF=""
CA=""
PROV_JS=""
SSM_LOG=""
cleanup() {
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
  for f in "$CA" "$PROV_JS" "$SSM_LOG"; do [ -n "$f" ] && rm -f "$f" || true; done
}
trap cleanup EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "필요한 명령 없음: $1" >&2; exit 1; }; }
need aws; need mongosh; need curl; need python3; need session-manager-plugin

# 로컬 포트가 이미 점유돼 있으면 거부한다. 안 그러면 다른 프로세스(예: 다른 DocumentDB 터널)의 리스너에
# mongosh 가 붙어 의도치 않은 클러스터에 명령을 보낼 수 있다(CodeRabbit).
port_open() { (exec 3<>"/dev/tcp/localhost/$LOCAL_PORT") 2>/dev/null && { exec 3>&- 3<&-; return 0; } || return 1; }
if port_open; then
  echo "로컬 포트 $LOCAL_PORT 가 이미 사용 중 — LOCAL_PORT 를 비어있는 값으로 지정해 다시 실행하세요." >&2
  exit 1
fi

echo "[1/5] master 자격증명 + 앱 역할 ARN 로드 (AWS_PROFILE=$AWS_PROFILE)"
MASTER_JSON=$(aws secretsmanager get-secret-value --secret-id "$DOCDB_SECRET_ID" --query SecretString --output text)
jget() { python3 -c "import sys,json;print(json.load(sys.stdin)['$1'])"; }
MU=$(printf '%s' "$MASTER_JSON" | jget username)
MP=$(printf '%s' "$MASTER_JSON" | jget password)
DOCDB_HOST=$(printf '%s' "$MASTER_JSON" | jget host)
APP_ROLE_ARN=$(aws iam get-role --role-name "$APP_ROLE_NAME" --query 'Role.Arn' --output text)
echo "  cluster: $DOCDB_HOST"
echo "  app role(\$external user): $APP_ROLE_ARN"

echo "[2/5] Amazon global CA 번들 다운로드"
CA=$(mktemp)
curl -fsS -o "$CA" "$CA_URL"

echo "[3/5] SSM 터널 오픈 (localhost:$LOCAL_PORT → $DOCDB_HOST:27017)"
JUMP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$JUMP_NAME_TAG" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ -n "$JUMP" ] && [ "$JUMP" != "None" ] || { echo "점프 호스트($JUMP_NAME_TAG) running 인스턴스를 못 찾음" >&2; exit 1; }
SSM_LOG=$(mktemp)
aws ssm start-session --target "$JUMP" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$DOCDB_HOST\"],\"portNumber\":[\"27017\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}" \
  >"$SSM_LOG" 2>&1 &
PF=$!
# 이 세션이 포트를 열 때까지 대기(최대 ~30s). PF 가 죽으면 즉시 실패(점유 중인 다른 리스너에 붙지 않도록).
for _ in $(seq 1 30); do
  kill -0 "$PF" 2>/dev/null || { echo "SSM 세션이 종료됨:" >&2; cat "$SSM_LOG" >&2; exit 1; }
  port_open && break
  sleep 1
done
port_open || { echo "터널 포트($LOCAL_PORT)가 열리지 않음:" >&2; cat "$SSM_LOG" >&2; exit 1; }

echo "[4/5] \$external 유저 등록(멱등) + 검증 — MONGODB-AWS, readWrite on '$DOCDB_DB'"
# 자격증명을 argv/환경변수가 아니라 0600 임시 JS 파일로 전달한다. tlsAllowInvalidHostnames=true 는 터널
# 호스트명 불일치만 허용(인증서 체인은 tlsCAFile 로 검증). retryWrites=false 는 DocumentDB 필수.
PROV_JS=$(mktemp)
chmod 600 "$PROV_JS"
cat >"$PROV_JS" <<JS
const uri = "mongodb://${MU}:${MP}@localhost:${LOCAL_PORT}/" +
  "?tls=true&tlsCAFile=${CA}&tlsAllowInvalidHostnames=true&retryWrites=false&authSource=admin";
const ext = Mongo(uri).getDB("\$external");
const roleArn = "${APP_ROLE_ARN}";
const roles = [{ role: "readWrite", db: "${DOCDB_DB}" }];
try {
  ext.runCommand({ createUser: roleArn, mechanisms: ["MONGODB-AWS"], roles });
  print("  created: " + roleArn);
} catch (e) {
  if (/already exists/i.test(e.message) || e.code === 51003 || e.codeName === "Location51003") {
    ext.runCommand({ updateUser: roleArn, roles });
    print("  updated(exists): " + roleArn);
  } else { throw e; }
}
const u = (ext.runCommand({ usersInfo: roleArn }).users || []).find(function (x) { return x.user === roleArn; });
if (!u) { print("  검증 실패: 유저 없음"); quit(1); }
const ok = (u.roles || []).some(function (r) { return r.role === "readWrite" && r.db === "${DOCDB_DB}"; });
const mech = (u.mechanisms || []).includes("MONGODB-AWS");
print("  roles: " + JSON.stringify(u.roles) + " / mechanisms: " + JSON.stringify(u.mechanisms));
if (!ok || !mech) { print("  검증 실패: role/mechanism 불일치"); quit(1); }
print("  검증 OK");
JS
mongosh --quiet --nodb --file "$PROV_JS"

echo "[5/5] 완료. 앱은 이제 인스턴스 역할로 접속한다(비번 없음):"
echo "  mongodb://<DOCDB_ENDPOINT>:27017/?tls=true&tlsCAFile=global-bundle.pem&retryWrites=false&authSource=\$external&authMechanism=MONGODB-AWS"
echo "  (엔드포인트는 SSM /chilsami/docdb/endpoint → ec2 user_data 가 DOCDB_ENDPOINT 로 주입. BackEnd 연동은 SCRUM-688 Part 3.)"
