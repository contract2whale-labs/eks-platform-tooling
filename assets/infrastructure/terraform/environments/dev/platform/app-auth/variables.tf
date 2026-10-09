# variables.tf — platform/app-auth 루트 모듈 (dev · prod 공통 코드)

variable "expected_account_id" {
  description = "AWS account that owns the user pool and the secret; 12 digits."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id)) # 예: "111111111111" 통과
    error_message = "Account ID must be 12 digits."
  }
}

variable "region" {
  description = "AWS region of the user pool; only ap-northeast-2 is supported."
  type        = string
  default     = "ap-northeast-2" # 기본값: "ap-northeast-2"
  nullable    = false

  validation {
    condition     = var.region == "ap-northeast-2" # 예: 단일 값 비교
    error_message = "This root supports ap-northeast-2 only."
  }
}

variable "environment" {
  description = "Explicit environment name, 2-20 lowercase letters, digits or hyphens."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,19}$", var.environment)) # 예: "dev" 통과 / "Dev" 거부
    error_message = "Use a 2-20 character lowercase environment name."
  }
}

# Cognito hosted UI 의 접두어입니다. 리전 안에서 유일해야 하므로 계정 번호를 넣습니다 (원본 course-<계정>-<환경>).
variable "domain_prefix" {
  description = "Cognito hosted UI domain prefix, unique per region (e.g. course-111111111111-dev); must not contain aws, amazon or cognito."
  type        = string # 예: "course-111111111111-dev"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$", var.domain_prefix)) && !can(regex("aws|amazon|cognito", var.domain_prefix)) # 예: 소문자 · 숫자 · 하이픈, 예약어 없음
    error_message = "domain_prefix must be 1-63 lowercase alphanumerics or hyphens and must not contain aws, amazon or cognito."
  }
}

# 브라우저가 로그인 뒤 돌아올 origin 입니다. callback 은 <ui_origin>/ui/callback, logout 은 <ui_origin>/ui/ 로 고정합니다.
variable "ui_origin" {
  description = "HTTPS origin of the UI as the browser sees it (port 8443 through the SSM tunnel, no port on a public hostname)."
  type        = string # 예: "https://dev.playdevops.click:8443"
  nullable    = false

  validation {
    condition     = can(regex("^https://[a-z0-9.-]+(:[0-9]{2,5})?$", var.ui_origin)) # 예: https + 호스트 + 선택적 포트, 경로 없음
    error_message = "ui_origin must be https://<host>[:port] without a path."
  }
}

variable "verifier_client_id" {
  description = "Non-secret client ID from the protected Cognito provisioning operation."
  type        = string
  default     = null
  nullable    = true
}
