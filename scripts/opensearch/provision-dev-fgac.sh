#!/usr/bin/env bash
#
# dev 앱용 OpenSearch FGAC 프로비저닝 (SCRUM-567)
# ─────────────────────────────────────────────────────────────────────────────
# dev 는 새 도메인 없이 prod OpenSearch 도메인을 인덱스 네임스페이스(dev-*)로 격리 공유한다.
# environments/dev 가 dev 전용 자격증명 시크릿(chilsami/dev/opensearch)과
# OPENSEARCH_INDEX_PREFIX=dev- 를 앱에 주입하지만, 그 자격증명에 해당하는 "도메인 내부
# 유저/롤/롤매핑"은 자동 생성되지 않는다 — FGAC 객체는 AWS API 가 아니라 도메인 보안플러그인의
# _plugins/_security REST 로만 만들어지고, 도메인은 VPC 내부 전용이라 CI 에서 못 닿기 때문.
# 이 스크립트가 그 1회성 프로비저닝을 SSM 터널 경유로 수행한다.
#
# 멱등: 모두 PUT(원하는 상태로 덮어쓰기)이라 몇 번 다시 돌려도 안전하다.
#   dev 시크릿을 회전(random_password.dev_opensearch)하면 유저 비번이 어긋나 앱이 401 →
#   그때 이 스크립트를 다시 실행하면 비번이 재동기화된다.
#
# 사전조건:
#   - AWS_PROFILE 이 master + dev 시크릿을 모두 read 할 수 있어야 함(관리자 chilsami).
#     chilsami-infra(최소권한)는 dev 시크릿 read 불가.  →  aws sso login --profile chilsami
#   - session-manager-plugin 설치(SSM 포트포워딩용).
# 사용: AWS_PROFILE=chilsami ./provision-dev-fgac.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-chilsami}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
LOCAL_PORT="${LOCAL_PORT:-9243}"
JUMP_NAME_TAG="${JUMP_NAME_TAG:-chilsami-app}" # 도메인 443 에 닿는 running 인스턴스(점프 호스트)
ROLE_NAME="dev_app"
export AWS_PROFILE AWS_REGION

need() { command -v "$1" >/dev/null 2>&1 || { echo "필요한 명령 없음: $1" >&2; exit 1; }; }
need aws; need curl; need python3

echo "[1/5] 시크릿 로드 (AWS_PROFILE=$AWS_PROFILE, region=$AWS_REGION)"
secret() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text; }
MASTER_JSON=$(secret chilsami/opensearch/master)
DEV_JSON=$(secret chilsami/dev/opensearch)
jget() { python3 -c "import sys,json;print(json.load(sys.stdin)['$1'])"; }
MU=$(printf '%s' "$MASTER_JSON" | jget username)
MP=$(printf '%s' "$MASTER_JSON" | jget password)
OSH=$(printf '%s' "$MASTER_JSON" | jget endpoint)
export DU DP
DU=$(printf '%s' "$DEV_JSON" | jget username)
DP=$(printf '%s' "$DEV_JSON" | jget password)
echo "  dev username: $DU   domain: $OSH"

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
trap 'kill "$PF" 2>/dev/null || true' EXIT

BASE="https://localhost:$LOCAL_PORT"
# master basic auth. --retry 로 터널 준비될 때까지 대기. -k: 터널 localhost SNI 가 도메인 인증서와 불일치.
put() { # label path body
  local code
  code=$(curl -s -k -o /tmp/os-fgac-resp.json -w '%{http_code}' \
    --retry 30 --retry-delay 1 --retry-all-errors --connect-timeout 3 \
    -u "$MU:$MP" -H 'Content-Type: application/json' -X PUT "$BASE$2" --data "$3")
  case "$code" in
    200 | 201) echo "  [$1] OK ($code)" ;;
    *) echo "  [$1] 실패 HTTP $code: $(cat /tmp/os-fgac-resp.json)" >&2; exit 1 ;;
  esac
}

echo "[3/5] 롤/유저/롤매핑 PUT (멱등)"
# 롤: dev-* 인덱스 전체권한(indices_all) — prod course_v1/place_v1 등은 접근 불가(격리).
#     클러스터는 복합연산(_bulk/_mget/_msearch) + 헬스/스탯 모니터로 한정.
ROLE_BODY='{"cluster_permissions":["cluster_composite_ops","cluster_monitor"],"index_permissions":[{"index_patterns":["dev-*"],"allowed_actions":["indices_all"]}]}'
put "role:$ROLE_NAME" "/_plugins/_security/api/roles/$ROLE_NAME" "$ROLE_BODY"

# 유저: 비번은 dev 시크릿 값 그대로. json.dumps 로 안전하게 직렬화(특수문자 대비), 로그 미출력.
USER_BODY=$(python3 -c 'import json,os;print(json.dumps({"password":os.environ["DP"]}))')
put "user:$DU" "/_plugins/_security/api/internalusers/$DU" "$USER_BODY"

MAP_BODY=$(python3 -c 'import json,os;print(json.dumps({"users":[os.environ["DU"]]}))')
put "rolesmapping:$ROLE_NAME" "/_plugins/_security/api/rolesmapping/$ROLE_NAME" "$MAP_BODY"

echo "[4/5] 검증: dev 자격증명으로 실제 인증되는지 (401 이면 실패)"
code=$(curl -s -k -o /dev/null -w '%{http_code}' --retry 10 --retry-delay 1 --retry-all-errors \
  -u "$DU:$DP" "$BASE/")
echo "  dev 자격증명 인증 HTTP: $code"
[ "$code" = "200" ] || { echo "  dev 자격증명 인증 실패 — 유저/비번 불일치 의심" >&2; exit 1; }

echo "[5/5] 완료. dev 앱을 1회 재기동하면 dev-* 인덱스가 생성/색인되고 검색이 복구된다."
echo "      (참고: dev DB 에 코스 데이터가 있어야 색인 결과가 채워진다.)"
