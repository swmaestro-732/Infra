output "zone_id" {
  description = "Route53 hosted zone ID"
  value       = aws_route53_zone.this.zone_id
}

output "name_servers" {
  description = "이 zone 의 네임서버 4개 — 가비아 도메인관리 → 네임서버에 등록(위임)한다."
  value       = aws_route53_zone.this.name_servers
}
