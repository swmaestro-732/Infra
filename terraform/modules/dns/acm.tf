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
  # 키는 domain_name 으로 잡는다(plan 시점에 알 수 있는 값). resource_record_name 은 인증서
  # 생성 후에야 정해지는 값이라 for_each 키로 쓰면 "Invalid for_each argument"(plan 시점 미지)로 실패한다.
  # apex + wildcard 는 동일한 검증 레코드를 내므로 allow_overwrite 로 충돌을 허용한다(HashiCorp ACM 공식 예시 패턴).
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
  allow_overwrite = true
}

# 검증 완료를 기다린다. cloudfront 는 이 리소스가 노출하는 certificate_arn 을 참조해 순서를 강제.
resource "aws_acm_certificate_validation" "cloudfront" {
  provider = aws.virginia

  certificate_arn         = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}
