data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  domain_name = "${var.name}-search"
}

# ───────── 서비스 연결 역할 (VPC 도메인 생성 전제) ─────────
# VPC 기반 OpenSearch 도메인은 계정에 이 SLR 이 있어야 생성 가능(없으면 CreateDomain 400).
# 계정에 이미 존재하면 create_service_linked_role=false 로 두고 terraform import.
resource "aws_iam_service_linked_role" "opensearch" {
  count            = var.create_service_linked_role ? 1 : 0
  aws_service_name = "opensearchservice.amazonaws.com"
  description      = "SLR for Amazon OpenSearch Service VPC access"
}

# ───────── 보안그룹 (앱 티어만 443 허용, reference chaining) ─────────
resource "aws_security_group" "opensearch" {
  name        = "${var.name}-opensearch-sg"
  description = "OpenSearch HTTPS from app tier only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTPS from app"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [var.app_sg_id]
  }

  egress {
    description = "all"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-opensearch-sg" }
}

# ───────── FGAC 마스터 자격증명 → Secrets Manager (RDS 패턴 재사용) ─────────
# 최초 생성 시 초기 비번으로만 쓰인다(이후 ignore_changes 로 out-of-band 관리).
resource "random_password" "master" {
  length           = 20
  special          = true
  override_special = "!#$%^&*()-_=+"
  min_lower        = 1
  min_upper        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "aws_secretsmanager_secret" "master" {
  name = "${var.name}/opensearch/master"
}

resource "aws_secretsmanager_secret_version" "master" {
  secret_id = aws_secretsmanager_secret.master.id
  secret_string = jsonencode({
    username = var.master_user_name
    password = random_password.master.result
    endpoint = aws_opensearch_domain.this.endpoint
  })

  # 최초 seed 만 TF 가 심고, 이후 비번은 out-of-band(콘솔/CLI)로 관리 → apply 가 옛 값으로 되돌리지 않게.
  # (도메인 master 비번은 write-only 라 plan 이 드리프트를 못 읽음. 이 시크릿만 되돌아가면 도메인과
  #  어긋나 인증 401 이 재발하므로 secret_string 을 고정한다. 도메인 쪽 ignore_changes 와 짝.)
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ───────── 감사 로그 (CloudWatch) — FGAC 활성 시 지원 ─────────
resource "aws_cloudwatch_log_group" "audit" {
  name              = "/aws/opensearch/${var.name}/audit"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_resource_policy" "opensearch" {
  policy_name = "${var.name}-opensearch-logs"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "es.amazonaws.com" }
      Action    = ["logs:PutLogEvents", "logs:CreateLogStream"]
      Resource  = "${aws_cloudwatch_log_group.audit.arn}:*"
    }]
  })
}

# ───────── OpenSearch 도메인 (VPC 배치 · 전구간 암호화 · FGAC) ─────────
resource "aws_opensearch_domain" "this" {
  domain_name    = local.domain_name
  engine_version = var.engine_version

  cluster_config {
    instance_type          = var.instance_type
    instance_count         = var.instance_count
    zone_awareness_enabled = var.multi_az

    dynamic "zone_awareness_config" {
      for_each = var.multi_az ? [1] : []
      content {
        availability_zone_count = 2
      }
    }
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = var.volume_size
  }

  # 데이터 서브넷(프라이빗)에 배치 — 퍼블릭 엔드포인트 없음
  vpc_options {
    subnet_ids         = slice(var.subnet_ids, 0, var.multi_az ? 2 : 1)
    security_group_ids = [aws_security_group.opensearch.id]
  }

  encrypt_at_rest {
    enabled = true
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  # Fine-Grained Access Control (내부 사용자 DB) — 세밀한 인가는 FGAC 가 담당
  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = true

    master_user_options {
      master_user_name     = var.master_user_name
      master_user_password = random_password.master.result
    }
  }

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.audit.arn
    log_type                 = "AUDIT_LOGS"
  }

  # 네트워크(VPC/SG)+FGAC 로 접근을 통제하므로 도메인 정책은 도메인 범위 허용으로 두고
  # 세밀한 인가는 FGAC(내부 사용자 DB)에 위임한다.
  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "*" }
      Action    = "es:*"
      Resource  = "arn:aws:es:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:domain/${local.domain_name}/*"
    }]
  })

  tags = { Name = local.domain_name }

  depends_on = [
    aws_cloudwatch_log_resource_policy.opensearch,
    aws_iam_service_linked_role.opensearch,
  ]

  # master 비번은 최초 생성값만 TF 가 세팅하고, 이후 회전/리셋은 out-of-band 로 한다.
  # (write-only 라 plan 이 드리프트를 못 읽고, random_password 재생성 시 apply 가 도메인 비번을
  #  옛 값으로 밀어 인증을 깨뜨리는 걸 방지 — 시크릿 ignore_changes 와 짝.)
  lifecycle {
    ignore_changes = [advanced_security_options[0].master_user_options[0].master_user_password]
  }
}

# ───────── 앱(EC2) 에 마스터 시크릿 읽기 권한 (최소권한) ─────────
resource "aws_iam_role_policy" "app_secret_read" {
  count = var.app_role_name != null ? 1 : 0
  name  = "${var.name}-opensearch-secret-read"
  role  = var.app_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.master.arn
    }]
  })
}
