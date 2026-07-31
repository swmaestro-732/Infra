output "cloudfront_url" {
  description = "HTTPS 진입점 (CloudFront 기본 도메인)"
  value       = "https://${module.cloudfront.domain_name}"
}

output "site_url" {
  description = "커스텀 도메인 진입점 (루트·api 모두 CloudFront 로 연결)."
  value       = "https://${local.domain}"
}

output "route53_name_servers" {
  description = "courmy.com Route53 네임서버 4개 — 가비아 도메인관리 → 네임서버에 등록(위임)한다. 위임 전파 후 ACM/도메인 연결(2차 PR) 가능."
  value       = module.dns.name_servers
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
  description = "미디어 CloudFront 도메인 (스킴 없음). 앱 S3_MEDIA_CDN_URL(https://…)은 SSM /chilsami/media/cdn-url 로 주입됨"
  value       = module.media.cdn_domain_name
}

output "app_config_secret_arn" {
  # 배포 후 콘솔/CLI로 수동 주입(fail-closed, TF가 값 미생성). put-secret-value 로 아래 키 전체 JSON 주입:
  #   kakao_client_id, jwt_secret, kakao_rest_api_key(카카오 로컬 검색), tmap_app_key(Tmap 도보) — 모두 필수.
  #   kakao_native_app_key(안드로이드/iOS SDK 로그인 aud) — 선택(미주입 시 웹 로그인만).
  description = "앱 설정 시크릿 ARN. 필수 4키(kakao_client_id·jwt_secret·kakao_rest_api_key·tmap_app_key) + 선택 kakao_native_app_key — 배포 후 수동 주입."
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
