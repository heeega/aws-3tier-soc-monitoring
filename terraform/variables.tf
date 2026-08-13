variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "project_name" {
  description = "프로젝트 식별용 이름 (리소스 태그에 사용)"
  type        = string
  default     = "soc-3tier"
}

variable "admin_ips" {
  description = "SSH 접속 허용 관리자 IP 목록"
  type        = list(string)
  default = [
    "222.233.151.194/32",  # NewSchool
    "211.178.91.6/32",     # 집
  ]
}