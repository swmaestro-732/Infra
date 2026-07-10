output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID 목록"
  value       = aws_subnet.public[*].id
}

output "app_subnet_ids" {
  description = "앱 서브넷 ID 목록"
  value       = aws_subnet.app[*].id
}

output "data_subnet_ids" {
  description = "데이터 서브넷 ID 목록"
  value       = aws_subnet.data[*].id
}

output "search_subnet_ids" {
  description = "검색·캐시(데이터 서비스) 서브넷 ID 목록"
  value       = aws_subnet.search[*].id
}
