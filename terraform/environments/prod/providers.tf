provider "aws" {
  region = var.aws_region

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
provider "aws" {
  alias  = "virginia"
  region = "us-east-1"

  default_tags {
    tags = {
      Project     = "chilsami"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
