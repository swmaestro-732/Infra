output "queue_url" {
  description = "메인 큐 URL — 앱에 SQS_FALLBACK_EVENTS_QUEUE_URL 로 주입."
  value       = aws_sqs_queue.main.url
}

output "queue_arn" {
  description = "메인 큐 ARN — 앱 role IAM 정책 Resource."
  value       = aws_sqs_queue.main.arn
}

output "dlq_arn" {
  description = "DLQ ARN."
  value       = aws_sqs_queue.dlq.arn
}
