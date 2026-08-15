# ---------- S3 Bucket for Flow Logs (장기보관/감사대응용) ----------
resource "aws_s3_bucket" "flow_logs" {
  bucket_prefix = "${var.project_name}-flowlogs-"
  force_destroy = true

  tags = {
    Name = "${var.project_name}-flowlogs"
  }
}

# ---------- IAM Role for Flow Logs -> CloudWatch Logs ----------
resource "aws_iam_role" "flow_logs" {
  name = "${var.project_name}-flowlogs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "vpc-flow-logs.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "${var.project_name}-flowlogs-policy"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "${var.project_name}-flowlogs"
  retention_in_days = 30
}

# ---------- Flow Log #1: CloudWatch Logs (실시간 모니터링/알람용) ----------
resource "aws_flow_log" "to_cloudwatch" {
  vpc_id               = aws_vpc.main.id
  traffic_type          = "ALL"
  log_destination_type  = "cloud-watch-logs"
  log_destination       = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn           = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60

  tags = {
    Name = "${var.project_name}-flowlog-cloudwatch"
  }
}

# ---------- Flow Log #2: S3 (장기보관/감사대응용) ----------
resource "aws_flow_log" "to_s3" {
  vpc_id                = aws_vpc.main.id
  traffic_type           = "ALL"
  log_destination_type   = "s3"
  log_destination        = aws_s3_bucket.flow_logs.arn
  max_aggregation_interval = 60

  tags = {
    Name = "${var.project_name}-flowlog-s3"
  }
}