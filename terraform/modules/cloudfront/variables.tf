variable "name" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "alb_dns_name" {
  description = "오리진 ALB 의 DNS 이름"
  type        = string
}

variable "price_class" {
  description = "CloudFront 가격 등급 (PriceClass_200 = 북미·유럽·아시아 엣지 포함)"
  type        = string
  default     = "PriceClass_200"
}

variable "origin_verify_secret" {
  description = "ALB origin 검증용 시크릿. 설정 시 X-Origin-Verify 커스텀 헤더로 오리진에 전달."
  type        = string
  default     = ""
  sensitive   = true
}
