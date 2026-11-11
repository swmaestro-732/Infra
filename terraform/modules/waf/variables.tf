variable "name" {
  description = "리소스 이름 프리픽스 (예: chilsami)."
  type        = string
}

variable "managed_rules_count_only" {
  description = "true 면 관리형 규칙과 요청 횟수 제한을 차단하지 않고 기록만 한다(Count). 오탐 확인 후 false 로 바꿔 차단한다. /actuator 차단은 항상 Block."
  type        = bool
  default     = true
}

variable "rate_limit_per_5min" {
  description = "IP 하나가 5분 동안 보낼 수 있는 요청 수. 넘으면 차단(또는 Count)."
  type        = number
  default     = 1000
}

variable "log_retention_days" {
  description = "WAF 로그(CloudWatch Logs) 보관 기간(일)."
  type        = number
  default     = 30
}
