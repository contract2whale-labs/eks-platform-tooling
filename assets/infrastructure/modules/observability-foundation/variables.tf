# variables.tf — modules/observability-foundation (dev · prod 루트 모듈이 공유하는 모듈)

variable "expected_account_id" {
  description = "AWS account that owns the cluster and the signal buckets; 12 digits."
  type        = string # 예: string (앞자리 0 이 사라지지 않도록 문자열)
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id)) # 예: "111111111111" 통과 / "1111" 거부
    error_message = "expected_account_id must contain exactly 12 digits."
  }
}

variable "region" {
  description = "Region of the cluster and the signal buckets; only ap-northeast-2 is supported."
  type        = string
  default     = "ap-northeast-2" # 기본값: "ap-northeast-2" (서울 리전)
  nullable    = false

  validation {
    condition     = var.region == "ap-northeast-2" # 예: 단일 값 비교 (앞 챕터 모듈과 같은 고정)
    error_message = "This module supports ap-northeast-2 only."
  }
}

# 저장소 이름 · 객체 접두사 · 역할 이름에 함께 들어갑니다. workspace 로 환경을 나누지 않습니다.
variable "environment" {
  description = "Environment name used in bucket names, object prefixes and role names; dev or prod."
  type        = string # 예: "dev" (dev 루트 모듈) / "prod" (prod 루트 모듈)
  nullable    = false

  validation {
    condition     = contains(["dev", "prod"], var.environment) # 예: "dev" 통과 / "stage" 거부
    error_message = "environment must be dev or prod."
  }
}

variable "cluster_contract" {
  description = "Four fields of the upstream cluster contract: name, arn, region and kubernetes_version."
  type = object({
    name               = string # 예: "contract2whale-dev-eks"
    arn                = string # 예: "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
    region             = string # 예: "ap-northeast-2"
    kubernetes_version = string # 예: "1.36"
  })
  nullable = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,98}[a-z0-9]$", var.cluster_contract.name)) # 예: "contract2whale-dev-eks"(22자) 통과 (소문자 DNS 형식 3~100자 — EKS 클러스터 이름 한도)
    error_message = "cluster_contract.name must be a lowercase DNS-style name of 3-100 characters."
  }

  validation {
    condition     = can(regex("^arn:aws:eks:[a-z0-9-]+:[0-9]{12}:cluster/[A-Za-z0-9_-]+$", var.cluster_contract.arn)) # 예: EKS 클러스터 ARN 형식만 통과
    error_message = "cluster_contract.arn must be an EKS cluster ARN."
  }
}

# 사람이 저장소 역할을 맡아 점검할 때 쓰는 영구 IAM 역할 ARN 입니다 (work/lab.env 의 DEV_OPERATOR_ROLE_ARN; 관련 구성 state-access-role 과 같은 규칙).
variable "trusted_principal_arns" {
  description = "Exact existing IAM role ARNs allowed to assume the three storage roles for inspection; never STS session ARNs."
  type        = set(string) # 예: set(string) (중복 없는 집합; 순서가 정책에 영향을 주지 않음)
  nullable    = false

  validation {
    condition = (
      length(var.trusted_principal_arns) > 0 &&  # 예: 1 이상
      length(var.trusted_principal_arns) <= 4 && # 예: 4 이하
      alltrue([
        for arn in var.trusted_principal_arns :
        can(regex("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9_+=,.@/-]+$", arn)) # 예: "arn:aws:iam::111111111111:role/PlatformOperator" 통과 / assumed-role 거부
      ])
    )
    error_message = "Supply 1-4 exact existing IAM role ARNs; root, user, wildcard and assumed-role session ARNs are rejected."
  }
}

variable "permissions_boundary_arn" {
  description = "Optional existing customer-managed permissions boundary attached to the three storage roles."
  type        = string
  default     = null # 기본값: null (boundary 를 붙이지 않음)

  validation {
    condition = var.permissions_boundary_arn == null ? true : can(regex(
      "^arn:aws:iam::[0-9]{12}:policy/[A-Za-z0-9_+=,.@/-]+$", var.permissions_boundary_arn # 예: "arn:aws:iam::111111111111:policy/PlatformBoundary"
    ))
    error_message = "Supply an existing customer-managed IAM policy ARN or null."
  }
}

# account-baseline State 의 state_object_keys 출력입니다. 이 루트 모듈의 key 가 그 목록에 있어야 저장소를 만듭니다 (providers.tf 의 계약 검사).
variable "allowed_state_keys" {
  description = "state_object_keys output of the account-baseline root; must contain this root's own state key."
  type        = list(string) # 예: ["account-baseline/terraform.tfstate", …, "platform/observability/terraform.tfstate"]
  nullable    = false

  validation {
    condition     = alltrue([for key in var.allowed_state_keys : can(regex("/terraform[.]tfstate$", key))]) # 예: 모든 항목이 terraform.tfstate 로 끝남
    error_message = "allowed_state_keys must contain state object keys ending in /terraform.tfstate."
  }
}
