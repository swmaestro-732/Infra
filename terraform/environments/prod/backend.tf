# 원격 상태(remote state) — S3 백엔드 + S3 네이티브 상태 잠금(use_lockfile, TF 1.10+).
# ⚠️ 첫 `terraform init` 전에 상태 버킷을 먼저 생성해야 한다.
#    (README → "원격 상태 부트스트랩" 참고)
terraform {
  backend "s3" {
    bucket       = "chilsami-tfstate-ap-northeast-2"
    key          = "prod/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}
