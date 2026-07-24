variable "domain_name" {
  description = "관리할 루트 도메인 (예: courmy.com). 가비아에서 구매했고, 이 Route53 zone 으로 NS 를 위임한다."
  type        = string
}
