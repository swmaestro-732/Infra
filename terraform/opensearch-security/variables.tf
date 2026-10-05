variable "aws_region" {
  description = "AWS 리전 (시크릿/상태 버킷과 동일)"
  type        = string
  default     = "ap-northeast-2"
}

# OpenSearch 도메인은 VPC 내부 전용(퍼블릭 엔드포인트 없음)이라 CI/로컬에서 직접 못 닿는다.
# 유일한 apply 경로는 SSM 포트포워딩 터널(로컬 9243 → 도메인 443)이므로 기본값을 localhost 로 둔다.
# 터널을 쓰면 TLS SNI 가 localhost 라 도메인 인증서와 불일치 → insecure 로 검증을 끈다.
# (앱-도메인 트래픽은 VPC 내부에서만 오가고, 이 apply 는 운영자가 터널로 1회 수행한다. README 참조.)
variable "opensearch_url" {
  description = "opensearch provider 가 접속할 URL. 터널 사용 시 https://localhost:9243"
  type        = string
  default     = "https://localhost:9243"
}

variable "insecure" {
  description = "TLS 인증서 검증 생략(터널 localhost SNI 불일치 회피). 터널 apply 에서 true."
  type        = bool
  default     = true
}
