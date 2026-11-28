variable "name" {
  description = "리소스 이름 접두사"
  type        = string
}

variable "bucket_name" {
  description = "미디어 S3 버킷 이름 (전역 유니크 — 계정 ID 접미사 권장). ec2 모듈의 S3_MEDIA_BUCKET 과 같은 값을 넘긴다."
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

variable "aliases" {
  description = "미디어 CDN 대체 도메인(CNAME). 예: [media.courmy.com]. 비우면 기본 도메인만 사용. 첫 항목이 SSM cdn-url 값이 된다."
  type        = list(string)
  default     = []
}

variable "acm_certificate_arn" {
  description = "us-east-1 ACM 인증서 ARN. aliases 를 쓰면 반드시 지정(aliases 를 커버해야 함). 비우면 CloudFront 기본 인증서."
  type        = string
  default     = ""
}
