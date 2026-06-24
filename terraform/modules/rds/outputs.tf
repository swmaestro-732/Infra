output "writer_endpoint" {
  description = "Writer 엔드포인트 (host:port)"
  value       = aws_db_instance.primary.endpoint
}

output "reader_endpoint" {
  description = "Read Replica 엔드포인트"
  value       = try(aws_db_instance.replica[0].endpoint, null)
}

output "rds_sg_id" {
  description = "RDS 보안그룹 ID"
  value       = aws_security_group.rds.id
}

output "secret_arn" {
  description = "DB 자격증명 Secrets Manager ARN"
  value       = aws_secretsmanager_secret.db.arn
}
