output "alb_dns_name" {
  description = "ALB 접속 주소 (브라우저로 여기 접속)"
  value       = aws_lb.web.dns_name
}

output "attacker_public_ip" {
  description = "공격자 EC2 Public IP"
  value       = aws_instance.attacker.public_ip
}

output "github_actions_role_arn" {
  description = "GitHub Actions가 assume할 IAM Role ARN"
  value       = aws_iam_role.github_actions.arn
}
# CI/CD 파이프라인 테스트용 주석