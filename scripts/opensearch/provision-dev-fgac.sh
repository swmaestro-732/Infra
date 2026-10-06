#!/usr/bin/env bash
#
# dev 앱용 OpenSearch FGAC 프로비저닝 — IAM/SigV4 (SCRUM-567)
# ─────────────────────────────────────────────────────────────────────────────
# dev 는 새 도메인 없이 prod OpenSearch 도메인을 인덱스 네임스페이스(dev-*)로 격리 공유한다.
# dev 앱은 자기 EC2 인스턴스 역할로 요청에 SigV4 서명해 붙는다(비밀번호 없음). 도메인은 그 IAM
# 역할 ARN 을 backend_role 로 보고 dev_app 롤(dev-* 한정)의 권한을 부여한다.
#
# FGAC 롤/롤매핑은 AWS API 가 아니라 도메인 보안플러그인의 _plugins/_security REST 로만 만들어지고,
# 도메인은 VPC 내부 전용이라 CI 에서 못 닿는다. 이 스크립트가 그 1회성 PUT 을 SSM 터널 경유로 한다.
#
# 보안: 도메인은 공인 CA(Amazon) 인증서를 쓰므로 TLS 를 검증한다 — curl --connect-to 로 TLS 호스트명은
#   실제 도메인으로 유지하고 연결만 로컬 터널(localhost)로 보낸다('-k' 미사용 → 터널 포트 선점 MITM 방지).
#   master 자격증명은 프로세스 인자(ps 노출) 대신 600 권한 curl 설정파일(-K)로 전달하고 종료 시 삭제한다.
#
# 멱등: 모두 PUT(원하는 상태로 덮어쓰기)이라 몇 번 다시 돌려도 안전하다. 비밀번호가 없어 회전이
#   없으므로 사실상 한 번만 돌리면 끝(도메인 재생성/수동변경 시에만 재실행).
#
# 사전조건:
#   - AWS_PROFILE 이 master 시크릿 read + iam get-role 가능해야 함(관리자 chilsami).
#     →  aws sso login --profile chilsami
#   - session-manager-plugin 설치(SSM 포트포워딩용).
# 사용: AWS_PROFILE=chilsami ./provision-dev-fgac.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-chilsami}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
LOCAL_PORT="${LOCAL_PORT:-9243}"
JUMP_NAME_TAG="${JUMP_NAME_TAG:-chilsami-app}" # 도메인 443 에 닿는 running 인스턴스(점프 호스트)
DEV_ROLE_NAME="${DEV_ROLE_NAME:-chilsami-dev-ec2-role}" # backend_role 로 매핑할 dev 인스턴스 역할
ROLE_NAME="dev_app"
export AWS_PROFILE AWS_REGION

PF=""
CURL_CFG=""
cleanup() {
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
  [ -n "$CURL_CFG" ] && rm -f "$CURL_CFG" || true
}
trap cleanup EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "필요한 명령 없음: $1" >&2; exit 1; }; }
need aws; need curl; need python3

echo "[1/5] master 자격증명 + dev 역할 ARN 로드 (AWS_PROFILE=$AWS_PROFILE)"
MASTER_JSON=$(aws secretsmanager get-secret-value --secret-id chilsami/opensearch/master --query SecretString --output text)
jget() { python3 -c "import sys,json;print(json.load(sys.stdin)['$1'])"; }
MU=$(printf '%s' "$MASTER_JSON" | jget username)
MP=$(printf '%s' "$MASTER_JSON" | jget password)
OSH=$(printf '%s' "$MASTER_JSON" | jget endpoint)
DEV_ROLE_ARN=$(aws iam get-role --role-name "$DEV_ROLE_NAME" --query 'Role.Arn' --output text)
echo "  domain: $OSH"
echo "  dev role(backend_role): $DEV_ROLE_ARN"

# master 자격증명을 argv(ps 노출) 대신 600 권한 설정파일로 전달한다.
CURL_CFG=$(mktemp)
chmod 600 "$CURL_CFG"
printf 'user = "%s:%s"\n' "$MU" "$MP" >"$CURL_CFG"

echo "[2/5] SSM 터널 오픈 (localhost:$LOCAL_PORT → $OSH:443)"
JUMP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$JUMP_NAME_TAG" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
[ -n "$JUMP" ] && [ "$JUMP" != "None" ] || { echo "점프 호스트($JUMP_NAME_TAG) running 인스턴스를 못 찾음" >&2; exit 1; }
aws ssm start-session --target "$JUMP" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$OSH\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"$LOCAL_PORT\"]}" \
  >/tmp/ssm-os-fgac.log 2>&1 &
PF=$!

BASE="https://$OSH"
# --connect-to: TLS 호스트명·인증서는 실제 도메인($OSH)으로 검증하고 TCP 연결만 로컬 터널로 보낸다.
# -K: user:pass 를 argv 가 아닌 600 설정파일에서 읽는다. (둘 다 CodeRabbit 보안 지적 반영)
CURL_COMMON=(-s --retry 30 --retry-delay 1 --retry-all-errors --connect-timeout 3
  --connect-to "$OSH:443:localhost:$LOCAL_PORT" -K "$CURL_CFG")

put() { # label path body
  local code
  code=$(curl "${CURL_COMMON[@]}" -o /tmp/os-fgac-resp.json -w '%{http_code}' \
    -H 'Content-Type: application/json' -X PUT "$BASE$2" --data "$3")
  case "$code" in
    200 | 201) echo "  [$1] OK ($code)" ;;
    *) echo "  [$1] 실패 HTTP $code: $(cat /tmp/os-fgac-resp.json)" >&2; exit 1 ;;
  esac
}

echo "[3/5] 롤/롤매핑 PUT (멱등) — 내부유저 없음(SigV4)"
# 롤: dev-* 인덱스 전체권한(indices_all) — prod course_v1/place_v1 등은 접근 불가(격리).
#     클러스터는 복합연산(_bulk/_mget/_msearch) + 헬스/스탯 모니터로 한정.
ROLE_BODY='{"cluster_permissions":["cluster_composite_ops","cluster_monitor"],"index_permissions":[{"index_patterns":["dev-*"],"allowed_actions":["indices_all"]}]}'
put "role:$ROLE_NAME" "/_plugins/_security/api/roles/$ROLE_NAME" "$ROLE_BODY"

# 롤매핑: 내부유저 대신 dev 인스턴스 역할 ARN 을 backend_role 로. 앱이 SigV4 로 붙으면 이 ARN 이 매칭돼 dev_app 권한 획득.
export DEV_ROLE_ARN
MAP_BODY=$(python3 -c 'import json,os;print(json.dumps({"backend_roles":[os.environ["DEV_ROLE_ARN"]]}))')
put "rolesmapping:$ROLE_NAME" "/_plugins/_security/api/rolesmapping/$ROLE_NAME" "$MAP_BODY"

echo "[4/5] 검증: 롤/롤매핑 존재 + backend_role 일치"
export ROLE_NAME
curl "${CURL_COMMON[@]}" "$BASE/_plugins/_security/api/roles/$ROLE_NAME" |
  python3 -c 'import sys,json,os;d=json.load(sys.stdin);r=os.environ["ROLE_NAME"];assert r in d,"롤 생성 실패";print(f"  role 존재: {r in d}")'
curl "${CURL_COMMON[@]}" "$BASE/_plugins/_security/api/rolesmapping/$ROLE_NAME" |
  python3 -c 'import sys,json,os;d=json.load(sys.stdin);r=os.environ["ROLE_NAME"];arn=os.environ["DEV_ROLE_ARN"];br=d.get(r,{}).get("backend_roles",[]);print(f"  backend_roles: {br}");assert arn in br,"backend_role 매핑 불일치";print("  검증 OK")'

echo "[5/5] 완료. dev 앱을 1회 재기동하면 인스턴스 역할 SigV4 로 인증되어 dev-* 인덱스가 생성/색인된다."
echo "      (참고: dev DB 에 코스 데이터가 있어야 색인 결과가 채워진다.)"
