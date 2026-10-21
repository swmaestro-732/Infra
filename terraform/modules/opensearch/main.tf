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

  # SG 규칙 description 은 ASCII 만 허용(AWS 제약) → 영문. 설명은 주석으로.
  # prod 앱 SG + 추가 허용 SG(dev 등). 인라인 단일 소스로 관리(standalone rule 혼용 금지 — perpetual diff).
  ingress {
    description     = "HTTPS from app and extra client SGs (e.g. dev)"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = concat([var.app_sg_id], var.extra_ingress_sg_ids)
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

# ───────── FGAC 마스터 = IAM 역할 (SCRUM-675) ─────────
# 단일 노드가 교체돼 클러스터가 재생성되면 내부 사용자 DB 의 마스터 비밀번호가 시크릿과 어긋나 401 이 났다(2026-10-20, 21).
# 마스터를 IAM 역할로 두면 맞출 비밀번호가 없다. prod 앱과 admin_principal_arns(SSO 관리자 등)만 이 역할을 assume 한다.
resource "aws_iam_role" "admin" {
  name = "${var.name}-opensearch-admin"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "sts:AssumeRole"
      # 계정 루트 위임 + PrincipalArn 조건: SSO 역할처럼 이름이 바뀌는 주체도 패턴으로 허용하면서 그 외는 막는다.
      Condition = { ArnLike = { "aws:PrincipalArn" = var.admin_principal_arns } }
    }]
  })
}

# 앱이 기동 시 읽는 접속 정보. 이름(${var.name}/opensearch/master)은 ec2 모듈이 순환 의존 없이 참조하려고 유지한다.
# 비밀번호는 없다(앱은 assume_role_arn 을 assume 해 SigV4 서명).
resource "aws_secretsmanager_secret" "master" {
  name = "${var.name}/opensearch/master"
}

resource "aws_secretsmanager_secret_version" "master" {
  secret_id = aws_secretsmanager_secret.master.id
  secret_string = jsonencode({
    endpoint        = aws_opensearch_domain.this.endpoint
    region          = data.aws_region.current.name
    assume_role_arn = aws_iam_role.admin.arn
  })
}

# ───────── 감사 로그 (CloudWatch) — FGAC 활성 시 지원 ─────────
resource "aws_cloudwatch_log_group" "audit" {
  name              = "/aws/opensearch/${var.name}/audit"
  retention_in_days = var.log_retention_days
}

# 에러 로그 — 노드 장애 직전 OpenSearch 가 남긴 오류(OOM, 디스크, 클러스터 형성 실패 등) 추적용
resource "aws_cloudwatch_log_group" "error" {
  name              = "/aws/opensearch/${var.name}/error"
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
      Resource = [
        "${aws_cloudwatch_log_group.audit.arn}:*",
        "${aws_cloudwatch_log_group.error.arn}:*",
      ]
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

  # Fine-Grained Access Control — 마스터는 IAM 역할. 내부 사용자 DB 는 켜 둔다(끄는 변경의 blue/green 위험 회피,
  # 남은 내부 사용자는 provision 스크립트가 정리).
  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = true

    master_user_options {
      master_user_arn = aws_iam_role.admin.arn
    }
  }

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.audit.arn
    log_type                 = "AUDIT_LOGS"
  }

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.error.arn
    log_type                 = "ES_APPLICATION_LOGS"
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
}

# nori 패키지 ID 자동 조회 — 리전·엔진버전별 AWS 관리 ID(예: G248827013)라 data source 가 없어
# describe-packages 로 plan 시점에 찾는다. var.nori_package_id 로 오버라이드 가능(조회 생략).
# 실행 역할에 opensearch:DescribePackages 필요. validate 는 data source 미실행이라 무관.
# ※ 응답 키는 PackageDetailsList 다(PackageDetails 아님). nori 는 앱 필수라, 못 찾으면 조용히
#    넘어가지 않고 exit 1 로 plan 을 실패시킨다(조용한 미연결 방지).
data "external" "nori_package" {
  count = var.nori_package_id == "" ? 1 : 0

  program = ["bash", "-c", <<-EOT
    set -euo pipefail
    id=$(aws opensearch describe-packages --region ${data.aws_region.current.name} \
      --filters Name=EngineVersion,Value=${var.engine_version} \
      --query "PackageDetailsList[?PackageName=='analysis-nori' && PackageStatus=='AVAILABLE'].PackageID | [0]" \
      --output text)
    if [ "$id" = "None" ] || [ -z "$id" ]; then
      echo "analysis-nori(AVAILABLE) 패키지를 못 찾음 — engine=${var.engine_version}, 리전/버전 확인 필요" >&2
      exit 1
    fi
    printf '{"id":"%s"}' "$id"
  EOT
  ]
}

locals {
  # 오버라이드 우선, 없으면 자동 조회 결과(못 찾으면 위 data source 가 이미 실패해 여기 도달 안 함).
  # one() 로 count=0(오버라이드 지정) 케이스에서 인덱스 에러 없이 null 처리. try 는 쓰지 않는다
  # (try 가 조회 실패까지 삼켜 조용한 미연결로 되돌아가므로).
  nori_package_id = var.nori_package_id != "" ? var.nori_package_id : one(data.external.nori_package[*].result.id)
}

# analysis-nori(한글 형태소) 연결. 앱 인덱스 매핑(place/course)이 analyzer:nori 를 쓰므로 필수.
# 관리형 도메인은 nori 를 번들로 안 주고 ZIP-PLUGIN 패키지 associate 로 붙인다. associate 는 blue/green 유발.
resource "aws_opensearch_package_association" "nori" {
  count       = local.nori_package_id != "" ? 1 : 0
  package_id  = local.nori_package_id
  domain_name = aws_opensearch_domain.this.domain_name

  # associate/dissociate 는 blue/green 배포라 오래 걸린다. 실측상 30m 를 초과해 타임아웃 실패한 이력이
  # 있어(비번 회전 blue/green 과 겹치면 더 김) 60m 로 상향.
  timeouts {
    create = "60m"
    delete = "60m"
  }
}

# ───────── 앱(EC2) 에 접속 정보 시크릿 읽기 + 마스터 역할 assume 권한 (최소권한) ─────────
resource "aws_iam_role_policy" "app_secret_read" {
  count = var.app_role_name != null ? 1 : 0
  name  = "${var.name}-opensearch-secret-read"
  role  = var.app_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.master.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = aws_iam_role.admin.arn
      },
    ]
  })
}
