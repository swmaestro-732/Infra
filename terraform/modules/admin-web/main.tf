# Admin Web: 어드민 웹(Next.js 정적 export)용 S3 버킷 + CloudFront(OAC).
# 버킷은 완전 비공개이고 CloudFront OAC 로만 읽는다. 배포는 GitHub Actions(OIDC)가 s3 sync 후 무효화한다.

resource "aws_s3_bucket" "this" {
  bucket = "${var.name}-admin-web-ap-northeast-2"

  tags = { Name = "${var.name}-admin-web" }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_cloudfront_origin_access_control" "this" {
  name                              = "${var.name}-admin-web-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

# trailingSlash 정적 export 는 /courses/ 를 /courses/index.html 로 내보낸다.
# S3 REST 오리진(OAC)은 디렉터리 인덱스를 모르므로 뷰어 요청에서 경로를 바꿔 준다.
resource "aws_cloudfront_function" "index_rewrite" {
  name    = "${var.name}-admin-web-index"
  runtime = "cloudfront-js-2.0"
  comment = "디렉터리 경로를 index.html 로 바꾼다"
  publish = true
  code    = <<-JS
    function handler(event) {
      var request = event.request;
      var uri = request.uri;
      if (uri.endsWith('/')) {
        request.uri = uri + 'index.html';
      } else if (uri.split('/').pop().indexOf('.') === -1) {
        request.uri = uri + '/index.html';
      }
      return request;
    }
  JS
}

resource "aws_cloudfront_response_headers_policy" "security" {
  name = "${var.name}-admin-web-security"

  security_headers_config {
    content_security_policy {
      content_security_policy = var.content_security_policy
      override                = true
    }
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = false
      override                   = true
    }
  }
}

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  comment             = "${var.name} admin web (S3 static)"
  is_ipv6_enabled     = true
  price_class         = var.price_class
  http_version        = "http2and3"
  default_root_object = "index.html"
  aliases             = [var.domain_name]

  origin {
    domain_name              = aws_s3_bucket.this.bucket_regional_domain_name
    origin_id                = "s3-admin-web"
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  default_cache_behavior {
    target_origin_id           = "s3-admin-web"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.index_rewrite.arn
    }
  }

  # 없는 경로는 정적 export 의 404 페이지로
  custom_error_response {
    error_code         = 403
    response_code      = 404
    response_page_path = "/404.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 404
    response_page_path = "/404.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = var.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = { Name = "${var.name}-admin-web-cdn" }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontServicePrincipalReadOnly"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.this.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.this.arn
        }
      }
    }]
  })
}
