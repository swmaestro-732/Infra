terraform {
  backend "s3" {
    bucket       = "chilsami-tfstate-440922629441"
    key          = "bootstrap/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}
