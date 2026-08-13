output "zone_id" {
  description = "Route53 hosted zone ID"
  value       = aws_route53_zone.this.zone_id
}

output "name_servers" {
  description = "이 zone 의 네임서버 4개 — 가비아 도메인관리 → 네임서버에 등록(위임)한다."
  value       = aws_route53_zone.this.name_servers
}

output "certificate_arn" {
  description = "CloudFront 용 ACM 인증서 ARN(us-east-1, 검증 완료). CloudFront viewer_certificate 에 사용."
  value       = aws_acm_certificate_validation.cloudfront.certificate_arn
}

output "acm_validation_record_fqdns" {
  description = "apex=wildcard 공용 검증 레코드 FQDN — 같은 *.courmy.com 도메인의 다른 리전 인증서(ALB용)가 재사용."
  value       = [for r in aws_route53_record.acm_validation : r.fqdn]
}
