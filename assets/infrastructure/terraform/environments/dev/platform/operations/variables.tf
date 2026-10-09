# variables.tf — platform/operations 루트 모듈 (dev · prod 공통 코드)
# 대신 state_bucket_name 을 받습니다. 원본의 "cat modules/operations/variables.tf > variables.tf" 복사는 쓰지 않습니다 (내용이 다름).

variable "expected_account_id" {
  description = "AWS account that owns the cluster and the operations resources; 12 digits."
  type        = string # 예: string (앞자리 0 이 사라지지 않도록 문자열)
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id)) # 예: "111111111111" 통과
    error_message = "Account ID must be 12 digits."
  }
}

# 클러스터가 서울 리전에 있으므로 리전도 고정합니다. 모듈은 cluster_contract.region 이 같은 값인지 따로 검사합니다.
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
  description = "Explicit environment name, 2-20 lowercase letters, digits or hyphens."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,19}$", var.environment)) # 예: "dev" 통과 / "Dev" 거부
    error_message = "Use a 2-20 character lowercase environment name."
  }
}

# 앞 루트 모듈(eks)의 State가 있는 버킷입니다. backend.hcl 의 bucket 과 같은 값입니다.
variable "state_bucket_name" {
  description = "S3 bucket holding the eks state read by terraform_remote_state."
  type        = string # 예: "company-dev-tfstate-111111111111" (work/lab.env 의 DEV_STATE_BUCKET)
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name)) # 예: S3 버킷 이름 규칙
    error_message = "state_bucket_name must be a valid S3 bucket name."
  }
}

# 이 환경이 운영하는 도구 목록입니다. 모듈 기본값은 autoscaler 하나이지만 dev 루트 모듈은 네 도구를 처음부터 모두 켭니다 (D5; 도구별 STEP 0 "AWS 자원 추가" 는 없음).
variable "enabled_services" {
  description = "Operations services whose AWS resources this root declares."
  type        = set(string)
  default     = ["autoscaler", "external_secrets", "fluent_bit", "velero"] # 기본값: 네 도구 모두 (모듈 validation 이 이름을 검사)
  nullable    = false
}

variable "application_log_retention_days" {
  description = "Retention in days for the platform container log group (module validation restricts the allowed values)."
  type        = number
  default     = 90 # 기본값: 90 (모듈 허용 목록 중 하나)
  nullable    = false
}

# 알림 루트의 생성보다 앞서 적용될 수 있으므로 공개 ARN을 선택 입력으로 받습니다.
variable "alerts_topic_arn" {
  description = "Reviewed public SNS topic ARN; null until the alerting root exists."
  type        = string
  default     = null
  nullable    = true
  validation {
    condition     = var.alerts_topic_arn == null ? true : can(regex("^arn:aws:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$", var.alerts_topic_arn))
    error_message = "alerts_topic_arn must be null or an SNS topic ARN."
  }
}
