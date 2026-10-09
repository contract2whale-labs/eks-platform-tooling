# tests/account-integrations.tftest.hcl — account-integrations 루트 모듈 (dev · prod 공통 코드)
# 모듈 안 리소스(module.component.terraform_data.contract)는 expect_failures 로 지정할 수 없으므로(Terraform 1.16.0 실측) 계정 · 계약 불일치 거부는 모듈 테스트가 맡습니다.
# terraform_remote_state 는 override_data 로 가짜 출력을 줍니다. 실제 AWS · S3 API 를 호출하지 않습니다. 모듈 자체의 규칙은 modules/account-integrations/tests/contracts.tftest.hcl 이 확인합니다. 아래 ID 는 AWS 에 없는 fixture 입니다.

mock_provider "aws" {
  override_during = apply # 예: apply 단계에서 computed 값을 아래 defaults 로 채움

  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::reports-contract2whale-dev-eks-111111111111-ap-northeast-2", id = "reports-contract2whale-dev-eks-111111111111-ap-northeast-2" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:ap-northeast-2:111111111111:contract2whale-dev-eks-platform-operations" }
  }
}

variables {
  expected_account_id = "111111111111"
  region              = "ap-northeast-2"
  environment         = "dev"
  state_bucket_name   = "company-dev-tfstate-111111111111"
}

override_data {
  target = data.terraform_remote_state.vpc
  values = {
    outputs = {
      network_logs_bucket_name = "cp-dev-network-logs-111111111111-ap-northeast-2"
      network_logs_bucket_arn  = "arn:aws:s3:::cp-dev-network-logs-111111111111-ap-northeast-2"
      vpc_id                   = "vpc-0123456789abcdef0"
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
        alerts_topic_arn        = "arn:aws:sns:ap-northeast-2:111111111111:contract2whale-dev-alerts"
      }
    }
  }
}

# 1. 두 State 출력에서 모듈 계약 두 개를 조립합니다 (입력 파일 없음).
run "assembles_contracts_from_state" {
  command = plan

  assert {
    condition     = local.network_logs_contract == { bucket_name = "cp-dev-network-logs-111111111111-ap-northeast-2", bucket_arn = "arn:aws:s3:::cp-dev-network-logs-111111111111-ap-northeast-2" }
    error_message = "network_logs_contract must be assembled from the network/vpc state outputs."
  }

  assert {
    condition     = local.operations_contract.cluster_name == "contract2whale-dev-eks" && local.operations_contract.platform_log_group_name == "/platform/contract2whale-dev-eks/application" && length(keys(local.operations_contract)) == 7
    error_message = "operations_contract must carry the seven items from the platform/operations state."
  }

  assert {
    condition     = terraform_data.environment_boundary.input == "dev"
    error_message = "The environment marker must record dev."
  }
}

run "default_apply_has_no_external_consumer" {
  command = apply

  assert {
    condition     = length(keys(output.integration_contract)) == 8 && output.integration_contract.external_log_queue_url == null && output.integration_contract.external_log_consumer_role_arn == null
    error_message = "integration_contract must have eight keys with null external consumer handles by default."
  }

  assert {
    condition     = output.integration_contract.reports_bucket_name == "reports-contract2whale-dev-eks-111111111111-ap-northeast-2" && output.integration_contract.backup_bucket_arn == "arn:aws:s3:::velero-contract2whale-dev-eks-111111111111-ap-northeast-2"
    error_message = "The reports bucket name must follow reports-<cluster>-<account>-<region> and the backup bucket must be reused from operations."
  }

  assert {
    condition     = output.integration_contract.alarm_topic_arn == "arn:aws:sns:ap-northeast-2:111111111111:contract2whale-dev-eks-platform-operations" && output.integration_contract.account_id == var.expected_account_id
    error_message = "The alarm topic must be the <cluster>-platform-operations topic of this account."
  }
}

# 3. 이 디렉터리는 dev 만 받습니다.
run "reject_non_dev_environment" {
  command = plan

  variables {
    environment = "prod"
  }

  expect_failures = [terraform_data.environment_boundary]
}

# 4. 로그 버킷 출력이 없는 network/vpc State(출력 계약과 계약 테스트 이전) 는 거부됩니다.
run "reject_vpc_state_without_log_bucket" {
  command = plan

  override_data {
    target = data.terraform_remote_state.vpc
    values = {
      outputs = {
        vpc_id = "vpc-0123456789abcdef0"
      }
    }
  }

  expect_failures = [data.terraform_remote_state.vpc]
}

# 5. operations_contract 출력이 없는 platform/operations State(운영 기반 루트 모듈과 계약 이전) 는 거부됩니다.
run "reject_operations_state_without_contract" {
  command = plan

  override_data {
    target = data.terraform_remote_state.operations
    values = {
      outputs = {}
    }
  }

  expect_failures = [data.terraform_remote_state.operations]
}

# 6. fluent_bit 을 끈 운영 기반 구성(platform_log_group_name null) 은 알람 dimension 이 없어 거부됩니다.
run "reject_operations_state_without_log_group" {
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
          velero_bucket_name      = "velero-contract2whale-dev-eks-111111111111-ap-northeast-2"
          velero_bucket_arn       = "arn:aws:s3:::velero-contract2whale-dev-eks-111111111111-ap-northeast-2"
          alerts_topic_arn        = null
        }
      }
    }
  }

  expect_failures = [data.terraform_remote_state.operations]
}
