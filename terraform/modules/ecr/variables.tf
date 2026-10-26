variable "name" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "service" {
  description = "이미지 서비스 이름 (기존 BackEnd 리포지토리는 기본값 유지)"
  type        = string
  default     = "backend"
}
