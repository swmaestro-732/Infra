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

output "cdn_hosted_zone_id" {
  description = "CloudFront 배포의 Route53 hosted zone ID (커스텀 도메인 alias 레코드용)"
  value       = aws_cloudfront_distribution.this.hosted_zone_id
}

output "distribution_arn" {
  description = "CloudFront 배포 ARN"
  value       = aws_cloudfront_distribution.this.arn
}
