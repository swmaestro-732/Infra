# Google Workspace 메일(courmy.com). 값은 Admin 콘솔이 준 그대로 — DNS 에 공개되는 값이라 커밋해도 된다.
# 콘솔 수동 추가 대신 코드로 두어 새 AWS 계정으로 zone 을 옮길 때 그대로 재현되게 한다.

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

# DKIM 공개키(2048비트). 서명용 개인키는 Google 만 가진다 — 공개키는 DNS 로 공개하는 값.
locals {
  google_dkim = "v=DKIM1;k=rsa;p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAljkwyzJFkBRvOYZqHloHLLrU23biQZlrkeobKqIs6dZhIKMJsw23WoUPYHUMhMUeuy+ertEWszu+j2iu9otzVsC5HUHFR3p2pOtNp7a6DRafh1yeL1IXwZhXgl46qZGWxpcEpn9PWzBz5nKGhZ5/NCoxWTs8gP3MAJ2K4+Fo7nvvJJjLc5FUOVSPDzZanckrG5CVMzWVEQ8D9zCyRR2OEp8vPko6FmoWnBgx0w999kR1Taz9pvUmbT38N+f//mTcV+vNquLxBgS+apmdv0IuVmhkgXThK8pK3RRbu0putGGIfB4RRJUuQqgMwZ/H6ObIX7afWWEHhuMPcjtJFVYpcQIDAQAB"
}

# Route53 TXT 문자열은 255자 제한 → \"\" 로 두 문자열로 나눈다(AWS provider 문서 방식). 수신 측은 이어 붙여 읽는다.
resource "aws_route53_record" "dkim" {
  zone_id = module.dns.zone_id
  name    = "google._domainkey.${local.domain}"
  type    = "TXT"
  ttl     = 300
  records = ["${substr(local.google_dkim, 0, 255)}\"\"${substr(local.google_dkim, 255, -1)}"]
}

# DMARC 는 우선 관찰(p=none)로 시작한다. 리포트 수신 주소(rua)가 정해지면 추가하고, 이상 없으면 quarantine 으로 올린다.
resource "aws_route53_record" "dmarc" {
  zone_id = module.dns.zone_id
  name    = "_dmarc.${local.domain}"
  type    = "TXT"
  ttl     = 300
  records = ["v=DMARC1; p=none"]
}
