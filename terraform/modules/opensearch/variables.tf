variable "name" {
  description = "리소스 이름 접두사 (예: chilsami)"
  type        = string
}

variable "vpc_id" {
  description = "도메인을 배치할 VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "도메인을 배치할 서브넷 (검색 티어). 단일노드는 첫 1개, multi_az 는 첫 2개 사용"
  type        = list(string)

  validation {
    condition     = !var.multi_az || length(var.subnet_ids) >= 2
    error_message = "multi_az = true 면 subnet_ids 가 서로 다른 AZ 서브넷 2개 이상이어야 합니다."
  }
}

variable "app_sg_id" {
  description = "443 인그레스를 허용할 앱 인스턴스 보안그룹 ID"
  type        = string
}

variable "app_role_name" {
  description = "마스터 시크릿 읽기 권한을 부여할 앱 EC2 IAM 역할 이름 (null 이면 미부여)"
  type        = string
  default     = null
}

variable "engine_version" {
  description = "OpenSearch 엔진 버전"
  type        = string
  default     = "OpenSearch_2.11"
}

variable "instance_type" {
  description = "데이터 노드 인스턴스 타입"
  type        = string
  default     = "t3.small.search"
}

variable "instance_count" {
  description = "데이터 노드 수 (MVP 단일노드=1)"
  type        = number
  default     = 1
}

variable "multi_az" {
  description = "다중 AZ(zone awareness) 활성화 — true 면 서브넷/노드 2개 필요"
  type        = bool
  default     = false
}

variable "volume_size" {
  description = "노드당 EBS(gp3) 크기(GB) — t3.small.search 최소 10"
  type        = number
  default     = 10
}

variable "master_user_name" {
  description = "FGAC 마스터 사용자 이름"
  type        = string
  default     = "admin"
}

variable "log_retention_days" {
  description = "감사 로그 CloudWatch 보관일"
  type        = number
  default     = 14
}
