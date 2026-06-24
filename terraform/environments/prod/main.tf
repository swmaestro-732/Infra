# =============================================================================
# 칠삼이 인프라 — prod 환경 루트 (단일 AWS 계정)
# MVP1 구성: ALB → EC2(Docker) → RDS(Writer / Reader, Multi-AZ)
# 각 컴포넌트는 terraform/modules 아래 모듈로 작성하고 여기서 호출한다.
# =============================================================================

# TODO(MVP1): 네트워크 — VPC / Public·Private Subnet / IGW / NAT
# module "network" {
#   source      = "../../modules/network"
#   environment = var.environment
# }

# TODO(MVP1): ALB (Public Subnet, HTTPS 리스너)
# module "alb" {
#   source     = "../../modules/alb"
#   vpc_id     = module.network.vpc_id
#   subnet_ids = module.network.public_subnet_ids
# }

# TODO(MVP1): EC2 + Docker (Private Subnet, ALB 타깃)
# module "ec2" {
#   source    = "../../modules/ec2"
#   subnet_id = module.network.private_subnet_ids[0]
# }

# TODO(MVP1): RDS (Writer / Reader, Multi-AZ)
# module "rds" {
#   source     = "../../modules/rds"
#   subnet_ids = module.network.private_subnet_ids
# }
