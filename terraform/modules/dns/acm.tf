# CloudFront 용 ACM 인증서 — 반드시 us-east-1(aws.virginia). DNS 검증.
# 루트(courmy.com) + 와일드카드(*.courmy.com: api·www 등)를 한 인증서로 커버한다.
resource "aws_acm_certificate" "cloudfront" {
  provider = aws.virginia

  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# ACM DNS 검증 레코드 — 이 zone 에 생성(NS 위임이 전파됐으므로 검증이 통과한다).
resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cloudfront.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true # 루트/와일드카드가 같은 검증 레코드를 낼 때 충돌 방지
}

# 검증 완료를 기다린다. cloudfront 는 이 리소스가 노출하는 certificate_arn 을 참조해 순서를 강제.
resource "aws_acm_certificate_validation" "cloudfront" {
  provider = aws.virginia

  certificate_arn         = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}
