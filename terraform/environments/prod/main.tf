# =============================================================================
# 칠삼이 인프라 — prod 환경 루트 (단일 AWS 계정)
# MVP1 구성: ALB → EC2(Docker, ASG) → RDS(Writer Multi-AZ / Read Replica)
# =============================================================================

locals {
  name   = "chilsami"
  domain = "courmy.com" # 가비아 구매. NS 를 Route53 zone 으로 위임한다.

  # 커스텀 도메인 목록(루트 + api). CloudFront aliases 와 Route53 레코드에서 공통으로 쓴다.
  # 도메인 추가/변경은 여기 한 곳만 고치면 된다.
  site_domains = [local.domain, "api.${local.domain}"]
}

# CloudFront ↔ ALB origin 검증 시크릿 (직접 우회 차단)
resource "random_password" "origin_verify" {
  length  = 32
  special = false
}

# 앱 설정 시크릿 (kakao_client_id, jwt_secret + 지도 API 키) — DB 시크릿과 달리 값은 Terraform이 생성하지 않는다.
# 의도적으로 secret_version 을 만들지 않는다(fail-closed): 알려진 플레이스홀더 서명키가
# 잠시라도 배포되면 JWT 위조가 가능하므로, 실제 값은 배포 후 콘솔/CLI로 반드시 수동 주입한다.
#   aws secretsmanager put-secret-value --secret-id chilsami/app/config \
#     --secret-string '{"kakao_client_id":"<실값>","jwt_secret":"<32B+ 실값>",
#       "kakao_rest_api_key":"<카카오 로컬 REST 키>","tmap_app_key":"<Tmap>"}'
# kakao_client_id·jwt_secret·kakao_rest_api_key·tmap_app_key **모두 필수**(fail-closed) — 4개를 한 JSON 으로 주입한다.
# 값 주입 전에는 EC2 부트스트랩의 get-secret-value 가 실패하고, user_data 의 재시도
# 백오프가 값이 채워질 때까지 대기한다(ec2 모듈 참고).
resource "aws_secretsmanager_secret" "app_config" {
  name        = "${local.name}/app/config"
  description = "앱 설정 시크릿 (kakao_client_id·jwt_secret·kakao_rest_api_key·tmap_app_key 모두 필수) — 값은 배포 후 수동 주입(fail-closed, TF가 값 미생성)"
}

module "network" {
  source = "../../modules/network"

  name = local.name
  azs  = var.azs
}

module "alb" {
  source = "../../modules/alb"

  name                 = local.name
  vpc_id               = module.network.vpc_id
  public_subnet_ids    = module.network.public_subnet_ids
  enable_origin_verify = true
  origin_verify_secret = random_password.origin_verify.result
  health_check_path    = "/actuator/health" # Spring 앱 health (permitAll·200)
}

module "ecr" {
  source = "../../modules/ecr"

  name = local.name
}

module "dns" {
  source = "../../modules/dns"

  # ACM(CloudFront용)은 us-east-1 이어야 하므로 virginia provider 를 주입한다.
  providers = {
    aws          = aws
    aws.virginia = aws.virginia
  }

  domain_name = local.domain
}

module "cloudfront" {
  source = "../../modules/cloudfront"

  name                 = local.name
  alb_dns_name         = module.alb.alb_dns_name
  enable_origin_verify = true
  origin_verify_secret = random_password.origin_verify.result

  # 커스텀 도메인 연결(루트 + api). 인증서는 dns 모듈이 발급·검증한 us-east-1 ACM.
  aliases             = local.site_domains
  acm_certificate_arn = module.dns.certificate_arn
}

# 도메인 → CloudFront alias 레코드. courmy.com·api.courmy.com 모두 백엔드 CloudFront 로 향한다.
# (루트는 추후 프론트로 재지정 가능.) A(IPv4)·AAAA(IPv6) 둘 다 둔다.
resource "aws_route53_record" "site" {
  for_each = toset(local.site_domains)

  zone_id = module.dns.zone_id
  name    = each.value
  type    = "A"

  alias {
    name                   = module.cloudfront.domain_name
    zone_id                = module.cloudfront.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "site_ipv6" {
  for_each = toset(local.site_domains)

  zone_id = module.dns.zone_id
  name    = each.value
  type    = "AAAA"

  alias {
    name                   = module.cloudfront.domain_name
    zone_id                = module.cloudfront.hosted_zone_id
    evaluate_target_health = false
  }
}

module "ec2" {
  source = "../../modules/ec2"

  name             = local.name
  vpc_id           = module.network.vpc_id
  app_subnet_ids   = module.network.app_subnet_ids
  alb_sg_id        = module.alb.alb_sg_id
  target_group_arn = module.alb.target_group_arn

  # 백엔드 배포: ECR 이미지 pull + Secrets Manager 에서 DB접속 fetch
  aws_region         = var.aws_region
  ecr_repository_url = module.ecr.repository_url
  db_secret_name     = "${local.name}/rds/credentials" # 이름으로 전달(rds 모듈과 순환 의존 회피)

  # Kakao/JWT 설정 — 이름으로 전달(위 시크릿 리소스와 순환 의존 없음)
  app_config_secret_name = aws_secretsmanager_secret.app_config.name

  # 미디어 S3/CDN — 버킷명은 결정적 문자열로 직접 조합, CDN 도메인은 SSM Parameter 이름으로 전달
  # (둘 다 module.media 의 output 을 직접 참조하지 않음 — media 가 이미 이 모듈의 app_role_name 을
  #  참조하므로, 반대 방향 참조를 추가하면 순환 의존이 발생한다)
  s3_media_bucket          = "${local.name}-media-ap-northeast-2"
  media_cdn_ssm_param_name = "/${local.name}/media/cdn-url"
}

# 앱이 기동 시 Kakao/JWT 설정 시크릿을 읽도록 EC2 역할에 권한 부여 (최소권한)
resource "aws_iam_role_policy" "app_config_secret_read" {
  name = "${local.name}-app-config-secret-read"
  role = module.ec2.iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.app_config.arn
    }]
  })
}

module "rds" {
  source = "../../modules/rds"

  name            = local.name
  vpc_id          = module.network.vpc_id
  data_subnet_ids = module.network.data_subnet_ids
  app_sg_id       = module.ec2.instance_sg_id

  # 단일 AZ writer(2a) + cross-AZ reader(2c) — standby 대신 읽기 가능한 복제본 운용
  multi_az            = false
  create_read_replica = true
  writer_az           = var.azs[0]
  reader_az           = var.azs[1]

  # 앱이 기동 시 시크릿(writer/reader host)을 읽도록 EC2 역할에 권한 부여
  app_role_name = module.ec2.iam_role_name
}

module "opensearch" {
  source = "../../modules/opensearch"

  name       = local.name
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.search_subnet_ids # 검색·캐시 전용 티어(프라이빗)에 배치
  app_sg_id  = module.ec2.instance_sg_id        # 앱 인스턴스만 443 접근

  # MVP: 단일 노드로 시작 (여유 시 multi_az=true + instance_count=2)
  instance_count = 1
  multi_az       = false

  # SLR(AWSServiceRoleForAmazonOpenSearchService)은 이전 CreateDomain 시도 때
  # AWS 가 이미 자동 생성함 → Terraform 이 중복 생성하지 않도록 false.
  create_service_linked_role = false

  # 앱이 마스터 시크릿(엔드포인트·자격증명)을 읽도록 EC2 역할에 권한 부여
  app_role_name = module.ec2.iam_role_name
}

module "monitoring" {
  source = "../../modules/monitoring"

  name       = local.name
  vpc_id     = module.network.vpc_id
  subnet_id  = module.network.app_subnet_ids[0] # 앱 티어(프라이빗)에 배치
  app_sg_id  = module.ec2.instance_sg_id        # 로그/트레이스 push 인그레스 + 스크레이프 룰
  aws_region = var.aws_region
}

module "media" {
  source = "../../modules/media"

  name          = local.name
  app_role_name = module.ec2.iam_role_name
  # 모바일 앱 전용 — 브라우저 업로드가 없어 CORS 불필요(빈 목록 → CORS 리소스 미생성).
  # 웹 프론트 도입 시 실제 오리진 목록으로 지정할 것(와일드카드 금지).
  frontend_origins = []
}

# 개발자용 데이터스토어 접근 IAM (SSM 터널로 RDS/OpenSearch + 접속 시크릿 read, 최소권한)
module "dev_access" {
  source = "../../modules/iam"

  name = local.name
  # 1인 1사용자 권장(감사). 팀원 추가 시 여기에 이름 추가 후 apply, 액세스키는 별도 발급.
  developer_usernames = ["chilsami-be-dev"]
}
