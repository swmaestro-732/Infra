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

    # IAM 정책 전파·SSM 파라미터 생성·시크릿 값 수동 주입(fail-closed) 지연에 대비한 재시도 백오프.
    # set -euo pipefail 하에서 첫 조회 실패로 user_data 가 즉시 죽지 않도록, 값이 준비될 때까지 대기한다.
    retry() {
      local n=1
      until "$@"; do
        if [ $n -ge 30 ]; then echo "retry: '$*' 가 $n 회 실패 — 중단" >&2; return 1; fi
        echo "retry $n/30: '$*' 실패, 재시도 대기…" >&2
        sleep $((n < 12 ? n * 5 : 60))
        n=$((n + 1))
      done
    }

    SECRET=$(retry aws secretsmanager get-secret-value --secret-id ${var.db_secret_name} --region ${var.aws_region} --query SecretString --output text)
    DB_HOST=$(echo "$SECRET" | jq -r .writer_host)
    DB_NAME=$(echo "$SECRET" | jq -r .dbname)
    DB_USER=$(echo "$SECRET" | jq -r .username)
    DB_PASS=$(echo "$SECRET" | jq -r .password)
    DB_PORT=$(echo "$SECRET" | jq -r .port)

    # Kakao OAuth·JWT — 값은 배포 후 콘솔/CLI로 수동 주입(fail-closed). 값 주입 전에는 조회 실패 → 위 retry 로 대기.
    APP_SECRET=$(retry aws secretsmanager get-secret-value --secret-id ${var.app_config_secret_name} --region ${var.aws_region} --query SecretString --output text)
    KAKAO_CLIENT_ID=$(echo "$APP_SECRET" | jq -r .kakao_client_id)
    JWT_SECRET=$(echo "$APP_SECRET" | jq -r .jwt_secret)

    # 카카오 네이티브 앱 키(안드로이드/iOS SDK 로그인 id_token 의 aud) — 선택값.
    # 미주입 시 빈 값 → 앱은 웹(REST 키) 로그인만 허용(fail-soft). 필수 키와 달리 // "" 폴백.
    KAKAO_NATIVE_APP_KEY=$(echo "$APP_SECRET" | jq -r '.kakao_native_app_key // ""')

    # 지도 API 키(카카오 로컬 검색·Tmap 보행자) — kakao_client_id·jwt_secret 과 함께 필수(fail-closed). 배포 후 수동 주입.
    KAKAO_REST_API_KEY=$(echo "$APP_SECRET" | jq -r .kakao_rest_api_key)
    TMAP_APP_KEY=$(echo "$APP_SECRET" | jq -r .tmap_app_key)

    # 미디어 CDN 도메인 — CloudFront 생성 후에나 알 수 있어 SSM Parameter로 런타임 조회 (media 모듈과 순환 의존 회피)
    MEDIA_CDN_URL=$(retry aws ssm get-parameter --name "${var.media_cdn_ssm_param_name}" --region ${var.aws_region} --query Parameter.Value --output text)

    # 관측(로그/트레이스) push 대상 = 모니터링 호스트 private IP. SSM Parameter로 런타임 조회
    # (monitoring 모듈과 순환 의존 회피). 관측은 앱 기동을 막지 않도록 fail-soft — 없으면 건너뛴다.
    MON_HOST=""
    OTEL_ARGS=""
    if [ -n "${var.monitoring_host_ssm_param_name}" ]; then
      # 같은 apply 에서 monitoring 이 값을 나중에 기록할 수 있어 짧게(최대 ~1분) 재시도 후 fail-soft.
      # 모니터링 IP 변경의 완전한 자동 수렴은 인스턴스 refresh 로 처리 — 상시 재조회 데몬은 MVP 과설계라 두지 않는다.
      for _ in $(seq 1 6); do
        MON_HOST=$(aws ssm get-parameter --name "${var.monitoring_host_ssm_param_name}" --region ${var.aws_region} --query Parameter.Value --output text 2>/dev/null || echo "")
        [ -n "$MON_HOST" ] && break
        sleep 10
      done
      if [ -n "$MON_HOST" ]; then
        OTEL_ARGS="-e MANAGEMENT_TRACING_ENABLED=true -e MANAGEMENT_OTLP_TRACING_ENDPOINT=http://$MON_HOST:4318/v1/traces"
      fi
    fi

    docker pull ${var.ecr_repository_url}:latest
    docker rm -f app 2>/dev/null || true
    docker run -d --restart always -p ${var.app_port}:8080 --name app \
      $OTEL_ARGS \
      -e SPRING_DATASOURCE_URL="jdbc:postgresql://$DB_HOST:$DB_PORT/$DB_NAME" \
      -e SPRING_DATASOURCE_USERNAME="$DB_USER" \
      -e SPRING_DATASOURCE_PASSWORD="$DB_PASS" \
      -e AWS_REGION="${var.aws_region}" \
      -e S3_MEDIA_BUCKET="${var.s3_media_bucket}" \
      -e S3_MEDIA_CDN_URL="$MEDIA_CDN_URL" \
      -e KAKAO_CLIENT_ID="$KAKAO_CLIENT_ID" \
      -e KAKAO_NATIVE_APP_KEY="$KAKAO_NATIVE_APP_KEY" \
      -e JWT_SECRET="$JWT_SECRET" \
      -e KAKAO_REST_API_KEY="$KAKAO_REST_API_KEY" \
      -e TMAP_APP_KEY="$TMAP_APP_KEY" \
      -e SPRING_PROFILES_ACTIVE="prod" \
      -e LOGGING_STRUCTURED_FORMAT_CONSOLE="ecs" \
      ${var.ecr_repository_url}:latest

    # ───────── 로그 수집 사이드카 (Grafana Alloy → Loki) ─────────
    # 앱 컨테이너 stdout 을 Docker API 로 tail → 모니터링 호스트 Loki(3100)로 push.
    # MON_HOST 없으면(모니터링 미가동/미연동) 스킵 — 앱은 정상 기동(fail-soft).
    # Alloy 가 docker.sock 에 root 로 직접 접근하지 않도록, 컨테이너 조회/로그(GET)만 노출하는
    # 최소 권한 소켓 프록시(read-only, POST 차단) 뒤에 두고 Alloy 는 그 프록시(tcp)만 바라본다.
    # ⚠️ 관측 사이드카는 앱 배포/CD(ASG instance refresh)를 절대 막지 않도록 best-effort.
    # subshell + set +e 로 감싸 이미지 pull 실패 등 어떤 오류가 나도 user_data 는 성공 종료한다.
    if [ -n "$MON_HOST" ]; then
      (
        set +e
        docker network inspect obs >/dev/null 2>&1 || docker network create obs
        docker rm -f docker-socket-proxy 2>/dev/null || true
        docker run -d --restart always --name docker-socket-proxy --network obs \
          -e CONTAINERS=1 -e POST=0 \
          -v /var/run/docker.sock:/var/run/docker.sock:ro \
          tecnativa/docker-socket-proxy:0.3.0
        mkdir -p /etc/alloy
        echo "${base64encode(file("${path.module}/templates/alloy-config.alloy"))}" | base64 -d > /etc/alloy/config.alloy
        docker rm -f alloy 2>/dev/null || true
        docker run -d --restart always --name alloy --network obs \
          -e LOKI_URL="http://$MON_HOST:3100/loki/api/v1/push" \
          -v /etc/alloy/config.alloy:/etc/alloy/config.alloy:ro \
          grafana/alloy:v1.5.1 run /etc/alloy/config.alloy
      ) || echo "warn: 관측 사이드카(alloy/socket-proxy) 기동 실패 — 앱은 정상, 로그 수집만 스킵"
    fi
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
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 강제
    # Docker 컨테이너(bridge)에서 IMDS 로 가는 요청은 홉이 하나 더 붙는다. 1이면 TTL 이 깎여 드롭돼
    # 컨테이너 안 AWS SDK 가 인스턴스 롤 자격증명을 못 얻는다(S3 presign 500). 2 로 올려 컨테이너에서도 IMDSv2 도달 가능하게 한다.
    http_put_response_hop_limit = 2
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
