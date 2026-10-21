output "endpoint" {
  description = "OpenSearch 도메인 VPC 엔드포인트"
  value       = aws_opensearch_domain.this.endpoint
}

output "domain_arn" {
  description = "OpenSearch 도메인 ARN"
  value       = aws_opensearch_domain.this.arn
}

output "sg_id" {
  description = "OpenSearch 보안그룹 ID"
  value       = aws_security_group.opensearch.id
}

output "admin_role_arn" {
  description = "FGAC 마스터 IAM 역할 ARN"
  value       = aws_iam_role.admin.arn
}

output "master_secret_arn" {
  description = "OpenSearch 접속 정보(endpoint, region, assume_role_arn) Secrets Manager ARN"
  value       = aws_secretsmanager_secret.master.arn
}
