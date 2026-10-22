variable "name" {
  description = "리소스 이름 접두사 (예: chilsami)"
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "ElastiCache 를 둘 프라이빗 서브넷(검색·캐시 티어)"
  type        = list(string)
}

variable "app_sg_id" {
  description = "6379 인그레스를 허용할 앱 인스턴스 SG"
  type        = string
}

variable "extra_ingress_sg_ids" {
  description = "추가로 6379 를 허용할 SG(기본 없음 — dev 는 자체 docker redis 사용이라 공유 안 함)"
  type        = list(string)
  default     = []
}

variable "app_role_name" {
  description = "AUTH 토큰 시크릿 읽기 권한을 줄 앱 EC2 역할 이름. null 이면 권한 미부여."
  type        = string
  default     = null
}

variable "node_type" {
  description = "노드 타입. Pub/Sub 전용이라 소형으로 충분(Graviton)."
  type        = string
  default     = "cache.t4g.micro"
}

variable "engine_version" {
  description = "Valkey 엔진 버전(Redis OSS 호환, 동급 노드 대비 저렴)"
  type        = string
  default     = "8.0"
}
