# dev 환경 원격 상태 — prod 와 같은 상태 버킷, 다른 key(격리). prod state 를 건드리지 않는다.
terraform {
  backend "s3" {
    bucket       = "chilsami-tfstate-ap-northeast-2"
    key          = "dev/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}
