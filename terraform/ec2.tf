# ---------- Web Server (Amazon Linux 2023, Public Subnet) ----------
resource "aws_instance" "web" {
  ami                     = "ami-06882388850fd4a12" # Amazon Linux 2023 (ap-northeast-2)
  instance_type           = "t3.micro"
  subnet_id               = aws_subnet.public_a.id
  vpc_security_group_ids  = [aws_security_group.web.id]
  key_name                = "soc-3tier-key"

  tags = {
    Name = "${var.project_name}-web"
    Tier = "web"
  }
}

# ---------- Attacker EC2 (Ubuntu 22.04, Public Subnet) ----------
resource "aws_instance" "attacker" {
  ami                     = "ami-012a353bb3afb92ee" # Ubuntu 22.04 LTS (ap-northeast-2)
  instance_type           = "t3.micro"
  subnet_id               = aws_subnet.public_c.id
  vpc_security_group_ids  = [aws_security_group.attacker.id]
  key_name                = "soc-3tier-key"

  user_data = <<-EOF
              #!/bin/bash
              apt-get update -y
              apt-get install -y nmap nikto
              EOF

  tags = {
    Name = "${var.project_name}-attacker"
    Tier = "attacker"
  }
}