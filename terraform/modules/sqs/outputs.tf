output "queue_url" {
  description = "메인 큐 URL — 용도에 맞는 앱 환경변수로 주입."
  value       = aws_sqs_queue.main.url
}

output "queue_arn" {
  description = "메인 큐 ARN — 발행자·컨슈머 role IAM 정책 Resource."
  value       = aws_sqs_queue.main.arn
}

output "dlq_arn" {
  description = "DLQ ARN."
  value       = aws_sqs_queue.dlq.arn
}
