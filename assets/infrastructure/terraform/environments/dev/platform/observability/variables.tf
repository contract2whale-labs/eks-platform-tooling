# variables.tf — platform/observability 루트 모듈 (dev · prod 공통 코드)

variable "expected_account_id" {
  description = "AWS account that owns the cluster and the signal buckets; 12 digits."
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

# main.tf 의 environment_boundary 가 이 디렉터리에서는 "dev" 만 허용합니다.
variable "environment" {
  description = "Explicit environment name; this directory accepts dev only."
  type        = string
  nullable    = false

  validation {
    condition     = contains(["dev", "prod"], var.environment) # 예: "dev" 통과 / "stage" 거부 (모듈과 같은 검사)
    error_message = "environment must be dev or prod."
  }
}

# 앞 루트 모듈 4곳(eks · platform/operations · network/vpc · account-baseline)의 State 가 있는 버킷입니다. backend.hcl 의 bucket 과 같은 값입니다.
variable "state_bucket_name" {
  description = "S3 bucket holding the eks, platform/operations, network/vpc and account-baseline states read by terraform_remote_state."
  type        = string # 예: "company-dev-tfstate-111111111111" (work/lab.env 의 DEV_STATE_BUCKET)
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name)) # 예: S3 버킷 이름 규칙
    error_message = "state_bucket_name must be a valid S3 bucket name."
  }
}

variable "trusted_principal_arns" {
  description = "Exact existing IAM role ARNs allowed to assume the three storage roles for inspection; never STS session ARNs."
  type        = set(string) # 예: set(string)
  nullable    = false

  validation {
    condition = (
      length(var.trusted_principal_arns) > 0 &&  # 예: 1 이상
      length(var.trusted_principal_arns) <= 4 && # 예: 4 이하
      alltrue([
        for arn in var.trusted_principal_arns :
        can(regex("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9_+=,.@/-]+$", arn)) # 예: IAM 역할 ARN 만 통과
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
    condition     = var.permissions_boundary_arn == null ? true : can(regex("^arn:aws:iam::[0-9]{12}:policy/[A-Za-z0-9_+=,.@/-]+$", var.permissions_boundary_arn)) # 예: 고객 관리형 정책 ARN
    error_message = "Supply an existing customer-managed IAM policy ARN or null."
  }
}

# 저장소 수명 주기의 기준일입니다. dev 는 traces 를 40 으로 둡니다 (후반부 Tempo 보존 30일보다 길게).
variable "signal_retention_days" {
  description = "Backstop expiration days per signal bucket; must exceed each component's own retention."
  type        = map(number)
  default     = { metrics = 400, logs = 90, traces = 40 } # 기본값: 지표 400 · 로그 90 · 트레이스 40 (모듈 기본 30 을 dev 에서 40 으로)
  nullable    = false

  validation {
    condition     = toset(keys(var.signal_retention_days)) == toset(["metrics", "logs", "traces"]) && alltrue([for days in values(var.signal_retention_days) : days >= 1 && floor(days) == days]) # 예: 필드 계약 · 양의 정수
    error_message = "signal_retention_days needs the keys metrics, logs and traces with positive whole-day values."
  }
}

# 아래 세 값은 계약 필드에만 쓰입니다. 관리형 큐 전환 구성(메시지 큐 전환)이 앞의 둘을 바꿉니다.
variable "active_trace_backend" {
  description = "Which message queue the trace pipeline uses now: self-managed or managed."
  type        = string
  default     = "self-managed" # 기본값: "self-managed" (클러스터 안에 직접 세운 브로커)
  nullable    = false

  validation {
    condition     = contains(["self-managed", "managed"], var.active_trace_backend) # 예: 두 값만
    error_message = "active_trace_backend must be self-managed or managed."
  }
}

variable "storage_epoch" {
  description = "Trace backend transition generation."
  type        = number
  default     = 1 # 기본값: 1 (전환 전의 초기 세대 번호)
  nullable    = false

  validation {
    condition     = var.storage_epoch >= 1 && floor(var.storage_epoch) == var.storage_epoch # 예: 1 이상의 정수
    error_message = "storage_epoch must be a whole number of 1 or more."
  }
}

variable "policy_version" {
  description = "Contract rule version."
  type        = number
  default     = 1 # 기본값: 1 (첫 버전)
  nullable    = false

  validation {
    condition     = var.policy_version >= 1 && floor(var.policy_version) == var.policy_version # 예: 1 이상의 정수
    error_message = "policy_version must be a whole number of 1 or more."
  }
}

variable "additional_bucket_names" {
  description = "Other buckets of this account that must stay reachable through the S3 gateway endpoint (for example the application media bucket)."
  type        = list(string) # 예: ["cp-dev-app-exports-111111111111-ap-northeast-2"]
  default     = []           # 기본값: []
  nullable    = false

  validation {
    condition     = alltrue([for name in var.additional_bucket_names : can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", name))]) # 예: S3 버킷 이름 규칙
    error_message = "additional_bucket_names must contain valid S3 bucket names."
  }
}
