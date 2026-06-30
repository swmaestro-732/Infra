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

variable "aws_region" {
  description = "ECR 로그인·Secrets Manager 조회용 리전"
  type        = string
}

variable "ecr_repository_url" {
  description = "배포할 백엔드 이미지 ECR URL (없으면 nginx 플레이스홀더 유지)"
  type        = string
  default     = ""
}

variable "db_secret_name" {
  description = "DB 자격증명 Secrets Manager 시크릿 이름 (앱이 기동 시 fetch — 이름으로 전달해 rds 모듈과의 순환 의존 회피)"
  type        = string
  default     = ""
}
