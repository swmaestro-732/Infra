# 어드민 웹(swmaestro-732/Admin): S3 정적 호스팅 + CloudFront, chilsami-admin.courmy.com.
# Next.js 정적 export 를 GitHub Actions(OIDC)가 main push 때 s3 sync 하고 CloudFront 를 무효화한다.

locals {
  admin_web_domain = "chilsami-admin.${local.domain}"
}

module "admin_web" {
  source = "../../modules/admin-web"

  name            = local.name
  domain_name     = local.admin_web_domain
  certificate_arn = module.dns.certificate_arn

  # 정적 export 의 인라인 부트스트랩 스크립트 때문에 script-src 에 'unsafe-inline' 이 필요하다(서버가 없어 nonce 불가).
  # 대신 외부 출처는 구글 로그인(GIS), 네이버 지도, Pretendard(jsDelivr), 백엔드 API 만 연다.
  content_security_policy = join("; ", [
    "default-src 'self'",
    "script-src 'self' 'unsafe-inline' https://accounts.google.com https://oapi.map.naver.com https://*.map.naver.net https://*.pstatic.net",
    "style-src 'self' 'unsafe-inline' https://accounts.google.com https://cdn.jsdelivr.net",
    "font-src 'self' https://cdn.jsdelivr.net",
    "img-src 'self' data: blob: https:",
    "connect-src 'self' https://api.${local.domain} https://accounts.google.com https://oapi.map.naver.com https://*.naver.com https://*.naver.net https://*.pstatic.net https://kr-col-ext.nelo.navercorp.com",
    "frame-src https://accounts.google.com",
    "object-src 'none'",
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "form-action 'self'",
  ])
}

resource "aws_route53_record" "admin_web" {
  for_each = toset(["A", "AAAA"])

  zone_id = module.dns.zone_id
  name    = local.admin_web_domain
  type    = each.value

  alias {
    name                   = module.admin_web.distribution_domain_name
    zone_id                = module.admin_web.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}

# Admin 레포 main 브랜치 워크플로우만 정적 파일을 올리고 무효화할 수 있다.
resource "aws_iam_role" "admin_web_deploy" {
  name = "${local.name}-admin-web-deploy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = data.aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:swmaestro-732/Admin:ref:refs/heads/main"
        }
      }
    }]
  })

  tags = { Name = "${local.name}-admin-web-deploy" }
}

resource "aws_iam_role_policy" "admin_web_deploy" {
  name = "${local.name}-admin-web-deploy"
  role = aws_iam_role.admin_web_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListBucket"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = module.admin_web.bucket_arn
      },
      {
        Sid      = "SyncObjects"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:DeleteObject", "s3:GetObject"]
        Resource = "${module.admin_web.bucket_arn}/*"
      },
      {
        Sid      = "Invalidate"
        Effect   = "Allow"
        Action   = "cloudfront:CreateInvalidation"
        Resource = module.admin_web.distribution_arn
      },
    ]
  })
}
