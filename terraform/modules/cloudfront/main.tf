# CloudFront — ALB 앞단 CDN. 기본 도메인(*.cloudfront.net)으로 즉시 HTTPS 제공.
# 캐싱은 비활성(API 트래픽). 실도메인 확보 시 aliases + ACM(us-east-1) 인증서를 추가한다.

# 관리형 정책은 ID 하드코딩 대신 이름으로 조회 (계정/리전마다 ID 안전)
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  comment         = "${var.name} CDN (ALB origin)"
  is_ipv6_enabled = true
  price_class     = var.price_class
  http_version    = "http2and3"

  # 커스텀 도메인(있을 때만). acm_certificate_arn 과 짝을 이룬다.
  aliases = var.aliases

  origin {
    domain_name = var.alb_dns_name
    origin_id   = "alb"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # ALB 에 HTTPS 리스너가 없으므로 HTTP 로 연결
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # ALB 가 이 헤더를 요구하도록 설정되어 있으면, CloudFront 만 통과(직접 우회 차단)
    dynamic "custom_header" {
      for_each = var.enable_origin_verify ? [1] : []
      content {
        name  = "X-Origin-Verify"
        value = var.origin_verify_secret
      }
    }
  }

  default_cache_behavior {
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https" # 뷰어는 항상 HTTPS 로
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]

    # 관리형 정책: 캐싱 비활성 + 모든 뷰어 요청(헤더/쿠키/쿼리) 오리진 전달 = API 동작
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # acm_certificate_arn 이 비면 기본 인증서(*.cloudfront.net), 있으면 커스텀 도메인 인증서.
  dynamic "viewer_certificate" {
    for_each = var.acm_certificate_arn == "" ? [1] : []
    content {
      cloudfront_default_certificate = true
    }
  }

  dynamic "viewer_certificate" {
    for_each = var.acm_certificate_arn == "" ? [] : [1]
    content {
      acm_certificate_arn      = var.acm_certificate_arn
      ssl_support_method       = "sni-only"
      minimum_protocol_version = "TLSv1.2_2021"
    }
  }

  tags = {
    Name = "${var.name}-cdn"
  }

  # enable_origin_verify=true 인데 시크릿이 비면 빈 헤더를 전달 → 차단
  lifecycle {
    precondition {
      condition     = !var.enable_origin_verify || var.origin_verify_secret != ""
      error_message = "enable_origin_verify=true 이면 origin_verify_secret 이 비어있을 수 없습니다."
    }
  }
}
