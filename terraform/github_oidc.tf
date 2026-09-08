# ---------- GitHub Actions OIDC Provider ----------
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# ---------- GitHub Actions가 위임받을 IAM Role ----------
resource "aws_iam_role" "github_actions" {
  name = "${var.project_name}-github-actions-role"
  # AWS 허용 범위(1~12시간) 중 최소 권한 원칙에 따라 가장 짧은 값 선택
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            "token.actions.githubusercontent.com:sub" = [
            "repo:heeega/aws-3tier-soc-monitoring:*",
            "repo:heeega@*/aws-3tier-soc-monitoring@*:*"
            ]
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-github-actions-role"
  }
}

# ---------- Terraform plan에 필요한 권한 (토이 프로젝트 범위상 AdministratorAccess, 추후 축소 예정) ----------
resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}