# variables.tf — delivery 루트 모듈 (dev · prod 공통 코드)
# 대신 state_bucket_name 을 받습니다. 이미지 리포지토리 이름 · 보존 개수 · 네임스페이스 · 두 앱 좌표(commerce-web · commerce-api)는 모듈 기본값(과정 값)을 씁니다.

variable "expected_account_id" {
  description = "AWS account that owns the cluster, the registry and the signing key; 12 digits."
  type        = string # 예: string (앞자리 0 이 사라지지 않도록 문자열)
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id)) # 예: "111111111111" 통과
    error_message = "Account ID must be 12 digits."
  }
}

variable "region" {
  description = "AWS region for this root; only ap-northeast-2 is supported."
  type        = string
  default     = "ap-northeast-2" # 기본값: "ap-northeast-2"
  nullable    = false

  validation {
    condition     = var.region == "ap-northeast-2" # 예: 단일 값 비교
    error_message = "This root supports ap-northeast-2 only."
  }
}

# main.tf 의 environment_boundary 가 이 디렉터리에서는 "dev" 만 허용합니다 (prod 는 prod/delivery).
variable "environment" {
  description = "Explicit environment name: dev or prod (selects the CI role name cp-<env>-ci-delivery and the gitops overlay path)."
  type        = string
  nullable    = false

  validation {
    condition     = contains(["dev", "prod"], var.environment) # 예: "dev" 통과 / "staging" 거부
    error_message = "environment must be dev or prod."
  }
}

# 앞 루트 모듈(eks · account-baseline) 의 State 가 있는 버킷입니다. backend.hcl 의 bucket 과 같은 값입니다.
variable "state_bucket_name" {
  description = "S3 bucket holding the eks and account-baseline states read by terraform_remote_state."
  type        = string # 예: "company-dev-tfstate-111111111111" (work/lab.env 의 DEV_STATE_BUCKET)
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name)) # 예: S3 버킷 이름 규칙
    error_message = "state_bucket_name must be a valid S3 bucket name."
  }
}

variable "github_app_repositories" {
  description = "GitHub owner ID plus owner/name and repository ID of the two application repositories (storefront and backend) whose main branch may assume the CI role."
  type = object({
    owner_id = string # 예: "201234567" (gh api orgs/contract2whale-labs --jq .id)
    web = object({
      name = string # 예: "contract2whale-labs/commerce-web" (Next.js 스토어프런트)
      id   = string # 예: "1012345601" (gh api repos/contract2whale-labs/commerce-web --jq .id)
    })
    api = object({
      name = string # 예: "contract2whale-labs/commerce-api" (Medusa 백엔드)
      id   = string # 예: "1012345602" (gh api repos/contract2whale-labs/commerce-api --jq .id)
    })
  })
  nullable = false

  validation {
    condition     = alltrue([for repository in [var.github_app_repositories.web, var.github_app_repositories.api] : can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", repository.name))]) # 예: "owner/name" 형식만 (ID 형식 · 같은 owner 검사는 모듈 validation)
    error_message = "Each application repository name must be owner/name."
  }
}

variable "gitops_repository" {
  description = "GitHub owner/name of the repository that holds gitops/ (this infrastructure repository; read by Argo CD with a deploy key)."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.gitops_repository)) # 예: "owner/name" 형식만
    error_message = "gitops_repository must be owner/name."
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

# 키 회전 중에만 씁니다 (증적과 복구 런북): 이전 서명 키의 ID 를 넣으면 모듈이 alias/delivery-signing-previous 를 만들고 Kyverno 가 두 키를 병행 신뢰합니다. 재서명이 끝나면 null 로 되돌립니다.
variable "previous_signing_key_id" {
  description = "Key ID of the previous cosign signing key during rotation (creates alias/delivery-signing-previous); null when not rotating."
  type        = string
  default     = null # 기본값: null (회전 중이 아님)

  validation {
    condition     = var.previous_signing_key_id == null ? true : can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", var.previous_signing_key_id)) # 예: KMS 키 ID(UUID)
    error_message = "previous_signing_key_id must be a KMS key ID (UUID) or null."
  }
}

variable "argocd_oidc_client_id" {
  description = "Non-secret ID produced by the protected Cognito client operation."
  type        = string
  default     = null
  nullable    = true
}
