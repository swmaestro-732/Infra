# =============================================================================
# 칠삼이 인프라 — prod 환경 루트 (단일 AWS 계정)
# MVP1 구성: ALB → EC2(Docker, ASG) → RDS(Writer Multi-AZ / Read Replica)
# =============================================================================

locals {
  name = "chilsami"
}

module "network" {
  source = "../../modules/network"

  name = local.name
  azs  = var.azs
}

module "alb" {
  source = "../../modules/alb"

  name              = local.name
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
}

module "cloudfront" {
  source = "../../modules/cloudfront"

  name         = local.name
  alb_dns_name = module.alb.alb_dns_name
}

module "ec2" {
  source = "../../modules/ec2"

  name             = local.name
  vpc_id           = module.network.vpc_id
  app_subnet_ids   = module.network.app_subnet_ids
  alb_sg_id        = module.alb.alb_sg_id
  target_group_arn = module.alb.target_group_arn
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
