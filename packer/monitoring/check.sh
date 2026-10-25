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
cmp "$CHECK_DIR/false.runtime" "$CHECK_DIR/true.runtime"
grep -Fq "\${DATA_DEV}" "$CHECK_DIR/true.sh"
grep -Fq "\${DS_PROMETHEUS}" "$CHECK_DIR/true.sh"

GRAFANA_VERSION=$(sed -n '/^variable "grafana_version" {/,/^}/s/.*default *= "\([^"]*\)"/\1/p' "$REPO_ROOT/terraform/modules/monitoring/variables.tf")
sed -n 's/^ *image: //p' "$REPO_ROOT/terraform/modules/monitoring/templates/docker-compose.yml.tftpl" \
  | sed "s/\${grafana_version}/$GRAFANA_VERSION/" | LC_ALL=C sort > "$CHECK_DIR/compose-images"
awk '/^lgtm_images:/{f=1;next} f&&/^[^[:space:]-]/{f=0} f&&/^[[:space:]]*-[[:space:]]/{sub(/^[[:space:]]*-[[:space:]]*/,"");print}' \
  "$REPO_ROOT/packer/monitoring/ansible/roles/monitoring/defaults/main.yml" \
  | LC_ALL=C sort > "$CHECK_DIR/baked-images"
cmp "$CHECK_DIR/compose-images" "$CHECK_DIR/baked-images"
echo 'PASS: both user_data branches, unchanged runtime, shell escapes, image versions'
