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
