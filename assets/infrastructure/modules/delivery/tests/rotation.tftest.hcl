# tests/rotation.tftest.hcl — modules/delivery
# 증적과 복구: 서명 키 교체 중(previous_signing_key_id 지정)에만 생기는 권한을 확인합니다 — CI Role 은 이전 키로 **검증만** 할 수 있어야 합니다(resign 워크플로의 사전 확인).

mock_provider "aws" {
  override_during = apply

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
}

variables {
  gitops_repository = "contract2whale-labs/cloud-platform-infrastructure" # mock: 실제 GitHub에 접근하지 않음
  cluster_contract = {
    name   = "contract2whale-dev-eks"
    arn    = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
    region = "ap-northeast-2"
  }
  expected_account_id       = "111111111111"
  region                    = "ap-northeast-2"
  environment               = "dev"
  github_oidc_provider_arn  = "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com"
  external_secrets_role_arn = "arn:aws:iam::111111111111:role/contract2whale-dev-eks-external-secrets"
  cognito_issuer            = "https://cognito-idp.ap-northeast-2.amazonaws.com/ap-northeast-2_AbCdEfGhI"
  github_app_repositories = {
    owner_id = "201234567" # 예: fixture ID — owner 1 · 저장소 2 (실제 저장소의 ID 가 아님)
    web      = { name = "contract2whale-labs/commerce-web", id = "1012345601" }
    api      = { name = "contract2whale-labs/commerce-api", id = "1012345602" }
  }
}

# 1. 키 교체 중: resign 워크플로가 이전 키의 서명을 **검증만** 할 수 있어야 합니다 — Sign 은 없고, Resource 는 alias 가 아니라 key ARN.
run "ci_policy_can_only_verify_with_previous_key" {
  command = apply

  variables {
    previous_signing_key_id = "1234abcd-12ab-34cd-86ef-1234567890ab" # 예: 이전 키 A 의 key ID
  }

  assert {
    condition     = [for statement in jsondecode(aws_iam_role_policy.ci.policy).Statement : statement.Sid] == ["EcrLogin", "EcrPush", "KmsSign", "KmsVerifyPrevious"] # 예: 교체 중에만 4개
    error_message = "During rotation the CI policy must add exactly one statement: KmsVerifyPrevious."
  }

  assert {
    condition     = sort(jsondecode(aws_iam_role_policy.ci.policy).Statement[3].Action) == tolist(["kms:DescribeKey", "kms:GetPublicKey"]) # 예: cosign 검증이 부르는 두 API 만 (kms:Sign 없음)
    error_message = "KmsVerifyPrevious must allow only kms:GetPublicKey and kms:DescribeKey."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.ci.policy).Statement[3].Resource == "arn:aws:kms:ap-northeast-2:111111111111:key/1234abcd-12ab-34cd-86ef-1234567890ab" # 예: key ARN (alias ARN 아님)
    error_message = "KmsVerifyPrevious must target the previous key by its key ARN."
  }
}
