# 계정 부트스트랩 — prod/dev Terraform 보다 먼저, 계정마다 한 번 로컬에서 apply 한다.
# tfstate 버킷 · GitHub OIDC 공급자 · Terraform 실행 역할 · 예산 알림.
# 실행: AWS_PROFILE=<새 계정 관리자> terraform -chdir=terraform/bootstrap apply
# state 는 첫 apply 뒤 backend.tf 로 이 버킷(bootstrap/terraform.tfstate)에 옮긴다.
# 빈 계정에서 다시 시작할 때는 backend.tf 를 잠시 치우고 apply → backend.tf 복원 → init -migrate-state.
# 예산 알림 메일: TF_VAR_alert_emails='["you@example.com"]' 로 넘긴다(빈 값으로 apply 하면 알림이 빠진다).

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"

  default_tags {
    tags = {
      Project     = "chilsami"
      Environment = "bootstrap"
      ManagedBy   = "terraform"
    }
  }
}

variable "github_repo" {
  description = "Terraform 역할을 쓸 GitHub 레포 (OIDC sub 조건)"
  type        = string
  default     = "swmaestro-732/Infra"
}

variable "monthly_budget_usd" {
  description = "월 예산 (크레딧 소진 속도 기준)"
  type        = number
  default     = 280
}

variable "alert_emails" {
  description = "예산 알림 메일. 공개 레포라 기본값에 두지 않고 TF_VAR_alert_emails 로 넘긴다"
  type        = list(string)
  default     = []
}

data "aws_caller_identity" "current" {}

locals {
  # 버킷 이름은 전역 유일 — 계정 ID 를 붙여 옛 계정 버킷과 겹치지 않게 한다.
  state_bucket = "chilsami-tfstate-${data.aws_caller_identity.current.account_id}"
}

# ---------- tfstate 버킷 ----------
resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "tfstate_tls_only" {
  bucket = aws_s3_bucket.tfstate.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}

# ---------- GitHub OIDC + Terraform 실행 역할 ----------
# prod 의 cd.tf 는 이 공급자를 data 로 읽기만 한다.
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1", "1c58a3a8518e8759bf075b76b750d4f2df264fcd"]
}

resource "aws_iam_role" "gha_terraform" {
  name = "chilsami-gha-terraform"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*" }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "gha_terraform_admin" {
  role       = aws_iam_role.gha_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ---------- 예산 ----------
resource "aws_budgets_budget" "monthly" {
  name         = "chilsami-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = length(var.alert_emails) > 0 ? [
      { type = "ACTUAL", threshold = 80 },
      { type = "FORECASTED", threshold = 100 },
    ] : []
    content {
      comparison_operator        = "GREATER_THAN"
      notification_type          = notification.value.type
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      subscriber_email_addresses = var.alert_emails
    }
  }
}

# 이상 비용 탐지는 새 계정에 기본 모니터(Default-Services-Monitor)와 일일 구독이 이미 있어 따로 만들지 않는다
# (서비스 차원 모니터는 계정당 1개 제한).

output "state_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}

output "terraform_role_arn" {
  value = aws_iam_role.gha_terraform.arn
}
