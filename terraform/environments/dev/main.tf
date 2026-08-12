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
  public_subnet_ids      = data.terraform_remote_state.prod.outputs.public_subnet_ids
  private_route_table_id = data.terraform_remote_state.prod.outputs.private_route_table_id
  route53_zone_id        = data.terraform_remote_state.prod.outputs.route53_zone_id
  media_bucket           = data.terraform_remote_state.prod.outputs.media_bucket_name
}

# ───────── dev 전용 app_config 시크릿 (prod 와 자격증명 격리) ─────────
# jwt_secret 은 dev 전용으로 자동 생성 → dev 에서 발급한 JWT 가 prod 에서 통하지 않게 격리(보안 경계).
# kakao/tmap 키는 비워 두면 dev 는 카카오 모킹 로그인·지도 기능 fail-soft 로 동작(개발 편의).
resource "random_password" "dev_jwt" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "dev_app_config" {
  name = "${local.name}/dev/app/config"
}

resource "aws_secretsmanager_secret_version" "dev_app_config" {
  secret_id = aws_secretsmanager_secret.dev_app_config.id
  secret_string = jsonencode({
    kakao_client_id      = "" # 비움 → dev 는 카카오 모킹 로그인
    jwt_secret           = random_password.dev_jwt.result
    kakao_rest_api_key   = "" # 지도 검색 — 필요 시 콘솔로 dev 값 주입
    tmap_app_key         = "" # 도보 경로 — 필요 시 콘솔로 dev 값 주입
    kakao_native_app_key = ""
  })
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
  alb_sg_id          = aws_security_group.dev_alb.id
  aws_region         = var.aws_region
  ecr_repository_url = module.ecr_dev.repository_url

  dev_db_password = random_password.dev_db.result

  app_config_secret_name   = aws_secretsmanager_secret.dev_app_config.name # dev 전용(jwt 격리)
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

# dev 인스턴스 → dev 전용 app_config 시크릿 read(prod 시크릿 접근 없음). DB 는 로컬이라 RDS 시크릿 불필요.
resource "aws_iam_role_policy" "dev_secret_read" {
  name = "${local.name}-dev-secret-read"
  role = module.dev_server.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.dev_app_config.arn]
    }]
  })
}

# ───────── dev ALB (인터넷 페이싱, prod 퍼블릭 서브넷 재사용 — ALB 는 2 AZ 필요) ─────────
resource "aws_security_group" "dev_alb" {
  name        = "${local.name}-dev-alb-sg"
  description = "dev ALB - public 80/443"
  vpc_id      = local.vpc_id

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTP (redirect)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-dev-alb-sg" }
}

resource "aws_lb" "dev" {
  name               = "${local.name}-dev-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.dev_alb.id]
  subnets            = local.public_subnet_ids

  tags = { Name = "${local.name}-dev-alb" }
}

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

# ───────── ACM(ap-northeast-2, ALB용) — dev.courmy.com, Route53 DNS 검증 ─────────
resource "aws_acm_certificate" "dev" {
  domain_name       = local.dev_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name}-dev-cert" }
}

resource "aws_route53_record" "dev_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.dev.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = local.route53_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "dev" {
  certificate_arn         = aws_acm_certificate.dev.arn
  validation_record_fqdns = [for r in aws_route53_record.dev_cert_validation : r.fqdn]
}

resource "aws_lb_listener" "dev_https" {
  load_balancer_arn = aws_lb.dev.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.dev.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.dev.arn
  }
}

resource "aws_lb_listener" "dev_http_redirect" {
  load_balancer_arn = aws_lb.dev.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_route53_record" "dev" {
  zone_id = local.route53_zone_id
  name    = local.dev_domain
  type    = "A"

  alias {
    name                   = aws_lb.dev.dns_name
    zone_id                = aws_lb.dev.zone_id
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
