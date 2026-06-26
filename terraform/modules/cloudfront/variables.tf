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

variable "enable_origin_verify" {
  description = "origin 시크릿 헤더 전달 활성화 여부 (plan 시점에 알아야 하므로 시크릿 값과 분리)."
  type        = bool
  default     = false
}

variable "origin_verify_secret" {
  description = "ALB origin 검증용 시크릿. enable_origin_verify=true 일 때 X-Origin-Verify 커스텀 헤더로 오리진에 전달."
  type        = string
  default     = ""
  sensitive   = true
}
