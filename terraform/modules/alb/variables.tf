variable "name" {
  description = "리소스 이름 프리픽스"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "public_subnet_ids" {
  description = "ALB를 배치할 퍼블릭 서브넷"
  type        = list(string)
}

variable "app_port" {
  description = "타깃(EC2) 포트"
  type        = number
  default     = 80
}

variable "health_check_path" {
  description = "타깃 그룹 헬스체크 경로"
  type        = string
  default     = "/"
}

variable "ingress_cidrs" {
  description = "ALB 인바운드 허용 CIDR (MVP: 인터넷 / 추후 CloudFront prefix list로 제한)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_origin_verify" {
  description = "origin 시크릿 헤더 검증 활성화 여부 (plan 시점에 알아야 하므로 시크릿 값과 분리)."
  type        = bool
  default     = false
}

variable "origin_verify_secret" {
  description = "CloudFront origin 검증 시크릿. enable_origin_verify=true 일 때 X-Origin-Verify 헤더가 일치하는 요청만 타깃으로 전달(직접 우회 차단)."
  type        = string
  default     = ""
  sensitive   = true
}
