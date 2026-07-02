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
