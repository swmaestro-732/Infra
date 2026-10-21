#!/usr/bin/env bash
#
# OpenSearch FGAC 프로비저닝 — dev 앱 격리 롤 + 사람용 admin 내부 사용자 (SCRUM-567, SCRUM-675)
# ─────────────────────────────────────────────────────────────────────────────
# dev 는 새 도메인 없이 prod OpenSearch 도메인을 인덱스 네임스페이스(dev-*)로 격리 공유한다.
# dev 앱은 자기 EC2 인스턴스 역할로 요청에 SigV4 서명해 붙는다(비밀번호 없음). 도메인은 그 IAM
# 역할 ARN 을 backend_role 로 보고 dev_app 롤(dev-* 한정)의 권한을 부여한다.
# 사람은 내부 사용자 admin(시크릿 chilsami/opensearch/master 의 비밀번호)으로 Dashboards 에 로그인한다.
#
# FGAC 롤/롤매핑은 클러스터 안 보안 인덱스에 저장돼, 단일 노드 교체로 클러스터가 재생성되면 사라진다.
# 그때 이 스크립트를 다시 돌린다. 마스터는 prod 앱 IAM 역할(chilsami-ec2-role)이라 도메인 설정에 남아 있다.
#
# 인증: 마스터 역할을 assume 한 임시 자격증명으로 curl --aws-sigv4 서명한다(비밀번호 없음).
# 보안: 도메인은 공인 CA(Amazon) 인증서를 쓰므로 TLS 를 검증한다 — curl --connect-to 로 TLS 호스트명은
#   실제 도메인으로 유지하고 연결만 로컬 터널(localhost)로 보낸다('-k' 미사용 → 터널 포트 선점 MITM 방지).
#   임시 자격증명은 프로세스 인자(ps 노출) 대신 600 권한 curl 설정파일(-K)로 전달하고 종료 시 삭제한다.
#
# 멱등: 모두 PUT(원하는 상태로 덮어쓰기)이라 몇 번 다시 돌려도 안전하다.
#
# 사전조건:
#   - AWS_PROFILE 이 마스터 역할 assume + iam get-role + 시크릿 read + opensearch describe-domain 가능해야 함(SSO 관리자 chilsami).
#     →  aws sso login --profile chilsami
#   - session-manager-plugin 설치(SSM 포트포워딩용), curl 7.75 이상(--aws-sigv4).
# 사용: AWS_PROFILE=chilsami ./provision-dev-fgac.sh
#   클러스터 재생성 후, 또는 시크릿 비밀번호를 회전한 뒤 다시 돌린다.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-chilsami}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
LOCAL_PORT="${LOCAL_PORT:-9243}"
DOMAIN_NAME="${DOMAIN_NAME:-chilsami-search}"
MASTER_ROLE_NAME="${MASTER_ROLE_NAME:-chilsami-ec2-role}" # FGAC 마스터(prod 앱 역할). SSO 관리자만 assume 가능
JUMP_NAME_TAG="${JUMP_NAME_TAG:-chilsami-app}" # 도메인 443 에 닿는 running 인스턴스(점프 호스트)
DEV_ROLE_NAME="${DEV_ROLE_NAME:-chilsami-dev-ec2-role}" # backend_role 로 매핑할 dev 인스턴스 역할
ADMIN_SECRET="${ADMIN_SECRET:-chilsami/opensearch/master}" # 사람용 admin 자격증명(username/password)
ROLE_NAME="dev_app"
export AWS_PROFILE AWS_REGION

PF=""
CURL_CFG=""
USER_BODY_FILE=""
cleanup() {
  [ -n "$PF" ] && kill "$PF" 2>/dev/null || true
  [ -n "$CURL_CFG" ] && rm -f "$CURL_CFG" || true
  [ -n "$USER_BODY_FILE" ] && rm -f "$USER_BODY_FILE" || true
}
trap cleanup EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "필요한 명령 없음: $1" >&2; exit 1; }; }
need aws; need curl; need python3

echo "[1/6] 도메인, 역할 ARN 조회 + 마스터 역할 assume (AWS_PROFILE=$AWS_PROFILE)"
OSH=$(aws opensearch describe-domain --domain-name "$DOMAIN_NAME" --query 'DomainStatus.Endpoints.vpc' --output text)
MASTER_ROLE_ARN=$(aws iam get-role --role-name "$MASTER_ROLE_NAME" --query 'Role.Arn' --output text)
DEV_ROLE_ARN=$(aws iam get-role --role-name "$DEV_ROLE_NAME" --query 'Role.Arn' --output text)
ADMIN_JSON=$(aws secretsmanager get-secret-value --secret-id "$ADMIN_SECRET" --query SecretString --output text)
CREDS=$(aws sts assume-role --role-arn "$MASTER_ROLE_ARN" --role-session-name provision-fgac \
  --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
echo "  domain: $OSH"
echo "  master role: $MASTER_ROLE_ARN"
echo "  dev role(backend_role): $DEV_ROLE_ARN"

# 임시 자격증명을 argv(ps 노출) 대신 600 권한 설정파일로 전달한다.
CURL_CFG=$(mktemp)
chmod 600 "$CURL_CFG"
read -r AK SK ST <<<"$CREDS"
printf 'user = "%s:%s"\nheader = "x-amz-security-token: %s"\naws-sigv4 = "aws:amz:%s:es"\n' "$AK" "$SK" "$ST" "$AWS_REGION" >"$CURL_CFG"
unset CREDS AK SK ST

echo "[2/6] SSM 터널 오픈 (localhost:$LOCAL_PORT → $OSH:443)"
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
# --connect-to: TLS 호스트명·인증서(그리고 SigV4 서명 Host)는 실제 도메인($OSH)으로 두고 TCP 연결만 로컬 터널로 보낸다.
CURL_COMMON=(-s --retry 30 --retry-delay 1 --retry-all-errors --connect-timeout 3
  --connect-to "$OSH:443:localhost:$LOCAL_PORT" -K "$CURL_CFG")

call() { # label method path [body]
  local code
  code=$(curl "${CURL_COMMON[@]}" -o /tmp/os-fgac-resp.json -w '%{http_code}' \
    -H 'Content-Type: application/json' -X "$2" "$BASE$3" ${4:+--data "$4"})
  case "$code" in
    200 | 201) echo "  [$1] OK ($code)" ;;
    *) echo "  [$1] 실패 HTTP $code: $(cat /tmp/os-fgac-resp.json)" >&2; exit 1 ;;
  esac
}

echo "[3/6] 마스터 인증 확인"
call "authinfo" GET "/_plugins/_security/authinfo"

echo "[4/6] dev_app 롤/롤매핑 PUT (멱등)"
# 롤: dev-* 인덱스 전체권한(indices_all) — prod place/course 인덱스는 접근 불가(격리).
#     클러스터는 복합연산(_bulk/_mget/_msearch) + 헬스/스탯 모니터로 한정.
ROLE_BODY='{"cluster_permissions":["cluster_composite_ops","cluster_monitor"],"index_permissions":[{"index_patterns":["dev-*"],"allowed_actions":["indices_all"]}]}'
call "role:$ROLE_NAME" PUT "/_plugins/_security/api/roles/$ROLE_NAME" "$ROLE_BODY"
export DEV_ROLE_ARN
MAP_BODY=$(python3 -c 'import json,os;print(json.dumps({"backend_roles":[os.environ["DEV_ROLE_ARN"]]}))')
call "rolesmapping:$ROLE_NAME" PUT "/_plugins/_security/api/rolesmapping/$ROLE_NAME" "$MAP_BODY"

echo "[5/6] 사람용 내부 사용자 admin PUT (시크릿 비밀번호로 생성/갱신)"
# 본문은 python 으로 만들어 비밀번호 특수문자도 안전하게 이스케이프하고, argv(ps 노출) 대신 600 권한 파일로 넘긴다.
USER_BODY_FILE=$(mktemp)
chmod 600 "$USER_BODY_FILE"
printf '%s' "$ADMIN_JSON" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(json.dumps({"password":d["password"],"backend_roles":[]}))' >"$USER_BODY_FILE"
ADMIN_USER=$(printf '%s' "$ADMIN_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["username"])')
unset ADMIN_JSON
call "internalusers:$ADMIN_USER" PUT "/_plugins/_security/api/internalusers/$ADMIN_USER" "@$USER_BODY_FILE"
rm -f "$USER_BODY_FILE"

echo "[6/6] admin 을 all_access, security_manager 에 추가 (기존 매핑, 특히 마스터 IAM 역할은 유지)"
export ADMIN_USER
for r in all_access security_manager; do
  call "get:$r" GET "/_plugins/_security/api/rolesmapping/$r"
  BODY=$(python3 -c '
import json,os,sys
m=json.load(open("/tmp/os-fgac-resp.json")).get(sys.argv[1],{})
users=sorted(set(m.get("users",[]))|{os.environ["ADMIN_USER"]})
print(json.dumps({"backend_roles":m.get("backend_roles",[]),"hosts":m.get("hosts",[]),"users":users}))' "$r")
  call "rolesmapping:$r" PUT "/_plugins/_security/api/rolesmapping/$r" "$BODY"
done

echo "완료. dev 앱을 1회 재기동하면 dev-* 인덱스가 생성/색인된다. 사람은 Dashboards 에 admin/시크릿 비밀번호로 로그인한다."
