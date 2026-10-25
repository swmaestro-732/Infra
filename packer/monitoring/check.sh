#!/bin/bash
# AWS 접근 없이 두 user_data 경로와 이미지 버전 동기화를 검사한다.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CHECK_DIR=$(mktemp -d)
trap 'rm -rf "$CHECK_DIR"' EXIT
TEMPLATE="$REPO_ROOT/terraform/modules/monitoring/templates/user_data.sh.tftpl"

for golden in false true; do
  terraform -chdir="$CHECK_DIR" console <<HCL | tr -d '"\n' | base64 -d > "$CHECK_DIR/$golden.sh"
base64encode(templatefile("$TEMPLATE", merge({for key in ["aws_region", "grafana_secret_name", "slack_webhook_secret_name", "loki_config", "tempo_config", "mimir_config", "grafana_ds", "grafana_dashboards_provider", "grafana_alert_contactpoints", "grafana_alert_policies", "grafana_alert_rules", "cloudwatch_config", "dashboards_bucket", "dashboards_hash", "prometheus_cfg", "compose"] : key => "test"}, {golden_ami = $golden})))
HCL
  bash -n "$CHECK_DIR/$golden.sh"
  sed -n '/^# ───────── 관측 데이터용 EBS 마운트/,$p' "$CHECK_DIR/$golden.sh" > "$CHECK_DIR/$golden.runtime"
done

grep -q '^dnf install -y docker jq$' "$CHECK_DIR/false.sh"
grep -q '^  dd if=/dev/zero of=/swapfile' "$CHECK_DIR/false.sh"
if grep -Eq '^(dnf |  dd |curl .*compose/releases|  curl .*awscli)' "$CHECK_DIR/true.sh"; then
  echo 'FAIL: golden user_data still installs packages or swap' >&2
  exit 1
fi
for tool in docker aws jq; do
  grep -q "^command -v $tool " "$CHECK_DIR/true.sh"
done
grep -q '^docker compose version ' "$CHECK_DIR/true.sh"
[ -s "$CHECK_DIR/false.runtime" ]

# 안정-5 config: golden 은 재작성 생략(AMI 에 베이크), non-golden 은 기록(AMI 없음).
BAKED=(
  /opt/monitoring/loki/config.yaml
  /opt/monitoring/tempo/config.yaml
  /opt/monitoring/mimir/mimir.yaml
  /opt/monitoring/grafana/provisioning/datasources/datasources.yaml
  /opt/monitoring/grafana/provisioning/dashboards/dashboards.yaml
)
for d in "${BAKED[@]}"; do
  grep -Fq "> $d" "$CHECK_DIR/false.sh" || { echo "FAIL: non-golden 이 $d 미작성" >&2; exit 1; }
  ! grep -Fq "> $d" "$CHECK_DIR/true.sh" || { echo "FAIL: golden 이 구운 config $d 를 재작성" >&2; exit 1; }
done
# TF값/시크릿/가변 config 는 양쪽 다 런타임 기록.
for d in \
  /opt/monitoring/prometheus/prometheus.yml \
  /opt/monitoring/cloudwatch/config.yml \
  /opt/monitoring/grafana/provisioning/alerting/rules.yaml \
  /opt/monitoring/docker-compose.yml; do
  grep -Fq "> $d" "$CHECK_DIR/true.sh" || { echo "FAIL: golden 이 $d 미작성" >&2; exit 1; }
  grep -Fq "> $d" "$CHECK_DIR/false.sh" || { echo "FAIL: non-golden 이 $d 미작성" >&2; exit 1; }
done
# golden 런타임 == non-golden 런타임에서 구운-5 작성줄만 제외(그 외 EBS/대시보드/시크릿/compose 는 동일).
printf '%s\n' "${BAKED[@]}" | sed 's#^#> #' > "$CHECK_DIR/baked.patterns"
grep -vF -f "$CHECK_DIR/baked.patterns" "$CHECK_DIR/false.runtime" > "$CHECK_DIR/false.runtime.nb"
cmp "$CHECK_DIR/false.runtime.nb" "$CHECK_DIR/true.runtime"
# 드리프트 가드: ansible 이 굽는 config 집합 == golden user_data 가 생략하는 config 집합.
grep -oE 'dest: /opt/monitoring/\S+' "$REPO_ROOT/packer/monitoring/ansible/roles/monitoring/tasks/main.yml" \
  | sed 's/dest: //' | LC_ALL=C sort > "$CHECK_DIR/ansible-baked"
comm -23 \
  <(grep -oE '> /opt/monitoring/\S+' "$CHECK_DIR/false.sh" | sed 's/> //' | LC_ALL=C sort -u) \
  <(grep -oE '> /opt/monitoring/\S+' "$CHECK_DIR/true.sh" | sed 's/> //' | LC_ALL=C sort -u) \
  > "$CHECK_DIR/udata-baked"
cmp "$CHECK_DIR/ansible-baked" "$CHECK_DIR/udata-baked"

grep -Fq "\${DATA_DEV}" "$CHECK_DIR/true.sh"
grep -Fq "\${DS_PROMETHEUS}" "$CHECK_DIR/true.sh"

GRAFANA_VERSION=$(sed -n '/^variable "grafana_version" {/,/^}/s/.*default *= "\([^"]*\)"/\1/p' "$REPO_ROOT/terraform/modules/monitoring/variables.tf")
sed -n 's/^ *image: //p' "$REPO_ROOT/terraform/modules/monitoring/templates/docker-compose.yml.tftpl" \
  | sed "s/\${grafana_version}/$GRAFANA_VERSION/" | LC_ALL=C sort > "$CHECK_DIR/compose-images"
awk '/^lgtm_images:/{f=1;next} f&&/^[^[:space:]-]/{f=0} f&&/^[[:space:]]*-[[:space:]]/{sub(/^[[:space:]]*-[[:space:]]*/,"");print}' \
  "$REPO_ROOT/packer/monitoring/ansible/roles/monitoring/defaults/main.yml" \
  | LC_ALL=C sort > "$CHECK_DIR/baked-images"
cmp "$CHECK_DIR/compose-images" "$CHECK_DIR/baked-images"
echo 'PASS: user_data 양경로 + 안정-5 베이크 분리(ansible↔user_data 동기) + 런타임 동일 + 이스케이프 + 이미지 버전'
