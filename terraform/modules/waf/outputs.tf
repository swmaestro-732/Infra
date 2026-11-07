output "web_acl_arn" {
  description = "CloudFront 배포의 web_acl_id 로 넘기는 Web ACL ARN."
  value       = aws_wafv2_web_acl.this.arn
}

output "log_group_name" {
  description = "WAF 로그 그룹 이름 (us-east-1)."
  value       = aws_cloudwatch_log_group.waf.name
}
