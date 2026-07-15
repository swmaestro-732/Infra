output "policy_arn" {
  description = "개발자 데이터스토어 접근 정책 ARN"
  value       = aws_iam_policy.datastore_access.arn
}

output "developer_user_names" {
  description = "생성된 개발자 IAM 사용자 이름 목록 (액세스키는 별도 발급)"
  value       = [for u in aws_iam_user.developer : u.name]
}
