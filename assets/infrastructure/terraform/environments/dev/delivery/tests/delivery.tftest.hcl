# tests/delivery.tftest.hcl — delivery 루트 모듈 (dev · prod 공통 코드)
# terraform_remote_state 는 override_data 로 가짜 출력을 줍니다. 실제 AWS · S3 API 를 호출하지 않으며 아래 ID 는 AWS 에 없는 fixture 입니다.

mock_provider "aws" {
  override_during = apply # 예: apply 단계에서 computed 값을 아래 defaults 로 채움

  mock_resource "aws_ecr_repository" {
    defaults = {
      arn            = "arn:aws:ecr:ap-northeast-2:111111111111:repository/commerce-api" # 예: mock 은 인스턴스마다 같은 값을 돌려줍니다 (이름만 설정값이라 리포지토리별로 다름)
      repository_url = "111111111111.dkr.ecr.ap-northeast-2.amazonaws.com/commerce-api"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:ap-northeast-2:111111111111:key/1234abcd-12ab-34cd-86ef-1234567890ab"
      key_id = "1234abcd-12ab-34cd-86ef-1234567890ab"
    }
  }

  mock_data "aws_kms_public_key" {
    defaults = { public_key_pem = "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEmock\n-----END PUBLIC KEY-----\n" }
  }

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/platform/mock-role" }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:mock-AbCdEf" }
  }

  mock_resource "aws_cognito_user_pool_client" {
    defaults = { id = "7example8argocdclientid9", client_secret = "mock-client-secret" }
  }
}

variables {
  gitops_repository   = "contract2whale-labs/cloud-platform-infrastructure" # mock: 실제 GitHub에 접근하지 않음
  expected_account_id = "111111111111"
  region              = "ap-northeast-2"
  environment         = "dev"
  state_bucket_name   = "company-dev-tfstate-111111111111"
  github_app_repositories = {
    owner_id = "201234567" # 예: fixture ID — owner 1 · 저장소 2 (실제 저장소의 ID 가 아님)
    web      = { name = "contract2whale-labs/commerce-web", id = "1012345601" }
    api      = { name = "contract2whale-labs/commerce-api", id = "1012345602" }
  }
}

override_data {
  target = data.terraform_remote_state.eks
  values = {
    outputs = {
      cluster_contract = {
        name               = "contract2whale-dev-eks"
        arn                = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
        region             = "ap-northeast-2"
        vpc_id             = "vpc-0123456789abcdef0"
        kubernetes_version = "1.36"
      }
    }
  }
}

# account-baseline State 출력 (Dev GitHub OIDC 연결과 Prod 코드 배치 github_oidc_provider_arn + 무시되는 항목)
override_data {
  target = data.terraform_remote_state.account_baseline
  values = {
    outputs = {
      account_id               = "111111111111"
      github_oidc_provider_arn = "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com"
      state_access_role_arn    = "arn:aws:iam::111111111111:role/platform/cp-dev-terraform-state"
    }
  }
}

# platform/operations State 출력 (운영 도구 external_secrets_role_arn + 무시되는 계약)
override_data {
  target = data.terraform_remote_state.operations
  values = {
    outputs = {
      external_secrets_role_arn = "arn:aws:iam::111111111111:role/contract2whale-dev-eks-external-secrets"
      operations_contract       = { account_id = "111111111111", cluster_name = "contract2whale-dev-eks" }
    }
  }
}

# platform/app-auth State 출력 (팀 로그인과 API 인가 ui_auth.issuer + 무시되는 항목)
override_data {
  target = data.terraform_remote_state.app_auth
  values = {
    outputs = {
      ui_auth = { issuer = "https://cognito-idp.ap-northeast-2.amazonaws.com/ap-northeast-2_AbCdEfGhI", client_id = "1example2uiclientid3" }
    }
  }
}

# 1. 네 State 출력에서 모듈 입력을 조립합니다 (입력 파일 없음).
run "assembles_inputs_from_state" {
  command = plan

  assert {
    condition     = local.cluster_contract.name == "contract2whale-dev-eks" && length(keys(local.cluster_contract)) == 3 && terraform_data.environment_boundary.input == "dev"
    error_message = "cluster_contract must carry name, arn and region from the eks state and the boundary marker must be dev."
  }

  assert {
    condition     = local.github_oidc_provider_arn == "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com" && local.external_secrets_role_arn == "arn:aws:iam::111111111111:role/contract2whale-dev-eks-external-secrets" && endswith(local.cognito_issuer, "ap-northeast-2_AbCdEfGhI")
    error_message = "The OIDC provider, the External Secrets controller role and the Cognito issuer must come from their states."
  }
}

run "first_apply_exposes_contract_env_and_git_files" {
  command = apply

  assert {
    condition     = length(keys(output.delivery_contract)) == 14 && sort(keys(output.delivery_contract.ecr_repositories)) == tolist(["commerce-api", "commerce-web"]) && output.delivery_contract.argocd.gitops_paths.web == "gitops/apps/commerce-web/overlays/dev" && output.delivery_contract.ci_role_name == "cp-dev-ci-delivery"
    error_message = "delivery_contract must expose 14 keys, both commerce repositories, the dev overlay path and the dev CI role name."
  }


}

# 3. 이 디렉터리는 prod 를 거부합니다.
run "reject_prod_in_dev_directory" {
  command = plan

  variables {
    environment = "prod"
  }

  expect_failures = [terraform_data.environment_boundary]
}

# 4. eks State 에 cluster_contract 의 arn 이 없으면 거부합니다 (생성 계획과 private API 검증 미적용).
run "reject_eks_without_cluster_arn" {
  command = plan

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = { cluster_contract = { name = "contract2whale-dev-eks", region = "ap-northeast-2" } }
    }
  }

  expect_failures = [data.terraform_remote_state.eks]
}

# 5. account-baseline State 에 provider ARN 이 없으면 거부합니다 (Dev GitHub OIDC 연결과 Prod 코드 배치 미적용).
run "reject_account_baseline_without_oidc_provider" {
  command = plan

  override_data {
    target = data.terraform_remote_state.account_baseline
    values = {
      outputs = { account_id = "111111111111", state_access_role_arn = "arn:aws:iam::111111111111:role/platform/cp-dev-terraform-state" }
    }
  }

  expect_failures = [data.terraform_remote_state.account_baseline]
}

# 6. operations State 에 External Secrets controller Role 이 없으면 거부합니다 (운영 도구 미적용 또는 external_secrets 비활성).
run "reject_operations_without_external_secrets_role" {
  command = plan

  override_data {
    target = data.terraform_remote_state.operations
    values = {
      outputs = { operations_contract = { account_id = "111111111111" } }
    }
  }

  expect_failures = [data.terraform_remote_state.operations]
}
