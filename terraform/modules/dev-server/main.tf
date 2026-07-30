# =============================================================================
# dev 개발 서버 — develop 이미지를 돌리는 단일 인스턴스(ALB/ASG 없음, private).
# 공개 노출 없음: SSM 포트포워딩(인스턴스 localhost)으로만 접근한다.
# DB 는 prod RDS 인스턴스를 공유하되 별도 DB(dev_db_name)를 쓴다.
# CD 는 최초 부팅(user_data) 이후 SSM send-command 로 재배포한다(docker pull + 재기동).
# =============================================================================

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  # 배포 로직(로그인→시크릿 fetch→docker pull→run). 인스턴스의 /usr/local/bin/dev-redeploy.sh 로 심어두고
  # 부팅 시 1회 실행 + CD 가 SSM send-command 로 재실행한다(단일 소스). dev 오버라이드: 프로파일=dev,
  # DB=dev_db_name, 이미지 태그=image_tag. 이미지 태그가 아직 없으면(첫 CD 전) pull 실패 → 이후 CD 로 정상.
  deploy_script = <<-RUN
    aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${split("/", var.ecr_repository_url)[0]}

    # 시크릿 수동 주입 지연 대비 재시도. dev 는 짧게(최대 12회 ~5.5분) — 영구오류(AccessDenied 등)로 오래 매달리지 않는다.
    retry() {
      local n=1
      until "$@"; do
        if [ $n -ge 12 ]; then echo "retry: '$*' 가 $n 회 실패 — 중단" >&2; return 1; fi
        echo "retry $n/12: '$*' 실패, 재시도 대기…" >&2
        sleep $((n * 5))
        n=$((n + 1))
      done
    }

    # prod RDS 시크릿에서 접속정보 — DB 이름만 dev 로 오버라이드(격리).
    SECRET=$(retry aws secretsmanager get-secret-value --secret-id ${var.db_secret_name} --region ${var.aws_region} --query SecretString --output text)
    DB_HOST=$(echo "$SECRET" | jq -r .writer_host)
    DB_USER=$(echo "$SECRET" | jq -r .username)
    DB_PASS=$(echo "$SECRET" | jq -r .password)
    DB_PORT=$(echo "$SECRET" | jq -r .port)

    APP_SECRET=$(retry aws secretsmanager get-secret-value --secret-id ${var.app_config_secret_name} --region ${var.aws_region} --query SecretString --output text)
    KAKAO_CLIENT_ID=$(echo "$APP_SECRET" | jq -r .kakao_client_id)
    JWT_SECRET=$(echo "$APP_SECRET" | jq -r .jwt_secret)
    KAKAO_REST_API_KEY=$(echo "$APP_SECRET" | jq -r '.kakao_rest_api_key // ""')
    TMAP_APP_KEY=$(echo "$APP_SECRET" | jq -r '.tmap_app_key // ""')

    MEDIA_CDN_URL=$(retry aws ssm get-parameter --name "${var.media_cdn_ssm_param_name}" --region ${var.aws_region} --query Parameter.Value --output text)

    # pull 실패는 즉시 종료(set -e) — 옛 컨테이너를 지우기 전에 멈춰 롤백 없이 기존 서비스 유지.
    # 첫 부팅(이미지 없음) 허용은 호출부(user_data 의 '|| true')가 담당한다.
    docker pull ${var.ecr_repository_url}:${var.image_tag}
    docker rm -f app 2>/dev/null || true
    docker run -d --restart always -p ${var.app_port}:8080 --name app \
      -e SPRING_DATASOURCE_URL="jdbc:postgresql://$DB_HOST:$DB_PORT/${var.dev_db_name}" \
      -e SPRING_DATASOURCE_USERNAME="$DB_USER" \
      -e SPRING_DATASOURCE_PASSWORD="$DB_PASS" \
      -e AWS_REGION="${var.aws_region}" \
      -e S3_MEDIA_BUCKET="${var.s3_media_bucket}" \
      -e S3_MEDIA_CDN_URL="$MEDIA_CDN_URL" \
      -e KAKAO_CLIENT_ID="$KAKAO_CLIENT_ID" \
      -e JWT_SECRET="$JWT_SECRET" \
      -e KAKAO_REST_API_KEY="$KAKAO_REST_API_KEY" \
      -e TMAP_APP_KEY="$TMAP_APP_KEY" \
      -e SPRING_PROFILES_ACTIVE="dev" \
      ${var.ecr_repository_url}:${var.image_tag}
  RUN
}

# ───────── SG: egress 만. SSM 포트포워딩은 인스턴스 localhost 로 붙으므로 인바운드 불필요. ─────────
resource "aws_security_group" "dev" {
  name        = "${var.name}-dev-sg"
  description = "dev app instance (private, SSM only; no inbound)"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-dev-sg" }
}

resource "aws_security_group_rule" "dev_egress_all" {
  type              = "egress"
  description       = "all"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.dev.id
}

# ───────── IAM: SSM 접속 + ECR pull. 시크릿 read 는 환경(prod/main.tf)에서 부여. ─────────
resource "aws_iam_role" "dev" {
  name = "${var.name}-dev-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.dev.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.dev.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "dev" {
  name = "${var.name}-dev-ec2-profile"
  role = aws_iam_role.dev.name
}

# ───────── 단일 인스턴스(ASG/ALB 없음) ─────────
resource "aws_instance" "dev" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.dev.id]
  iam_instance_profile   = aws_iam_instance_profile.dev.name

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 강제
  }

  # user_data(배포 스크립트 등) 변경은 인스턴스 교체로 반영한다. 기존 인스턴스는 user_data 를
  # 재실행하지 않아 /usr/local/bin/dev-redeploy.sh 가 오래되므로, 교체로 최신 스크립트를 심는다.
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail

    if ! swapon --show | grep -q /swapfile; then
      dd if=/dev/zero of=/swapfile bs=1M count=2048
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
      sysctl -w vm.swappiness=10
    fi

    dnf update -y
    dnf install -y docker jq unzip
    systemctl enable --now docker

    # aws cli (AL2023 기본 미포함)
    if ! command -v aws >/dev/null 2>&1; then
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
      unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install
    fi

    # 배포 스크립트를 심어둔다(중첩 heredoc 회피 위해 base64) — CD 가 SSM send-command 로 재실행해 재배포한다.
    echo "${base64encode("#!/bin/bash\nset -euo pipefail\n${local.deploy_script}")}" | base64 -d > /usr/local/bin/dev-redeploy.sh
    chmod +x /usr/local/bin/dev-redeploy.sh

    # 최초 1회 실행(이미지 없으면 실패해도 부팅은 계속 — 이후 CD 가 배포).
    /usr/local/bin/dev-redeploy.sh || true
  EOF

  tags = { Name = var.name_tag }

  # AL2023 SSM 파라미터가 새 AMI 로 갱신돼도 dev 인스턴스를 자동 교체하지 않는다
  # (배포는 SSM send-command 로 하므로 재생성 불필요). AMI 갱신은 필요 시 수동으로.
  lifecycle {
    ignore_changes = [ami]
  }
}
