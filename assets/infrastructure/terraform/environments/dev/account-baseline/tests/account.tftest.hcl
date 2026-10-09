# tests/account.tftest.hcl — account-baseline 루트 모듈 (dev · prod 공통 코드)
# mock provider 로 AWS API 호출 없이 plan 만 실행해 정책 Statement · 기본 비활성화 · 입력 거부 · 상위 State 대조 계약을 확인합니다.
# GitHub OIDC 계약은 account 의 tests/github-identity.tftest.hcl 이 따로 검사합니다.
# mock 테스트는 로컬 구성 계약을 증명할 뿐 IAM 권한이나 실제 State 버킷을 증명하지 않습니다.

mock_provider "aws" {
  # data source 의 계산 결과는 mock 에서 임의 문자열이므로 JSON 형태의 fixture 를 줍니다.
  # 실제 policy 조립 결과나 IAM 허용을 증명하지 않습니다. 아래에서 입력 statement 를 검사합니다.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" # 예: 빈 정책 JSON (형식만 유지)
    }
  }
}

# bootstrap/state 의 root 출력을 S3 대신 고정 fixture 로 대체합니다. 실제 버킷을 읽지 않습니다.
override_data {
  target = data.terraform_remote_state.bootstrap
  values = {
    outputs = {
      state_bucket_name   = "company-dev-tfstate-111111111111"              # 예: state 출력과 같은 형식
      state_bucket_arn    = "arn:aws:s3:::company-dev-tfstate-111111111111" # 예: 정책 리소스 ARN 의 접두사
      state_region        = "ap-northeast-2"
      expected_account_id = "111111111111"
    }
  }
}

# 테스트 fixture 입니다. provider 가 mock 이므로 이 계정에 접근하지 않습니다.
variables {
  expected_account_id          = "111111111111"
  region                       = "ap-northeast-2"
  environment                  = "dev"
  state_bucket_name            = "company-dev-tfstate-111111111111"
  trusted_principal_arns       = ["arn:aws:iam::111111111111:role/PlatformOperator"]
  additional_state_object_keys = []
  permissions_boundary_arn     = null
  manage_iam_password_policy   = false
  create_github_oidc           = false # mock fixture: omit OIDC creation and actual-account reuse input
  existing_github_oidc_provider_arn = null
}

run "disabled_options_fixture" {
  command = plan

  # State 본문에는 DeleteObject 가 없고 잠금 파일에는 DeleteObject 가 있어야 합니다.
  assert {
    condition = (
      !contains(
        one([
          for s in data.aws_iam_policy_document.state_access.statement :
          s if s.sid == "ReadWriteSelectedStates"
        ]).actions,
        "s3:DeleteObject"
      ) &&
      contains(
        one([
          for s in data.aws_iam_policy_document.state_access.statement :
          s if s.sid == "ManageSelectedLocks"
        ]).actions,
        "s3:DeleteObject"
      )
    )
    error_message = "State deletion is excluded while lock deletion is required."
  }

  # 계정 전역 암호 정책은 기본값에서 만들지 않습니다.
  assert {
    condition     = length(aws_iam_account_password_policy.local_users) == 0
    error_message = "Optional account-wide resources must remain disabled by default."
  }

  # 기본 허용 key 는 이 구성 · 공개 DNS 구성 · 네트워크 구성 3개입니다.
  assert {
    condition = toset(output.state_object_keys) == toset([
      "account-baseline/terraform.tfstate",
      "account-baseline-dns/terraform.tfstate",
      "network/vpc/terraform.tfstate",
    ])
    error_message = "Only the three explicit baseline state keys should be allowed by default."
  }

  # 정책의 버킷 ARN 은 bootstrap/state 출력을 그대로 씁니다.
  assert {
    condition = (
      local.state_bucket_arn == "arn:aws:s3:::company-dev-tfstate-111111111111" &&
      length(local.state_object_arns) == 3 &&
      length(local.lock_object_arns) == 3 &&
      contains(local.lock_object_arns, "arn:aws:s3:::company-dev-tfstate-111111111111/network/vpc/terraform.tfstate.tflock")
    )
    error_message = "State and lock object ARNs must be derived from the bootstrap bucket ARN."
  }

  assert {
    condition     = aws_iam_role.terraform_state_access.name == "cp-dev-terraform-state"
    error_message = "The role name must identify its environment and backend-only purpose."
  }
}

run "explicit_optional_resources" {
  command = plan

  variables {
    manage_iam_password_policy   = true
    additional_state_object_keys = ["network/extensions/terraform.tfstate"]
  }

  assert {
    condition = (
      length(aws_iam_account_password_policy.local_users) == 1 &&
      aws_iam_account_password_policy.local_users[0].max_password_age == 0
    )
    error_message = "Password policy opt-in should not introduce periodic expiry."
  }

  assert {
    condition     = length(output.state_object_keys) == 4
    error_message = "An additional exact state key must be included."
  }
}

# STS 세션 ARN 은 영구 주체가 아니므로 신뢰 정책에 넣지 않습니다.
run "reject_sts_session_principal" {
  command = plan

  variables {
    trusted_principal_arns = ["arn:aws:sts::111111111111:assumed-role/PlatformOperator/session"]
  }

  expect_failures = [var.trusted_principal_arns]
}

# 와일드카드 key 는 최소 권한 계약을 깨므로 거부합니다.
run "reject_wildcard_state_key" {
  command = plan

  variables {
    additional_state_object_keys = ["*/terraform.tfstate"]
  }

  expect_failures = [var.additional_state_object_keys]
}

# 읽은 bootstrap State 의 버킷 이름이 입력과 다르면 다른 계정 · 다른 버킷의 State 이므로 중단합니다.
run "reject_bootstrap_bucket_mismatch" {
  command = plan

  variables {
    state_bucket_name = "company-other-tfstate-111111111111"
  }

  expect_failures = [data.terraform_remote_state.bootstrap]
}

# 값 초기화와 SCRAM 연결의 독립 root만 정확한 State key로 허용합니다.
run "queue_secret_roots_exact_scope" {
  command = plan
  variables {
    additional_state_object_keys = [
      "platform/queue-secrets/terraform.tfstate",
      "platform/queue-association/terraform.tfstate",
    ]
  }
  assert {
    condition = alltrue([
      contains(output.state_object_keys, "platform/queue-secrets/terraform.tfstate"),
      contains(output.state_object_keys, "platform/queue-association/terraform.tfstate"),
      !contains(output.state_object_keys, "bootstrap/state/terraform.tfstate"),
      !contains(output.state_object_keys, "platform/queue/other.tfstate"),
    ])
    error_message = "Allow the two exact queue lifecycle states without extending bootstrap or unrelated object scope."
  }
}
