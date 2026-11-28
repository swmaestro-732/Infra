resource "aws_security_group" "alb" {
  name        = "${var.name}-alb-sg"
  description = "ALB ingress/egress"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.ingress_cidrs
  }

  # 443: dev.courmy.com 이 CloudFront 를 우회해 ALB 로 직결(TLS 종단). 공개 인바운드.
  ingress {
    description = "HTTPS (dev.courmy.com direct)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "all"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-alb-sg" }
}

resource "aws_lb" "this" {
  name                       = "${var.name}-alb"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = var.public_subnet_ids
  drop_invalid_header_fields = true

  tags = { Name = "${var.name}-alb" }
}

resource "aws_lb_target_group" "this" {
  name        = "${var.name}-tg"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200-399"
  }

  tags = { Name = "${var.name}-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  # enable_origin_verify=true: 헤더 없는 직접 접근은 403, CloudFront(헤더 보유) 만 아래 rule 로 전달.
  # false: 기존처럼 전부 forward. (게이트는 plan 시점에 아는 boolean 으로 판단)
  default_action {
    type             = var.enable_origin_verify ? "fixed-response" : "forward"
    target_group_arn = var.enable_origin_verify ? null : aws_lb_target_group.this.arn

    dynamic "fixed_response" {
      for_each = var.enable_origin_verify ? [1] : []
      content {
        content_type = "text/plain"
        message_body = "Forbidden"
        status_code  = "403"
      }
    }
  }
}

# CloudFront origin 시크릿 헤더가 일치할 때만 타깃으로 전달 (ALB 직접 우회 차단)
# priority 100: 그 앞(10~30)에 계정 이전 점검용 write-block 규칙이 끼어든다(아래).
resource "aws_lb_listener_rule" "origin_verify" {
  count        = var.enable_origin_verify ? 1 : 0
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [var.origin_verify_secret]
    }
  }

  # enable_origin_verify=true 인데 시크릿이 비면 빈 헤더로 검증 = 누구나 우회 → 차단
  lifecycle {
    precondition {
      condition     = var.origin_verify_secret != ""
      error_message = "enable_origin_verify=true 이면 origin_verify_secret 이 비어있을 수 없습니다."
    }
  }
}

# ───────── 계정 이전(cutover) 점검용 write-block (write_block_enabled=true 일 때만) ─────────
# CloudFront 가 쓰는 80 리스너에서 origin_verify(100)보다 먼저 평가된다. 쓰기(POST/PUT/PATCH/DELETE)와
# 실시간 채팅 경로를 503 으로 막아 이전 중 데이터 변경을 동결하고, 읽기는 그대로 통과시킨다.
# 운영자 검증용으로 X-Cutover-Bypass 헤더(+origin 헤더)가 맞으면 쓰기도 타깃으로 보낸다.
locals {
  write_block_body = jsonencode({ message = "서비스 이전 점검 중입니다. 잠시 후 다시 시도해 주세요." })
}

resource "aws_lb_listener_rule" "write_block_bypass" {
  count        = var.write_block_enabled ? 1 : 0
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }

  dynamic "condition" {
    for_each = var.enable_origin_verify ? [1] : []
    content {
      http_header {
        http_header_name = "X-Origin-Verify"
        values           = [var.origin_verify_secret]
      }
    }
  }

  condition {
    http_header {
      http_header_name = "X-Cutover-Bypass"
      values           = [var.write_block_bypass_value]
    }
  }

  # 바이패스 값이 비면 우회 헤더 검증이 무의미 → 차단
  lifecycle {
    precondition {
      condition     = var.write_block_bypass_value != ""
      error_message = "write_block_enabled=true 이면 write_block_bypass_value 가 비어있을 수 없습니다."
    }
  }
}

resource "aws_lb_listener_rule" "write_block_methods" {
  count        = var.write_block_enabled ? 1 : 0
  listener_arn = aws_lb_listener.http.arn
  priority     = 20

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = local.write_block_body
      status_code  = "503"
    }
  }

  condition {
    http_request_method {
      values = ["POST", "PUT", "PATCH", "DELETE"]
    }
  }
}

resource "aws_lb_listener_rule" "write_block_paths" {
  count        = var.write_block_enabled && length(var.write_block_paths) > 0 ? 1 : 0
  listener_arn = aws_lb_listener.http.arn
  priority     = 30

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = local.write_block_body
      status_code  = "503"
    }
  }

  condition {
    path_pattern {
      values = var.write_block_paths
    }
  }
}
