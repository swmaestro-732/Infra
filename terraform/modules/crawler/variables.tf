variable "name" {
  description = "환경별 리소스 접두사 (chilsami / chilsami-dev)"
  type        = string
}

variable "environment" {
  description = "Spring 프로파일 및 egress 정책 (prod / dev)"
  type        = string

  validation {
    condition     = contains(["prod", "dev"], var.environment)
    error_message = "environment 는 prod 또는 dev 여야 합니다."
  }
}

variable "vpc_id" {
  description = "크롤러 VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "NAT 경로가 있는 프라이빗 서브넷 ID 목록"
  type        = list(string)
}

variable "aws_region" {
  description = "AWS API 및 로그 리전"
  type        = string
}

variable "desired_capacity" {
  description = "고정 인스턴스 수 (0 또는 1, min/max/desired 동일)"
  type        = number
  default     = 1

  validation {
    condition     = contains([0, 1], var.desired_capacity)
    error_message = "크롤러는 환경별 0 또는 1대만 허용합니다."
  }
}

variable "enabled" {
  description = "크롤링 작업 실행 여부 (dev 검증 전에는 false)"
  type        = bool
  default     = false
}

variable "ecr_repository_url" {
  description = "크롤러 ECR URL (:latest, linux/arm64 이미지)"
  type        = string
}

variable "ecr_repository_arn" {
  description = "pull 을 허용할 크롤러 ECR ARN"
  type        = string
}

variable "queue_url" {
  description = "크롤링 결과 SQS URL"
  type        = string
}

variable "queue_arn" {
  description = "발행을 허용할 크롤링 결과 SQS ARN"
  type        = string
}

variable "db_url" {
  description = "JDBC URL (prod Reader / dev 로컬 Postgres, 자격증명 제외)"
  type        = string
}

variable "db_security_group_id" {
  description = "dev egress 5432 목적지 SG. prod 는 전체 egress 라 쓰지 않는다(null)."
  type        = string
  default     = null
}

variable "media_bucket" {
  description = "crawler/* 업로드 대상 미디어 버킷 이름"
  type        = string
}

variable "cdn_base_url" {
  description = "미디어 CloudFront URL (https:// 포함)"
  type        = string
}

variable "instance_types" {
  description = "spot 후보 인스턴스 타입(arm64). 첫 번째가 기본, 재고가 없으면 나머지로 확보한다."
  type        = list(string)
  default     = ["t4g.small", "t4g.medium", "c7g.medium", "m7g.medium"]
}
