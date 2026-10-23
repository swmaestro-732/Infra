output "endpoint" {
  description = "DocumentDB 클러스터(writer) 엔드포인트"
  value       = aws_docdb_cluster.this.endpoint
}

output "reader_endpoint" {
  description = "DocumentDB reader 엔드포인트"
  value       = aws_docdb_cluster.this.reader_endpoint
}

output "port" {
  description = "DocumentDB 포트"
  value       = aws_docdb_cluster.this.port
}

output "sg_id" {
  description = "DocumentDB 보안그룹 ID"
  value       = aws_security_group.docdb.id
}

output "secret_arn" {
  description = "접속 자격증명 Secrets Manager ARN"
  value       = aws_secretsmanager_secret.creds.arn
}

output "secret_name" {
  description = "마스터(admin) 자격증명 Secrets Manager 이름 (Infra 전용)"
  value       = aws_secretsmanager_secret.creds.name
}

output "endpoint_ssm_param_name" {
  description = "앱이 읽는 DocumentDB 엔드포인트 SSM Parameter 이름 (IAM 인증 — 자격증명 불필요)"
  value       = aws_ssm_parameter.endpoint.name
}
