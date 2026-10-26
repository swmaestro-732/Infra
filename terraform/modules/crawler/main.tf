# arm64 전용 AL2023 — t4g.small 에 x86 이미지를 기동하지 않도록 SSM 파라미터도 분리한다.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_security_group" "this" {
  name        = "${var.name}-crawler-sg"
  description = "Crawler worker (no ingress; admin via SSM)"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-crawler-sg" }
}

resource "aws_security_group_rule" "egress_all" {
  count             = var.environment == "prod" ? 1 : 0
  type              = "egress"
  description       = "All outbound (prod convention)"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.this.id
}

# dev-server 와 같은 allowlist: dnf(80), DNS(53), HTTPS(443), NTP(123).
# SG 는 도메인을 지정할 수 없어 Apify/Anthropic/Kakao/Instagram CDN 의 HTTPS 는 인터넷 전체 허용.
resource "aws_security_group_rule" "dev_egress" {
  for_each = var.environment == "dev" ? {
    http    = { port = 80, protocol = "tcp" }
    https   = { port = 443, protocol = "tcp" }
    dns_tcp = { port = 53, protocol = "tcp" }
    dns_udp = { port = 53, protocol = "udp" }
    ntp     = { port = 123, protocol = "udp" }
  } : {}

  type              = "egress"
  description       = "Crawler ${each.key} outbound"
  from_port         = each.value.port
  to_port           = each.value.port
  protocol          = each.value.protocol
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.this.id
}

resource "aws_security_group_rule" "dev_egress_db" {
  count                    = var.environment == "dev" ? 1 : 0
  type                     = "egress"
  description              = "PostgreSQL to dev DB only"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.this.id
  source_security_group_id = var.db_security_group_id
}

# 외부 API 키는 Slack 웹훅과 같은 방식: 시크릿 껍데기만 생성, 값은 콘솔/CLI 로 수동 주입.
resource "aws_secretsmanager_secret" "api" {
  for_each    = toset(["APIFY_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "KAKAO_API_KEY"])
  name        = "${var.name}/crawler/${replace(lower(each.value), "_", "-")}"
  description = "Crawler ${each.value} — 값은 수동 주입"
}

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "db" {
  name        = "${var.name}/crawler/db"
  description = "crawler_ro 로그인 비밀번호 — Flyway V18 이후 scripts/crawler/provision-db-role.sh 실행"
}

# Terraform 은 DB 내부 역할을 수정하지 않는다. writer 에서 1회 LOGIN 활성화 후 크롤러를 refresh 한다.
resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = "crawler_ro"
    password = random_password.db.result
  })
}

# Alloy 는 socket-proxy·SSM 조회·모니터링 SG 연결이 추가로 필요해 awslogs 로 직접 전송한다.
resource "aws_cloudwatch_log_group" "this" {
  name              = "/${var.name}/crawler"
  retention_in_days = 14
}

resource "aws_iam_role" "this" {
  name = "${var.name}-crawler-role"
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
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "this" {
  name = "${var.name}-crawler"
  role = aws_iam_role.this.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
        Resource = var.queue_arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "arn:aws:s3:::${var.media_bucket}/crawler/*"
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*" # 이 API 만 리소스 한정 불가
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
        Resource = var.ecr_repository_arn
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = concat([aws_secretsmanager_secret.db.arn], [for secret in aws_secretsmanager_secret.api : secret.arn])
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.this.arn}:*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-crawler-profile"
  role = aws_iam_role.this.name
}

locals {
  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    aws_region         = var.aws_region
    ecr_repository_url = var.ecr_repository_url
    environment        = var.environment
    enabled            = var.enabled
    queue_url          = var.queue_url
    db_url             = var.db_url
    db_secret_id       = aws_secretsmanager_secret.db.arn
    apify_secret_id    = aws_secretsmanager_secret.api["APIFY_TOKEN"].arn
    claude_secret_id   = aws_secretsmanager_secret.api["CLAUDE_CODE_OAUTH_TOKEN"].arn
    kakao_secret_id    = aws_secretsmanager_secret.api["KAKAO_API_KEY"].arn
    media_bucket       = var.media_bucket
    cdn_base_url       = var.cdn_base_url
    log_group          = aws_cloudwatch_log_group.this.name
  })
}

resource "aws_launch_template" "this" {
  name_prefix   = "${var.name}-crawler-"
  image_id      = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_types[0]
  user_data     = base64encode(local.user_data)

  # spot 여부와 후보 타입은 ASG mixed_instances_policy 가 정한다(한 타입 재고 부족 시 다른 타입으로 확보).

  iam_instance_profile {
    arn = aws_iam_instance_profile.this.arn
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.this.id]
    delete_on_termination       = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # 앱과 동일: Docker bridge 를 거쳐 IMDSv2 자격증명을 읽는다.
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = "gp3"
      volume_size           = 20
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-crawler" }
  }

  lifecycle {
    # SSM 최신 AMI 가 바뀔 때마다 관련 없는 apply 로 실행 중인 크롤러가 교체되지 않게 한다.
    # AMI 갱신은 이 줄을 잠시 빼고 의도적으로 apply 한다.
    ignore_changes = [image_id]

    precondition {
      # 한글 주석도 바이트에 포함한다(base64 로부터 구한 패딩 포함 상한).
      condition     = ceil(length(base64encode(local.user_data)) * 3 / 4) <= 16384
      error_message = "크롤러 user_data 는 16 KiB 이하여야 합니다."
    }
  }
}

resource "aws_autoscaling_group" "this" {
  name                = "${var.name}-crawler-asg"
  vpc_zone_identifier = var.subnet_ids
  min_size            = var.desired_capacity
  max_size            = var.desired_capacity
  desired_capacity    = var.desired_capacity
  capacity_rebalance  = false
  health_check_type   = "EC2"

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 0 # 전부 spot
      spot_allocation_strategy                 = "price-capacity-optimized"
    }
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.this.id
        version            = aws_launch_template.this.latest_version
      }
      dynamic "override" {
        for_each = var.instance_types
        content {
          instance_type = override.value
        }
      }
    }
  }

  # 한 번에 한 크롤러만 실행: 기존 인스턴스 종료 후 교체(짧은 중단 허용).
  # 정책은 CD 의 StartInstanceRefresh 에도 적용된다. latest 태그 재배포 시 SkipMatching=false 필요.
  instance_maintenance_policy {
    min_healthy_percentage = 0
    max_healthy_percentage = 100
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0
      max_healthy_percentage = 100
      instance_warmup        = 180
      skip_matching          = false
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name}-crawler"
    propagate_at_launch = true
  }

  depends_on = [
    aws_iam_role_policy.this,
    aws_iam_role_policy_attachment.ssm,
    aws_secretsmanager_secret_version.db,
    aws_security_group_rule.egress_all,
    aws_security_group_rule.dev_egress,
    aws_security_group_rule.dev_egress_db,
  ]
}
