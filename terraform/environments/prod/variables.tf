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

# ───────── 계정 이전(cutover) 스위치 ─────────
# 구 계정이 courmy.com·api.courmy.com 의 CloudFront alias·레코드를 보유한 동안엔 false 로 apply 하고,
# alias 이전(update-domain-association) 후 true 로 바꿔 Terraform 관리로 되돌린다.
variable "attach_site_aliases" {
  description = "백엔드 CloudFront 에 site_domains alias 를 붙일지. false 면 alias 없이 ACM 인증서만 연결(alias 이전 대상 준비)."
  type        = bool
  default     = false
}

variable "manage_site_records" {
  description = "site_domains 의 Route53 A/AAAA alias 레코드를 Terraform 이 만들지(allow_overwrite 로 임시 레코드 인수)."
  type        = bool
  default     = false
}

variable "write_block_enabled" {
  description = "ALB write-block(쓰기 메서드 503) 활성화 — 이전 중 데이터 동결용. 우회 헤더 값은 output write_block_bypass_value."
  type        = bool
  default     = false
}
