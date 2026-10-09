# tests/edge.tftest.hcl — platform/edge 루트 모듈 (dev · prod 공통 코드)
# 모듈 자체의 규칙(원본 거부 3가지 · internal 모드 거부 · WAF 규칙 수)은 modules/edge/tests/edge.tftest.hcl 이 확인합니다.

mock_provider "aws" {}

mock_provider "aws" {
  alias = "global"
}

variables {
  expected_account_id = "111111111111"
  region              = "ap-northeast-2"
  environment         = "dev"
  state_bucket_name   = "company-dev-tfstate-111111111111"
}

override_data {
  target = data.terraform_remote_state.gateway
  values = {
    outputs = {
      gateway_contract = {
        cluster_name          = "contract2whale-dev-eks"
        vpc_id                = "vpc-0123456789abcdef0"
        exposure_mode         = "internal"
        nlb_security_group_id = "sg-0123456789abcdef0"
        public_zone_id        = "ZPUBLIC"
        dns_zone_name         = "dev.playdevops.click"
        region                = "ap-northeast-2"
        external_dns_enabled  = true
      }
    }
  }
}

run "disabled_dev_plans_marker_only" {
  command = plan

  assert {
    condition     = local.gateway_contract == { cluster_name = "contract2whale-dev-eks", vpc_id = "vpc-0123456789abcdef0", exposure_mode = "internal", nlb_security_group_id = "sg-0123456789abcdef0", public_zone_id = "ZPUBLIC", dns_zone_name = "dev.playdevops.click" }
    error_message = "gateway_contract must be assembled from the platform/gateway state (six items only)."
  }

  assert {
    condition     = module.component.edge_contract == null && terraform_data.environment_boundary.input == "dev"
    error_message = "Disabled edge must plan only the environment marker."
  }
}

# 2. 비활성 출력은 null 입니다 (mock apply).
run "disabled_output_is_null" {
  command = apply

  assert {
    condition     = output.edge_contract == null
    error_message = "edge_contract must be null while disabled."
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

# 4. gateway_contract 가 없는 State(계약 테스트와 controller 설치 이전) 는 거부됩니다.
run "reject_state_without_gateway_contract" {
  command = plan

  override_data {
    target = data.terraform_remote_state.gateway
    values = {
      outputs = {
        cluster_name = "contract2whale-dev-eks"
      }
    }
  }

  expect_failures = [data.terraform_remote_state.gateway]
}
