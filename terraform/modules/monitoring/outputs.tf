output "instance_id" {
  description = "모니터링 호스트 인스턴스 ID (SSM 세션·포트포워딩 대상)"
  value       = aws_instance.this.id
}

output "private_ip" {
  description = "모니터링 호스트 프라이빗 IP (앱 Alloy push 대상 — 후속 연동)"
  value       = aws_instance.this.private_ip
}

output "sg_id" {
  description = "모니터링 호스트 보안그룹 ID"
  value       = aws_security_group.monitoring.id
}

output "grafana_secret_arn" {
  description = "Grafana admin 자격증명 Secrets Manager ARN"
  value       = aws_secretsmanager_secret.grafana_admin.arn
}
