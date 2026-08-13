# =============================================================================
# dev 개발 서버 — 독립 state(dev/terraform.tfstate). develop 자동배포, dev.courmy.com 공개(ALB+ACM),
# DB 는 인스턴스 내 Docker Postgres 로 격리. prod 변경과 완전히 분리된 apply/plan/destroy.
#
# 공유 prod 자원(VPC·퍼블릭 서브넷·NAT 라우트테이블·Route53 zone·app_config 시크릿·미디어 버킷)은
# prod state 를 terraform_remote_state 로 읽는다(prod outputs 가 계약). dev 는 prod state 를 안 건드림.
# =============================================================================

locals {
  name       = "chilsami"
  domain     = "courmy.com"
  dev_domain = "dev.${local.domain}"
}

# ───────── prod 공유 자원 (읽기 전용) ─────────
data "terraform_remote_state" "prod" {
  backend = "s3"
  config = {
    bucket = "chilsami-tfstate-ap-northeast-2"
    key    = "prod/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

# GitHub Actions OIDC provider (계정 공용 — prod 가 생성, dev 는 조회만)
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

locals {
  vpc_id                 = data.terraform_remote_state.prod.outputs.vpc_id
  private_route_table_id = data.terraform_remote_state.prod.outputs.private_route_table_id
  route53_zone_id        = data.terraform_remote_state.prod.outputs.route53_zone_id
  media_bucket           = data.terraform_remote_state.prod.outputs.media_bucket_name

  # dev 는 kakao/tmap 키를 prod app_config 에서 그대로 읽는다(같은 외부 앱 자격증명). jwt 만 dev 전용.
  prod_app_config_secret_arn = data.terraform_remote_state.prod.outputs.app_config_secret_arn

  # dev 는 별도 ALB 를 만들지 않고 prod ALB 를 재사용한다(비용 절감). prod state 가 계약으로 노출한
  # 443 리스너 ARN·ALB SG·ALB DNS/zone 을 읽어, host 규칙과 Route53 alias 만 dev 가 소유한다.
  alb_https_listener_arn = data.terraform_remote_state.prod.outputs.alb_https_listener_arn
  alb_security_group_id  = data.terraform_remote_state.prod.outputs.alb_security_group_id
  alb_dns_name           = data.terraform_remote_state.prod.outputs.alb_dns_name
  alb_zone_id            = data.terraform_remote_state.prod.outputs.alb_zone_id
}

# ───────── dev jwt 시크릿 (prod 와 격리되는 유일한 값) ─────────
# jwt_secret 은 dev 전용으로 자동 생성 → dev 에서 발급한 JWT 가 prod 에서 통하지 않게 격리(보안 경계).
# kakao/tmap/native 는 prod app_config(chilsami/app/config)에서 실키를 그대로 읽으므로 여기 두지 않는다.
resource "random_password" "dev_jwt" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "dev_jwt" {
  name = "${local.name}/dev/app/jwt"
}

resource "aws_secretsmanager_secret_version" "dev_jwt" {
  secret_id     = aws_secretsmanager_secret.dev_jwt.id
  secret_string = jsonencode({ jwt_secret = random_password.dev_jwt.result })

  # 최초 생성값 고정(재생성 방지). 이후 회전 시엔 콘솔/CLI 로 주입.
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ───────── dev 전용 ECR (prod repo 와 격리) ─────────
module "ecr_dev" {
  source = "../../modules/ecr"
  name   = "${local.name}-dev"
}

# ───────── dev 전용 프라이빗 서브넷(단일 AZ) + NAT egress(prod private RT 재사용) ─────────
resource "aws_subnet" "dev" {
  vpc_id            = local.vpc_id
  cidr_block        = "10.0.40.0/24"
  availability_zone = var.az

  tags = { Name = "${local.name}-dev", Tier = "dev" }
}

resource "aws_route_table_association" "dev" {
  subnet_id      = aws_subnet.dev.id
  route_table_id = local.private_route_table_id
}

# dev 로컬 Postgres 비밀번호(devnet 전용·미노출)
resource "random_password" "dev_db" {
  length  = 20
  special = false
}

# ───────── dev 개발 서버 (private, ALB 뒤, DB=로컬 Docker Postgres) ─────────
module "dev_server" {
  source = "../../modules/dev-server"

  name               = local.name
  name_tag           = "${local.name}-dev-app"
  vpc_id             = local.vpc_id
  subnet_id          = aws_subnet.dev.id
  alb_sg_id          = local.alb_security_group_id # prod ALB SG → dev 8080 인바운드 허용
  aws_region         = var.aws_region
  ecr_repository_url = module.ecr_dev.repository_url
  ecr_repository_arn = module.ecr_dev.repository_arn

  dev_db_password = random_password.dev_db.result

  keys_secret_id           = local.prod_app_config_secret_arn      # kakao/tmap/native = prod 실키 공유
  jwt_secret_id            = aws_secretsmanager_secret.dev_jwt.arn # jwt = dev 전용(격리)
  media_cdn_ssm_param_name = "/${local.name}/media/cdn-url"
  s3_media_bucket          = local.media_bucket
}

# dev 인스턴스 → 공용 미디어 버킷 업로드/삭제
resource "aws_iam_role_policy" "dev_media_write" {
  name = "${local.name}-dev-media-write"
  role = module.dev_server.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
      Resource = "arn:aws:s3:::${local.media_bucket}/*"
    }]
  })
}

# dev 인스턴스 → prod app_config(kakao/tmap 실키, read-only) + dev jwt 시크릿 read.
# prod 시크릿은 read 만 — dev 가 값을 쓰지 못한다. DB 는 로컬이라 RDS 시크릿 불필요.
resource "aws_iam_role_policy" "dev_secret_read" {
  name = "${local.name}-dev-secret-read"
  role = module.dev_server.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [local.prod_app_config_secret_arn, aws_secretsmanager_secret.dev_jwt.arn]
    }]
  })
}

# ───────── prod ALB 재사용 — dev 타깃그룹 + 443 host 규칙 (별도 dev ALB 없음) ─────────
# 별도 ALB(월 ~$18)를 안 만들고 prod ALB 를 공유한다. dev 는 (1) 자기 타깃그룹, (2) prod 443
# 리스너에 얹는 host 규칙, (3) Route53 alias 만 소유. 리스너·인증서·ALB SG 443 은 prod 소유.
resource "aws_lb_target_group" "dev" {
  name        = "${local.name}-dev-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  target_type = "instance"

  health_check {
    path                = "/actuator/health"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group_attachment" "dev" {
  target_group_arn = aws_lb_target_group.dev.arn
  target_id        = module.dev_server.instance_id
  port             = 8080
}

# prod ALB 443 리스너에 host 규칙을 얹어 dev.courmy.com → dev 타깃그룹으로 보낸다.
# 리스너 ARN 은 prod state 가 노출한 것을 remote_state 로 읽는다(리스너=prod 소유, 규칙=dev 소유).
# 인증서는 prod 의 리전 와일드카드(*.courmy.com, ap-northeast-2)가 이미 dev.courmy.com 을 커버.
# priority 는 prod 쪽 규칙과 안 겹치게 100 대(현재 prod 443 엔 default 403 뿐).
resource "aws_lb_listener_rule" "dev" {
  listener_arn = local.alb_https_listener_arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.dev.arn
  }

  condition {
    host_header {
      values = [local.dev_domain]
    }
  }
}

# dev.courmy.com → prod ALB (alias). https 로 붙으면 위 host 규칙이 dev TG 로 보낸다.
# http(80)로 오면 prod 리스너의 origin-verify default(403)에 막힌다 — dev 는 https 사용 전제.
resource "aws_route53_record" "dev" {
  zone_id = local.route53_zone_id
  name    = local.dev_domain
  type    = "A"

  alias {
    name                   = local.alb_dns_name
    zone_id                = local.alb_zone_id
    evaluate_target_health = true
  }
}

# ───────── dev CD — BackEnd develop 워크플로우 배포 역할(OIDC) ─────────
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
        Resource = module.ecr_dev.repository_arn
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
