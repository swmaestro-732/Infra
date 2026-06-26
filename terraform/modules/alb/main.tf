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
resource "aws_lb_listener_rule" "origin_verify" {
  count        = var.enable_origin_verify ? 1 : 0
  listener_arn = aws_lb_listener.http.arn
  priority     = 1

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
