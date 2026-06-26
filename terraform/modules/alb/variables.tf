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
