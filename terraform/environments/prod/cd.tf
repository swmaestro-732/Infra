# =============================================================================
# BackEnd CD — GitHub Actions(OIDC) 배포 역할: ECR push + ASG Instance Refresh 로 무중단 배포
# (CD가 이미지 push 후 instance refresh 를 트리거 → 새 인스턴스가 user_data 로 :latest pull)
# OIDC provider 는 부트스트랩에서 이미 생성됨 → data 로 참조.
# =============================================================================

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
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # BackEnd 레포의 main 브랜치 워크플로우만 허용 (임의 브랜치/PR 차단)
          "token.actions.githubusercontent.com:sub" = "repo:swmaestro-732/BackEnd:ref:refs/heads/main"
        }
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
        Sid    = "AsgInstanceRefresh"
        Effect = "Allow"
        Action = [
          "autoscaling:StartInstanceRefresh",
          "autoscaling:CancelInstanceRefresh",
        ]
        Resource = module.ec2.asg_arn # 우리 ASG 로만 한정
      },
      {
        Sid    = "AsgDescribe"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeInstanceRefreshes", # CD 가 refresh 진행상태 폴링
          "autoscaling:DescribeAutoScalingGroups",
        ]
        Resource = "*" # autoscaling Describe* 는 리소스 한정 미지원
      },
    ]
  })
}

# =============================================================================
# dev CD — BackEnd develop 워크플로우: ECR(dev-*) push + SSM SendCommand 로 dev 인스턴스 재배포
# (ASG 없는 단일 인스턴스라 instance refresh 대신 SSM RunShellScript 로 docker pull + 재기동)
# =============================================================================
resource "aws_iam_role" "backend_deploy_dev" {
  name = "${local.name}-backend-deploy-dev"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          # BackEnd 레포의 develop 브랜치 워크플로우만 허용
          "token.actions.githubusercontent.com:sub" = "repo:swmaestro-732/BackEnd:ref:refs/heads/develop"
        }
      }
    }]
  })

  tags = { Name = "${local.name}-backend-deploy-dev" }
}

resource "aws_iam_role_policy" "backend_deploy_dev" {
  name = "${local.name}-backend-deploy-dev"
  role = aws_iam_role.backend_deploy_dev.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
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
        Resource = module.ecr_dev.repository_arn # dev 전용 repo 로만 push(prod repo 접근 없음)
      },
      {
        Sid    = "SsmRedeployDevInstance"
        Effect = "Allow"
        Action = ["ssm:SendCommand"]
        Resource = [
          module.dev_server.instance_arn,
          "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
        ]
      },
      {
        Sid      = "SsmPollCommand"
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
        Resource = "*"
      },
    ]
  })
}

output "backend_deploy_dev_role_arn" {
  description = "BackEnd develop CD 가 assume 할 dev 배포 역할 ARN (GitHub Actions vars 에 등록)"
  value       = aws_iam_role.backend_deploy_dev.arn
}
