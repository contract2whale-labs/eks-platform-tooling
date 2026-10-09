# variables.tf — modules/operations (dev · prod 루트 모듈이 공유하는 모듈)

variable "enabled_services" {
  description = "AWS 리소스를 선언할 운영 도구 목록입니다."
  type        = set(string)
  default     = ["autoscaler"] # 기본값: autoscaler 하나 (운영 기반 루트 모듈과 계약 루트 모듈은 네 도구를 모두 전달)

  validation {
    condition     = alltrue([for name in var.enabled_services : contains(["autoscaler", "external_secrets", "fluent_bit", "velero"], name)]) # 예: "karpenter" 거부
    error_message = "Select only the operations services built in this root."
  }
}

variable "expected_account_id" {
  description = "실습 리소스를 관리할 실제 AWS 계정 ID입니다."
  type        = string # 예: "111111111111"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id)) # 예: 숫자 12자리만 통과
    error_message = "12자리 AWS 계정 번호가 필요합니다."
  }
}

variable "region" {
  description = "운영 리소스를 만들 리전입니다. cluster_contract.region 과 같아야 합니다."
  type        = string
  default     = "ap-northeast-2" # 기본값: 서울 리전
}

variable "cluster_contract" {
  description = "EKS 루트 모듈의 cluster_contract 출력입니다. 아래 네 필드만 받고 나머지 필드는 타입 변환에서 제외됩니다."
  type = object({
    name               = string # 예: "contract2whale-dev-eks"
    arn                = string # 예: "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
    region             = string # 예: "ap-northeast-2"
    kubernetes_version = string # 예: "1.36"
  })

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,98}[a-z0-9]$", var.cluster_contract.name)) # 예: 소문자 DNS 형식 3~100자 (EKS 클러스터 이름 한도; 백업 버킷 이름 길이는 providers.tf 계약 검사)
    error_message = "클러스터 이름은 소문자 DNS 형식 3~100자여야 합니다."
  }
}

variable "node_group_autoscaling_group_names" {
  description = "EKS 루트 모듈이 출력한 관리형 노드 그룹의 ASG 이름 집합입니다. AWS 가 정한 이름이므로 추측해 입력하지 않습니다."
  type        = set(string) # 예: ["eks-contract2whale-dev-eks-system-0ac12345-..."] (운영 기반 루트 모듈과 계약 루트 모듈이 eks State 의 node_contract.autoscaling_group_names 를 전달)

  validation {
    condition     = length(var.node_group_autoscaling_group_names) > 0 && alltrue([for n in var.node_group_autoscaling_group_names : length(n) > 0]) # 예: [] 거부
    error_message = "최소 하나의 실제 ASG 이름이 필요합니다."
  }
}

variable "application_log_retention_days" {
  description = "플랫폼 컨테이너 로그 그룹의 보존 일수입니다. 앱 로그의 보존 일수가 아닙니다."
  type        = number
  default     = 90 # 기본값: 90일

  validation {
    condition     = contains([7, 14, 30, 60, 90, 120, 150, 180, 365], var.application_log_retention_days) # 예: 90 통과 / 45 거부
    error_message = "문서에서 지원하는 CloudWatch 보존 일수 중 하나를 선택하세요."
  }
}
