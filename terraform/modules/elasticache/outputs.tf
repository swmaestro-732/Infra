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

output "user_name" {
  description = "앱이 접속할 IAM 인증 user 이름(=user_id). SigV4 토큰의 User 파라미터."
  value       = aws_elasticache_user.app.user_name
}

output "replication_group_id" {
  description = "캐시 이름(=replication_group_id). SigV4 토큰 서명 대상 호스트."
  value       = aws_elasticache_replication_group.this.replication_group_id
}
