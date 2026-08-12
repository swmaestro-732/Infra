# =============================================================================
# dev 개발 서버 — develop 자동배포, dev.courmy.com 공개(ALB+ACM), DB 는 인스턴스 내 Docker Postgres 로 격리.
# prod 스택 자원(VPC·퍼블릭 서브넷·NAT·시크릿·미디어·Route53 zone·dev_access)을 공유하므로 같은 state 에
# 두고 파일만 분리한다. dev 변경이 prod state 를 건드리는 트레이드오프가 있다.
#
# 구성:
#   - dev 전용 프라이빗 서브넷(10.0.40.0/24, 단일 AZ) + 기존 private RT(NAT) 재사용
#   - dev ALB(인터넷 페이싱, prod 퍼블릭 서브넷 재사용) + ACM(ap-northeast-2) + Route53 dev.courmy.com
#   - dev 인스턴스(private, ALB 뒤): app + Docker Postgres(devnet 전용) — prod RDS 안 씀
#   - 접근: 공개 API 는 dev.courmy.com, 관리/DB 는 SSM. CD 는 develop push → SSM send-command 재배포.
#
# TODO(추후): 완전 격리가 필요하면 environments/dev/ 로 들어내고 공유 자원은 terraform_remote_state 로.
# 공유 참조(main.tf): module.network, module.dns(zone), aws_secretsmanager_secret.app_config, 미디어 버킷.
#   main.tf 에서 dev 참조: module.dev_access.app_name_tags = [..., "-dev-app"].
# CD 데이터소스 data.aws_iam_openid_connect_provider.github 는 cd.tf 에 있다(prod 역할과 공용).
# =============================================================================

# dev 전용 ECR — prod repo 와 분리. 공유 시 dev push 가 lifecycle(imageCountMoreThan=10)로
# prod latest 이미지를 만료시키거나 latest 를 덮어쓰는 배포경계 위반이 생기므로 별도 repo 로 격리.
module "ecr_dev" {
  source = "../../modules/ecr"

  name = "${local.name}-dev"
}

# dev 개발 서버 — develop 이미지, dev ALB(dev.courmy.com) 뒤 private, DB 는 인스턴스 내 Docker Postgres 로 격리.
module "dev_server" {
  source = "../../modules/dev-server"

  name               = local.name
  name_tag           = "${local.name}-dev-app"
  vpc_id             = module.network.vpc_id
  subnet_id          = aws_subnet.dev.id             # dev 전용 프라이빗 서브넷
  alb_sg_id          = aws_security_group.dev_alb.id # ALB→8080 인바운드 허용
  aws_region         = var.aws_region
  ecr_repository_url = module.ecr_dev.repository_url # dev 전용 repo(prod 격리)

  # dev DB 는 인스턴스 내 Docker Postgres — prod RDS 안 씀(완전 격리)
  dev_db_password = random_password.dev_db.result

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

# dev 인스턴스가 기동 시 app_config 시크릿(kakao/jwt)을 읽도록 권한 부여(최소권한). DB 는 로컬이라 RDS 시크릿 불필요.
resource "aws_iam_role_policy" "dev_secret_read" {
  name = "${local.name}-dev-secret-read"
  role = module.dev_server.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.app_config.arn]
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

locals {
  dev_domain = "dev.${local.domain}"
}

# ───────── dev 전용 프라이빗 서브넷(단일 AZ) + NAT egress(기존 private RT 재사용) ─────────
resource "aws_subnet" "dev" {
  vpc_id            = module.network.vpc_id
  cidr_block        = "10.0.40.0/24"
  availability_zone = var.azs[0]

  tags = { Name = "${local.name}-dev", Tier = "dev" }
}

resource "aws_route_table_association" "dev" {
  subnet_id      = aws_subnet.dev.id
  route_table_id = module.network.private_route_table_id
}

# dev 로컬 Postgres 비밀번호(devnet 전용·미노출, dev 한정)
resource "random_password" "dev_db" {
  length  = 20
  special = false
}

# ───────── dev ALB (인터넷 페이싱, 기존 prod 퍼블릭 서브넷 재사용 — ALB 는 2 AZ 필요) ─────────
resource "aws_security_group" "dev_alb" {
  name        = "${local.name}-dev-alb-sg"
  description = "dev ALB - public 80/443"
  vpc_id      = module.network.vpc_id

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
  subnets            = module.network.public_subnet_ids

  tags = { Name = "${local.name}-dev-alb" }
}

resource "aws_lb_target_group" "dev" {
  name        = "${local.name}-dev-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = module.network.vpc_id
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

# ───────── ACM 인증서(ap-northeast-2, ALB용) — dev.courmy.com, Route53 DNS 검증 ─────────
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

  zone_id         = module.dns.zone_id
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

# dev.courmy.com → dev ALB (기존 prod Route53 zone 재사용)
resource "aws_route53_record" "dev" {
  zone_id = module.dns.zone_id
  name    = local.dev_domain
  type    = "A"

  alias {
    name                   = aws_lb.dev.dns_name
    zone_id                = aws_lb.dev.zone_id
    evaluate_target_health = true
  }
}

output "dev_url" {
  description = "dev 개발 서버 공개 URL"
  value       = "https://${local.dev_domain}"
}
