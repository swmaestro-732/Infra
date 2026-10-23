variable "name" {
  description = "리소스 접두어"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "DocumentDB 서브넷 그룹용 프라이빗 DB 티어 서브넷(2개 AZ 이상)"
  type        = list(string)
}

variable "app_sg_id" {
  description = "앱 인스턴스 SG — 27017 접근 허용 대상"
  type        = string
}

variable "instance_class" {
  description = "DocumentDB 인스턴스 클래스"
  type        = string
  default     = "db.t3.medium"
}

variable "engine_version" {
  description = "DocumentDB 엔진 버전"
  type        = string
  default     = "5.0.0"
}

variable "backup_retention_days" {
  description = "자동 백업 보관 일수"
  type        = number
  default     = 7
}
