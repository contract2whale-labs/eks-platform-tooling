# external-log-consumer.tf — modules/account-integrations (dev · prod 루트 모듈이 공유하는 모듈)
# 실제 상대의 Role ARN 과 합의한 External ID 가 있기 전에는 켜지 않습니다. 켜면 앞 네트워크 구성이 만든 로그 버킷에 알림 설정이 붙습니다 (버킷 자체는 재선언하지 않음).

resource "aws_sqs_queue" "logs" {
  count                      = var.enable_external_log_consumer ? 1 : 0                     # 예: 기본 0개, 켜면 1개
  name                       = "${var.operations_contract.cluster_name}-network-log-events" # 예: "contract2whale-dev-eks-network-log-events"
  sqs_managed_sse_enabled    = true                                                         # 예: true (SQS 가 관리하는 키로 저장 암호화)
  message_retention_seconds  = 1209600                                                      # 예: 1209600 (14일 동안 보관)
  visibility_timeout_seconds = 300                                                          # 예: 300 (받은 메시지를 5분 동안 숨김)
  receive_wait_time_seconds  = 20                                                           # 예: 20 (최대 20초까지 기다리는 긴 폴링)

  depends_on = [terraform_data.contract] # 예: 계약 검사를 통과한 뒤에 만듭니다
}

# 로그 버킷(같은 계정)에서 오는 S3 서비스 요청만 sqs:SendMessage 를 허용합니다.
resource "aws_sqs_queue_policy" "logs" {
  count     = var.enable_external_log_consumer ? 1 : 0 # 예: 기본 0개, 켜면 1개
  queue_url = aws_sqs_queue.logs[0].url                # 예: "https://sqs.ap-northeast-2.amazonaws.com/111111111111/contract2whale-dev-eks-network-log-events"
  policy = jsonencode({
    Version = "2012-10-17" # 예: "2012-10-17" (정책 문법 버전, 날짜가 아닙니다)
    Statement = [{
      Effect    = "Allow"                          # 예: "Allow" (조건에 맞는 요청을 허용합니다)
      Principal = { Service = "s3.amazonaws.com" } # 예: S3 서비스만 주체로 허용합니다
      Action    = "sqs:SendMessage"                # 예: "sqs:SendMessage" (메시지를 넣는 동작만 허용)
      Resource  = aws_sqs_queue.logs[0].arn        # 예: "arn:aws:sqs:ap-northeast-2:111111111111:contract2whale-dev-eks-network-log-events"
      Condition = {
        ArnEquals    = { "aws:SourceArn" = var.network_logs_contract.bucket_arn } # 예: "arn:aws:s3:::cp-dev-network-logs-111111111111-ap-northeast-2"
        StringEquals = { "aws:SourceAccount" = var.expected_account_id }          # 예: "111111111111" (같은 계정의 버킷만)
      }
    }]
  })
}

# S3 한 버킷의 notification 설정 전체는 하나의 resource · State 가 소유해야 합니다.
# 앞 네트워크 구성이 만든 같은 버킷의 flow/ 와 dns/ 를 queue 블록 두 개로 한 리소스에서 관리합니다.
resource "aws_s3_bucket_notification" "network_logs" {
  count  = var.enable_external_log_consumer ? 1 : 0 # 예: 기본 0개, 켜면 1개
  bucket = var.network_logs_contract.bucket_name    # 예: "cp-dev-network-logs-111111111111-ap-northeast-2"

  queue {
    id            = "flow-logs"               # 예: "flow-logs" (알림 항목 식별자)
    queue_arn     = aws_sqs_queue.logs[0].arn # 예: 위에서 만든 큐의 ARN
    events        = ["s3:ObjectCreated:*"]    # 예: Put · Copy · Multipart 완료를 알리며 같은 키의 다시 쓰기도 포함합니다
    filter_prefix = "flow/"                   # 예: "flow/" (VPC Flow Log 저장 경로)
  }

  queue {
    id            = "dns-logs"                # 예: "dns-logs" (알림 항목 식별자)
    queue_arn     = aws_sqs_queue.logs[0].arn # 예: 같은 큐로 보냅니다
    events        = ["s3:ObjectCreated:*"]    # 예: Put · Copy · Multipart 완료
    filter_prefix = "dns/"                    # 예: "dns/" (DNS 질의 로그 저장 경로)
  }

  depends_on = [aws_sqs_queue_policy.logs] # 예: 큐 정책을 붙인 뒤에 알림을 설정합니다 (S3 가 정책을 검사)
}

# 상대 계정의 Role 만 합의된 External ID 로 이 Role 을 맡을 수 있습니다.
resource "aws_iam_role" "external_log_consumer" {
  count = var.enable_external_log_consumer ? 1 : 0                      # 예: 기본 0개, 켜면 1개
  name  = "${var.operations_contract.cluster_name}-external-log-reader" # 예: "contract2whale-dev-eks-external-log-reader"
  assume_role_policy = jsonencode({
    Version = "2012-10-17" # 예: "2012-10-17" (정책 문법 버전, 날짜가 아닙니다)
    Statement = [{
      Effect    = "Allow"                                                                                  # 예: "Allow" (조건에 맞는 요청을 허용합니다)
      Principal = { AWS = try(var.external_log_consumer.principal_role_arn, "") }                          # 예: "arn:aws:iam::222222222222:role/log-consumer" (기본 null 이면 "" — count 0 이라 평가되지 않음)
      Action    = "sts:AssumeRole"                                                                         # 예: "sts:AssumeRole" (이 Role 을 맡는 동작)
      Condition = { StringEquals = { "sts:ExternalId" = try(var.external_log_consumer.external_id, "") } } # 예: 합의한 External ID 와 같아야 허용합니다
    }]
  })

  depends_on = [terraform_data.contract] # 예: 계약 검사를 통과한 뒤에 만듭니다
}

# 큐 동작 5종과 로그 버킷의 flow/* · dns/* 객체 읽기만 허용합니다 (버킷 전체 · 목록 조회 없음).
resource "aws_iam_role_policy" "external_log_consumer" {
  count = var.enable_external_log_consumer ? 1 : 0 # 예: 기본 0개, 켜면 1개
  role  = aws_iam_role.external_log_consumer[0].id # 예: "contract2whale-dev-eks-external-log-reader"
  name  = "consume-network-logs"                   # 예: "consume-network-logs" (Role 안에서의 정책 이름)
  policy = jsonencode({
    Version = "2012-10-17" # 예: "2012-10-17" (정책 문법 버전, 날짜가 아닙니다)
    Statement = [
      {
        Effect   = "Allow"                                                                                                                 # 예: 이 큐 하나에서 메시지를 받고 지우고 상태를 조회하는 동작만 허용
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ChangeMessageVisibility"] # 예: 큐 동작 5종
        Resource = aws_sqs_queue.logs[0].arn                                                                                               # 예: 큐 ARN
      },
      {
        Effect   = "Allow"                                                                                             # 예: 두 경로의 객체 읽기만 허용
        Action   = ["s3:GetObject"]                                                                                    # 예: 객체 읽기
        Resource = ["${var.network_logs_contract.bucket_arn}/flow/*", "${var.network_logs_contract.bucket_arn}/dns/*"] # 예: ["arn:aws:s3:::cp-dev-network-logs-…/flow/*", "…/dns/*"]
      }
    ]
  })
}

# 가장 오래된 미삭제 메시지가 15분(900초)을 넘으면 소비 지연 신호입니다. 소비 중단뿐 아니라 처리 속도·재시도·적체도 확인합니다. 큐와 같은 스위치로 켜집니다.
resource "aws_cloudwatch_metric_alarm" "log_queue_age" {
  count               = var.enable_external_log_consumer ? 1 : 0                         # 예: 기본 0개, 외부 소비자를 켜면 1개
  alarm_name          = "${var.operations_contract.cluster_name}-external-log-queue-age" # 예: "contract2whale-dev-eks-external-log-queue-age" (주제 정책의 접두사 조건과 일치)
  namespace           = "AWS/SQS"                                                        # 예: "AWS/SQS" (SQS 의 지표 묶음)
  metric_name         = "ApproximateAgeOfOldestMessage"                                  # 예: 미삭제 메시지의 근사 최대 나이(초)
  dimensions          = { QueueName = aws_sqs_queue.logs[0].name }                       # 예: { QueueName = "contract2whale-dev-eks-network-log-events" }
  statistic           = "Maximum"                                                        # 예: "Maximum" (구간 안의 최댓값을 봅니다)
  period              = 300                                                              # 예: 300 (5분 구간)
  evaluation_periods  = 2                                                                # 예: 2 (최근 구간 2개를 봅니다)
  threshold           = 900                                                              # 예: 900 (15분)
  comparison_operator = "GreaterThanThreshold"                                           # 예: 임계값보다 클 때 초과로 셉니다
  treat_missing_data  = "notBreaching"                                                   # 예: "notBreaching" (결측 구간을 미달로 셉니다)
  alarm_actions       = [aws_sns_topic.platform.arn]                                     # 예: ALARM 이 될 때 이 주제로 보냅니다

  depends_on = [aws_sns_topic_policy.platform] # 예: 발행 정책이 붙은 뒤에 이 알람을 만듭니다
}
