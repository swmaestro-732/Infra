variable "name" {
  description = "리소스 이름 프리픽스"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "public_subnet_ids" {
  description = "ALB를 배치할 퍼블릭 서브넷"
  type        = list(string)
}

variable "app_port" {
  description = "타깃(EC2) 포트"
  type        = number
  default     = 80
}

variable "health_check_path" {
  description = "타깃 그룹 헬스체크 경로"
  type        = string
  default     = "/"
}

variable "ingress_cidrs" {
  description = "ALB 인바운드 허용 CIDR (MVP: 인터넷 / 추후 CloudFront prefix list로 제한)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_origin_verify" {
  description = "origin 시크릿 헤더 검증 활성화 여부 (plan 시점에 알아야 하므로 시크릿 값과 분리)."
  type        = bool
  default     = false
}

variable "origin_verify_secret" {
  description = "CloudFront origin 검증 시크릿. enable_origin_verify=true 일 때 X-Origin-Verify 헤더가 일치하는 요청만 타깃으로 전달(직접 우회 차단)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "write_block_enabled" {
  description = "계정 이전 점검용 write-block 활성화. true 면 80 리스너에서 쓰기 메서드·write_block_paths 를 503 으로 막는다(X-Cutover-Bypass 헤더 일치 시 통과)."
  type        = bool
  default     = false
}

variable "write_block_bypass_value" {
  description = "write-block 우회 헤더(X-Cutover-Bypass) 값. write_block_enabled=true 면 필수."
  type        = string
  default     = ""
  sensitive   = true
}

variable "write_block_paths" {
  description = "write-block 시 메서드와 무관하게 503 으로 막을 경로 패턴(예: 채팅 WebSocket/STOMP 엔드포인트). 비우면 경로 규칙 미생성."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.write_block_paths) <= 5
    error_message = "ALB path-pattern 조건 값은 규칙당 최대 5개다."
  }
}
