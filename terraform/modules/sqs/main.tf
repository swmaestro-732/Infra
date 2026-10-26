# SQS(표준큐). 메인 큐 + DLQ(redrive). queue_name 으로 폴백 이벤트·크롤링 결과 큐를 구분한다.
# 중복 배달은 컨슈머가 멱등 처리한다(폴백 이벤트는 eventId 멱등키).
# IAM 권한은 이 모듈에 안 두고 env 루트에서 앱 role 에 붙인다. ec2↔sqs 순환의존을 피하려는 것.
# queue_name 기본값은 fallback-events — 기존 큐 이름과 리소스 주소를 유지한다.

# 처리에 계속 실패한 메시지를 격리하는 큐. 유실 막고 나중에 다시 처리하려는 것.
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name}-${var.queue_name}-dlq"
  message_retention_seconds = var.dlq_message_retention_seconds # 메인보다 길게(이동 직후 만료 방지)

  tags = { Name = "${var.name}-${var.queue_name}-dlq" }
}

# 메인 큐. 발행된 이벤트를 받아 컨슈머가 처리한다. maxReceiveCount 넘기면 DLQ 로 넘어간다.
resource "aws_sqs_queue" "main" {
  name                       = "${var.name}-${var.queue_name}"
  message_retention_seconds  = var.message_retention_seconds
  visibility_timeout_seconds = var.visibility_timeout_seconds

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = { Name = "${var.name}-${var.queue_name}" }
}

# DLQ 는 이 메인 큐만 소스로 허용(다른 큐가 이 DLQ 를 쓰지 못하게 제한).
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main.arn]
  })
}
