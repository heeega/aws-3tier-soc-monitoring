# ---------- Lambda 코드 압축 ----------
data "archive_file" "log_shipper_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambda/log_shipper.py"
  output_path = "${path.module}/../lambda/log_shipper.zip"
}

# ---------- Lambda 실행 역할 ----------
resource "aws_iam_role" "log_shipper_exec" {
  name = "${var.project_name}-log-shipper-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "log_shipper_permissions" {
  name = "${var.project_name}-log-shipper-policy"
  role = aws_iam_role.log_shipper_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface"
        ]
        Resource = "*"
      }
    ]
  })
}

# ---------- Lambda 함수 (VPC 내부 배치) ----------
resource "aws_lambda_function" "log_shipper" {
  function_name    = "${var.project_name}-log-shipper"
  filename         = data.archive_file.log_shipper_zip.output_path
  source_code_hash = data.archive_file.log_shipper_zip.output_base64sha256
  handler          = "log_shipper.lambda_handler"
  runtime          = "python3.12"
  role             = aws_iam_role.log_shipper_exec.arn
  timeout          = 30
  memory_size      = 256

  vpc_config {
    subnet_ids         = [aws_subnet.was_a.id]
    security_group_ids = [aws_security_group.log_shipper_lambda.id]
  }

  environment {
    variables = {
      ES_HOST = "http://${aws_instance.elk.private_ip}:9200"
    }
  }

  tags = {
    Name = "${var.project_name}-log-shipper"
  }
}

# ---------- CloudWatch Logs 구독 필터 -> Lambda 트리거 ----------
resource "aws_lambda_permission" "allow_cloudwatch" {
  statement_id  = "AllowCloudWatchLogsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.log_shipper.function_name
  principal     = "logs.ap-northeast-2.amazonaws.com"
  source_arn    = "${aws_cloudwatch_log_group.flow_logs.arn}:*"
}

resource "aws_cloudwatch_log_subscription_filter" "flow_logs_to_lambda" {
  name            = "${var.project_name}-flowlogs-to-elasticsearch"
  log_group_name  = aws_cloudwatch_log_group.flow_logs.name
  filter_pattern  = ""
  destination_arn = aws_lambda_function.log_shipper.arn

  depends_on = [aws_lambda_permission.allow_cloudwatch]
}