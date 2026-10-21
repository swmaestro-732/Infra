#!/usr/bin/env bash
#
# OpenSearch 클러스터 재생성 후 복구 (SCRUM-675)
# ─────────────────────────────────────────────────────────────────────────────
# 단일 노드 시절 노드가 교체되며 클러스터가 빈 상태로 다시 만들어졌다(2026-10-20, 21). 지금은 2노드라 드물지만,
# 그래도 유실되면 인덱스와 함께 보안 인덱스도 초기화돼 다음 세 가지가 깨진다. 이 스크립트가 순서대로 되살린다.
#   1. 마스터(admin) 비밀번호가 시크릿과 어긋나 401 → 비밀번호 재지정
#      같은 값으로 update-domain-config 하면 "변경 없음"으로 무시되므로 임시 값으로 바꿨다가 시크릿 값으로 되돌린다.
#      마스터 로그인이 이미 되면 건너뛴다(정상 상태에서 실행해도 prod 가 401 을 겪지 않게).
#   2. dev 앱 FGAC 롤/매핑(dev_app) 소실 → provision-dev-fgac.sh
#   3. place/course 인덱스 소실 → 앱 재시작(기동 시 인덱스 생성 + 빈 인덱스면 DB 에서 재색인)
#      prod 는 한 대씩 재시작하고 헬스 200 을 기다려 무중단으로 돌린다.
#
# 데이터 원본은 DB 라 유실은 없다. 실행은 사람이 한다(알람: Grafana "OpenSearch 검색 문서 수 급감").
#
# 사전조건: aws sso login --profile chilsami (SSO 관리자: 도메인 설정 변경, 시크릿 read, SSM SendCommand)
# 사용: AWS_PROFILE=chilsami ./scripts/opensearch/recover-opensearch.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-chilsami}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
DOMAIN_NAME="${DOMAIN_NAME:-chilsami-search}"
MASTER_SECRET="${MASTER_SECRET:-chilsami/opensearch/master}"
PROD_TAG="${PROD_TAG:-chilsami-app}"
DEV_TAG="${DEV_TAG:-chilsami-dev-app}"
MIN_DOCS="${MIN_DOCS:-1000}" # 재색인 완료로 볼 최소 문서 수(시스템 인덱스만 남으면 약 11)
export AWS_PROFILE AWS_REGION
DIR="$(cd "$(dirname "$0")" && pwd)"

TMP_FILES=()
cleanup() { [ ${#TMP_FILES[@]} -eq 0 ] || rm -f "${TMP_FILES[@]}"; }
trap cleanup EXIT
tmpfile() { local f; f=$(mktemp); chmod 600 "$f"; TMP_FILES+=("$f"); echo "$f"; }

instances() { # tag → running 인스턴스 ID 목록
  aws ec2 describe-instances --filters "Name=tag:Name,Values=$1" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

remote() { # instance script → stdout (인스턴스 역할 자격증명으로 실행. 비밀번호는 원격에서 시크릿을 직접 읽는다)
  local f id status
  f=$(tmpfile)
  python3 -c 'import json,sys;print(json.dumps({"InstanceIds":[sys.argv[1]],"DocumentName":"AWS-RunShellScript","Parameters":{"commands":[sys.argv[2]],"executionTimeout":["900"]}}))' "$1" "$2" >"$f"
  id=$(aws ssm send-command --cli-input-json "file://$f" --query Command.CommandId --output text)
  while :; do
    status=$(aws ssm get-command-invocation --command-id "$id" --instance-id "$1" --query Status --output text 2>/dev/null || echo Pending)
    case "$status" in Pending | InProgress | Delayed) sleep 3 ;; *) break ;; esac
  done
  aws ssm get-command-invocation --command-id "$id" --instance-id "$1" --query StandardOutputContent --output text
  [ "$status" = Success ] || { echo "원격 실행 실패($1): $status" >&2; return 1; }
}

# 원격에서 마스터 자격증명으로 OpenSearch 를 호출하는 셸 조각. 자격증명은 curl -K - (stdin)로 넘겨 ps 에 남기지 않는다.
OS_CALL="S=\$(aws secretsmanager get-secret-value --secret-id $MASTER_SECRET --region $AWS_REGION --query SecretString --output text)
H=\$(echo \"\$S\" | jq -r .endpoint)
os() { echo \"\$S\" | jq -r '\"user = \\\"\" + .username + \":\" + .password + \"\\\"\"' | curl -s -K - \"\$@\"; }"

wait_domain() { # 이전 변경 시작 시각 → 새 변경이 끝날 때까지 대기
  local s p
  for _ in $(seq 1 80); do
    s=$(aws opensearch describe-domain-change-progress --domain-name "$DOMAIN_NAME" --query 'ChangeProgressStatus.[StartTime,Status]' --output text)
    p=$(aws opensearch describe-domain --domain-name "$DOMAIN_NAME" --query 'DomainStatus.Processing' --output text)
    if [ "${s%%	*}" != "$1" ] && [[ "$s" == *COMPLETED* ]] && [ "$p" = False ]; then return 0; fi
    sleep 15
  done
  echo "도메인 변경이 20분 안에 끝나지 않음" >&2
  exit 1
}

set_master_password() { # mode(temp|secret)
  local f prev
  f=$(tmpfile)
  aws secretsmanager get-secret-value --secret-id "$MASTER_SECRET" --query SecretString --output text |
    python3 -c '
import json,secrets,sys
s=json.load(sys.stdin)
pw=s["password"] if sys.argv[1]=="secret" else "Tmp-"+secrets.token_hex(8)+"-Aa1!"
print(json.dumps({"DomainName":sys.argv[2],"AdvancedSecurityOptions":{"MasterUserOptions":{"MasterUserName":s["username"],"MasterUserPassword":pw}}}))' "$1" "$DOMAIN_NAME" >"$f"
  prev=$(aws opensearch describe-domain-change-progress --domain-name "$DOMAIN_NAME" --query 'ChangeProgressStatus.StartTime' --output text)
  aws opensearch update-domain-config --cli-input-json "file://$f" >/dev/null
  wait_domain "$prev"
}

PROD=($(instances "$PROD_TAG"))
DEV=($(instances "$DEV_TAG"))
[ ${#PROD[@]} -gt 0 ] || { echo "prod 인스턴스($PROD_TAG)를 못 찾음" >&2; exit 1; }
echo "prod: ${PROD[*]} / dev: ${DEV[*]:-(없음)}"

echo "[1/4] 마스터 로그인 확인"
code=$(remote "${PROD[0]}" "$OS_CALL
os -o /dev/null -w '%{http_code}' \"https://\$H/_plugins/_security/authinfo\"")
echo "  authinfo HTTP $code"
if [ "$code" != 200 ]; then
  echo "  마스터 비밀번호 재지정: 임시 값 → 시크릿 값 (각 1분 안팎)"
  set_master_password temp
  set_master_password secret
  code=$(remote "${PROD[0]}" "$OS_CALL
os -o /dev/null -w '%{http_code}' \"https://\$H/_plugins/_security/authinfo\"")
  [ "$code" = 200 ] || { echo "  재지정 후에도 HTTP $code" >&2; exit 1; }
  echo "  복구 OK (200)"
fi

echo "[2/4] dev FGAC 롤/매핑"
"$DIR/provision-dev-fgac.sh"

RESTART='docker restart app >/dev/null
for i in $(seq 1 60); do
  [ "$(curl -s -o /dev/null -w %{http_code} localhost:8080/actuator/health)" = 200 ] && { echo healthy; exit 0; }
  sleep 5
done
echo "health 미복구"; exit 1'

echo "[3/4] 앱 재시작 (prod 한 대씩, 그다음 dev)"
for i in "${PROD[@]}" "${DEV[@]}"; do
  echo "  $i: $(remote "$i" "$RESTART")"
done

echo "[4/4] 재색인 확인 (문서 수 >= $MIN_DOCS)"
for _ in $(seq 1 40); do
  out=$(remote "${PROD[0]}" "$OS_CALL
os \"https://\$H/_cat/indices?h=index,docs.count&s=index\" | grep -v '^\\.'")
  total=$(echo "$out" | awk '{s+=$2} END {print s+0}')
  if [ "$total" -ge "$MIN_DOCS" ]; then
    echo "$out" | sed 's/^/  /'
    echo "완료: 문서 $total 개"
    exit 0
  fi
  sleep 15
done
echo "10분 안에 문서 수가 $MIN_DOCS 에 못 미침. 앱 로그를 확인한다." >&2
exit 1
