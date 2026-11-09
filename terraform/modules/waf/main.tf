# CloudFront 앞단 AWS WAF (SCRUM-788). CLOUDFRONT 범위라 us-east-1 provider 로 만들어야 한다(호출부에서 주입).
# - /actuator 차단: 관리 엔드포인트(prometheus 전체 메트릭 등) 외부 노출 방지. 항상 Block.
# - 관리형 규칙(Known bad inputs, IP reputation)과 IP 당 요청 횟수 제한: 봇 스캔 대응.
#   오탐 확인 전까지 managed_rules_count_only=true 로 기록만 하고, 확인 후 false 로 차단한다.

locals {
  managed_count = var.managed_rules_count_only
}

resource "aws_wafv2_web_acl" "this" {
  name        = "${var.name}-cdn"
  description = "${var.name} CloudFront Web ACL"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # 오리진(Tomcat, Spring)은 %61ctuator, //actuator, /api/../actuator 같은 변형도 /actuator 로 해석한다.
  # URL 디코딩, 경로 정규화, 소문자화를 거친 뒤 판별해 이런 우회를 같이 막는다. 응답은 존재를 드러내지 않게 404.
  rule {
    name     = "block-actuator"
    priority = 0

    action {
      block {
        custom_response {
          response_code = 404
        }
      }
    }

    statement {
      byte_match_statement {
        search_string         = "/actuator"
        positional_constraint = "STARTS_WITH"

        field_to_match {
          uri_path {}
        }

        text_transformation {
          priority = 0
          type     = "URL_DECODE"
        }
        text_transformation {
          priority = 1
          type     = "NORMALIZE_PATH"
        }
        text_transformation {
          priority = 2
          type     = "LOWERCASE"
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-block-actuator"
      sampled_requests_enabled   = false
    }
  }

  # 알려진 공격 패턴(Log4j, 경로 조작 등)과 취약점 스캐너 요청.
  rule {
    name     = "aws-known-bad-inputs"
    priority = 10

    override_action {
      dynamic "count" {
        for_each = local.managed_count ? [1] : []
        content {}
      }
      dynamic "none" {
        for_each = local.managed_count ? [] : [1]
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-known-bad-inputs"
      sampled_requests_enabled   = false
    }
  }

  # AWS 위협 인텔리전스 기반 악성 IP(봇, 정찰 소스).
  rule {
    name     = "aws-ip-reputation"
    priority = 20

    override_action {
      dynamic "count" {
        for_each = local.managed_count ? [1] : []
        content {}
      }
      dynamic "none" {
        for_each = local.managed_count ? [] : [1]
        content {}
      }
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-ip-reputation"
      sampled_requests_enabled   = false
    }
  }

  # IP 당 5분 요청 수 제한. 스캔은 수 분 안에 약 200건씩 몰려 들어온다(11-06 관측).
  rule {
    name     = "rate-limit-per-ip"
    priority = 30

    action {
      dynamic "count" {
        for_each = local.managed_count ? [1] : []
        content {}
      }
      dynamic "block" {
        for_each = local.managed_count ? [] : [1]
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit                 = var.rate_limit_per_5min
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-rate-limit"
      sampled_requests_enabled   = false
    }
  }

  # 샘플 요청은 redacted_fields 를 거치지 않아 인증 헤더와 쿠키가 원문으로 남으므로 규칙과 ACL 모두 끈다.
  # 오탐 확인은 마스킹된 CloudWatch 로그(aws-waf-logs-*)로 한다.
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-cdn-waf"
    sampled_requests_enabled   = false
  }

  tags = {
    Name = "${var.name}-cdn-waf"
  }
}

# WAF 로그(요청 IP, 경로, User-Agent, 매칭 규칙). 이름은 aws-waf-logs- 로 시작해야 한다.
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.name}-cdn"
  retention_in_days = var.log_retention_days
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  # 로그에 개인정보와 인증 정보가 남지 않게 가린다. 봇 분석에 필요한 IP, 경로, User-Agent 는 남긴다.
  # - authorization, cookie: 인증 토큰
  # - query_string: 사용자 위치(userLat, userLng)와 검색어가 쿼리로 온다
  # - x-device-id: 기기 식별자
  # - referer: 이전 페이지 URL 에 위치와 검색어 쿼리가 그대로 담길 수 있다
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
  redacted_fields {
    single_header {
      name = "x-device-id"
    }
  }
  redacted_fields {
    single_header {
      name = "referer"
    }
  }
  redacted_fields {
    query_string {}
  }
}
