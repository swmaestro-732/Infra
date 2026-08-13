provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "chilsami"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}
