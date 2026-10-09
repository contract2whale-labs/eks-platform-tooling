# variables.tf — account-integrations 루트 모듈 (dev · prod 공통 코드)
# 대신 state_bucket_name 과 environment 를 받습니다. 원본의 "cat modules/account-integrations/variables.tf > variables.tf" 복사는 쓰지 않습니다 (내용이 다름).

variable "expected_account_id" {
  description = "AWS account that owns the platform and receives the integration resources; 12 digits."
  type        = string # 예: string (앞자리 0 이 사라지지 않도록 문자열)
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id)) # 예: "111111111111" 통과
    error_message = "Account ID must be 12 digits."
  }
}

# 클러스터 · 로그 버킷이 서울 리전에 있으므로 리전도 고정합니다. 모듈은 operations_contract.region 이 같은 값인지 따로 검사합니다.
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

# 앞 루트 모듈(network/vpc · platform/operations) 의 State 가 있는 버킷입니다. backend.hcl 의 bucket 과 같은 값입니다.
variable "state_bucket_name" {
  description = "S3 bucket holding the network/vpc and platform/operations states read by terraform_remote_state."
  type        = string # 예: "company-dev-tfstate-111111111111" (work/lab.env 의 DEV_STATE_BUCKET)
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name)) # 예: S3 버킷 이름 규칙
    error_message = "state_bucket_name must be a valid S3 bucket name."
  }
}

variable "log_bytes_per_five_minutes_threshold" {
  description = "IncomingBytes sum per 5 minutes that raises the platform log volume alarm (module validation requires > 0)."
  type        = number
  default     = 52428800 # 기본값: 52428800 (50 MiB / 5분)
  nullable    = false
}

variable "enable_external_log_consumer" {
  description = "Create the SQS queue, bucket notification, cross-account role and queue-age alarm only when a real external consumer exists."
  type        = bool
  default     = false # 기본값: false (선택 기능 꺼짐 — 리소스 0개)
  nullable    = false
}

# 값은 terraform.tfvars 가 아니라 -var-file 또는 TF_VAR_external_log_consumer 로 공급합니다 (비밀 입력).
variable "external_log_consumer" {
  description = "Real IAM role ARN of the external consumer and the agreed External ID (16+ characters); null unless the consumer is enabled."
  type = object({
    principal_role_arn = string # 예: "arn:aws:iam::222222222222:role/log-consumer"
    external_id        = string # 예: "AGREED-EXTERNAL-ID-0001"
  })
  default   = null # 기본값: null (모듈 validation 이 형식을 검사)
  sensitive = true # 예: true (plan · output 화면에서 값을 가림)
}

variable "notification_email_addresses" {
  description = "Email addresses that receive the SNS confirmation mail; empty set creates no subscription."
  type        = set(string)
  default     = [] # 기본값: [] (구독 0개; 모듈 validation 이 형식을 검사)
  nullable    = false
}
