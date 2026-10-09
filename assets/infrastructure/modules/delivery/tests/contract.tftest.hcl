# tests/contract.tftest.hcl — modules/delivery

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

  mock_resource "aws_cognito_user_pool_client" {
    defaults = { id = "7example8argocdclientid9", client_secret = "mock-client-secret" } # 예: Cognito 가 발급하는 값의 fixture
  }
}

variables {
  argocd_oidc_client_id = "7example8argocdclientid9"
  gitops_repository     = "contract2whale-labs/cloud-platform-infrastructure" # mock: 실제 GitHub에 접근하지 않음
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

run "contract_has_fourteen_keys" {
  command = apply

  assert {
    condition     = length(keys(output.delivery_contract)) == 14 # 예: account_id … application … kyverno
    error_message = "delivery_contract must expose 14 keys."
  }

  assert {
    condition     = output.delivery_contract.ecr_registry == "111111111111.dkr.ecr.ap-northeast-2.amazonaws.com" && sort(keys(output.delivery_contract.ecr_repositories)) == tolist(["commerce-api", "commerce-web"]) && output.delivery_contract.ecr_repositories["commerce-web"].name == "commerce-web" # 예: 레지스트리 · 리포지토리 2개 (url 은 mock fixture 라 이름으로 대조)
    error_message = "The contract must carry the registry and both commerce repositories."
  }

  assert {
    condition     = output.delivery_contract.argocd.gitops_ssh_url == "git@github.com:contract2whale-labs/cloud-platform-infrastructure.git" && output.delivery_contract.argocd.gitops_paths.web == "gitops/apps/commerce-web/overlays/dev" && output.delivery_contract.argocd.gitops_paths.api == "gitops/apps/commerce-api/overlays/dev" && output.delivery_contract.argocd.application_namespace == "contract2whale-demo" # 예: Argo CD 계약 (overlay 경로 2개)
    error_message = "Argo CD contract must carry the SSH url, both dev overlay paths and the tenant namespace."
  }

  assert {
    condition     = output.delivery_contract.application.namespace == "contract2whale-demo" && output.delivery_contract.application.web.deployment == "commerce-web" && output.delivery_contract.application.api.deployment == "commerce-api" && output.delivery_contract.application.api.migration_service_account == "delivery-migration" # 예: 애플리케이션 데이터 data 루트 모듈이 읽는 앱 좌표 (워크로드 2개)
    error_message = "Application contract must carry the tenant namespace, both workload names and the migration service account."
  }

  assert {
    condition     = output.delivery_contract.application.web.container == "commerce-web" && output.delivery_contract.application.api.container == "commerce-api" # 예: Rollout 컨테이너 이름 (kustomize edit set image · Kyverno 테스트 자원이 같은 이름)
    error_message = "Application contract must carry the container name of each workload."
  }

  assert {
    condition     = output.delivery_contract.signing_key_alias == "alias/delivery-signing" && startswith(output.delivery_contract.signing_public_key_pem, "-----BEGIN PUBLIC KEY-----") # 예: 환경 무관 alias · PEM
    error_message = "Contract must carry the environment-independent key alias and the PEM public key."
  }

  assert {
    condition     = output.delivery_contract.argocd.oidc_issuer == "https://cognito-idp.ap-northeast-2.amazonaws.com/ap-northeast-2_AbCdEfGhI" && output.delivery_contract.argocd.oidc_client_id == "7example8argocdclientid9" && output.delivery_contract.argocd.oidc_secret_name == "delivery/argocd-oidc-client" # 예: SSO 설정
    error_message = "Argo CD contract must carry the Cognito issuer, the client id and the OIDC secret name."
  }
}

run "identities_are_chained_and_scoped" {
  command = plan

  assert {
    condition     = sort(keys(aws_eks_pod_identity_association.kyverno)) == tolist(["kyverno-admission-controller", "kyverno-reports-controller"]) && alltrue([for association in aws_eks_pod_identity_association.kyverno : association.namespace == "kyverno"]) # 예: SA 2개 · 네임스페이스 kyverno
    error_message = "Kyverno associations must target the admission and reports controllers in kyverno."
  }

  assert {
    condition     = jsondecode(aws_iam_role.argocd_secrets.assume_role_policy).Statement[0].Principal.AWS == "arn:aws:iam::111111111111:role/contract2whale-dev-eks-external-secrets" && jsondecode(aws_iam_role.argocd_secrets.assume_role_policy).Statement[0].Condition.StringEquals["aws:PrincipalTag/kubernetes-service-account"] == "external-secrets" # 예: 신뢰 주체 · 태그 조건
    error_message = "argocd_secrets role must trust only the 운영 도구 External Secrets controller role with the service-account tag condition."
  }

  assert {
    condition     = aws_iam_role.migration.name == "contract2whale-dev-eks-delivery-migration" && aws_iam_role.migration.path == "/platform/" && jsondecode(aws_iam_role.migration.assume_role_policy).Statement[0].Principal.Service == "pods.eks.amazonaws.com" && jsondecode(aws_iam_role.migration.assume_role_policy).Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-service-account"] == "delivery-migration" # 예: 애플리케이션 데이터 identity 루트의 조회 조건(이름 · 경로 · 신뢰 주체)과 SA 조건
    error_message = "The migration role must be <cluster>-delivery-migration under /platform/ and trust only Pod Identity sessions of the delivery-migration service account."
  }

  assert {
    condition     = aws_secretsmanager_secret.argocd_repo.name == "delivery/argocd-repo-key" && aws_secretsmanager_secret.argocd_repo.recovery_window_in_days == 0 && aws_secretsmanager_secret.argocd_oidc.name == "delivery/argocd-oidc-client" # 예: 환경 무관 비밀 이름
    error_message = "Delivery secrets must be delivery/argocd-repo-key and delivery/argocd-oidc-client with no recovery window."
  }

}

# 4. Kyverno · Argo CD 비밀 정책은 읽기뿐입니다 (PutImage · Upload · Sign 없음; KMS 는 GetPublicKey · DescribeKey 만).
run "delivery_identities_are_read_only" {
  command = apply

  assert {
    condition = alltrue([
      for action in flatten([for statement in jsondecode(aws_iam_role_policy.kyverno.policy).Statement : statement.Action]) :
      !contains(["ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "kms:Sign", "kms:Decrypt"], action) # 예: 쓰기 · 서명 · 복호화 없음
    ])
    error_message = "Kyverno policy must be ECR read-only with KMS public-key access only."
  }

  assert {
    condition     = sort(jsondecode(aws_iam_role_policy.kyverno.policy).Statement[2].Action) == tolist(["kms:DescribeKey", "kms:GetPublicKey"]) && jsondecode(aws_iam_role_policy.kyverno.policy).Statement[2].Resource == [aws_kms_key.signing.arn] # 예: 공개 키 조회는 서명 키만
    error_message = "Kyverno KmsPublicKey statement must allow GetPublicKey and DescribeKey on the signing key only."
  }

  assert {
    condition     = sort(jsondecode(aws_iam_role_policy.argocd_secrets.policy).Statement[0].Action) == tolist(["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue"]) && length(jsondecode(aws_iam_role_policy.argocd_secrets.policy).Statement[0].Resource) == 2 # 예: 읽기 2동작 · 비밀 2개
    error_message = "argocd_secrets policy must read exactly the two delivery secrets."
  }
}

# 5. DNS label 이 아닌 네임스페이스는 validation 이 거부합니다.
run "reject_non_dns_namespace" {
  command = plan

  variables {
    application_namespace = "contract2whale_Demo" # 예: 대문자 · 밑줄 거부
  }

  expect_failures = [var.application_namespace]
}
