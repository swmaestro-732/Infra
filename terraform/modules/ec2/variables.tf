variable "name" {
  description = "리소스 이름 프리픽스"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "app_subnet_ids" {
  description = "인스턴스를 배치할 앱(프라이빗) 서브넷"
  type        = list(string)
}

variable "alb_sg_id" {
  description = "ALB 보안그룹 ID (인바운드 허용 소스)"
  type        = string
}

variable "target_group_arn" {
  description = "ALB 타깃 그룹 ARN"
  type        = string
}

variable "instance_type" {
  description = "EC2 인스턴스 타입"
  type        = string
  default     = "t3.small"
}

variable "app_port" {
  description = "컨테이너/인스턴스 포트"
  type        = number
  default     = 80
}

variable "desired_capacity" {
  description = "ASG 희망 용량"
  type        = number
  default     = 2
}

variable "min_size" {
  description = "ASG 최소"
  type        = number
  default     = 2
}

variable "max_size" {
  description = "ASG 최대"
  type        = number
  default     = 4
}
