# ---------- Lambda 코드 압축 ----------
data "archive_file" "block_attacker_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambda/block_attacker.py"
  output_path = "${path.module}/../lambda/block_attacker.zip"
}

# ---------- Lambda 실행 역할 ----------
resource "aws_iam_role" "lambda_exec" {
  name = "${var.project_name}-lambda-block-attacker-role"

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

resource "aws_iam_role_policy" "lambda_permissions" {
  name = "${var.project_name}-lambda-block-attacker-policy"
  role = aws_iam_role.lambda_exec.id

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
          "logs:StartQuery",
          "logs:GetQueryResults"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkAclEntry",
          "ec2:DescribeNetworkAcls"
        ]
        Resource = "*"
      }
    ]
  })
}

# ---------- Lambda 함수 ----------
resource "aws_lambda_function" "block_attacker" {
  function_name    = "${var.project_name}-block-attacker"
  filename         = data.archive_file.block_attacker_zip.output_path
  source_code_hash = data.archive_file.block_attacker_zip.output_base64sha256
  handler          = "block_attacker.lambda_handler"
  runtime          = "python3.12"
  role             = aws_iam_role.lambda_exec.arn
  timeout          = 30

  environment {
    variables = {
      NACL_ID = aws_network_acl.web_nacl.id
    }
  }

  tags = {
    Name = "${var.project_name}-block-attacker"
  }
}

# ---------- SNS가 Lambda를 트리거하도록 권한 부여 ----------
resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.block_attacker.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.security_alerts.arn
}

# ---------- SNS 구독 (Lambda) ----------
resource "aws_sns_topic_subscription" "lambda_alert" {
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.block_attacker.arn
}