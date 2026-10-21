output "primary_endpoint" {
  description = "Valkey 프라이머리 엔드포인트(앱이 rediss:// 로 접속)"
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "port" {
  description = "Redis 포트"
  value       = aws_elasticache_replication_group.this.port
}

output "sg_id" {
  description = "Redis 보안그룹 ID"
  value       = aws_security_group.redis.id
}

output "auth_secret_arn" {
  description = "AUTH 토큰·엔드포인트 Secrets Manager ARN"
  value       = aws_secretsmanager_secret.auth.arn
}

output "auth_secret_name" {
  description = "AUTH 토큰 시크릿 이름(앱 env 주입용)"
  value       = aws_secretsmanager_secret.auth.name
}
