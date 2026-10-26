output "dev_url" {
  description = "dev 개발 서버 공개 URL"
  value       = "https://${local.dev_domain}"
}

output "dev_server_instance_id" {
  description = "dev 인스턴스 ID (aws ssm start-session --target)"
  value       = module.dev_server.instance_id
}

output "dev_ecr_repository_url" {
  description = "dev 전용 ECR URL (BackEnd Actions vars DEV_ECR_REPOSITORY)"
  value       = module.ecr_dev.repository_url
}

output "crawl_results_queue_url" {
  description = "dev 크롤링 결과 큐 URL — 크롤러 발행·백엔드 소비용."
  value       = module.crawl_results_queue.queue_url
}

output "crawl_results_queue_arn" {
  description = "dev 크롤링 결과 큐 ARN — 크롤러 발행 권한 부여용."
  value       = module.crawl_results_queue.queue_arn
}

output "backend_deploy_dev_role_arn" {
  description = "BackEnd develop CD 가 assume 할 dev 배포 역할 ARN (Actions vars AWS_DEPLOY_ROLE_ARN_DEV)"
  value       = aws_iam_role.backend_deploy_dev.arn
}
