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

output "hosted_zone_id" {
  description = "CloudFront 배포의 Route53 hosted zone ID (alias 레코드용, 전역 고정값을 하드코딩하지 않기 위해 노출)."
  value       = aws_cloudfront_distribution.this.hosted_zone_id
}
