# DNS 모듈 — Route53 hosted zone.
# 가비아에서 구매한 도메인(courmy.com)의 NS 를 이 zone 으로 위임한다.
# ACM 인증서·검증(CloudFront용, us-east-1)은 NS 위임이 전파된 뒤 별도 PR 에서 추가한다.
resource "aws_route53_zone" "this" {
  name = var.domain_name

  tags = {
    Name = var.domain_name
  }
}
