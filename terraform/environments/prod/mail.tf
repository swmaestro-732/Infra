# Google Workspace 메일(courmy.com). 값은 Admin 콘솔이 준 그대로 — DNS 에 공개되는 값이라 커밋해도 된다.
# 콘솔 수동 추가 대신 코드로 두어 새 AWS 계정으로 zone 을 옮길 때 그대로 재현되게 한다.
# DKIM·DMARC 는 Gmail 활성화 후 콘솔에서 DKIM 키를 받은 뒤 추가한다.

resource "aws_route53_record" "mail_mx" {
  zone_id = module.dns.zone_id
  name    = local.domain
  type    = "MX"
  ttl     = 300
  records = ["1 smtp.google.com"]
}

# Route53 은 같은 이름에 TXT 세트가 하나뿐이라 도메인 인증 값과 SPF 를 한 세트에 둔다.
# 인증 값은 인증이 끝난 뒤에도 지우지 않는다(Google 이 주기적으로 재확인).
resource "aws_route53_record" "apex_txt" {
  zone_id = module.dns.zone_id
  name    = local.domain
  type    = "TXT"
  ttl     = 300
  records = [
    "google-site-verification=cmCV3f2SO8srmAhqAFiZMen1jYVZTPvimQrurYWYECg",
    "v=spf1 include:_spf.google.com ~all",
  ]
}
