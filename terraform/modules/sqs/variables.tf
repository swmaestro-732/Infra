variable "name" {
  description = "큐 이름 프리픽스 (예: chilsami 또는 chilsami-dev). 큐는 <name>-course-count-events(+-dlq)."
  type        = string
}

variable "max_receive_count" {
  description = "메시지가 이 횟수만큼 재배달 실패하면 DLQ 로 이동 (poison message 격리)."
  type        = number
  default     = 5
}

variable "message_retention_seconds" {
  description = "미소비 메시지 큐 보관 기간(초). 기본 4일."
  type        = number
  default     = 345600
}

variable "dlq_message_retention_seconds" {
  description = "DLQ 보관 기간(초). 메인보다 길게 — SQS 는 DLQ 이동 시 원 enqueue timestamp 를 유지하므로, DLQ==메인이면 오래 묵은 메시지가 이동 직후 만료될 수 있다. 기본 14일."
  type        = number
  default     = 1209600
}

variable "visibility_timeout_seconds" {
  description = "컨슈머가 집은 메시지를 숨기는 시간(초). 이 안에 삭제 안 하면 재배달. 기본 30초."
  type        = number
  default     = 30
}
