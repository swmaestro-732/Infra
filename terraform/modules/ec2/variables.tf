variable "name" {
  description = "리소스 이름 프리픽스"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "app_subnet_ids" {
  description = "인스턴스를 배치할 앱(프라이빗) 서브넷"
  type        = list(string)
}

variable "alb_sg_id" {
  description = "ALB 보안그룹 ID (인바운드 허용 소스)"
  type        = string
}

variable "target_group_arn" {
  description = "ALB 타깃 그룹 ARN"
  type        = string
}

variable "instance_type" {
  description = "EC2 인스턴스 타입"
  type        = string
  default     = "t3.small"
}

variable "app_port" {
  description = "컨테이너/인스턴스 포트"
  type        = number
  default     = 80
}

variable "desired_capacity" {
  description = "ASG 희망 용량"
  type        = number
  default     = 2
}

variable "min_size" {
  description = "ASG 최소"
  type        = number
  default     = 2
}

variable "max_size" {
  description = "ASG 최대"
  type        = number
  default     = 4
}

variable "aws_region" {
  description = "ECR 로그인·Secrets Manager 조회용 리전"
  type        = string
}

variable "ecr_repository_url" {
  description = "배포할 백엔드 이미지 ECR URL (없으면 nginx 플레이스홀더 유지)"
  type        = string
  default     = ""
}

variable "db_secret_name" {
  description = "DB 자격증명 Secrets Manager 시크릿 이름 (앱이 기동 시 fetch — 이름으로 전달해 rds 모듈과의 순환 의존 회피)"
  type        = string
  default     = ""
}

variable "app_config_secret_name" {
  description = "앱 외부키(KAKAO/TMAP 등) Secrets Manager 시크릿 이름 (앱이 기동 시 fetch). jwt_secret 은 jwt_secret_name 으로 분리."
  type        = string
  default     = ""
}

variable "jwt_secret_name" {
  description = "jwt_secret 전용 Secrets Manager 시크릿 이름 (prod 전용, dev 와 격리). dev 가 공유하는 app_config 에 jwt 를 두지 않기 위해 분리(SCRUM-680)."
  type        = string
  default     = ""
}

variable "opensearch_secret_name" {
  description = "OpenSearch FGAC 마스터 자격증명(endpoint/username/password) Secrets Manager 시크릿 이름 (앱이 기동 시 fetch — 이름으로 전달해 opensearch 모듈과의 순환 의존 회피). 빈 값이면 검색 미연결(fail-soft)."
  type        = string
  default     = ""
}

variable "s3_media_bucket" {
  description = "미디어 S3 버킷 이름 (컨테이너 S3_MEDIA_BUCKET env로 전달 — 결정적 이름이라 media 모듈 output 없이 직접 조합)"
  type        = string
  default     = ""
}

variable "media_cdn_ssm_param_name" {
  description = "미디어 CloudFront 도메인을 담은 SSM Parameter 이름 (앱이 기동 시 fetch — media 모듈과의 순환 의존 회피)"
  type        = string
  default     = ""
}

variable "monitoring_host_ssm_param_name" {
  description = "모니터링 호스트 private IP를 담은 SSM Parameter 이름 (앱이 기동 시 fetch — monitoring 모듈과의 순환 의존 회피). 빈 값이면 로그/트레이스 push 미설정."
  type        = string
  default     = ""
}

variable "sqs_fallback_events_queue_url" {
  description = "폴백 이벤트 SQS 큐 URL (앱에 SQS_FALLBACK_EVENTS_QUEUE_URL 로 주입). 빈 값이면 백엔드가 발행/구독 미설정(fail-soft)."
  type        = string
  default     = ""
}

variable "sqs_crawl_results_queue_url" {
  description = "크롤링 결과 SQS 큐 URL (앱에 SQS_CRAWL_RESULTS_QUEUE_URL 로 주입)."
  type        = string
  default     = ""
}

variable "redis_endpoint_ssm_param_name" {
  description = "Redis 프라이머리 엔드포인트를 담은 SSM Parameter 이름 (앱이 기동 시 fetch — elasticache 모듈과의 순환 의존 회피). 빈 값이면 Redis 미연결(fail-soft, 앱은 @ConditionalOnExpression 으로 캐시 없이 기동)."
  type        = string
  default     = ""
}

variable "redis_user" {
  description = "Redis IAM 인증 user 이름(=user_id, SigV4 토큰 User 파라미터). 결정적 값이라 직접 전달. 빈 값이면 미주입."
  type        = string
  default     = ""
}

variable "redis_cache_name" {
  description = "Redis replication_group_id(SigV4 서명 대상 호스트). 결정적 값이라 직접 전달. 빈 값이면 미주입."
  type        = string
  default     = ""
}

variable "docdb_endpoint_ssm_param_name" {
  description = "DocumentDB 엔드포인트를 담은 SSM Parameter 이름 (앱이 기동 시 fetch — documentdb 모듈과 순환 의존 회피). IAM 인증(MONGODB-AWS)이라 자격증명은 불필요. 빈 값이면 DocumentDB 미연결(fail-soft)."
  type        = string
  default     = ""
}
