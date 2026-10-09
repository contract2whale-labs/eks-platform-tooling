# variables.tf — modules/account-integrations (dev · prod 루트 모듈이 공유하는 모듈)

variable "expected_account_id" {
  description = "이 연동 리소스를 만드는 AWS 계정의 12자리 번호입니다."
  type        = string # 예: string (앞자리 0 이 사라지지 않도록 문자열)
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id)) # 예: "111111111111" 통과, "1111-1111" 거부
    error_message = "사용자 AWS 계정의 12자리 번호가 필요합니다."
  }
}

variable "region" {
  description = "연동 리소스를 만드는 리전입니다. 앞 구성 계약의 region 과 같아야 합니다 (main.tf 의 contract 가 대조)."
  type        = string
  default     = "ap-northeast-2" # 기본값: "ap-northeast-2" (서울 리전)
  nullable    = false
}

variable "operations_contract" {
  description = "운영 기반 구성(운영 기반 루트 모듈과 계약 platform/operations)의 operations_contract 출력 7항목입니다. root State 전체가 아니라 공개 계약만 받습니다."
  # 예: { account_id = "111111111111", cluster_name = "contract2whale-dev-eks", region = "ap-northeast-2", platform_log_group_name = "/platform/contract2whale-dev-eks/application", velero_bucket_name = "velero-…", velero_bucket_arn = "arn:aws:s3:::velero-…", alerts_topic_arn = "arn:aws:sns:…" }
  type = object({
    account_id              = string # 예: "111111111111" (운영 기반 구성을 적용한 계정)
    cluster_name            = string # 예: "contract2whale-dev-eks" (버킷 · 주제 · 알람 이름의 접두사)
    region                  = string # 예: "ap-northeast-2"
    platform_log_group_name = string # 예: "/platform/contract2whale-dev-eks/application" (로그량 알람의 dimension)
    velero_bucket_name      = string # 예: "velero-contract2whale-dev-eks-111111111111-ap-northeast-2" (재선언하지 않음)
    velero_bucket_arn       = string # 예: "arn:aws:s3:::velero-contract2whale-dev-eks-111111111111-ap-northeast-2" (계약 출력 backup_bucket_arn 으로 전달)
    alerts_topic_arn        = string # 예: "arn:aws:sns:ap-northeast-2:111111111111:contract2whale-dev-alerts" 또는 null (알림 루트 모듈과 설치 검사 이전)
  })
  nullable = false
}

variable "network_logs_contract" {
  description = "네트워크 구성(관련 구성 network/vpc)의 network_logs_bucket_name · network_logs_bucket_arn 출력을 묶은 계약입니다."
  # 예: { bucket_name = "cp-dev-network-logs-111111111111-ap-northeast-2", bucket_arn = "arn:aws:s3:::cp-dev-network-logs-111111111111-ap-northeast-2" }
  type = object({
    bucket_name = string # 예: "cp-dev-network-logs-111111111111-ap-northeast-2" (flow/ · dns/ 로그가 쌓이는 버킷)
    bucket_arn  = string # 예: "arn:aws:s3:::cp-dev-network-logs-111111111111-ap-northeast-2"
  })
  nullable = false
}

variable "log_bytes_per_five_minutes_threshold" {
  description = "플랫폼 로그 그룹의 5분 수집 바이트(IncomingBytes 합계) 경고 임계값입니다. 비용 예측값이나 유실 탐지 임계값이 아닙니다."
  type        = number
  default     = 52428800 # 기본값: 52428800 (50 MiB / 5분)
  nullable    = false

  validation {
    condition     = var.log_bytes_per_five_minutes_threshold > 0 # 예: 52428800 통과, 0 거부
    error_message = "임계값은 0보다 커야 합니다."
  }
}

variable "enable_external_log_consumer" {
  description = "실제 외부 소비자가 있을 때만 true 로 바꿉니다. true 면 SQS 큐 · 큐 정책 · 버킷 알림 · cross-account Role · Role 정책 · 큐 적체 알람이 생깁니다."
  type        = bool
  default     = false # 기본값: false (선택 기능을 끈 상태 — 리소스 0개)
  nullable    = false
}

variable "external_log_consumer" {
  description = "외부 소비자의 실제 IAM Role ARN 과 합의된 External ID 입니다. 예시 숫자로 켜지 않습니다."
  # 예: { principal_role_arn = "arn:aws:iam::222222222222:role/log-consumer", external_id = "AGREED-EXTERNAL-ID-0001" }
  type = object({
    principal_role_arn = string # 예: "arn:aws:iam::222222222222:role/log-consumer" (상대 계정의 Role)
    external_id        = string # 예: "AGREED-EXTERNAL-ID-0001" (16자 이상, 상대와 합의한 값)
  })
  default   = null # 기본값: null (값이 없음)
  sensitive = true # 예: true (plan · output 화면에서 값을 가림)

  validation {
    # 예: null 이면 통과, 값이 있으면 Role ARN 형식과 16자 이상의 External ID 를 요구합니다
    condition     = var.external_log_consumer == null ? true : can(regex("^arn:aws:iam::[0-9]{12}:role/.+$", var.external_log_consumer.principal_role_arn)) && length(var.external_log_consumer.external_id) >= 16
    error_message = "유효한 실제 IAM role ARN과 16자 이상의 External ID가 필요합니다."
  }
}

variable "notification_email_addresses" {
  description = "SNS 확인 메일을 실제로 받을 사용자 주소입니다. 기본 빈 집합이며 주소를 넣으면 구독 요청(확인 메일)이 만들어집니다."
  type        = set(string)
  default     = [] # 기본값: [] (구독을 만들지 않음)
  nullable    = false

  validation {
    # 예: "ops-alerts@example.com" 통과, "ops-alerts" 거부
    condition     = alltrue([for email in var.notification_email_addresses : can(regex("^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$", email))])
    error_message = "이메일 주소 형식을 확인하세요."
  }
}
