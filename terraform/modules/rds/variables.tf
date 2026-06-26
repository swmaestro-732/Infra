variable "name" {
  description = "리소스 이름 프리픽스"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "data_subnet_ids" {
  description = "DB 서브넷 그룹용 데이터 서브넷"
  type        = list(string)
}

variable "app_sg_id" {
  description = "DB 접근을 허용할 앱 인스턴스 보안그룹"
  type        = string
}

variable "engine_version" {
  description = "PostgreSQL 엔진 버전"
  type        = string
  default     = "16.4"
}

variable "parameter_group_family" {
  description = "DB 파라미터 그룹 패밀리 (engine_version 메이저와 일치)"
  type        = string
  default     = "postgres16"
}

variable "timezone" {
  description = "DB 타임존"
  type        = string
  default     = "Asia/Seoul"
}

variable "instance_class" {
  description = "RDS 인스턴스 클래스"
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "초기 DB 이름"
  type        = string
  default     = "chilsami"
}

variable "username" {
  description = "마스터 사용자"
  type        = string
  default     = "chilsami"
}

variable "allocated_storage" {
  description = "스토리지(GB)"
  type        = number
  default     = 20
}

variable "multi_az" {
  description = "Writer Multi-AZ standby 활성화 (false면 단일AZ, 자동 페일오버 없음)"
  type        = bool
  default     = false
}

variable "create_read_replica" {
  description = "읽기 복제본 생성 여부"
  type        = bool
  default     = true
}

variable "writer_az" {
  description = "Writer 가용영역 (multi_az=false일 때 고정)"
  type        = string
  default     = "ap-northeast-2a"
}

variable "reader_az" {
  description = "Read Replica 가용영역 (writer와 다른 AZ 권장)"
  type        = string
  default     = "ap-northeast-2c"
}

variable "app_role_name" {
  description = "시크릿 읽기 권한을 부여할 앱(EC2) IAM 역할 이름 (null이면 미부여)"
  type        = string
  default     = null
}
