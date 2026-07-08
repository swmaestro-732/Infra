output "cloudfront_url" {
  description = "HTTPS 진입점 (CloudFront 기본 도메인)"
  value       = "https://${module.cloudfront.domain_name}"
}

output "ecr_repository_url" {
  description = "BackEnd 이미지 ECR URL (CD가 push)"
  value       = module.ecr.repository_url
}

output "backend_deploy_role_arn" {
  description = "BackEnd GitHub Actions CD 역할 ARN (레포 변수 AWS_DEPLOY_ROLE_ARN 로 등록)"
  value       = aws_iam_role.backend_deploy.arn
}

output "alb_dns_name" {
  description = "ALB DNS (CloudFront 오리진)"
  value       = module.alb.alb_dns_name
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.network.vpc_id
}

output "rds_writer_endpoint" {
  description = "RDS Writer 엔드포인트"
  value       = module.rds.writer_endpoint
}

output "rds_reader_endpoint" {
  description = "RDS Read Replica 엔드포인트"
  value       = module.rds.reader_endpoint
}

output "rds_secret_arn" {
  description = "DB 자격증명 Secrets Manager ARN"
  value       = module.rds.secret_arn
}

output "opensearch_endpoint" {
  description = "OpenSearch 도메인 VPC 엔드포인트 (앱 SG 경유 접근)"
  value       = module.opensearch.endpoint
}
