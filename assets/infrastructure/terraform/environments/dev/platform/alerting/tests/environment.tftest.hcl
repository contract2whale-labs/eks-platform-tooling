# tests/environment.tftest.hcl — platform/alerting 루트 모듈 (dev · prod 공통 코드)
# terraform_remote_state 는 override_data 로 가짜 출력을 줍니다. 실제 AWS · S3 API 를 호출하지 않습니다. 아래 ARN 은 AWS 에 없는 fixture 입니다.

mock_provider "aws" {
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:ap-northeast-2:111111111111:contract2whale-dev-alerts" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/contract2whale-dev-alertmanager", id = "contract2whale-dev-alertmanager" }
  }
}

variables {
  expected_account_id = "111111111111"
  environment         = "dev"
  region              = "ap-northeast-2"
  state_bucket_name   = "company-dev-tfstate-111111111111"
}

override_data {
  target = data.terraform_remote_state.eks
  values = {
    outputs = {
      cluster_contract = {
        name               = "contract2whale-dev-eks"
        arn                = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
        region             = "ap-northeast-2"
        kubernetes_version = "1.36"
      }
    }
  }
}

override_data {
  target = data.terraform_remote_state.operations
  values = {
    outputs = {
      operations_contract = {
        account_id              = "111111111111"
        cluster_name            = "contract2whale-dev-eks"
        region                  = "ap-northeast-2"
        platform_log_group_name = "/platform/contract2whale-dev-eks/application"
        velero_bucket_name      = "velero-contract2whale-dev-eks-111111111111-ap-northeast-2"
        velero_bucket_arn       = "arn:aws:s3:::velero-contract2whale-dev-eks-111111111111-ap-northeast-2"
        alerts_topic_arn        = null
      }
    }
  }
}

# 1. State 출력 두 곳에서 모듈 계약을 조립합니다 (입력 파일 없음).
run "assembles_contract_from_state" {
  command = plan

  assert {
    condition     = local.cluster_contract == { name = "contract2whale-dev-eks", arn = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks", region = "ap-northeast-2" }
    error_message = "cluster_contract must be assembled from the eks state outputs (name, arn, region only)."
  }

  assert {
    condition     = local.platform_log_group_name == "/platform/contract2whale-dev-eks/application" && terraform_data.environment_boundary.input == "dev"
    error_message = "platform_log_group_name must come from the platform/operations state and the environment marker must record dev."
  }
}

# 2. 루트 모듈 출력이 자기 환경의 계약과 env 문자열을 내보냅니다 (mock apply; 원본 run 이름 유지).
run "environment_contract" {
  command = apply

  assert {
    condition = (
      output.alerting_contract.environment == "dev" &&
      output.alerting_contract.account_id == "111111111111" &&
      output.alerting_contract.topic_arn == "arn:aws:sns:ap-northeast-2:111111111111:contract2whale-dev-alerts" &&
      output.alerting_contract.alarm_names.pool_acquire_timeout == "contract2whale-dev-pool-acquire-timeout"
    )
    error_message = "The root must export its own environment's alerting contract."
  }


  assert {
    condition     = length(keys(output.alerting_contract)) == 11
    error_message = "alerting_contract must have exactly eleven items."
  }
}

# 3. 이 디렉터리는 dev 만 받습니다 (원본 run 이름 유지).
run "reject_other_environment" {
  command = plan

  variables {
    environment = "prod"
  }

  expect_failures = [terraform_data.environment_boundary]
}

# 4. fluent_bit 을 끈 operations State(로그 그룹 null)는 거부됩니다.
run "reject_state_without_log_group" {
  command = plan

  override_data {
    target = data.terraform_remote_state.operations
    values = {
      outputs = {
        operations_contract = {
          account_id              = "111111111111"
          cluster_name            = "contract2whale-dev-eks"
          region                  = "ap-northeast-2"
          platform_log_group_name = null
          velero_bucket_name      = null
          velero_bucket_arn       = null
          alerts_topic_arn        = null
        }
      }
    }
  }

  expect_failures = [data.terraform_remote_state.operations]
}

# 5. cluster_contract 출력이 없는 eks State(환경 root 와 모듈 연결 이전) 는 거부됩니다.
run "reject_state_without_cluster_contract" {
  command = plan

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name = "contract2whale-dev-eks"
      }
    }
  }

  expect_failures = [data.terraform_remote_state.eks]
}
