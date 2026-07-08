variable "name" {
  description = "리소스 이름 접두사 (예: chilsami)"
  type        = string
}

variable "vpc_id" {
  description = "모니터링 호스트를 배치할 VPC ID"
  type        = string
}

variable "subnet_id" {
  description = "모니터링 호스트를 배치할 서브넷 (앱 티어 프라이빗 서브넷 1개)"
  type        = string
}

variable "app_sg_id" {
  description = "앱 인스턴스 보안그룹 ID — Loki/Tempo push 인그레스 허용 + Prometheus 스크레이프(8080) 룰 부착 대상"
  type        = string
}

variable "aws_region" {
  description = "AWS 리전 (user_data 내 aws cli 호출용)"
  type        = string
  default     = "ap-northeast-2"
}

variable "instance_type" {
  description = "모니터링 호스트 인스턴스 타입 (LGTM 5개 컨테이너 — 4GB+ 권장)"
  type        = string
  default     = "t3.medium"
}

variable "app_port" {
  description = "앱 컨테이너 포트 (Prometheus 스크레이프 대상)"
  type        = number
  default     = 8080
}

variable "app_name_tag" {
  description = "Prometheus EC2 서비스디스커버리가 찾을 앱 인스턴스 Name 태그"
  type        = string
  default     = "chilsami-app"
}

variable "data_volume_size" {
  description = "관측 데이터(Loki/Tempo/Mimir/Prometheus) EBS(gp3) 크기(GB)"
  type        = number
  default     = 30
}

variable "grafana_version" {
  description = "Grafana 컨테이너 태그"
  type        = string
  default     = "11.2.0"
}
