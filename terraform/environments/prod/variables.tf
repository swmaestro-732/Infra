variable "aws_region" {
  description = "리소스를 배포할 AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "environment" {
  description = "환경 이름 (단일 환경 — prod)"
  type        = string
  default     = "prod"
}

variable "azs" {
  description = "사용할 가용영역 (2개)"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

# analysis-nori(한글 형태소) 플러그인 패키지 ID 오버라이드. 기본 빈 값 → opensearch 모듈이
# describe-packages 로 자동 조회하므로 보통 그대로 둔다. 특정 ID 로 핀하고 싶을 때만 채운다.
variable "opensearch_nori_package_id" {
  description = "analysis-nori 패키지 ID 오버라이드 (빈 값이면 모듈이 자동 조회)."
  type        = string
  default     = ""
}
