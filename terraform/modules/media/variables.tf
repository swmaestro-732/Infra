variable "name" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "app_role_name" {
  description = "S3 쓰기 권한을 부여할 앱(EC2) IAM 역할 이름 (null 이면 정책 미부착)"
  type        = string
  default     = null
}

variable "frontend_origins" {
  description = "프리사인 업로드(PUT)를 허용할 웹 프론트엔드 오리진 목록 (CORS AllowedOrigins). 비우면([]) CORS 미설정 — 네이티브 앱 전용(브라우저 업로드 없음)이면 빈 값. 와일드카드(['*']) 금지."
  type        = list(string)
  default     = []
}

variable "price_class" {
  description = "CloudFront 가격 등급 (PriceClass_200 = 북미·유럽·아시아 엣지 포함)"
  type        = string
  default     = "PriceClass_200"
}
