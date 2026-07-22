output "bucket_name" {
  description = "미디어 S3 버킷 이름"
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "미디어 S3 버킷 ARN"
  value       = aws_s3_bucket.this.arn
}

output "cdn_domain_name" {
  description = "CloudFront 배포 도메인 (*.cloudfront.net) — 미디어 조회는 이 도메인 경유"
  value       = aws_cloudfront_distribution.this.domain_name
}

output "distribution_arn" {
  description = "CloudFront 배포 ARN"
  value       = aws_cloudfront_distribution.this.arn
}
