# tests/contracts.tftest.hcl — modules/account-integrations (dev · prod 루트 모듈이 공유하는 모듈)
# 모든 AWS 호출을 mock provider 로 대체합니다. 실제 구독 · 메일 발송 · 버킷 알림이 없습니다. 아래 이름 · ARN · 계정 번호는 AWS 에 없는 fixture 입니다 (terraform.tfvars 로 복사하지 않음).

mock_provider "aws" {
  override_during = apply # 예: apply 단계에서 computed 값을 아래 defaults 로 채움

  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::reports-fixture", id = "reports-fixture" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:ap-northeast-2:111111111111:cp-live-platform-operations" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:ap-northeast-2:111111111111:cp-live-network-log-events", url = "https://sqs.ap-northeast-2.amazonaws.com/111111111111/cp-live-network-log-events", name = "cp-live-network-log-events" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/cp-live-external-log-reader", id = "cp-live-external-log-reader" }
  }
}

variables {
  expected_account_id = "111111111111"
  operations_contract = {
    account_id              = "111111111111"
    cluster_name            = "cp-live"
    region                  = "ap-northeast-2"
    platform_log_group_name = "/platform/cp-live/application"
    velero_bucket_name      = "velero-fixture"
    velero_bucket_arn       = "arn:aws:s3:::velero-fixture"
    alerts_topic_arn        = "arn:aws:sns:ap-northeast-2:111111111111:cp-live-alerts"
  }
  network_logs_contract = { bucket_name = "network-logs-fixture", bucket_arn = "arn:aws:s3:::network-logs-fixture" }
}

# 1. 기본 입력: 외부 SIEM · 이메일 연결이 없고, 계약의 조건부 항목은 null, 알람은 5분 수집량 의미를 유지합니다 (mock apply).
run "default_has_no_external_consumer" {
  command = apply

  assert {
    condition     = length(aws_sqs_queue.logs) == 0 && length(aws_s3_bucket_notification.network_logs) == 0 && length(aws_iam_role.external_log_consumer) == 0 && length(aws_sns_topic_subscription.email) == 0 && length(aws_cloudwatch_metric_alarm.log_queue_age) == 0
    error_message = "기본 설정으로 외부 SIEM/이메일 연결을 생성하면 안 됩니다."
  }

  assert {
    condition     = output.integration_contract.external_log_consumer_role_arn == null && output.integration_contract.external_log_queue_url == null && output.integration_contract.backup_bucket_arn == var.operations_contract.velero_bucket_arn
    error_message = "비활성 연결은 null이며 운영 기반 구성의 backup bucket을 재사용해야 합니다."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.platform_log_volume.metric_name == "IncomingBytes" && aws_cloudwatch_metric_alarm.platform_log_volume.period == 300 && aws_cloudwatch_metric_alarm.platform_log_volume.threshold == 52428800
    error_message = "이 알람의 의미는 5분 수집량이며 로그 유실 지표로 변하면 안 됩니다."
  }

  assert {
    condition     = output.integration_contract.reports_bucket_name == "reports-fixture" && output.integration_contract.alarm_topic_arn == aws_sns_topic.platform.arn
    error_message = "integration_contract에 보고 버킷과 알람 주제가 있어야 합니다."
  }

  assert {
    condition     = startswith(aws_cloudwatch_metric_alarm.platform_log_volume.alarm_name, "${var.operations_contract.cluster_name}-") && strcontains(aws_sns_topic_policy.platform.policy, "alarm:${var.operations_contract.cluster_name}-*")
    error_message = "알람 이름은 주제 정책의 SourceArn 접두사(<cluster>-)로 시작해야 publish 가 허용됩니다."
  }
}

# 2. 선택 기능을 켜면 버킷 알림은 한 리소스가 flow/ · dns/ 두 항목을 소유하고, 소비자 Role 은 두 prefix 만 읽습니다 (mock apply).
run "opt_in_consumer_is_scoped" {
  command = apply

  variables {
    enable_external_log_consumer = true
    # 로컬 mock fixture 일 뿐 실제 고객이나 SIEM 정보가 아닙니다.
    external_log_consumer = { principal_role_arn = "arn:aws:iam::999999999999:role/mock-consumer", external_id = "MOCK-ONLY-NOT-A-REAL-EXTERNAL-ID" }
  }

  assert {
    condition     = length(aws_s3_bucket_notification.network_logs[0].queue) == 2 && length(aws_s3_bucket_notification.network_logs) == 1
    error_message = "같은 source bucket의 flow/dns 알림은 단일 소유 리소스에서 관리해야 합니다."
  }

  assert {
    condition     = toset(jsondecode(aws_iam_role_policy.external_log_consumer[0].policy).Statement[1].Resource) == toset(["arn:aws:s3:::network-logs-fixture/flow/*", "arn:aws:s3:::network-logs-fixture/dns/*"])
    error_message = "소비자는 network log prefix 두 곳만 읽어야 합니다."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.log_queue_age) == 1 && aws_cloudwatch_metric_alarm.log_queue_age[0].threshold == 900 && output.integration_contract.external_log_queue_url == aws_sqs_queue.logs[0].url
    error_message = "켜면 큐 적체 알람(15분)이 함께 생기고 계약이 큐 URL 을 실어야 합니다."
  }
}

# 3. 신원 없이 기능만 켜면 계약 검사(precondition 3)가 거부합니다.
run "reject_opt_in_without_identity" {
  command = plan

  variables {
    enable_external_log_consumer = true
    external_log_consumer        = null
  }

  expect_failures = [terraform_data.contract]
}

# 4. 다른 계정의 운영 기반 계약은 거부합니다 (precondition 1).
run "reject_contract_from_other_account" {
  command = plan

  variables {
    operations_contract = {
      account_id              = "222222222222"
      cluster_name            = "cp-live"
      region                  = "ap-northeast-2"
      platform_log_group_name = "/platform/cp-live/application"
      velero_bucket_name      = "velero-fixture"
      velero_bucket_arn       = "arn:aws:s3:::velero-fixture"
      alerts_topic_arn        = null
    }
  }

  expect_failures = [terraform_data.contract]
}

# 5. 로그 버킷 이름과 ARN 이 어긋난 계약은 거부합니다 (precondition 2).
run "reject_mismatched_network_logs_contract" {
  command = plan

  variables {
    network_logs_contract = { bucket_name = "network-logs-fixture", bucket_arn = "arn:aws:s3:::other-bucket" }
  }

  expect_failures = [terraform_data.contract]
}

# 6. 형식이 어긋난 이메일 주소는 validation 이 거부합니다.
run "reject_invalid_email" {
  command = plan

  variables {
    notification_email_addresses = ["ops-alerts"]
  }

  expect_failures = [var.notification_email_addresses]
}

# 7. 0 이하의 임계값과 16자 미만 External ID 는 validation 이 거부합니다.
run "reject_invalid_threshold_and_external_id" {
  command = plan

  variables {
    log_bytes_per_five_minutes_threshold = 0
    external_log_consumer                = { principal_role_arn = "arn:aws:iam::999999999999:role/mock-consumer", external_id = "SHORT" }
  }

  expect_failures = [var.log_bytes_per_five_minutes_threshold, var.external_log_consumer]
}
