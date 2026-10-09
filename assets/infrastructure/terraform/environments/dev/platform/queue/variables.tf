# variables.tf — platform/queue 루트 모듈 (dev · prod 공통 코드)

variable "expected_account_id" {
  description = "AWS account that owns the managed queue; 12 digits."
  type        = string # 예: "111111111111"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id))
    error_message = "expected_account_id must be a 12 digit AWS account id."
  }
}

variable "region" {
  description = "AWS region for this root; only ap-northeast-2 is supported."
  type        = string
  default     = "ap-northeast-2" # 기본값: "ap-northeast-2"

  validation {
    condition     = var.region == "ap-northeast-2"
    error_message = "This course pins every root to ap-northeast-2."
  }
}

variable "environment" {
  description = "Explicit environment name; this directory accepts dev only."
  type        = string

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "state_bucket_name" {
  description = "S3 bucket holding the network/vpc and eks states read by terraform_remote_state."
  type        = string # 예: "company-dev-tfstate-111111111111" (work/lab.env 의 DEV_STATE_BUCKET)

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be a valid S3 bucket name."
  }
}

variable "broker_instance_type" {
  description = "Broker instance type; kafka.t3.small keeps the lab cost low."
  type        = string
  default     = "kafka.t3.small" # 기본값: "kafka.t3.small"
}

variable "broker_storage_gib" {
  description = "EBS volume attached to each broker."
  type        = number
  default     = 30 # 기본값: 30 (원본 100 → 실습 규모)
}

variable "kafka_version" {
  description = "Broker version picked from aws kafka list-kafka-versions (3.9 or 4.0 series)."
  type        = string # 예: "3.9.0" (값은 조회 결과에서 고름 — 검증 불가)
}

variable "writer_username" {
  description = "Writing user; same name as the self-managed KafkaUser."
  type        = string
  default     = "tempo-distributor" # 기본값: "tempo-distributor"
}

variable "reader_username" {
  description = "Reading user; same name as the self-managed KafkaUser."
  type        = string
  default     = "tempo-consumer" # 기본값: "tempo-consumer"
}





variable "topic_name" {
  description = "Topic of the new Kafka offset space (epoch 2)."
  type        = string
  default     = "dev-tempo-traces-epoch-2" # 기본값: "dev-tempo-traces-epoch-2"

  validation {
    condition     = can(regex("^(dev|prod)-tempo-traces-epoch-[0-9]+$", var.topic_name)) # 예: "dev-tempo-traces-epoch-2" 통과 · "tempo-traces-epoch-2" 거부
    error_message = "topic_name must look like <environment>-tempo-traces-epoch-<number>."
  }
}

variable "partitions" {
  description = "Partition count of the topic; equals block-builder and live-store replicas."
  type        = number
  default     = 3 # 기본값: 3
}

variable "replication_factor" {
  description = "Default replication factor of the broker configuration."
  type        = number
  default     = 3 # 기본값: 3
}

variable "min_insync_replicas" {
  description = "Minimum in-sync replicas of the broker configuration."
  type        = number
  default     = 2 # 기본값: 2
}
