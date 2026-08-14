output "alb_dns_name" {
  description = "ALB 접속 주소 (브라우저로 여기 접속)"
  value       = aws_lb.web.dns_name
}

output "attacker_public_ip" {
  description = "공격자 EC2 Public IP"
  value       = aws_instance.attacker.public_ip
}