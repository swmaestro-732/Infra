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

output "monitoring_instance_id" {
  description = "모니터링(LGTM) 호스트 인스턴스 ID — SSM 포트포워딩(3000)으로 Grafana 접근"
  value       = module.monitoring.instance_id
}

output "grafana_secret_arn" {
  description = "Grafana admin 자격증명 Secrets Manager ARN"
  value       = module.monitoring.grafana_secret_arn
}

output "media_bucket_name" {
  description = "미디어 S3 버킷 이름 (앱 S3_MEDIA_BUCKET env)"
  value       = module.media.bucket_name
}

output "media_cdn_domain" {
  description = "미디어 CloudFront 도메인 (앱 S3_MEDIA_CDN_URL env)"
  value       = module.media.cdn_domain_name
}

output "app_config_secret_arn" {
  description = "앱 설정(KAKAO_CLIENT_ID, JWT_SECRET) Secrets Manager ARN — 배포 후 콘솔/CLI로 실제 값 수동 설정 필요"
  value       = aws_secretsmanager_secret.app_config.arn
}

output "dev_datastore_policy_arn" {
  description = "개발자 데이터스토어 접근 정책 ARN"
  value       = module.dev_access.policy_arn
}

output "dev_datastore_user_names" {
  description = "데이터스토어 접근 개발자 IAM 사용자 목록 (액세스키는 별도 발급)"
  value       = module.dev_access.developer_user_names
}
