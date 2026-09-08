resource "aws_iam_user" "terraform_deployer" {
  name = "terraform-deployer"
}
# ---------- Terraform 실행 전용 Role (실제 작업 권한 보유) ----------
resource "aws_iam_role" "terraform_executor" {
  name                 = "${var.project_name}-terraform-executor-role"
  max_session_duration = 3600  # AWS 최소 허용값, 최소 권한 원칙에 따라 가장 짧은 값 선택

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_user.terraform_deployer.arn
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-terraform-executor-role"
  }
}

# ---------- 이 Role에 실제 작업 권한 부여 (토이 프로젝트 범위상 AdministratorAccess, 추후 세부 권한으로 축소 예정) ----------
resource "aws_iam_role_policy_attachment" "terraform_executor_admin" {
  role       = aws_iam_role.terraform_executor.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# ---------- terraform-deployer가 executor Role을 위임받을 수 있는 최소 권한 정책 ----------
resource "aws_iam_user_policy" "terraform_deployer_assume_only" {
  name = "assume-terraform-executor-only"
  user = aws_iam_user.terraform_deployer.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "sts:AssumeRole"
        Resource = aws_iam_role.terraform_executor.arn
      }
    ]
  })
}

# ---------- 테스트용 저권한 사용자 (탈취된 키 시나리오 재현용) ----------
resource "aws_iam_user" "test_compromised_user" {
  name = "${var.project_name}-test-compromised-user"

  tags = {
    Name    = "${var.project_name}-test-compromised-user"
    Purpose = "API Key 악용 시나리오 재현 및 자동 대응 검증용"
  }
}

resource "aws_iam_user_policy" "test_compromised_user_policy" {
  name = "ec2-describe-and-run-only"
  user = aws_iam_user.test_compromised_user.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:RunInstances", "ec2:DescribeInstances", "ec2:DescribeAccountAttributes"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_access_key" "test_compromised_user_key" {
  user = aws_iam_user.test_compromised_user.name
}

output "test_user_access_key_id" {
  value = aws_iam_access_key.test_compromised_user_key.id
}

output "test_user_secret_key" {
  value     = aws_iam_access_key.test_compromised_user_key.secret
  sensitive = true
}