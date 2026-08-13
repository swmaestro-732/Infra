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

variable "ecr_repository_arn" {
  description = "dev ECR 리포지토리 ARN — pull 권한을 이 repo 로만 스코프(최소권한)."
  type        = string
}

variable "image_tag" {
  description = "배포할 이미지 태그. develop CD 가 push 하는 dev-latest."
  type        = string
  default     = "dev-latest"
}

variable "alb_sg_id" {
  description = "dev ALB 보안그룹 ID — 이 인스턴스 앱 포트(8080) 인바운드 허용 소스"
  type        = string
}

variable "dev_db_name" {
  description = "dev 전용 로컬 Postgres 데이터베이스 이름"
  type        = string
  default     = "chilsami_dev"
}

variable "dev_db_user" {
  description = "dev 로컬 Postgres 사용자"
  type        = string
  default     = "chilsami"
}

variable "dev_db_password" {
  description = "dev 로컬 Postgres 비밀번호 (환경에서 random_password 로 주입). DB 는 devnet 전용·미노출이라 dev 한정 사용."
  type        = string
  sensitive   = true
}

variable "keys_secret_id" {
  description = "kakao/tmap/native 키를 읽을 시크릿 ID/ARN (prod app_config 공유)"
  type        = string
}

variable "jwt_secret_id" {
  description = "jwt_secret 을 읽을 dev 전용 시크릿 ID/ARN (prod 와 격리)"
  type        = string
}

variable "media_cdn_ssm_param_name" {
  type = string
}

variable "s3_media_bucket" {
  type = string
}
