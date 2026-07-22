# 최신 Amazon Linux 2023 AMI (SSM 공개 파라미터)
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  # ECR URL 미설정 시 nginx 플레이스홀더, 설정 시 ECR 이미지 + Secrets Manager DB접속으로 앱 기동
  app_run = var.ecr_repository_url == "" ? "docker run -d --restart always -p ${var.app_port}:80 --name app nginx:alpine" : <<-RUN
    # aws cli 설치 (AL2023 기본 미포함 대비)
    if ! command -v aws >/dev/null 2>&1; then
      dnf install -y unzip
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
      unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install
    fi
    aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${var.ecr_repository_url == "" ? "_" : split("/", var.ecr_repository_url)[0]}

    SECRET=$(aws secretsmanager get-secret-value --secret-id ${var.db_secret_name} --region ${var.aws_region} --query SecretString --output text)
    DB_HOST=$(echo "$SECRET" | jq -r .writer_host)
    DB_NAME=$(echo "$SECRET" | jq -r .dbname)
    DB_USER=$(echo "$SECRET" | jq -r .username)
    DB_PASS=$(echo "$SECRET" | jq -r .password)
    DB_PORT=$(echo "$SECRET" | jq -r .port)

    # Kakao OAuth·JWT — 값은 배포 후 콘솔/CLI로 수동 설정 (root의 aws_secretsmanager_secret.app_config 참고)
    APP_SECRET=$(aws secretsmanager get-secret-value --secret-id ${var.app_config_secret_name} --region ${var.aws_region} --query SecretString --output text)
    KAKAO_CLIENT_ID=$(echo "$APP_SECRET" | jq -r .kakao_client_id)
    JWT_SECRET=$(echo "$APP_SECRET" | jq -r .jwt_secret)

    # 미디어 CDN 도메인 — CloudFront 생성 후에나 알 수 있어 SSM Parameter로 런타임 조회 (media 모듈과 순환 의존 회피)
    MEDIA_CDN_URL=$(aws ssm get-parameter --name "${var.media_cdn_ssm_param_name}" --region ${var.aws_region} --query Parameter.Value --output text)

    docker pull ${var.ecr_repository_url}:latest
    docker rm -f app 2>/dev/null || true
    docker run -d --restart always -p ${var.app_port}:8080 --name app \
      -e SPRING_DATASOURCE_URL="jdbc:postgresql://$DB_HOST:$DB_PORT/$DB_NAME" \
      -e SPRING_DATASOURCE_USERNAME="$DB_USER" \
      -e SPRING_DATASOURCE_PASSWORD="$DB_PASS" \
      -e AWS_REGION="${var.aws_region}" \
      -e S3_MEDIA_BUCKET="${var.s3_media_bucket}" \
      -e S3_MEDIA_CDN_URL="$MEDIA_CDN_URL" \
      -e KAKAO_CLIENT_ID="$KAKAO_CLIENT_ID" \
      -e JWT_SECRET="$JWT_SECRET" \
      ${var.ecr_repository_url}:latest
  RUN
}

# 규칙은 standalone 리소스로 관리한다. 다른 모듈(monitoring)이 이 SG 에 스크레이프 인그레스를
# aws_security_group_rule 로 추가하므로, inline 규칙과 섞이면 perpetual diff/규칙 덮어쓰기가 발생한다.
resource "aws_security_group" "instance" {
  name        = "${var.name}-ec2-sg"
  description = "app instances (from ALB only)"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name}-ec2-sg" }
}

resource "aws_security_group_rule" "instance_ingress_alb" {
  type                     = "ingress"
  description              = "from ALB"
  from_port                = var.app_port
  to_port                  = var.app_port
  protocol                 = "tcp"
  security_group_id        = aws_security_group.instance.id
  source_security_group_id = var.alb_sg_id
}

resource "aws_security_group_rule" "instance_egress_all" {
  type              = "egress"
  description       = "all"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.instance.id
}

# ───────── IAM (SSM 접속 + 추후 ECR pull 확장) ─────────
resource "aws_iam_role" "ec2" {
  name = "${var.name}-ec2-role"

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
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ECR 이미지 pull (CD에서 배포한 백엔드 이미지)
resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ───────── Launch Template (Docker 부트스트랩, IMDSv2) ─────────
resource "aws_launch_template" "this" {
  name_prefix   = "${var.name}-lt-"
  image_id      = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.ec2.arn
  }

  vpc_security_group_ids = [aws_security_group.instance.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 강제
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = false # basic monitoring(5분·무료). 필요 시 true로 detailed(1분·유료)
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -euo pipefail

    # swap 2GB (t3.small RAM 2GB 보완 — 컨테이너 OOM 방지)
    if ! swapon --show | grep -q /swapfile; then
      dd if=/dev/zero of=/swapfile bs=1M count=2048
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
      sysctl -w vm.swappiness=10
    fi

    dnf update -y
    dnf install -y docker jq
    systemctl enable --now docker

    # 앱 기동 (ECR 이미지 + Secrets Manager DB접속) 또는 nginx 플레이스홀더
    ${local.app_run}
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-app" }
  }
}

# ───────── Auto Scaling Group (멀티 AZ, ALB 타깃) ─────────
resource "aws_autoscaling_group" "this" {
  name                      = "${var.name}-asg"
  vpc_zone_identifier       = var.app_subnet_ids
  desired_capacity          = var.desired_capacity
  min_size                  = var.min_size
  max_size                  = var.max_size
  target_group_arns         = [var.target_group_arn]
  health_check_type         = "ELB"
  health_check_grace_period = 120

  launch_template {
    id = aws_launch_template.this.id
    # "$Latest"는 Terraform이 LT 버전 변경을 감지하지 못해 instance_refresh가 안 돌 수 있음.
    # latest_version 참조로 LT 변경 시 ASG diff → 롤링 교체 보장.
    version = aws_launch_template.this.latest_version
  }

  # 런치템플릿(user_data 등) 변경 시 롤링으로 인스턴스 교체 (새 이미지 무중단 배포).
  # launch_template 변경은 기본적으로 refresh 를 트리거하므로 별도 triggers 불필요.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 180 # 앱 부팅+헬스 안정화 시간
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name}-app"
    propagate_at_launch = true
  }
}
