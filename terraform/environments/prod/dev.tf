# =============================================================================
# dev 개발 서버 — develop 자동배포, private + SSM 프라이빗 접근.
# 현재는 prod 스택 자원(VPC·RDS·시크릿·미디어·dev_access)을 공유하므로 같은 state 에 두고
# 파일만 분리한다. 공유 참조(module.network/rds 등)가 단순해지는 대신 dev 변경이 prod state 를
# 건드리는 트레이드오프가 있다.
#
# TODO(추후): 완전 격리가 필요하면 이 파일을 environments/dev/ 로 들어내고,
#   - dev 전용 RDS 를 별도로 생성(현재는 prod RDS 인스턴스의 별도 DB=chilsami_dev 공유)
#   - 공유 자원은 terraform_remote_state 로 참조
#   - dev 전용 terraform-apply 파이프라인 추가
# 지금은 파일 분리까지만.
#
# 이 파일이 참조하는 prod 자원(main.tf 에 존재): module.network, module.rds, module.ecr(X — dev 는 ecr_dev),
#   aws_secretsmanager_secret.app_config. main.tf 쪽에서 dev 를 참조하는 곳:
#   module.rds.extra_app_sg_ids, module.dev_access.app_name_tags.
# CD 데이터소스 data.aws_iam_openid_connect_provider.github 는 cd.tf 에 있다(prod 역할과 공용).
# =============================================================================

# dev 전용 ECR — prod repo 와 분리. 공유 시 dev push 가 lifecycle(imageCountMoreThan=10)로
# prod latest 이미지를 만료시키거나 latest 를 덮어쓰는 배포경계 위반이 생기므로 별도 repo 로 격리.
module "ecr_dev" {
  source = "../../modules/ecr"

  name = "${local.name}-dev"
}

# dev 개발 서버 — develop 이미지, private(SSM 전용), prod RDS 공유(DB=chilsami_dev).
module "dev_server" {
  source = "../../modules/dev-server"

  name               = local.name
  name_tag           = "${local.name}-dev-app"
  vpc_id             = module.network.vpc_id
  subnet_id          = module.network.app_subnet_ids[0]
  aws_region         = var.aws_region
  ecr_repository_url = module.ecr_dev.repository_url # dev 전용 repo(prod 격리)

  # prod RDS 시크릿 재사용(host/user/pass/port), DB 이름만 dev 로 오버라이드
  db_secret_name = "${local.name}/rds/credentials"

  # 지도/JWT 설정·미디어는 prod 와 공용
  app_config_secret_name   = aws_secretsmanager_secret.app_config.name
  media_cdn_ssm_param_name = "/${local.name}/media/cdn-url"
  s3_media_bucket          = "${local.name}-media-ap-northeast-2"
}

# dev 인스턴스가 미디어(공용 prod 버킷)에 업로드/삭제할 수 있도록 S3 권한 부여
# (media 모듈은 prod EC2 역할에만 부여 — dev 역할엔 여기서 동일 범위로 추가).
resource "aws_iam_role_policy" "dev_media_write" {
  name = "${local.name}-dev-media-write"
  role = module.dev_server.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
      Resource = "arn:aws:s3:::${local.name}-media-ap-northeast-2/*"
    }]
  })
}

# dev 인스턴스가 기동 시 app_config·RDS 접속 시크릿을 읽도록 권한 부여(최소권한)
resource "aws_iam_role_policy" "dev_secret_read" {
  name = "${local.name}-dev-secret-read"
  role = module.dev_server.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.app_config.arn, module.rds.secret_arn]
    }]
  })
}

# ───────── dev CD — BackEnd develop 워크플로우 배포 역할(OIDC) ─────────
# ECR(dev repo) push + SSM SendCommand 로 dev 인스턴스 재배포(단일 인스턴스라 instance refresh 대신 SSM).
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

# ───────── dev outputs ─────────
output "dev_server_instance_id" {
  description = "dev 개발 서버 인스턴스 ID (aws ssm start-session --target 대상)"
  value       = module.dev_server.instance_id
}

output "dev_ecr_repository_url" {
  description = "dev 전용 ECR 리포지토리 URL (BackEnd Actions vars DEV_ECR_REPOSITORY 로 등록)"
  value       = module.ecr_dev.repository_url
}

output "backend_deploy_dev_role_arn" {
  description = "BackEnd develop CD 가 assume 할 dev 배포 역할 ARN (GitHub Actions vars AWS_DEPLOY_ROLE_ARN_DEV 로 등록)"
  value       = aws_iam_role.backend_deploy_dev.arn
}
