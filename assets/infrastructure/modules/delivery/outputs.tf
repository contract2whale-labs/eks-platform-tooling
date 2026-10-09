# outputs.tf — modules/delivery (dev · prod 루트 모듈이 공유하는 모듈)
# 애플리케이션 데이터(data 루트 모듈의 application · tenant-pod-identity 의 ECR · 네임스페이스) · 릴리스 파이프라인(CI Role · 리포지토리 · 키 alias) · 운영 환경(prod 루트 모듈) 가 이 이름을 씁니다.

output "delivery_contract" {
  description = "Account, region, environment, cluster, registry, the two repositories, signing key, CI role, the two application workloads, Argo CD and Kyverno settings for downstream roots and the bootstrap script."
  value = {
    account_id   = var.expected_account_id   # 예: "111111111111"
    region       = var.region                # 예: "ap-northeast-2"
    environment  = var.environment           # 예: "dev"
    cluster_name = var.cluster_contract.name # 예: "contract2whale-dev-eks"

    ecr_registry = local.ecr_registry # 예: "111111111111.dkr.ecr.ap-northeast-2.amazonaws.com"
    ecr_repositories = {
      for name, repository in aws_ecr_repository.app : name => {
        name = repository.name           # 예: "commerce-web" (필드 계약: commerce-api · commerce-web)
        url  = repository.repository_url # 예: "111111111111.dkr.ecr.ap-northeast-2.amazonaws.com/commerce-web"
        arn  = repository.arn            # 예: "arn:aws:ecr:ap-northeast-2:111111111111:repository/commerce-web"
      }
    }

    signing_key_arn        = aws_kms_key.signing.arn                        # 예: "arn:aws:kms:ap-northeast-2:111111111111:key/1234abcd-…"
    signing_key_alias      = aws_kms_alias.signing.name                     # 예: "alias/delivery-signing" (cosign --key awskms:///alias/delivery-signing · Kyverno keys.kms)
    signing_public_key_pem = data.aws_kms_public_key.signing.public_key_pem # 예: "-----BEGIN PUBLIC KEY-----\n…\n-----END PUBLIC KEY-----\n" (로컬 cosign verify --key · 증적)

    ci_role_arn  = aws_iam_role.ci.arn  # 예: "arn:aws:iam::111111111111:role/platform/cp-dev-ci-delivery" (Actions 의 role-to-assume)
    ci_role_name = aws_iam_role.ci.name # 예: "cp-dev-ci-delivery"

    application = {
      namespace = var.application_namespace # 예: "contract2whale-demo" (argocd.application_namespace 와 같은 값)
      web = {
        deployment = var.application_workloads.web.deployment # 예: "commerce-web" (Rollout · Service 이름 = 이미지 이름)
        container  = var.application_workloads.web.container  # 예: "commerce-web" (Rollout 컨테이너 이름 · kustomize edit set image 의 이미지 이름)
      }
      api = {
        deployment                = var.application_workloads.api.deployment                # 예: "commerce-api" (data 모듈의 비밀 접두사 contract2whale/<env>/commerce-api · 미디어 접두사 media/<env>/commerce-api/)
        container                 = var.application_workloads.api.container                 # 예: "commerce-api"
        migration_service_account = var.application_workloads.api.migration_service_account # 예: "delivery-migration" (data 계약 service_accounts.migration → tenant-pod-identity 연결)
      }
    }

    argocd = {
      namespace         = var.argocd_namespace                          # 예: "argocd"
      repo_secret_name  = aws_secretsmanager_secret.argocd_repo.name    # 예: "delivery/argocd-repo-key"
      repo_secret_arn   = aws_secretsmanager_secret.argocd_repo.arn     # 예: "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:delivery/argocd-repo-key-AbCdEf"
      oidc_secret_name  = aws_secretsmanager_secret.argocd_oidc.name    # 예: "delivery/argocd-oidc-client"
      secrets_role_arn  = aws_iam_role.argocd_secrets.arn               # 예: "arn:aws:iam::111111111111:role/platform/contract2whale-dev-eks-delivery-argocd-secrets" (SecretStore spec.provider.aws.role)
      oidc_issuer       = var.cognito_issuer                            # 예: "https://cognito-idp.ap-northeast-2.amazonaws.com/ap-northeast-2_AbCdEfGhI"
      oidc_client_id    = var.argocd_oidc_client_id                     # 예: "7example8argocdclientid9"
      gitops_repository = var.gitops_repository                         # 예: "contract2whale-labs/cloud-platform-infrastructure"
      gitops_ssh_url    = "git@github.com:${var.gitops_repository}.git" # 예: "git@github.com:contract2whale-labs/cloud-platform-infrastructure.git" (Application repoURL · repo Secret url)
      gitops_paths = {
        web = "gitops/apps/${var.application_workloads.web.deployment}/overlays/${var.environment}" # 예: "gitops/apps/commerce-web/overlays/dev" (Application commerce-web-dev 의 path)
        api = "gitops/apps/${var.application_workloads.api.deployment}/overlays/${var.environment}" # 예: "gitops/apps/commerce-api/overlays/dev" (Application commerce-api-dev 의 path)
      }
      gitops_revision       = "main"                    # 예: "main" (Application targetRevision)
      application_namespace = var.application_namespace # 예: "contract2whale-demo" (AppProject destination · Application destination)
    }

    kyverno = {
      namespace = var.kyverno_namespace    # 예: "kyverno"
      role_arn  = aws_iam_role.kyverno.arn # 예: "arn:aws:iam::111111111111:role/platform/contract2whale-dev-eks-delivery-kyverno"
    }
  }
}

output "ecr_repository_urls" {
  description = "Repository URL per image name."
  value       = { for name, repository in aws_ecr_repository.app : name => repository.repository_url } # 예: { commerce-api = "111111111111.dkr.ecr.ap-northeast-2.amazonaws.com/commerce-api", commerce-web = "…/commerce-web" }
}

output "signing_public_key_pem" {
  description = "PEM public key of the cosign signing key (not secret; local cosign verify --key input)."
  value       = data.aws_kms_public_key.signing.public_key_pem # 예: "-----BEGIN PUBLIC KEY-----…"
}

output "pod_identity_association_ids" {
  description = "Association ID per Kyverno service account (admission and reports controllers)."
  value       = { for name, association in aws_eks_pod_identity_association.kyverno : "kyverno_${replace(name, "kyverno-", "")}" => association.association_id } # 예: { kyverno_admission-controller = "a-1…", kyverno_reports-controller = "a-2…" }
}

# 이 출력 자체는 파일을 저장하지 않습니다. 승인된 delivery receipt와 registry를 사용하는 publisher가 gitops/platform/overlays/<env>/env.yaml을 만듭니다. Kustomize replacements가 ConfigMap 값을 Kyverno 정책과 SecretStore에 연결합니다.


# 같은 publisher가 gitops/platform/values/argo-cd-<env>.yaml의 SSO issuer와 client ID를 만듭니다. 시크릿은 값이 아니라 $argocd-oidc-cognito:clientSecret 참조입니다.
