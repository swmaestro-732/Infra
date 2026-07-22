# Media — 이미지 등 사용자 업로드 미디어용 S3 버킷 + CloudFront(OAC) 배포.
# 버킷은 완전 비공개(직접 접근 차단)이며, 조회는 CloudFront OAC 를 통해서만 허용한다.
# 업로드는 앱이 발급하는 presigned URL(PUT)로 클라이언트가 버킷에 직접 쓴다.

resource "aws_s3_bucket" "this" {
  bucket = "${var.name}-media-ap-northeast-2" # 전역 유니크 — 상태 버킷 네이밍 컨벤션과 동일

  tags = { Name = "${var.name}-media" }
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

# 클라이언트가 presigned URL 로 직접 PUT 업로드할 수 있도록 CORS 허용
resource "aws_s3_bucket_cors_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  cors_rule {
    allowed_methods = ["PUT", "GET"]
    allowed_origins = var.frontend_origins
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# ───────── CloudFront (S3 origin, OAC) ─────────

resource "aws_cloudfront_origin_access_control" "this" {
  name                              = "${var.name}-media-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# 관리형 정책은 ID 하드코딩 대신 이름으로 조회 (계정/리전마다 ID 안전)
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  comment         = "${var.name} media CDN (S3 origin)"
  is_ipv6_enabled = true
  price_class     = var.price_class
  http_version    = "http2and3"

  origin {
    domain_name              = aws_s3_bucket.this.bucket_regional_domain_name
    origin_id                = "s3-media"
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-media"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]

    # 이미지 등 정적 미디어 — 관리형 캐싱 최적화 정책 사용 (ALB CDN 과 달리 캐싱 활성)
    cache_policy_id = data.aws_cloudfront_cache_policy.caching_optimized.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true # *.cloudfront.net 기본 인증서로 HTTPS
  }

  tags = { Name = "${var.name}-media-cdn" }
}

# 이 CloudFront 배포에서 오는 요청만 GetObject 허용 (OAC 표준 버킷 정책)
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

# ───────── 앱(EC2) 에 이 버킷 읽기/쓰기 권한만 (최소권한) ─────────
resource "aws_iam_role_policy" "app_media_write" {
  count = var.app_role_name != null ? 1 : 0
  name  = "${var.name}-media-write"
  role  = var.app_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
      Resource = "${aws_s3_bucket.this.arn}/*"
    }]
  })
}

# CDN 도메인은 생성 후에나 알 수 있어, ec2 모듈이 module.media 를 직접 참조하지 않고도(순환 의존 회피)
# 기동 시 읽을 수 있도록 SSM Parameter로 게시한다.
resource "aws_ssm_parameter" "media_cdn_url" {
  name  = "/${var.name}/media/cdn-url"
  type  = "String"
  value = "https://${aws_cloudfront_distribution.this.domain_name}"

  tags = { Name = "${var.name}-media-cdn-url" }
}

# 앱(EC2) 에 위 파라미터 읽기 권한만 (최소권한) — media 를 참조하는 role 에 sibling 정책으로 부착
resource "aws_iam_role_policy" "app_media_config_read" {
  count = var.app_role_name != null ? 1 : 0
  name  = "${var.name}-media-config-read"
  role  = var.app_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = aws_ssm_parameter.media_cdn_url.arn
    }]
  })
}
