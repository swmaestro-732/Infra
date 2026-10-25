#!/bin/bash
set -euo pipefail

# 런타임 user_data와 동일한 2GB swap. sysctl 값은 다음 부팅에도 유지한다.
if ! swapon --show | grep -q /swapfile; then
  dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
echo 'vm.swappiness=10' > /etc/sysctl.d/99-monitoring-swap.conf
sysctl -w vm.swappiness=10

dnf update -y
dnf install -y docker jq unzip
systemctl enable docker
systemctl start docker

mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# AL2023에 AWS CLI v2가 이미 있으면 그대로 사용한다.
if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL 'https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip' -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi

docker compose version
aws --version | grep -q '^aws-cli/2\.'
jq --version

# docker-compose.yml.tftpl과 버전 동기화 필요 (Grafana는 variables.tf의 grafana_version 기본값).
docker pull grafana/grafana:11.2.0
docker pull quay.io/prometheuscommunity/yet-another-cloudwatch-exporter:v0.67.0
docker pull prom/prometheus:v2.54.1
docker pull grafana/mimir:2.13.0
docker pull grafana/loki:3.1.1
docker pull grafana/tempo:2.6.0

dnf clean all
