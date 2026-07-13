# =============================================================================
# 칠삼이 인프라 — prod 환경 루트 (단일 AWS 계정)
# MVP1 구성: ALB → EC2(Docker, ASG) → RDS(Writer Multi-AZ / Read Replica)
# =============================================================================

locals {
  name = "chilsami"
}

# CloudFront ↔ ALB origin 검증 시크릿 (직접 우회 차단)
resource "random_password" "origin_verify" {
  length  = 32
  special = false
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

module "cloudfront" {
  source = "../../modules/cloudfront"

  name                 = local.name
  alb_dns_name         = module.alb.alb_dns_name
  enable_origin_verify = true
  origin_verify_secret = random_password.origin_verify.result
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
