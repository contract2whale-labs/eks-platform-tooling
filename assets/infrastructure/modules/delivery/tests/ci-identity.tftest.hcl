# tests/ci-identity.tftest.hcl — modules/delivery

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

run "ci_role_trusts_only_release_refs" {
  command = plan

  assert {
    condition     = aws_iam_role.ci.name == "cp-dev-ci-delivery" && aws_iam_role.ci.path == "/platform/" # 예: 이름 · 경로 규칙
    error_message = "CI role must be /platform/cp-dev-ci-delivery."
  }

  assert {
    condition     = jsondecode(aws_iam_role.ci.assume_role_policy).Statement[0].Principal.Federated == var.github_oidc_provider_arn && jsondecode(aws_iam_role.ci.assume_role_policy).Statement[0].Action == "sts:AssumeRoleWithWebIdentity" # 예: OIDC provider 만 신뢰
    error_message = "Trust policy must federate the GitHub OIDC provider with AssumeRoleWithWebIdentity."
  }

  assert {
    condition     = jsondecode(aws_iam_role.ci.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com" # 예: aud 고정
    error_message = "aud must be sts.amazonaws.com."
  }

  assert {
    condition = jsondecode(aws_iam_role.ci.assume_role_policy).Statement[0].Condition.StringLike["token.actions.githubusercontent.com:sub"] == [
      "repo:contract2whale-labs@201234567/commerce-api@1012345602:ref:refs/heads/main",
      "repo:contract2whale-labs@201234567/commerce-web@1012345601:ref:refs/heads/main",
    ] # 예: 저장소 이름 정렬 순서 · owner ID · 저장소 ID 포함 (2026-07-15 이후 만든 저장소의 sub 형식)
    error_message = "sub must list only the two application repositories' main branch in the owner-id/repository-id format."
  }

  assert {
    condition = alltrue([
      for sub in [
        "repo:contract2whale-labs/commerce-web:ref:refs/heads/main",                       # 예: ID 없는 옛 형식
        "repo:contract2whale-labs@201234567/commerce-web@1099999999:ref:refs/heads/main",  # 예: 이름은 같고 저장소 ID 가 다름 (지우고 다시 만든 저장소)
        "repo:contract2whale-labs@299999999/commerce-web@1012345601:ref:refs/heads/main",  # 예: 이름은 같고 owner ID 가 다름 (이름을 넘겨받은 다른 owner)
        "repo:contract2whale-labs@201234567/commerce-web@1012345601:ref:refs/tags/v1.0.0", # 예: 태그 (Ruleset 이 보호하지 않는 ref)
        "repo:contract2whale-labs@201234567/commerce-web@1012345601:pull_request",         # 예: PR
      ] : !contains(local.github_subjects, sub)
    ]) && alltrue([for pattern in local.github_subjects : !strcontains(pattern, "*") && !strcontains(pattern, "?")]) # 예: 와일드카드가 없으므로 StringLike 는 정확히 일치할 때만 허용 → 위 다섯 sub 는 모두 거부
    error_message = "The trust policy must not match legacy subs, other IDs, tags or pull requests."
  }
}

# 2. 권한 정책: ECR push 는 이 모듈의 리포지토리만, KMS 는 서명 키만, eks:* · kms:Decrypt · iam:* 없음.
run "ci_policy_is_limited_to_push_and_sign" {
  command = apply # 예: 정책 Resource 가 ECR · KMS ARN(계산값)을 참조하므로 apply 단계에서 확인

  assert {
    condition     = [for statement in jsondecode(aws_iam_role_policy.ci.policy).Statement : statement.Sid] == ["EcrLogin", "EcrPush", "KmsSign"] # 예: Statement 3개
    error_message = "CI policy must contain exactly EcrLogin, EcrPush and KmsSign."
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.ci.policy).Statement[1].Resource) == 2 && contains(jsondecode(aws_iam_role_policy.ci.policy).Statement[1].Resource, aws_ecr_repository.app["commerce-web"].arn) && jsondecode(aws_iam_role_policy.ci.policy).Statement[2].Resource == aws_kms_key.signing.arn # 예: 저장소 2개 · 필드 계약
    error_message = "Push and sign statements must target only this module's two repositories and its key."
  }

  assert {
    condition = alltrue([
      for action in flatten([for statement in jsondecode(aws_iam_role_policy.ci.policy).Statement : statement.Action]) :
      !startswith(action, "eks:") && !startswith(action, "iam:") && action != "kms:Decrypt" && action != "kms:Encrypt" # 예: 클러스터 · IAM · 복호화 동작 없음
    ])
    error_message = "CI policy must not grant eks:*, iam:*, kms:Decrypt or kms:Encrypt."
  }

  assert {
    condition     = sort(jsondecode(aws_iam_role_policy.ci.policy).Statement[2].Action) == tolist(["kms:DescribeKey", "kms:GetPublicKey", "kms:Sign"]) # 예: 서명 3동작
    error_message = "KmsSign must allow exactly kms:Sign, kms:GetPublicKey and kms:DescribeKey."
  }
}

# 3. 다른 계정의 provider ARN 은 Role 의 precondition 이 거부합니다.
run "reject_provider_from_other_account" {
  command = plan

  variables {
    github_oidc_provider_arn = "arn:aws:iam::222222222222:oidc-provider/token.actions.githubusercontent.com"
  }

  expect_failures = [aws_iam_role.ci]
}

# 4. 태그 ref 와 숫자가 아닌 저장소 ID 는 validation 이 거부합니다 (두 변수 모두 실패해야 통과).
run "reject_tag_ref_and_non_numeric_repository_id" {
  command = plan

  variables {
    github_release_refs = ["refs/tags/v*"] # 예: branch 가 아님 — Ruleset 이 보호하지 않는 ref
    github_app_repositories = {
      owner_id = "201234567"
      web      = { name = "contract2whale-labs/commerce-web", id = "commerce-web" } # 예: 이름을 ID 자리에 넣은 실수 (숫자 ID 여야 함)
      api      = { name = "contract2whale-labs/commerce-api", id = "1012345602" }
    }
  }

  expect_failures = [var.github_release_refs, var.github_app_repositories]
}
