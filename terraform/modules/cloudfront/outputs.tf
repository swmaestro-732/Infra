output "domain_name" {
  description = "CloudFront 배포 도메인 (*.cloudfront.net)"
  value       = aws_cloudfront_distribution.this.domain_name
}

output "distribution_id" {
  description = "CloudFront 배포 ID"
  value       = aws_cloudfront_distribution.this.id
}

output "distribution_arn" {
  description = "CloudFront 배포 ARN"
  value       = aws_cloudfront_distribution.this.arn
}
