# DNS 모듈 — Route53 hosted zone.
# 가비아에서 구매한 도메인(courmy.com)의 NS 를 이 zone 으로 위임한다.
# ACM 인증서·검증(CloudFront용, us-east-1)은 NS 위임이 전파된 뒤 별도 PR 에서 추가한다.
#
# DNSSEC(CKV2_AWS_38): MVP 범위 밖으로 의도적으로 비활성. 활성화하려면 us-east-1 비대칭 KMS 키(KSK)
# + aws_route53_key_signing_key + aws_route53_hosted_zone_dnssec 에 더해, 가비아(등록기관)에 DS 레코드를
# 수동 등록해 신뢰 체인을 완성해야 한다(HTTPS 연결 목표와는 무관). 도메인 안정화 후 후속 이슈로 검토.
resource "aws_route53_zone" "this" {
  name = var.domain_name

  tags = {
    Name = var.domain_name
  }
}
