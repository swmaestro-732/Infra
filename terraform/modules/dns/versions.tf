terraform {
  required_version = ">= 1.11.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
      # ACM(CloudFront용)은 us-east-1 이어야 하므로 호출측에서 aws.virginia 를 주입받는다.
      configuration_aliases = [aws.virginia]
    }
  }
}
