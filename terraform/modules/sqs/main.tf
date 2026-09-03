# =============================================================================
# course→user 카운트 이벤트용 SQS (표준큐). 메인 큐 + DLQ(redrive).
# 정확성(이중집계 방지)의 근원은 컨슈머 eventId 멱등키(백엔드 소유) — 표준큐로 충분.
# IAM 권한은 이 모듈에 두지 않는다(env 루트에서 앱 role 에 부여) — ec2↔sqs 순환의존 회피.
# =============================================================================

# 데드레터 큐 — 처리에 반복 실패한 메시지를 격리 보관(유실 방지, 사후 재처리).
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name}-course-count-events-dlq"
  message_retention_seconds = var.message_retention_seconds

  tags = { Name = "${var.name}-course-count-events-dlq" }
}

# 메인 큐 — course 발행 이벤트 수신, user 컨슈머가 처리. maxReceiveCount 초과 시 DLQ 로 이동.
resource "aws_sqs_queue" "main" {
  name                       = "${var.name}-course-count-events"
  message_retention_seconds  = var.message_retention_seconds
  visibility_timeout_seconds = var.visibility_timeout_seconds

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = { Name = "${var.name}-course-count-events" }
}

# DLQ 는 이 메인 큐만 소스로 허용(다른 큐가 이 DLQ 를 쓰지 못하게 제한).
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main.arn]
  })
}
