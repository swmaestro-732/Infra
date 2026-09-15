variable "aws_region" {
  description = "리소스를 배포할 AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "environment" {
  description = "환경 이름 (단일 환경 — prod)"
  type        = string
  default     = "prod"
}

variable "azs" {
  description = "사용할 가용영역 (2개)"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

# analysis-nori(한글 형태소) 플러그인 AWS 패키지 ID. describe-packages 로 한 번 조회해 여기 default 에 고정
# (아래 명령). 빈 값이면 미연결 → 앱 인덱스(analyzer:nori) 색인이 실패하므로 값 채워 apply 해야 한다.
#   aws opensearch describe-packages --region ap-northeast-2 \
#     --filters Name=PackageType,Values=ZIP-PLUGIN \
#     --query "PackageDetails[?PackageName=='analysis-nori' && EngineVersion=='OpenSearch_2.11'].PackageID" --output text
variable "opensearch_nori_package_id" {
  description = "analysis-nori 옵션 플러그인의 AWS 패키지 ID (리전·엔진버전별). 빈 값이면 미연결."
  type        = string
  default     = "" # TODO(SCRUM-467): describe-packages 로 조회한 실제 ID 로 채우기 (예: "G1234567890")
}
