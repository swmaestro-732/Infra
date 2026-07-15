data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  secret_prefix = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret"
}

# ───────── 개발자 데이터스토어 접근 최소권한 정책 ─────────
# SSM 포트포워딩(앱 EC2 경유)으로 RDS/OpenSearch 에 붙고, 접속 시크릿 2개만 읽는다.
# 쓰기·삭제·타 리소스는 없음. Admin 대비 "터널 + 시크릿 read"만 남긴다.
data "aws_iam_policy_document" "datastore_access" {
  # 앱 인스턴스 조회 (점프 호스트 ID 찾기) + 데이터스토어 상태 조회
  statement {
    sid = "DescribeReadOnly"
    actions = [
      "ec2:DescribeInstances",
      "rds:DescribeDBInstances",
      "es:DescribeDomain",
      "es:ListDomainNames",
    ]
    resources = ["*"]
  }

  # 앱(Name=chilsami-app) 인스턴스에 한해 SSM 세션 시작.
  # SessionDocumentAccessCheck 로 "허용된 문서"만 쓰도록 강제(아래 문서 statement 와 결합).
  statement {
    sid       = "StartSessionOnAppInstances"
    actions   = ["ssm:StartSession"]
    resources = ["arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Name"
      values   = [var.app_name_tag]
    }
    condition {
      test     = "BoolIfExists"
      variable = "ssm:SessionDocumentAccessCheck"
      values   = ["true"]
    }
  }

  # 포트포워딩 전용 문서만 허용 (셸 접속용 SSM-SessionManagerRunShell 등은 불가)
  statement {
    sid     = "AllowPortForwardDocumentsOnly"
    actions = ["ssm:StartSession"]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.name}::document/AWS-StartPortForwardingSession",
      "arn:aws:ssm:${data.aws_region.current.name}::document/AWS-StartPortForwardingSessionToRemoteHost",
    ]
  }

  # 자기 세션만 종료/재개
  statement {
    sid       = "ManageOwnSessions"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:aws:ssm:*:*:session/$${aws:username}-*"]
  }

  # 접속 비밀번호: RDS/OpenSearch 시크릿 2개만 (랜덤 접미사 와일드카드)
  statement {
    sid     = "ReadDatastoreSecrets"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      "${local.secret_prefix}:${var.rds_secret_name}-*",
      "${local.secret_prefix}:${var.opensearch_secret_name}-*",
    ]
  }
}

resource "aws_iam_policy" "datastore_access" {
  name        = "${var.name}-dev-datastore-access"
  description = "개발자: SSM 포트포워딩(앱 EC2 경유)으로 RDS/OpenSearch 접근 + 접속 시크릿 read (최소권한)"
  policy      = data.aws_iam_policy_document.datastore_access.json
}

# ───────── 개발자 IAM 사용자 (1인 1사용자 권장, 액세스키는 콘솔/CLI로 별도 발급) ─────────
# 액세스키를 Terraform 으로 만들면 secret 이 tfstate 에 남으므로 키는 아웃오브밴드로 발급한다.
resource "aws_iam_user" "developer" {
  for_each = toset(var.developer_usernames)
  name     = each.value
  tags     = { Role = "dev-datastore-access" }
}

resource "aws_iam_user_policy_attachment" "developer" {
  for_each   = aws_iam_user.developer
  user       = each.value.name
  policy_arn = aws_iam_policy.datastore_access.arn
}
