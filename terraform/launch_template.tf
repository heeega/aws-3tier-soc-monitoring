resource "aws_launch_template" "web" {
  name_prefix   = "${var.project_name}-web-lt-"
  image_id      = "ami-06882388850fd4a12"
  instance_type = "t3.micro"
  key_name      = "soc-3tier-key"

  vpc_security_group_ids = [aws_security_group.web.id]

  user_data = base64encode(<<-EOF
#!/bin/bash
dnf update -y
dnf install -y httpd
systemctl enable httpd

# Harden: disable TRACE method (XST 방지)
echo "TraceEnable off" >> /etc/httpd/conf/httpd.conf

# Harden: add clickjacking protection header
echo "Header always append X-Frame-Options SAMEORIGIN" >> /etc/httpd/conf/httpd.conf

systemctl start httpd

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
echo "<h1>SOC 3-tier Toy Project - Web Tier</h1><p>Instance ID: $INSTANCE_ID</p>" > /var/www/html/index.html
EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}-web"
      Tier = "web"
    }
  }

  tags = {
    Name = "${var.project_name}-web-lt"
  }
}