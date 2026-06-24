output "alb_dns_name" {
  description = "ALB DNS 이름"
  value       = aws_lb.this.dns_name
}

output "alb_arn" {
  description = "ALB ARN"
  value       = aws_lb.this.arn
}

output "alb_sg_id" {
  description = "ALB 보안그룹 ID"
  value       = aws_security_group.alb.id
}

output "target_group_arn" {
  description = "타깃 그룹 ARN"
  value       = aws_lb_target_group.this.arn
}
