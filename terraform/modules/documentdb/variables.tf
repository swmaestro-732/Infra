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

variable "app_role_name" {
  description = "앱 EC2 역할 이름 — IAM 인증 시 $external 유저로 등록될 역할(프로비저닝 후속 티켓에서 사용). 앱은 마스터 시크릿을 읽지 않는다."
  type        = string
  default     = null
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
