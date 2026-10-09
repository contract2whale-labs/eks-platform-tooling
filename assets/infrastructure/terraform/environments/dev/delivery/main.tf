# main.tf — delivery 루트 모듈 (dev · prod 공통 코드)

module "component" {
  source = "../../../../modules/delivery" # 예: 이 루트 모듈에서 모듈까지의 상대 경로 (네 단계 위가 저장소 최상위)

  cluster_contract          = local.cluster_contract          # 예: eks State 로 조립한 3항목
  expected_account_id       = var.expected_account_id         # 예: "111111111111"
  region                    = var.region                      # 예: "ap-northeast-2"
  environment               = var.environment                 # 예: "dev" (cp-dev-ci-delivery · gitops/apps/commerce-web/overlays/dev · gitops/apps/commerce-api/overlays/dev)
  github_oidc_provider_arn  = local.github_oidc_provider_arn  # 예: account-baseline State 의 provider ARN
  external_secrets_role_arn = local.external_secrets_role_arn # 예: platform/operations State 의 ESO controller Role (assume-role chaining 신뢰 주체)
  argocd_oidc_client_id     = var.argocd_oidc_client_id
  cognito_issuer            = local.cognito_issuer         # 예: platform/app-auth State 의 Cognito issuer (Argo CD SSO)
  github_app_repositories   = var.github_app_repositories  # 예: { owner_id = "201234567", web = { name = "contract2whale-labs/commerce-web", id = "1012345601" }, api = { … } }
  gitops_repository         = var.gitops_repository        # 예: "contract2whale-labs/cloud-platform-infrastructure"
  permissions_boundary_arn  = var.permissions_boundary_arn # 예: null
  previous_signing_key_id   = var.previous_signing_key_id  # 예: null (키 회전 중에만 이전 키 ID — 증적과 복구 런북)
}

# 이 디렉터리는 dev 만 받습니다. input 은 State 에 남는 marker 이며 AWS 자원을 만들지 않습니다.
resource "terraform_data" "environment_boundary" {
  input = var.environment # 예: "dev" (input 변경은 in-place 갱신)

  lifecycle {
    precondition {
      condition     = var.environment == "dev" # 예: "dev" 통과 / "prod" 거부 (prod 는 prod/delivery 디렉터리)
      error_message = "This directory accepts only the dev environment."
    }

    precondition {
      condition     = terraform.workspace == "default" # 예: workspace 로 환경을 나누지 않음 (backend key · 버킷으로 구분)
      error_message = "Use default workspace and a distinct backend key."
    }
  }
}
