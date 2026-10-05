# OpenSearch 보안(데이터플레인) 상태 — prod/dev 와 같은 상태 버킷, 다른 key(격리).
# prod/dev state 를 건드리지 않는다. AWS provider(리소스)가 아니라 opensearch provider 가
# 도메인 _plugins/_security REST API 로 만드는 FGAC 객체(유저/롤/롤매핑)를 이 state 가 관리한다.
terraform {
  backend "s3" {
    bucket       = "chilsami-tfstate-ap-northeast-2"
    key          = "opensearch-security/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}
