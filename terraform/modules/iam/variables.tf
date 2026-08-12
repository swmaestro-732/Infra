variable "name" {
  description = "리소스 이름 접두사 (예: chilsami)"
  type        = string
}

variable "developer_usernames" {
  description = "데이터스토어 접근 권한을 줄 개발자 IAM 사용자 이름 목록. 감사(CloudTrail) 위해 1인 1사용자 권장. 빈 목록이면 정책만 생성"
  type        = list(string)
  default     = []
}

variable "app_name_tags" {
  description = "SSM 포트포워딩을 허용할 점프 호스트(앱 EC2)의 Name 태그 목록 (prod + dev 등)"
  type        = list(string)
  default     = ["chilsami-app"]
}

variable "rds_secret_name" {
  description = "읽기 허용할 RDS 자격증명 Secrets Manager 시크릿 이름(접미사 랜덤 제외)"
  type        = string
  default     = "chilsami/rds/credentials"
}

variable "opensearch_secret_name" {
  description = "읽기 허용할 OpenSearch 마스터 Secrets Manager 시크릿 이름(접미사 랜덤 제외)"
  type        = string
  default     = "chilsami/opensearch/master"
}

variable "monitoring_name_tag" {
  description = "SSM 포트포워딩을 허용할 모니터링(LGTM) 호스트의 Name 태그. Grafana(3000)를 로컬 포워딩해 보기 위함"
  type        = string
  default     = "chilsami-monitoring"
}

variable "grafana_secret_name" {
  description = "읽기 허용할 Grafana admin Secrets Manager 시크릿 이름(접미사 랜덤 제외)"
  type        = string
  default     = "chilsami/grafana/admin"
}
