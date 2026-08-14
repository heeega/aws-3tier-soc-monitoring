resource "aws_network_acl" "web_nacl" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [aws_subnet.public_a.id, aws_subnet.public_c.id]

  tags = {
    Name = "${var.project_name}-web-nacl"
  }
}

# 기본 인바운드 허용 규칙 (기존 SG가 이미 세부 통제하므로, NACL은 기본 허용 + 동적 차단 규칙만 담당)
resource "aws_network_acl_rule" "inbound_allow_all" {
  network_acl_id = aws_network_acl.web_nacl.id
  rule_number    = 900
  egress         = false
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}

resource "aws_network_acl_rule" "outbound_allow_all" {
  network_acl_id = aws_network_acl.web_nacl.id
  rule_number    = 900
  egress         = true
  protocol       = "-1"
  rule_action    = "allow"
  cidr_block     = "0.0.0.0/0"
}