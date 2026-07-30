variable "name" {
  description = "리소스 이름 접두사 (예: chilsami)"
  type        = string
}

variable "name_tag" {
  description = "인스턴스 Name 태그 (dev_access SSM 정책의 app_name_tags 와 일치해야 포트포워딩 허용)"
  type        = string
  default     = "chilsami-dev-app"
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  description = "dev 인스턴스를 둘 private 앱 서브넷 ID"
  type        = string
}

variable "aws_region" {
  type = string
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "app_port" {
  description = "호스트 포트(컨테이너 8080 매핑). SSM 포트포워딩 대상 포트."
  type        = number
  default     = 8080
}

variable "ecr_repository_url" {
  description = "백엔드 ECR 리포지토리 URL (prod 와 공용, dev 는 image_tag 로 구분)"
  type        = string
}

variable "image_tag" {
  description = "배포할 이미지 태그. develop CD 가 push 하는 dev-latest."
  type        = string
  default     = "dev-latest"
}

variable "db_secret_name" {
  description = "prod RDS 자격증명 시크릿 이름 (host/user/pass/port 재사용, DB 이름만 dev 로 오버라이드)"
  type        = string
}

variable "dev_db_name" {
  description = "dev 전용 데이터베이스 이름 (prod DB 와 격리)"
  type        = string
  default     = "chilsami_dev"
}

variable "app_config_secret_name" {
  type = string
}

variable "media_cdn_ssm_param_name" {
  type = string
}

variable "s3_media_bucket" {
  type = string
}
