# =============================================================================
# BackEnd CD — GitHub Actions(OIDC) 배포 역할: ECR push + SSM 로 EC2 배포
# OIDC provider 는 부트스트랩에서 이미 생성됨 → data 로 참조.
# =============================================================================

data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "backend_deploy" {
  name = "${local.name}-backend-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        # swmaestro-732/BackEnd 레포에서 온 토큰만 허용
        StringLike = { "token.actions.githubusercontent.com:sub" = "repo:swmaestro-732/BackEnd:*" }
      }
    }]
  })

  tags = { Name = "${local.name}-backend-deploy" }
}

resource "aws_iam_role_policy" "backend_deploy" {
  name = "${local.name}-backend-deploy"
  role = aws_iam_role.backend_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*" # GetAuthorizationToken 은 리소스 한정 불가
      },
      {
        Sid    = "EcrPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = module.ecr.repository_arn
      },
      {
        Sid      = "SsmRunShellDocument"
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript"
      },
      {
        Sid      = "SsmSendToAppInstancesOnly"
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = {
          StringEquals = { "ssm:resourceTag/Name" = "${local.name}-app" }
        }
      },
      {
        Sid      = "SsmTrackCommand"
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
        Resource = "*"
      },
      {
        Sid      = "Ec2DescribeForTargeting"
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*" # DescribeInstances 는 리소스 한정 불가
      },
    ]
  })
}
