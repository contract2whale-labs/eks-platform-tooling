# tests/github-identity.tftest.hcl — account-baseline 루트 모듈 (dev · prod 공통 코드)
# mock provider 로 AWS API 호출 없이 plan 만 실행해 GitHub OIDC 의 기본 미생성 · 생성 계약 · 모순 입력 거부를 확인합니다.
# 실제 provider 의 URL · audience 는 account 의 aws iam get-open-id-connect-provider 조회가 판정합니다.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" # 예: 빈 정책 JSON (형식만 유지)
    }
  }
}

# bootstrap/state 의 root 출력을 S3 대신 고정 fixture 로 대체합니다.
override_data {
  target = data.terraform_remote_state.bootstrap
  values = {
    outputs = {
      state_bucket_name   = "company-dev-tfstate-111111111111"
      state_bucket_arn    = "arn:aws:s3:::company-dev-tfstate-111111111111"
      state_region        = "ap-northeast-2"
      expected_account_id = "111111111111"
    }
  }
}

# 실제 기존 provider ARN 이 mock 테스트에 유입되지 않도록 fixture 는 기본값(미생성 · null)으로 둡니다.
variables {
  expected_account_id               = "111111111111"
  region                            = "ap-northeast-2"
  environment                       = "dev"
  state_bucket_name                 = "company-dev-tfstate-111111111111"
  trusted_principal_arns            = ["arn:aws:iam::111111111111:role/PlatformOperator"]
  create_github_oidc                = false
  existing_github_oidc_provider_arn = null
}

run "github_oidc_disabled_by_default" {
  command = plan

  assert {
    condition = (
      length(aws_iam_openid_connect_provider.github) == 0 &&
      output.github_oidc_provider_arn == null
    )
    error_message = "The GitHub OIDC provider must not be created unless explicitly requested."
  }
}

run "create_github_oidc_provider" {
  command = plan

  variables {
    create_github_oidc = true
  }

  assert {
    condition = (
      length(aws_iam_openid_connect_provider.github) == 1 &&
      aws_iam_openid_connect_provider.github[0].url == "https://token.actions.githubusercontent.com" &&
      contains(aws_iam_openid_connect_provider.github[0].client_id_list, "sts.amazonaws.com")
    )
    error_message = "GitHub OIDC creation must use the GitHub issuer URL and the STS audience."
  }
}

# 기존 ARN 을 재사용하면 리소스는 만들지 않고 출력만 그 ARN 을 돌려줍니다.
run "reuse_existing_github_oidc_provider" {
  command = plan

  variables {
    existing_github_oidc_provider_arn = "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com"
  }

  assert {
    condition = (
      length(aws_iam_openid_connect_provider.github) == 0 &&
      output.github_oidc_provider_arn == "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com"
    )
    error_message = "An existing provider ARN must be passed through without creating a resource."
  }
}

# 신규 생성과 기존 ARN 재사용을 동시에 지정하면 precondition 이 거부합니다.
run "reject_oidc_creation_with_existing_arn" {
  command = plan

  variables {
    create_github_oidc                = true
    existing_github_oidc_provider_arn = "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com"
  }

  expect_failures = [aws_iam_openid_connect_provider.github]
}

# 다른 계정의 provider ARN 은 이 계정의 것이 아니므로 거부합니다.
run "reject_foreign_oidc_provider_arn" {
  command = plan

  variables {
    existing_github_oidc_provider_arn = "arn:aws:iam::222222222222:oidc-provider/token.actions.githubusercontent.com"
  }

  expect_failures = [var.existing_github_oidc_provider_arn]
}
