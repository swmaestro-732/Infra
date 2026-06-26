output "repository_url" {
  description = "ECR 레포지토리 URL (이미지 push/pull 대상)"
  value       = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  description = "ECR 레포지토리 ARN"
  value       = aws_ecr_repository.this.arn
}

output "repository_name" {
  description = "ECR 레포지토리 이름"
  value       = aws_ecr_repository.this.name
}
