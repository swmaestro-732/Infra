output "bucket_name" {
  description = "정적 파일을 올릴 S3 버킷 이름 (GitHub Variables ADMIN_BUCKET)"
  value       = aws_s3_bucket.this.bucket
}

output "bucket_arn" {
  description = "S3 버킷 ARN"
  value       = aws_s3_bucket.this.arn
}

output "distribution_id" {
  description = "CloudFront 배포 ID (GitHub Variables ADMIN_DISTRIBUTION_ID)"
  value       = aws_cloudfront_distribution.this.id
}

output "distribution_arn" {
  description = "CloudFront 배포 ARN"
  value       = aws_cloudfront_distribution.this.arn
}

output "distribution_domain_name" {
  description = "Route53 alias 대상 도메인"
  value       = aws_cloudfront_distribution.this.domain_name
}

output "distribution_hosted_zone_id" {
  description = "Route53 alias 대상 호스티드 존 ID"
  value       = aws_cloudfront_distribution.this.hosted_zone_id
}
