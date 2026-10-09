# tests/alerting.tftest.hcl — modules/alerting (dev · prod 루트 모듈이 공유하는 모듈)
# 아래 ARN 은 AWS 에 존재하지 않는 테스트 fixture 입니다.

mock_provider "aws" {
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:ap-northeast-2:111111111111:contract2whale-dev-alerts" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/contract2whale-dev-alertmanager", id = "contract2whale-dev-alertmanager" }
  }
}

variables {
  expected_account_id     = "111111111111"
  environment             = "dev"
  region                  = "ap-northeast-2"
  platform_log_group_name = "/platform/contract2whale-dev-eks/application"
  cluster_contract = {
    name   = "contract2whale-dev-eks"
    arn    = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
    region = "ap-northeast-2"
  }
}

run "default_contract" {
  command = apply

  assert {
    condition     = length(keys(output.alerting_contract)) == 11 && output.alerting_contract.topic_arn == "arn:aws:sns:ap-northeast-2:111111111111:contract2whale-dev-alerts"
    error_message = "alerting_contract must have eleven items and carry the topic ARN."
  }

  assert {
    condition     = keys(output.alerting_contract.alarm_names) == ["pool_acquire_timeout"] && length(aws_cloudwatch_metric_alarm.armed_sample_deletion) == 0
    error_message = "Only the pool_acquire_timeout alarm exists unless the Dev probe detection is armed."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.publish.policy).Statement[0].Resource == aws_sns_topic.alerts.arn && jsondecode(aws_iam_role_policy.publish.policy).Statement[0].Action == "sns:Publish"
    error_message = "The Alertmanager role may only publish to this environment's topic."
  }

  assert {
    condition     = aws_eks_pod_identity_association.alertmanager.namespace == "monitoring" && aws_eks_pod_identity_association.alertmanager.service_account == "platform-alertmanager"
    error_message = "Pod Identity must bind monitoring/platform-alertmanager."
  }

  assert {
    condition     = aws_cloudwatch_log_metric_filter.pool_acquire_timeout.log_group_name == "/platform/contract2whale-dev-eks/application" && !strcontains(aws_cloudwatch_log_metric_filter.pool_acquire_timeout.pattern, "$.log")
    error_message = "The node agent filter reads the platform log group and must not depend on message text."
  }
}

run "armed_probe_in_dev" {
  command = apply

  variables {
    sample_delete_validation_run_id = "verify-0123456789abcdef0123456789abcdef"
  }

  assert {
    condition     = length(aws_cloudwatch_log_metric_filter.armed_sample_deletion) == 1 && output.alerting_contract.alarm_names.armed_sample_deletion == "contract2whale-dev-armed-sample-deletion"
    error_message = "Arming the Dev probe must add the armed_sample_deletion filter and alarm."
  }

  assert {
    condition     = strcontains(aws_cloudwatch_log_metric_filter.armed_sample_deletion[0].pattern, "verify-0123456789abcdef0123456789abcdef")
    error_message = "The armed filter must match the single validation run ID."
  }
}

# 3. Prod 에서는 점검 감지를 켤 수 없습니다.
run "reject_armed_in_prod" {
  command = plan

  variables {
    environment                     = "prod"
    sample_delete_validation_run_id = "verify-0123456789abcdef0123456789abcdef"
    platform_log_group_name         = "/platform/contract2whale-prod-eks/application"
    cluster_contract = {
      name   = "contract2whale-prod-eks"
      arn    = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-prod-eks"
      region = "ap-northeast-2"
    }
  }

  expect_failures = [terraform_data.contract]
}

# 4. 다른 클러스터의 로그 그룹은 거부됩니다.
run "reject_foreign_log_group" {
  command = plan

  variables {
    platform_log_group_name = "/platform/other-cluster/application"
  }

  expect_failures = [terraform_data.contract]
}

# 5. 환경 이름과 클러스터 이름이 어긋나면 거부됩니다 (Prod 계약을 Dev 입력에 넣은 경우).
run "reject_cluster_environment_mismatch" {
  command = plan

  variables {
    platform_log_group_name = "/platform/contract2whale-prod-eks/application"
    cluster_contract = {
      name   = "contract2whale-prod-eks"
      arn    = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-prod-eks"
      region = "ap-northeast-2"
    }
  }

  expect_failures = [terraform_data.contract]
}
