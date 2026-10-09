# variables.tf — modules/delivery (dev · prod 루트 모듈이 공유하는 모듈)
# ECR 리포지토리 이름 · 보존 개수 · GitOps 저장소 경로 · 네임스페이스 · 두 앱 좌표(commerce-web · commerce-api)는 기본값이 있고(과정 값), 루트 모듈은 계정 · 리전 · 환경 · 계약 · provider ARN 만 채웁니다.

variable "cluster_contract" {
  description = "Cluster identity (name, arn, region) taken from the eks root output."
  type = object({
    name   = string # 예: "contract2whale-dev-eks"
    arn    = string # 예: "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
    region = string # 예: "ap-northeast-2"
  })
  nullable = false

  validation {
    condition     = var.cluster_contract.region == "ap-northeast-2" # 예: 서울 리전일 때만 참
    error_message = "This implementation is verified for the Seoul region."
  }

  validation {
    condition     = can(regex("^arn:aws:eks:[a-z0-9-]+:[0-9]{12}:cluster/[A-Za-z0-9_-]+$", var.cluster_contract.arn)) # 예: split(":")[4] 로 계정을 꺼낼 수 있는 형식
    error_message = "cluster_contract.arn must be an EKS cluster ARN."
  }
}

variable "expected_account_id" {
  description = "AWS account that owns the cluster, the registry and the signing key; 12 digits."
  type        = string # 예: "111111111111" (앞자리 0 이 사라지지 않도록 문자열)
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id)) # 예: 숫자 12자리만 참
    error_message = "Use a 12-digit AWS account ID."
  }
}

variable "region" {
  description = "AWS region for the registry and the key; only ap-northeast-2 is supported."
  type        = string
  default     = "ap-northeast-2" # 기본값: "ap-northeast-2"
  nullable    = false

  validation {
    condition     = var.region == "ap-northeast-2" # 예: 단일 값 비교
    error_message = "This module supports ap-northeast-2 only."
  }
}

# CI Role 이름(cp-<env>-ci-delivery) 과 두 gitops overlay 경로(gitops/apps/commerce-web/overlays/<env> · gitops/apps/commerce-api/overlays/<env>)에 들어갑니다.
variable "environment" {
  description = "Environment name used in the CI role name and the gitops overlay path."
  type        = string
  nullable    = false

  validation {
    condition     = contains(["dev", "prod"], var.environment) # 예: "dev" 통과 / "stage" 거부
    error_message = "environment must be dev or prod."
  }
}

# 이미지 리포지토리 이름은 앱 이미지 이름(릴리스 파이프라인 의 commerce-web · commerce-api)과 같습니다. 클러스터 접두사를 붙이지 않습니다 (URI 가 <계정>.dkr.ecr.<리전>.amazonaws.com/commerce-web).
variable "ecr_repository_names" {
  description = "ECR repository names to create; each is the image name one application repository builds (storefront and backend)."
  type        = set(string)
  default     = ["commerce-web", "commerce-api"] # 기본값: ["commerce-web", "commerce-api"] (릴리스 파이프라인 앱 이미지 2개)
  nullable    = false

  validation {
    condition     = length(var.ecr_repository_names) > 0 && alltrue([for name in var.ecr_repository_names : can(regex("^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$", name))]) # 예: "commerce-web" 통과 / "Commerce_Web" 거부 (ECR 이름 규칙)
    error_message = "Supply at least one ECR repository name using lowercase letters, digits, and . _ - / separators."
  }
}

variable "image_retention_count" {
  description = "How many tagged release images (tag prefix v) each repository keeps before the lifecycle policy expires the oldest."
  type        = number
  default     = 30 # 기본값: 30 (릴리스 태그 v* 30개 보존)
  nullable    = false

  validation {
    condition     = var.image_retention_count >= 1 && floor(var.image_retention_count) == var.image_retention_count # 예: 1 이상의 정수
    error_message = "image_retention_count must be a whole number of 1 or more."
  }
}

variable "build_tag_expire_days" {
  description = "Days after push before CI build tags (prefix build-) expire; release tags v* are kept by count instead."
  type        = number
  default     = 14 # 기본값: 14 (커밋 SHA 빌드 태그는 2주 뒤 삭제)
  nullable    = false

  validation {
    condition     = var.build_tag_expire_days >= 1 && floor(var.build_tag_expire_days) == var.build_tag_expire_days # 예: 1 이상의 정수
    error_message = "build_tag_expire_days must be a whole number of 1 or more."
  }
}

variable "untagged_expire_days" {
  description = "Days after push before untagged images (superseded layers, failed pushes) expire."
  type        = number
  default     = 7 # 기본값: 7 (태그 없는 이미지는 7일 뒤 삭제)
  nullable    = false

  validation {
    condition     = var.untagged_expire_days >= 1 && floor(var.untagged_expire_days) == var.untagged_expire_days # 예: 1 이상의 정수
    error_message = "untagged_expire_days must be a whole number of 1 or more."
  }
}

# Dev GitHub OIDC 연결과 Prod 코드 배치 가 만든 계정당 하나의 GitHub OIDC provider 입니다. 루트 모듈이 account-baseline State 의 github_oidc_provider_arn 을 넘깁니다.
variable "github_oidc_provider_arn" {
  description = "ARN of the account's GitHub Actions OIDC provider (account-baseline output github_oidc_provider_arn)."
  type        = string # 예: "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com"
  nullable    = false

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.github_oidc_provider_arn)) # 예: GitHub 발급자 URL 로 끝나는 provider ARN 만
    error_message = "github_oidc_provider_arn must be the token.actions.githubusercontent.com provider of this account."
  }
}

variable "github_app_repositories" {
  description = "GitHub owner ID plus owner/name and repository ID of the two application repositories whose workflows may assume the CI role (storefront and backend)."
  type = object({
    owner_id = string # 예: "201234567" (두 저장소를 가진 조직의 숫자 ID — gh api orgs/contract2whale-labs --jq .id)
    web = object({
      name = string # 예: "contract2whale-labs/commerce-web" (Next.js 스토어프런트 저장소)
      id   = string # 예: "1012345601" (gh api repos/contract2whale-labs/commerce-web --jq .id)
    })
    api = object({
      name = string # 예: "contract2whale-labs/commerce-api" (Medusa 백엔드 저장소)
      id   = string # 예: "1012345602" (gh api repos/contract2whale-labs/commerce-api --jq .id)
    })
  })
  nullable = false

  validation {
    condition     = alltrue([for repository in [var.github_app_repositories.web, var.github_app_repositories.api] : can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", repository.name))]) # 예: "owner/name" 형식만
    error_message = "Each application repository name must be owner/name."
  }

  validation {
    condition     = var.github_app_repositories.web.name != var.github_app_repositories.api.name && var.github_app_repositories.web.id != var.github_app_repositories.api.id # 예: 두 저장소가 서로 다른지 (같으면 sub 조건이 겹침)
    error_message = "The storefront and backend repositories must be different."
  }

  validation {
    condition     = alltrue([for id in [var.github_app_repositories.owner_id, var.github_app_repositories.web.id, var.github_app_repositories.api.id] : can(regex("^[1-9][0-9]*$", id))]) # 예: "201234567" 통과 / "contract2whale-labs" · "" 거부 (GitHub 의 숫자 ID)
    error_message = "owner_id and both repository ids must be the numeric GitHub IDs (gh api orgs/<owner> --jq .id, gh api repos/<owner>/<name> --jq .id)."
  }

  validation {
    condition     = split("/", var.github_app_repositories.web.name)[0] == split("/", var.github_app_repositories.api.name)[0] # 예: owner_id 가 하나이므로 두 저장소의 owner 가 같아야 함
    error_message = "Both application repositories must belong to the owner that owner_id identifies."
  }
}

# 서명 · 게시가 허용되는 Git branch 입니다. PR 브랜치는 빌드만 하고 이 Role 을 맡지 못합니다. 태그(refs/tags/…)와 와일드카드는 받지 않습니다 — 앱 저장소 작업 경계 의 Ruleset 은 branch 만 보호하므로, 태그를 허용하면 Write 권한자가 검토 없는 커밋에 태그를 붙여 KMS 서명을 받을 수 있습니다.
variable "github_release_refs" {
  description = "Git branch refs from which the application workflows may assume the CI role; tags and wildcards are rejected because only branches are protected by the ruleset."
  type        = list(string)
  default     = ["refs/heads/main"] # 기본값: main 브랜치만 (Ruleset 이 PR · 리뷰를 강제하는 branch)
  nullable    = false

  validation {
    condition     = length(var.github_release_refs) > 0 && alltrue([for ref in var.github_release_refs : can(regex("^refs/heads/[^*?]+$", ref))]) # 예: "refs/heads/main" 통과 / "main" · "refs/tags/v*" · "refs/heads/*" 거부
    error_message = "Each release ref must be a branch ref without wildcards (for example refs/heads/main); tag refs are not accepted."
  }
}

# Argo CD 가 읽는 선언된 상태(Desired State) 저장소(인프라 저장소)입니다. deploy key(읽기 전용)로 SSH 접속합니다.
variable "gitops_repository" {
  description = "GitHub owner/name of the repository that holds gitops/ (read by Argo CD over SSH with a deploy key)."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.gitops_repository)) # 예: "owner/name" 형식만
    error_message = "gitops_repository must be owner/name."
  }
}

# Argo CD Application 의 대상 네임스페이스(앱 네임스페이스와 수집 허용 이 만드는 앱 네임스페이스)입니다. AppProject destinations 와 Kyverno 정책 범위가 이 값을 씁니다.
variable "application_namespace" {
  description = "Tenant namespace that receives the gitops sync (created by the application-namespace chapter)."
  type        = string
  default     = "contract2whale-demo" # 기본값: "contract2whale-demo" (애플리케이션 데이터 앱 네임스페이스)
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.application_namespace)) # 예: DNS label 규칙
    error_message = "application_namespace must be a DNS label."
  }
}

# api.migration_service_account 는 스키마 변경 계정 시크릿(migration)만 읽는 Pod Identity 연결의 ServiceAccount 이름으로, 애플리케이션 데이터 data 모듈이 계약(service_accounts.migration)으로 받아 tenant-pod-identity 가 연결을 만듭니다. Argo CD PreSync 마이그레이션 Job 은 ESO 가 만든 Secret 을 envFrom 으로 읽어 AWS 를 부르지 않으며 delivery-migration ServiceAccount 로 실행됩니다.
variable "application_workloads" {
  description = "The two commerce workloads the gitops overlays deploy: storefront (web) and Medusa backend (api) with the ServiceAccount name of its migration-secret Pod Identity association."
  type = object({
    web = object({
      deployment = string # 예: "commerce-web" (Rollout · Service 이름 = 이미지 이름)
      container  = string # 예: "commerce-web" (Rollout 컨테이너 이름)
    })
    api = object({
      deployment                = string # 예: "commerce-api" (애플리케이션 데이터 data 모듈의 비밀 접두사 contract2whale/<env>/commerce-api · 미디어 접두사 media/<env>/commerce-api/)
      container                 = string # 예: "commerce-api"
      migration_service_account = string # 예: "delivery-migration" (migration 시크릿 읽기 Pod Identity 연결 대상)
    })
  })
  default = {
    web = { deployment = "commerce-web", container = "commerce-web" }                                                   # 기본값: 스토어프런트 (Next.js 3000)
    api = { deployment = "commerce-api", container = "commerce-api", migration_service_account = "delivery-migration" } # 기본값: 백엔드 (Medusa 9000)
  }
  nullable = false

  validation {
    condition = alltrue([
      for name in [var.application_workloads.web.deployment, var.application_workloads.web.container, var.application_workloads.api.deployment, var.application_workloads.api.container, var.application_workloads.api.migration_service_account] :
      can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", name)) # 예: DNS label 규칙
    ])
    error_message = "Workload, container and migration service account names must be DNS labels."
  }

  validation {
    condition     = var.application_workloads.web.deployment != var.application_workloads.api.deployment # 예: 두 워크로드 이름이 서로 다른지 (같으면 overlay 경로 · 이미지 이름이 겹침)
    error_message = "The storefront and backend deployments must have different names."
  }
}

variable "argocd_namespace" {
  description = "Namespace where Argo CD and its SecretStore and ExternalSecret resources run."
  type        = string
  default     = "argocd" # 기본값: "argocd" (Helm release · Pod Identity 연결의 namespace)
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.argocd_namespace)) # 예: DNS label 규칙
    error_message = "argocd_namespace must be a DNS label."
  }
}

variable "kyverno_namespace" {
  description = "Namespace where Kyverno runs (Pod Identity association namespace)."
  type        = string
  default     = "kyverno" # 기본값: "kyverno"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.kyverno_namespace)) # 예: DNS label 규칙
    error_message = "kyverno_namespace must be a DNS label."
  }
}

variable "permissions_boundary_arn" {
  description = "Optional existing customer-managed permissions boundary attached to the CI role and the Pod Identity roles."
  type        = string
  default     = null # 기본값: null (boundary 를 붙이지 않음)

  validation {
    condition     = var.permissions_boundary_arn == null ? true : can(regex("^arn:aws:iam::[0-9]{12}:policy/[A-Za-z0-9_+=,.@/-]+$", var.permissions_boundary_arn)) # 예: 고객 관리형 정책 ARN
    error_message = "Supply an existing customer-managed IAM policy ARN or null."
  }
}

# 운영 도구(platform/operations)의 External Secrets controller Role 입니다. 클러스터 전체 컨트롤러 하나가 SecretStore 마다 다른 Role 을 맡는(assume-role chaining) 구조라, delivery 의 비밀 읽기 Role 은 이 Role 만 신뢰합니다.
variable "external_secrets_role_arn" {
  description = "IAM role of the cluster-wide External Secrets controller (operations root output external_secrets_role_arn); trusted by the delivery secrets role."
  type        = string # 예: "arn:aws:iam::111111111111:role/contract2whale-dev-eks-external-secrets"
  nullable    = false

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9_+=,.@/-]+$", var.external_secrets_role_arn)) # 예: IAM Role ARN 형식
    error_message = "external_secrets_role_arn must be an IAM role ARN."
  }
}

# 서비스 진입 경로(platform/app-auth)의 Cognito user pool issuer 입니다. Argo CD SSO 앱 클라이언트를 같은 pool 에 만들고, Argo CD 의 oidc.config.issuer 로 씁니다.
variable "cognito_issuer" {
  description = "Cognito user pool issuer URL (app-auth root output ui_auth.issuer); the Argo CD OIDC client is created in that pool."
  type        = string # 예: "https://cognito-idp.ap-northeast-2.amazonaws.com/ap-northeast-2_AbCdEfGhI"
  nullable    = false

  validation {
    condition     = can(regex("^https://cognito-idp\\.[a-z0-9-]+\\.amazonaws\\.com/[a-z]{2}-[a-z]+-[0-9]_[A-Za-z0-9]+$", var.cognito_issuer)) # 예: issuer 뒤가 user pool ID
    error_message = "cognito_issuer must be https://cognito-idp.<region>.amazonaws.com/<user pool id>."
  }
}

# Argo CD 로그인 콜백입니다. Dev 는 SSM 세션 + kubectl port-forward 안쪽(localhost)이라 http 로컬 주소이고, argocd CLI 의 브라우저 로그인은 8085 를 씁니다. Prod(운영 환경)는 HTTPRoute 의 https 주소로 바꿉니다.
variable "argocd_oidc_callback_urls" {
  description = "Allowed OAuth callback URLs of the Argo CD OIDC client (UI port-forward and argocd CLI login)."
  type        = list(string)
  default     = ["http://localhost:8080/auth/callback", "http://localhost:8085/auth/callback"] # 기본값: port-forward 8080 · CLI 8085
  nullable    = false

  validation {
    condition     = length(var.argocd_oidc_callback_urls) > 0 && alltrue([for url in var.argocd_oidc_callback_urls : can(regex("^https?://[^/]+/auth/callback$", url))]) # 예: /auth/callback 으로 끝나는 URL
    error_message = "Each callback URL must end with /auth/callback."
  }
}

variable "previous_signing_key_id" {
  description = "Key ID of the previous cosign signing key during rotation (creates alias/delivery-signing-previous); null when not rotating."
  type        = string
  default     = null # 기본값: null (회전 중이 아님)

  validation {
    condition     = var.previous_signing_key_id == null ? true : can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.previous_signing_key_id)) # 예: KMS 키 ID(UUID)
    error_message = "previous_signing_key_id must be a KMS key ID (UUID) or null."
  }
}

# ECR 레지스트리 스캔 설정은 계정 · 리전에 하나뿐인 싱글턴입니다 (registry-level). ENHANCED(Inspector v2) + CONTINUOUS_SCAN 이면 저장된 이미지에 새 CVE 가 공개될 때 자동 재스캔합니다 (Day-2 탐지). 다른 팀이 이미 관리하면 false.
variable "manage_registry_scanning" {
  description = "Manage the account-level ECR registry scanning configuration (ENHANCED, continuous scan of all repositories in the account and region); set false when another root owns it."
  type        = bool
  default     = true # 기본값: true (이 계정에서 ECR 스캔 설정을 이 모듈이 관리)
  nullable    = false
}

variable "argocd_oidc_client_id" {
  description = "Non-secret ID produced by the protected Cognito client operation."
  type        = string
  default     = null
  nullable    = true
}
