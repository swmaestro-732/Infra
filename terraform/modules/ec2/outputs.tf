output "instance_sg_id" {
  description = "앱 인스턴스 보안그룹 ID"
  value       = aws_security_group.instance.id
}

output "asg_name" {
  description = "Auto Scaling Group 이름"
  value       = aws_autoscaling_group.this.name
}

output "asg_arn" {
  description = "Auto Scaling Group ARN (CD instance refresh 권한 스코핑용)"
  value       = aws_autoscaling_group.this.arn
}

output "iam_role_name" {
  description = "인스턴스 IAM 역할 이름 (추후 정책 부착용)"
  value       = aws_iam_role.ec2.name
}
