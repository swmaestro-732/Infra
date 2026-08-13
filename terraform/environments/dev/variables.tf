variable "aws_region" {
  description = "리소스를 배포할 AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "az" {
  description = "dev 단일 가용영역"
  type        = string
  default     = "ap-northeast-2a"
}
