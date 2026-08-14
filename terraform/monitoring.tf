resource "aws_cloudwatch_log_metric_filter" "rejected_traffic" {
  name           = "${var.project_name}-rejected-traffic-filter"
  log_group_name = "soc-3tier-flowlogs"
  pattern        = "REJECT"

  metric_transformation {
    name      = "${var.project_name}-RejectedTrafficCount"
    namespace = "SOC3Tier"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "rejected_traffic_alarm" {
  alarm_name          = "${var.project_name}-high-reject-rate"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods   = 1
  metric_name          = "${var.project_name}-RejectedTrafficCount"
  namespace            = "SOC3Tier"
  period                = 60
  statistic             = "Sum"
  threshold             = 100
  alarm_description     = "1분 내 REJECT 트래픽이 100건 이상 발생 시 알람. 초기값 15건은 실측 결과 배경 트래픽(평상시 약 35건/분)보다 낮아 상시 오탐 발생, 배경 최댓값 대비 약 3배 마진을 둔 100건으로 재조정 (nmap 스캔 시 관측값 2050건으로 충분한 탐지 여유 확보)"
  alarm_actions          = [aws_sns_topic.security_alerts.arn]
  treat_missing_data      = "notBreaching"
}