variable "name" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "domain_name" {
  description = "어드민 웹 도메인 (예: chilsami-admin.courmy.com)"
  type        = string
}

variable "certificate_arn" {
  description = "CloudFront 용 ACM 인증서 ARN(us-east-1). *.courmy.com 와일드카드가 domain_name 을 덮는다."
  type        = string
}

variable "content_security_policy" {
  description = "응답 헤더로 거는 CSP. 정적 사이트라 XSS 가 곧 어드민 토큰 유출이므로 외부 출처를 필요한 것만 연다."
  type        = string
}

variable "price_class" {
  description = "CloudFront 가격 등급"
  type        = string
  default     = "PriceClass_200"
}
