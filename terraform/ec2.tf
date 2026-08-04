# 최신 Amazon Linux 2023 AMI 조회
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

# Web Tier Security Group (외부 -> Web: 80,443 / 관리자 -> Web: 22)
resource "aws_security_group" "web" {
  name   = "web-tier-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH from my IP only"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # TODO: 본인 IP로 제한 예정
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "web-tier-sg"
  }
}

# App Tier Security Group (Web -> App: 8080, Web -> App: 22(Bastion SSH))
resource "aws_security_group" "app" {
  name   = "app-tier-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "App port from Web tier only"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  ingress {
    description     = "SSH from Web tier (bastion) only"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "app-tier-sg"
  }
}

# Web Tier EC2
resource "aws_instance" "web" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  key_name               = "soc-3tier-key"
  subnet_id              = aws_subnet.web.id
  vpc_security_group_ids = [aws_security_group.web.id]

  tags = {
    Name = "web-tier-ec2"
  }
}

# App Tier EC2
resource "aws_instance" "app" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  key_name               = "soc-3tier-key"
  subnet_id              = aws_subnet.app.id
  vpc_security_group_ids = [aws_security_group.app.id]

  tags = {
    Name = "app-tier-ec2"
  }
}

# DB Tier Security Group (App Tier로부터 3306, App Tier로부터 22(Bastion SSH))
resource "aws_security_group" "db" {
  name   = "db-tier-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "MySQL from App tier only"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  ingress {
    description     = "SSH from App tier (bastion) only"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "db-tier-sg"
  }
}

# DB Tier EC2 (MySQL 직접 설치 예정)
resource "aws_instance" "db" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = "t3.micro"
  key_name               = "soc-3tier-key"
  subnet_id              = aws_subnet.db.id
  vpc_security_group_ids = [aws_security_group.db.id]

  tags = {
    Name = "db-tier-ec2"
  }
}