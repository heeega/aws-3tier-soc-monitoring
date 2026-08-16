resource "aws_instance" "elk" {
  ami                     = "ami-012a353bb3afb92ee" # Ubuntu 22.04 LTS (ap-northeast-2)
  instance_type           = "t3.micro"
  subnet_id               = aws_subnet.was_a.id
  vpc_security_group_ids  = [aws_security_group.elk_v2.id]
  key_name                = "soc-3tier-key"

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  user_data = base64encode(<<-EOF
#!/bin/bash
apt-get update -y
apt-get install -y ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y

apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

systemctl enable docker
systemctl start docker

usermod -aG docker ubuntu

sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" >> /etc/sysctl.conf

# Swap 2GB 생성 (물리 메모리 1GB로는 ELK 컨테이너 구동에 부족하여 완충 공간 확보)
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo "/swapfile none swap sw 0 0" >> /etc/fstab
EOF
  )

  tags = {
    Name = "${var.project_name}-elk"
    Tier = "elk"
  }
}