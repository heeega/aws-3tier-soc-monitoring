# CloudWatch Logs 로그 그룹 (기존 이름 재사용)
resource "aws_cloudwatch_log_group" "web_flowlog" {
  name              = "/vpc/web-tier-flowlogs"
  retention_in_days = 14
}

# Flow Log용 IAM 역할
resource "aws_iam_role" "flowlog_role" {
  name = "web-tier-flowlog-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "flowlog_policy" {
  name = "web-tier-flowlog-policy"
  role = aws_iam_role.flowlog_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# VPC Flow Log (Web Tier 서브넷에 연결)
resource "aws_flow_log" "web_tier" {
  iam_role_arn    = aws_iam_role.flowlog_role.arn
  log_destination = aws_cloudwatch_log_group.web_flowlog.arn
  traffic_type    = "ALL"
  subnet_id       = aws_subnet.web.id

  tags = {
    Name = "web-tier-flowlog"
  }
}