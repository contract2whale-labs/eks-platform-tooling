# tests/storage.tftest.hcl — modules/delivery

mock_provider "aws" {
  override_during = apply # 예: apply 단계의 computed 값을 아래 defaults 로 채움

  mock_resource "aws_ecr_repository" {
    defaults = {
      arn            = "arn:aws:ecr:ap-northeast-2:111111111111:repository/commerce-api" # 예: 정책 Resource 형식 fixture (mock 은 인스턴스마다 같은 값)
      repository_url = "111111111111.dkr.ecr.ap-northeast-2.amazonaws.com/commerce-api"  # 예: 계약 url fixture
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:ap-northeast-2:111111111111:key/1234abcd-12ab-34cd-86ef-1234567890ab" # 예: 키 ARN fixture
      key_id = "1234abcd-12ab-34cd-86ef-1234567890ab"                                             # 예: alias target fixture
    }
  }

  mock_data "aws_kms_public_key" {
    defaults = {
      public_key_pem = "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEmock\n-----END PUBLIC KEY-----\n" # 예: PEM 형식 fixture (실제 키 아님)
    }
  }

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/platform/mock-role" } # 예: Pod Identity 연결의 role_arn 형식 fixture
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:mock-AbCdEf" } # 예: 정책 Resource 형식 fixture
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

run "repositories_are_immutable_and_scanned" {
  command = plan

  assert {
    condition     = alltrue([for repository in aws_ecr_repository.app : repository.image_tag_mutability == "IMMUTABLE_WITH_EXCLUSION" && join(",", sort([for f in repository.image_tag_mutability_exclusion_filter : f.filter])) == "sha256-*.att,sha256-*.sig"]) # 예: 같은 태그 재사용 거부 (두 리포지토리 모두)
    error_message = "Both commerce repositories must be immutable except the cosign signature and attestation tags."
  }

  assert {
    condition     = alltrue([for repository in aws_ecr_repository.app : repository.image_scanning_configuration[0].scan_on_push == true]) # 예: push 마다 스캔
    error_message = "scan_on_push must be enabled on both repositories."
  }

  assert {
    condition     = sort(keys(aws_ecr_repository.app)) == tolist(["commerce-api", "commerce-web"]) && length(aws_ecr_lifecycle_policy.app) == 2 # 예: 기본 리포지토리 2개 + 정책 2개
    error_message = "The default repositories are commerce-web and commerce-api, each with one lifecycle policy."
  }

  assert {
    condition     = aws_ecr_registry_scanning_configuration.account[0].scan_type == "ENHANCED" && [for rule in aws_ecr_registry_scanning_configuration.account[0].rule : rule.scan_frequency] == ["CONTINUOUS_SCAN"] # 예: Inspector v2 지속 스캔 (rule 은 set — for 식으로 읽음)
    error_message = "Registry scanning must be ENHANCED with continuous scan."
  }
}

run "lifecycle_policy_expires_untagged_and_keeps_releases" {
  command = plan

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.app["commerce-web"].policy).rules[0].selection.tagStatus == "untagged" && jsondecode(aws_ecr_lifecycle_policy.app["commerce-web"].policy).rules[0].selection.countNumber == 7 # 예: untagged · 7
    error_message = "Rule 1 must expire untagged images after 7 days."
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.app["commerce-web"].policy).rules[1].selection.tagPrefixList == ["v"] && jsondecode(aws_ecr_lifecycle_policy.app["commerce-web"].policy).rules[1].selection.countNumber == 30 # 예: v · 30
    error_message = "Rule 2 must keep the newest 30 v* tags."
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.app["commerce-web"].policy).rules[2].selection.tagPrefixList == ["build-"] && jsondecode(aws_ecr_lifecycle_policy.app["commerce-web"].policy).rules[2].selection.countNumber == 14 # 예: 빌드 태그 14일
    error_message = "Rule 3 must expire build- tags after 14 days."
  }
}

# 3. prod 는 이미지가 남아 있으면 리포지토리 삭제를 거부합니다 (force_delete false).
run "prod_repository_refuses_force_delete" {
  command = plan

  variables {
    environment = "prod"
  }

  assert {
    condition     = alltrue([for repository in aws_ecr_repository.app : repository.force_delete == false]) # 예: prod false (두 리포지토리 모두)
    error_message = "force_delete must be false for prod."
  }
}

# 4. 서명 키: SIGN_VERIFY · ECC_NIST_P256 · alias 이름 · root 위임 정책.
run "signing_key_is_asymmetric_p256" {
  command = plan

  assert {
    condition     = aws_kms_key.signing.key_usage == "SIGN_VERIFY" && aws_kms_key.signing.customer_master_key_spec == "ECC_NIST_P256" # 예: 서명 전용 P-256
    error_message = "Signing key must be an ECC_NIST_P256 SIGN_VERIFY key."
  }

  assert {
    condition     = aws_kms_alias.signing.name == "alias/delivery-signing" && length(aws_kms_alias.signing_previous) == 0 # 예: 환경 무관 alias · 회전 중이 아니면 previous 없음
    error_message = "Alias name must be alias/delivery-signing and no previous alias exists outside a rotation."
  }

  assert {
    condition     = jsondecode(aws_kms_key.signing.policy).Statement[0].Principal.AWS == "arn:aws:iam::111111111111:root" && length(jsondecode(aws_kms_key.signing.policy).Statement) == 1 # 예: root 위임 Statement 1개
    error_message = "Key policy must delegate to the account root only (IAM policies decide the rest)."
  }
}

# 5. 다른 계정의 클러스터 ARN 은 계약 검사가 거부합니다.
run "reject_contract_from_other_account" {
  command = plan

  variables {
    cluster_contract = {
      name   = "contract2whale-dev-eks"
      arn    = "arn:aws:eks:ap-northeast-2:222222222222:cluster/contract2whale-dev-eks"
      region = "ap-northeast-2"
    }
  }

  expect_failures = [terraform_data.contract] # 예: precondition 1 실패
}

# 6. ECR 이름 규칙에 어긋나는 리포지토리 이름은 validation 이 거부합니다.
run "reject_invalid_repository_name" {
  command = plan

  variables {
    ecr_repository_names = ["Commerce_Web"] # 예: 대문자 거부
  }

  expect_failures = [var.ecr_repository_names]
}
