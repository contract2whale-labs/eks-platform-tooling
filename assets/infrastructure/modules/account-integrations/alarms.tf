# alarms.tf — modules/account-integrations (dev · prod 루트 모듈이 공유하는 모듈)
# 주제만 만든 상태에서는 외부에 통보되지 않습니다. 구독 확인(confirmation)은 사람이 메일에서 수행하는 별도 운영 단계입니다.
# 큐 적체 알람(aws_cloudwatch_metric_alarm.log_queue_age)은 큐를 참조하므로 큐와 같은 파일(선택 외부 로그 소비자 external-log-consumer.tf)에 있습니다.

resource "aws_sns_topic" "platform" {
  name = "${var.operations_contract.cluster_name}-platform-operations" # 예: "contract2whale-dev-eks-platform-operations" (알림 루트 모듈과 설치 검사 의 contract2whale-dev-alerts 와 다른 주제)

  depends_on = [terraform_data.contract] # 예: 계약 검사를 통과한 뒤에 만듭니다
}

# 같은 계정의 지정 접두사 알람 ARN 에서 오는 CloudWatch 서비스 요청만 sns:Publish 를 허용합니다.
resource "aws_sns_topic_policy" "platform" {
  arn = aws_sns_topic.platform.arn # 예: "arn:aws:sns:ap-northeast-2:111111111111:contract2whale-dev-eks-platform-operations"
  policy = jsonencode({
    Version = "2012-10-17" # 예: "2012-10-17" (정책 문법 버전, 날짜가 아닙니다)
    Statement = [{
      Sid       = "AllowCloudWatchAlarms"                  # 예: "AllowCloudWatchAlarms" (사람이 읽는 문장 식별자)
      Effect    = "Allow"                                  # 예: "Allow" (조건에 맞는 요청을 허용합니다)
      Principal = { Service = "cloudwatch.amazonaws.com" } # 예: CloudWatch 서비스만 주체로 허용합니다
      Action    = "sns:Publish"                            # 예: "sns:Publish" (메시지를 넣는 동작만 허용)
      Resource  = aws_sns_topic.platform.arn               # 예: 이 주제 하나만 대상으로 합니다
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.expected_account_id }                                                                                   # 예: "111111111111" (같은 계정의 알람만)
        ArnLike      = { "aws:SourceArn" = "arn:aws:cloudwatch:${var.region}:${var.expected_account_id}:alarm:${var.operations_contract.cluster_name}-*" } # 예: "arn:aws:cloudwatch:ap-northeast-2:111111111111:alarm:contract2whale-dev-eks-*"
      }
    }]
  })
}

# 주소를 넣고 apply 하면 SNS 가 실제 확인 메일을 보냅니다. 확인 전에는 수신이 완료되지 않습니다 (PendingConfirmation).
resource "aws_sns_topic_subscription" "email" {
  for_each  = var.notification_email_addresses # 예: [] 이면 구독 0개, 주소 1개면 구독 1개
  topic_arn = aws_sns_topic.platform.arn       # 예: 위에서 만든 주제의 ARN
  protocol  = "email"                          # 예: "email" (확인 절차가 필요한 전달 방식)
  endpoint  = each.value                       # 예: "ops-alerts@example.com" (본인이 받는 주소)
}

# 플랫폼 로그 그룹의 5분 수집 바이트가 임계값을 2구간 연속 넘으면 ALARM. 수집량 · 비용 신호이며 앱 동작이나 로그 유실 지표가 아닙니다.
resource "aws_cloudwatch_metric_alarm" "platform_log_volume" {
  alarm_name          = "${var.operations_contract.cluster_name}-platform-log-ingestion-spike"                                    # 예: "contract2whale-dev-eks-platform-log-ingestion-spike" (주제 정책의 접두사 조건과 일치)
  alarm_description   = "Platform log group IncomingBytes over 5-minute threshold; volume and cost, not app behavior or log loss" # 예: 콘솔에 표시할 설명
  namespace           = "AWS/Logs"                                                                                                # 예: "AWS/Logs" (CloudWatch Logs 의 지표 묶음)
  metric_name         = "IncomingBytes"                                                                                           # 예: "IncomingBytes" (수집된 바이트 수)
  dimensions          = { LogGroupName = var.operations_contract.platform_log_group_name }                                        # 예: { LogGroupName = "/platform/contract2whale-dev-eks/application" }
  statistic           = "Sum"                                                                                                     # 예: "Sum" (구간 안의 값을 더합니다)
  period              = 300                                                                                                       # 예: 300 (5분 구간)
  evaluation_periods  = 2                                                                                                         # 예: 2 (최근 구간 2개를 봅니다)
  datapoints_to_alarm = 2                                                                                                         # 예: 2 (그중 2개가 초과해야 ALARM)
  threshold           = var.log_bytes_per_five_minutes_threshold                                                                  # 예: 52428800 (50 MiB)
  comparison_operator = "GreaterThanThreshold"                                                                                    # 예: 임계값보다 클 때 초과로 셉니다
  treat_missing_data  = "notBreaching"                                                                                            # 예: "notBreaching" (결측 구간을 미달로 셉니다)
  alarm_actions       = [aws_sns_topic.platform.arn]                                                                              # 예: ALARM 이 될 때 이 주제로 보냅니다
  ok_actions          = [aws_sns_topic.platform.arn]                                                                              # 예: OK 로 돌아올 때도 이 주제로 보냅니다

  depends_on = [aws_sns_topic_policy.platform] # 예: 발행 정책이 붙은 뒤에 알람을 만듭니다
}
