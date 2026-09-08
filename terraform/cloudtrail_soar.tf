# ---------- S3 Bucket for CloudTrail ----------
resource "aws_s3_bucket" "cloudtrail" {
  bucket_prefix = "${var.project_name}-cloudtrail-"
  force_destroy = true

  tags = {
    Name = "${var.project_name}-cloudtrail"
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.cloudtrail.arn
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.cloudtrail.arn}/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      }
    ]
  })
}

# ---------- CloudWatch Log Group for CloudTrail ----------
resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/aws/cloudtrail/${var.project_name}-key-abuse"
  retention_in_days = 30
}

# ---------- IAM Role: CloudTrail -> CloudWatch Logs ----------
resource "aws_iam_role" "cloudtrail_to_cwl" {
  name = "${var.project_name}-cloudtrail-cwl-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "cloudtrail_to_cwl" {
  name = "${var.project_name}-cloudtrail-cwl-policy"
  role = aws_iam_role.cloudtrail_to_cwl.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      Resource = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
    }]
  })
}

# ---------- CloudTrail ----------
resource "aws_cloudtrail" "key_abuse_detection" {
  name                          = "${var.project_name}-key-abuse-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail.id
  include_global_service_events = true
  is_multi_region_trail         = true

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_to_cwl.arn

  depends_on = [aws_s3_bucket_policy.cloudtrail]

  tags = {
    Name = "${var.project_name}-key-abuse-trail"
  }
}

# ---------- Metric Filter: DryRun 정찰 패턴 탐지 ----------
resource "aws_cloudwatch_log_metric_filter" "dryrun_recon" {
  name           = "${var.project_name}-dryrun-recon-filter"
  log_group_name = aws_cloudwatch_log_group.cloudtrail.name
  pattern        = "{ $.errorCode = \"Client.DryRunOperation\" }"

  metric_transformation {
    name      = "${var.project_name}-DryRunReconCount"
    namespace = "SOC3TierKeyAbuse"
    value     = "1"
  }
}

# ---------- CloudWatch Alarm ----------
resource "aws_cloudwatch_metric_alarm" "dryrun_recon_alarm" {
  alarm_name          = "${var.project_name}-dryrun-recon-detected"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods   = 1
  metric_name          = "${var.project_name}-DryRunReconCount"
  namespace            = "SOC3TierKeyAbuse"
  period                = 300
  statistic             = "Sum"
  threshold             = 1
  alarm_description     = "API Key를 이용한 EC2 DryRun 정찰 시도 탐지 (실제 크립토마이닝 사고에서 확인된 초기 정찰 패턴, Amazon 2025.12 발표 참고)"
  alarm_actions          = [aws_sns_topic.key_abuse_alerts.arn]
  treat_missing_data     = "notBreaching"

  tags = {
    Name = "${var.project_name}-dryrun-recon-alarm"
  }
}

# ---------- SNS Topic ----------
resource "aws_sns_topic" "key_abuse_alerts" {
  name = "${var.project_name}-key-abuse-alerts"

  tags = {
    Name = "${var.project_name}-key-abuse-alerts"
  }
}

resource "aws_sns_topic_subscription" "key_abuse_email" {
  topic_arn = aws_sns_topic.key_abuse_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
# ---------- Lambda 코드 압축 ----------
data "archive_file" "key_disabler_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambda/key_disabler.py"
  output_path = "${path.module}/../lambda/key_disabler.zip"
}

# ---------- Lambda 실행 역할 ----------
resource "aws_iam_role" "key_disabler_exec" {
  name = "${var.project_name}-key-disabler-role"

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

resource "aws_iam_role_policy" "key_disabler_permissions" {
  name = "${var.project_name}-key-disabler-policy"
  role = aws_iam_role.key_disabler_exec.id

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
          "iam:ListUsers",
          "iam:ListAccessKeys",
          "iam:UpdateAccessKey"
        ]
        Resource = "*"
      }
    ]
  })
}

# ---------- Lambda 함수 ----------
resource "aws_lambda_function" "key_disabler" {
  function_name    = "${var.project_name}-key-disabler"
  filename         = data.archive_file.key_disabler_zip.output_path
  source_code_hash = data.archive_file.key_disabler_zip.output_base64sha256
  handler          = "key_disabler.lambda_handler"
  runtime          = "python3.12"
  role             = aws_iam_role.key_disabler_exec.arn
  timeout          = 30

  tags = {
    Name = "${var.project_name}-key-disabler"
  }
}

# ---------- SNS가 Lambda를 트리거하도록 권한 부여 ----------
resource "aws_lambda_permission" "allow_sns_key_disabler" {
  statement_id  = "AllowSNSInvokeKeyDisabler"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.key_disabler.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.key_abuse_alerts.arn
}

# ---------- SNS 구독 (Lambda) ----------
resource "aws_sns_topic_subscription" "key_disabler_trigger" {
  topic_arn = aws_sns_topic.key_abuse_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.key_disabler.arn
}