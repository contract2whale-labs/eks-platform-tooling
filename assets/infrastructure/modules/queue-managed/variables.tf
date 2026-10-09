# variables.tf — modules/queue-managed (dev · prod 루트 모듈이 공유하는 모듈)

variable "expected_account_id" {
  description = "AWS account that owns the managed queue; 12 digits."
  type        = string # 예: "111111111111" (앞자리 0 이 사라지지 않도록 문자열)

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id)) # 예: 숫자 12자리만 통과
    error_message = "expected_account_id must be a 12 digit AWS account id."
  }
}

variable "region" {
  description = "AWS region for the brokers, the customer managed key and the two secrets."
  type        = string
  default     = "ap-northeast-2" # 기본값: "ap-northeast-2" (서울 리전)

  validation {
    condition     = var.region == "ap-northeast-2" # 예: 이 과정의 자원은 모두 서울 리전
    error_message = "This course pins every root to ap-northeast-2."
  }
}

variable "environment" {
  description = "Environment name; becomes the first part of every resource name."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment) # 예: "dev" 통과 · "stage" 거부
    error_message = "environment must be dev or prod."
  }
}

variable "kafka_network_contract" {
  description = "network/vpc 루트 모듈(관리형 메시지 큐의 네트워크 경계)이 낸 브로커 · 클라이언트 Security Group, 영역별 브로커 서브넷, 클라이언트 리스너 포트입니다."
  type = object({
    broker_security_group_id = string      # 예: "sg-0broker..." (브로커 인터페이스에 붙일 Security Group)
    client_security_group_id = string      # 예: "sg-0client..." (전용 클라이언트 SG; 실제 노드 SG 입력과 구분)
    broker_subnet_ids_by_az  = map(string) # 예: { "ap-northeast-2a" = "subnet-0iii...", ... } (영역 3개)
    broker_port              = number      # 예: 9096 (클라이언트 경로 포트)
  })

  validation {
    condition     = length(var.kafka_network_contract.broker_subnet_ids_by_az) == 3 # 예: 3 == 3 만 통과
    error_message = "Broker subnets must cover exactly three availability zones."
  }

  validation {
    condition     = var.kafka_network_contract.broker_port == 9096 # 예: 9096 통과 · 9092 거부
    error_message = "The client listener port must be 9096 (TLS + SASL/SCRAM)."
  }
}

variable "workload_security_group_id" {
  description = "Actual EKS node security group from the eks state; the brokers accept this group on 9096."
  type        = string # 예: "sg-0nodes0123456789ab"

  validation {
    condition     = can(regex("^sg-[0-9a-f]+$", var.workload_security_group_id)) # 예: "sg-0nodes…" 형식만 통과
    error_message = "workload_security_group_id must be the actual EKS node SG id."
  }
}

variable "broker_instance_type" {
  description = "Broker instance type; the per-type partition limit is checked with a query, not with a value in code."
  type        = string
  default     = "kafka.t3.small" # 기본값: "kafka.t3.small" (실습 규모에서 가장 작은 유형)

  validation {
    condition     = startswith(var.broker_instance_type, "kafka.") # 예: "kafka.t3.small" 통과 · "m7i.large" 거부
    error_message = "broker_instance_type must start with kafka."
  }
}

variable "broker_storage_gib" {
  description = "EBS volume attached to each broker; must hold the 12 hour retention of the trace topic."
  type        = number
  default     = 30 # 기본값: 30 (원본 100 → 실습 규모 축소; 유입은 시험 trace 뿐)

  validation {
    condition     = var.broker_storage_gib >= 1 && floor(var.broker_storage_gib) == var.broker_storage_gib # 예: 30 통과 · 0.5 거부
    error_message = "broker_storage_gib must be an integer of at least 1."
  }
}

variable "kafka_version" {
  description = "Broker version; this course pins the 3.9 or the 4.0 series. The real list comes from aws kafka list-kafka-versions."
  type        = string

  validation {
    condition     = can(regex("^(3\\.9|4\\.0)\\.", var.kafka_version)) # 예: "3.9.0" · "4.0.0" 통과
    error_message = "kafka_version must be in the 3.9 or the 4.0 series."
  }
}

variable "writer_username" {
  description = "Writing user; must match the self-managed queue user name character for character."
  type        = string
  default     = "tempo-distributor" # 기본값: "tempo-distributor" (메시지 큐 클러스터와 사용자 의 KafkaUser 이름)
}

variable "reader_username" {
  description = "Reading user; must match the self-managed queue user name character for character."
  type        = string
  default     = "tempo-consumer" # 기본값: "tempo-consumer" (메시지 큐 클러스터와 사용자 의 KafkaUser 이름)
}
