output "security_group_id" {
  description = "DB 인그레스를 루트에서 연결할 크롤러 SG ID"
  value       = aws_security_group.this.id
}

output "asg_name" {
  description = "CD Instance Refresh 대상 ASG 이름"
  value       = aws_autoscaling_group.this.name
}

output "asg_arn" {
  description = "CD Instance Refresh 권한을 한정할 ASG ARN"
  value       = aws_autoscaling_group.this.arn
}

output "api_secret_arns" {
  description = "수동 주입할 API 시크릿 ARN (값은 출력하지 않음)"
  value       = { for key, secret in aws_secretsmanager_secret.api : key => secret.arn }
}

output "db_secret_arn" {
  description = "crawler_ro 프로비저닝에 사용할 시크릿 ARN (값은 출력하지 않음)"
  value       = aws_secretsmanager_secret.db.arn
}
