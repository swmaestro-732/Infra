provider "aws" {
  region = var.aws_region

  # 다른 계정 자격 증명으로 실행하면 시작 전에 거부한다(계정 이전 중 프로필 혼동 방지).
  allowed_account_ids = ["440922629441"]

  # 모든 리소스에 공통 태그를 자동 부여한다.
  default_tags {
    tags = {
      Project     = "chilsami"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# CloudFront 용 ACM 인증서는 반드시 us-east-1 에 있어야 하므로 별도 aliased provider 를 둔다.
# dns 모듈에 aws.virginia 로 주입한다.
provider "aws" {
  alias  = "virginia"
  region = "us-east-1"

  allowed_account_ids = ["440922629441"]

  default_tags {
    tags = {
      Project     = "chilsami"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
