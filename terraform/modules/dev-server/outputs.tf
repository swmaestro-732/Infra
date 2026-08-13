output "instance_id" {
  description = "dev 인스턴스 ID (SSM start-session --target 대상)"
  value       = aws_instance.dev.id
}

output "instance_arn" {
  description = "dev 인스턴스 ARN (CD 의 ssm:SendCommand Resource 한정용)"
  value       = aws_instance.dev.arn
}

output "security_group_id" {
  description = "dev 인스턴스 SG ID (RDS 인그레스 허용용)"
  value       = aws_security_group.dev.id
}

output "iam_role_name" {
  description = "dev 인스턴스 역할 이름 (시크릿 read 정책 부착용)"
  value       = aws_iam_role.dev.name
}
