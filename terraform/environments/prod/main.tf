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
}
