provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "chilsami"
      ManagedBy = "terraform"
      Scope     = "opensearch-security"
    }
  }
}

# master(admin) 자격증명으로 도메인 보안 API 에 붙어 FGAC 객체를 만든다.
# sign_aws_requests=false: SigV4 가 아니라 내부 유저 DB basic auth 를 쓴다(FGAC 관리의 정석).
# healthcheck=false: provider 기본 헬스체크는 GET / 를 때리는데 터널 타이밍/인증으로 흔들려
#   plan 이 불안정해질 수 있어 끈다(실제 접속 성공 여부는 리소스 apply 에서 드러난다).
provider "opensearch" {
  url               = var.opensearch_url
  username          = local.master.username
  password          = local.master.password
  sign_aws_requests = false
  insecure          = var.insecure
  healthcheck       = false
}
