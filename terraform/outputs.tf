output "web_public_ip" {
  description = "Web 서버 Public IP"
  value       = aws_instance.web.public_ip
}

output "attacker_public_ip" {
  description = "공격자 EC2 Public IP"
  value       = aws_instance.attacker.public_ip
}