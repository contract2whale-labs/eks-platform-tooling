# variables.tf — account-baseline 루트 모듈 (dev · prod 공통 코드)
# 계정 ID · 버킷 · 신뢰 역할은 실행자가 입력합니다. 기본값으로 임의 계정에 적용되지 않게 합니다.

variable "expected_account_id" {
  description = "User-owned AWS account. This root does not create an account."
  type        = string # 예: string (계정 ID 는 앞자리 0 이 있을 수 있어 숫자가 아닌 문자열로 받음)
  nullable    = false  # 예: false (null 입력 차단)

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id)) # 예: "111111111111" 통과 / "1111-1111-1111" 거부
    error_message = "expected_account_id must contain exactly 12 digits."
  }
}

variable "region" {
  description = "AWS commercial-region code. IAM and Route 53 are global services."
  type        = string
  default     = "ap-northeast-2" # 기본값: "ap-northeast-2" (서울 리전)
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", var.region)) # 예: "ap-northeast-2" 통과 / "cn-north-1" 도 형식은 통과하나 파티션이 다름
    error_message = "Use a commercial AWS region code such as ap-northeast-2."
  }
}

# workspace 에서 환경명을 추론하지 않습니다. 같은 값이 역할 이름과 태그로 전달됩니다.
variable "environment" {
  description = "Environment name used in IAM resource names; account isolation is in the backend bucket."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,19}$", var.environment)) # 예: "dev" 통과 / "Dev" 거부 / "d" 거부 (2~20자)
    error_message = "Use 2-20 lowercase letters, digits or hyphens, starting with a letter."
  }
}

# backend.hcl 의 bucket 과 같은 값입니다. remote_state 조회와 IAM 정책의 버킷 리소스가 이 이름을 씁니다.
variable "state_bucket_name" {
  description = "Existing bucket in the same commercial AWS account; the same value as bucket in backend.hcl."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name)) # 예: "company-dev-tfstate-111111111111" 통과 / "arn:aws:s3:::..." 거부
    error_message = "Supply the existing bucket name, not an ARN or URL."
  }
}

# 신뢰 주체는 02-AWS-SETUP 13절에서 확인한 같은 계정의 영구 IAM 역할 ARN 입니다 (work/lab.env 의 *_OPERATOR_ROLE_ARN).
variable "trusted_principal_arns" {
  description = "Exact existing IAM role ARNs allowed to assume the backend role; never STS session ARNs."
  type        = set(string) # 예: set(string) (중복 없는 집합; 순서가 정책에 영향을 주지 않음)
  nullable    = false       # 예: false (null 이면 length() 평가가 실패함)

  validation {
    condition = (
      length(var.trusted_principal_arns) > 0 &&  # 예: 1 이상 (신뢰 주체가 없으면 아무도 맡을 수 없음)
      length(var.trusted_principal_arns) <= 4 && # 예: 4 이하 (경로가 관리 없이 늘어나는 것 방지)
      alltrue([
        for arn in var.trusted_principal_arns :
        length(arn) <= 256 &&                                                 # 예: 256 (이 과정에서 정한 ARN 입력 상한)
        can(regex("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9_+=,.@/-]+$", arn)) # 예: "arn:aws:iam::111111111111:role/PlatformOperator" 통과 / sts assumed-role 거부
      ])
    )
    error_message = "Supply 1-4 exact existing commercial-partition IAM role ARNs; root, user, wildcard and assumed-role session ARNs are rejected."
  }
}

# 후속 루트 모듈의 정확한 State key 를 추가하는 입력입니다. * 로 넓히지 않습니다.
variable "additional_state_object_keys" {
  description = "Exact additional state keys this backend role may read and write; .tflock is derived automatically."
  type        = set(string)
  default     = [] # 기본값: [] (locals.tf 의 확정 key 3개만 허용)
  nullable    = false

  validation {
    condition = length(var.additional_state_object_keys) <= 32 && alltrue([ # 예: 정확한 key 32개 상한
      for key in var.additional_state_object_keys :
      length(key) <= 160 &&                                                     # 예: 160자 상한
      can(regex("^[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*/terraform[.]tfstate$", key)) # 예: "network/extensions/terraform.tfstate" 통과 / "*/terraform.tfstate" 거부
    ])
    error_message = "Use at most 32 exact relative paths ending /terraform.tfstate; wildcards and .tflock suffixes are not accepted."
  }
}

variable "permissions_boundary_arn" {
  description = "Optional existing customer-managed permissions boundary; it restricts, but does not grant, permissions."
  type        = string
  default     = null # 기본값: null (boundary 를 붙이지 않음)

  validation {
    condition = var.permissions_boundary_arn == null ? true : can(regex(
      "^arn:aws:iam::[0-9]{12}:policy/[A-Za-z0-9_+=,.@/-]+$", var.permissions_boundary_arn # 예: "arn:aws:iam::111111111111:policy/PlatformBoundary"
    ))
    error_message = "Supply an existing customer-managed IAM policy ARN or null."
  }
}

# 계정 전역 단일 설정이므로 기본은 관리하지 않습니다. 기존 소유권을 인수하지 않습니다.
variable "manage_iam_password_policy" {
  description = "Opt in only if this root owns the singleton account IAM-user password policy. Does not configure IAM Identity Center."
  type        = bool  # 예: bool (타입 자체가 값 범위를 제한하므로 validation 불필요)
  default     = false # 기본값: false (계정 전역 리소스이므로 기본은 관리하지 않음)
  nullable    = false
}
