# tests/observability.tftest.hcl — platform/observability 루트 모듈 (dev · prod 공통 코드)
# terraform_remote_state 는 override_data 로 가짜 출력을 주고, 모듈 안 aws data source 는 계약과 같은 값을 돌려주도록 override 합니다. 아래 ID 는 AWS 에 없는 fixture 입니다.

mock_provider "aws" {
  override_during = apply # 예: apply 단계의 computed 값을 아래 defaults 로 채움

  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" } # 예: 빈 정책 JSON (형식만 유지)
  }

  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::111111111111:policy/platform/mock-policy" } # 예: attachment 의 policy_arn 형식 검사를 통과하는 fixture
  }

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/platform/mock-role" } # 예: 연결의 role_arn 형식 fixture
  }

  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-signal-bucket" } # 예: 버킷 정책 Resource 형식 fixture
  }
}

variables {
  expected_account_id    = "111111111111"
  region                 = "ap-northeast-2"
  environment            = "dev"
  state_bucket_name      = "company-dev-tfstate-111111111111"
  trusted_principal_arns = ["arn:aws:iam::111111111111:role/PlatformOperator"]
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
        endpoint           = "https://ABCD1234.gr7.ap-northeast-2.eks.amazonaws.com"
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

# network/vpc State 출력 (관련 구성 vpc_id · 네트워크 로그 수집 network_logs_bucket_name)
override_data {
  target = data.terraform_remote_state.vpc
  values = {
    outputs = {
      vpc_id                   = "vpc-0123456789abcdef0"
      network_logs_bucket_name = "cp-dev-network-logs-111111111111-ap-northeast-2"
    }
  }
}

override_data {
  target = data.terraform_remote_state.account_baseline
  values = {
    outputs = {
      state_object_keys = ["account-baseline-dns/terraform.tfstate", "account-baseline/terraform.tfstate", "network/vpc/terraform.tfstate", "platform/observability/terraform.tfstate"]
    }
  }
}

# 실제 AWS 조회 결과가 계약과 같다고 가정하는 override 입니다.
override_data {
  target = module.component.data.aws_vpc_endpoint.s3
  values = { id = "vpce-0123456789abcdef0", state = "available" }
}

# mock apply 에서 버킷 이름 · 역할 ARN 을 실제 형식으로 고정합니다 (출력 전달 확인용).
override_resource {
  target = module.component.aws_s3_bucket.signal["metrics"]
  values = { id = "cp-dev-observability-metrics-111111111111-ap-northeast-2", arn = "arn:aws:s3:::cp-dev-observability-metrics-111111111111-ap-northeast-2" }
}

override_resource {
  target = module.component.aws_s3_bucket.signal["logs"]
  values = { id = "cp-dev-observability-logs-111111111111-ap-northeast-2", arn = "arn:aws:s3:::cp-dev-observability-logs-111111111111-ap-northeast-2" }
}

override_resource {
  target = module.component.aws_s3_bucket.signal["traces"]
  values = { id = "cp-dev-observability-traces-111111111111-ap-northeast-2", arn = "arn:aws:s3:::cp-dev-observability-traces-111111111111-ap-northeast-2" }
}

override_resource {
  target = module.component.aws_iam_role.observability_writer
  values = { arn = "arn:aws:iam::111111111111:role/platform/cp-dev-observability-writer" }
}

# 1. State 출력 4곳에서 모듈 입력을 조립합니다 (입력 파일 없음).
run "assembles_inputs_from_state" {
  command = plan

  assert {
    condition     = local.cluster_contract == { name = "contract2whale-dev-eks", arn = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks", region = "ap-northeast-2", kubernetes_version = "1.36" }
    error_message = "cluster_contract must be assembled from the eks state outputs (name, arn, region, kubernetes_version only)."
  }

  assert {
    condition     = local.operations_contract.cluster_name == "contract2whale-dev-eks" && local.vpc_id == "vpc-0123456789abcdef0" && local.network_logs_bucket_name == "cp-dev-network-logs-111111111111-ap-northeast-2" && contains(local.allowed_state_keys, "platform/observability/terraform.tfstate")
    error_message = "operations contract, vpc id, network log bucket and allowed state keys must come from their states."
  }

  assert {
    condition     = terraform_data.environment_boundary.input == "dev"
    error_message = "The environment marker must record dev."
  }
}

run "outputs_and_env_contract" {
  command = apply

  assert {
    condition     = length(keys(output.observability_contract)) == 17 && output.observability_contract.metrics_bucket == "cp-dev-observability-metrics-111111111111-ap-northeast-2" && output.observability_contract.cluster == "contract2whale-dev-eks"
    error_message = "observability_contract must pass through the module contract (17 keys)."
  }

  assert {
    condition     = output.observability_network_contract.endpoint_policy_mode == "restricted" && length(output.observability_network_contract.allowed_bucket_prefixes) == 5 && output.storage_role_arns.writer == "arn:aws:iam::111111111111:role/platform/cp-dev-observability-writer" && length(output.pod_identity_association_ids) == 9
    error_message = "Network contract, role ARNs and nine association IDs must be exposed."
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

# 4. operations_contract 가 없는 State(운영 기반 루트 모듈과 계약 미적용)는 거부됩니다.
run "reject_state_without_operations_contract" {
  command = plan

  override_data {
    target = data.terraform_remote_state.operations
    values = { outputs = { cluster_name = "contract2whale-dev-eks" } }
  }

  expect_failures = [data.terraform_remote_state.operations]
}
