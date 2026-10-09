# variables.tf — data 루트 모듈 (dev · prod 공통 코드)
# 원본의 `dev.inputs.json` · `dataops.prepare_root` 로 만들던 `dev.data.tfvars.json` 은 없습니다 — 학습자가 채우는 값은 아래 database 객체 하나뿐입니다.

variable "expected_account_id" {
  description = "AWS account that owns the cluster and receives the database, secrets and export bucket; 12 digits."
  type        = string # 예: "111111111111"
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

# main.tf 의 environment_boundary 가 이 디렉터리에서는 "dev" 만 허용합니다 (prod 는 prod/data).
variable "environment" {
  description = "Explicit environment name: dev or prod (used in secret names, the export prefix and the Environment tag)."
  type        = string
  nullable    = false

  validation {
    condition     = contains(["dev", "prod"], var.environment) # 예: "dev" 통과 / "staging" 거부
    error_message = "environment must be dev or prod."
  }
}

# 앞 루트 모듈(eks · network/vpc · delivery)의 State 가 있는 버킷입니다. backend.hcl 의 bucket 과 같은 값입니다.
variable "state_bucket_name" {
  description = "S3 bucket holding the eks, network/vpc and delivery states read by terraform_remote_state."
  type        = string # 예: "company-dev-tfstate-111111111111" (work/lab.env 의 DEV_STATE_BUCKET)
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name)) # 예: S3 버킷 이름 규칙
    error_message = "state_bucket_name must be a valid S3 bucket name."
  }
}

# 학습자가 리전 조회 결과로 채우는 유일한 입력입니다 (데이터 루트 모듈과 PostgreSQL 버전 고정). engine_version 을 문서 표에서 옮겨 적지 않습니다.
variable "database" {
  description = "Engine version resolved in this Region, instance class, storage window, backup retention and availability options."
  type = object({
    name                  = string # 예: "commercedb"
    engine_version        = string # 예: "17.6" (aws rds describe-db-engine-versions 조회 결과)
    instance_class        = string # 예: "db.t4g.micro"
    allocated_storage     = number # 예: 20
    max_allocated_storage = number # 예: 100
    backup_retention_days = number # 예: 7
    multi_az              = bool   # 예: false (Dev)
    deletion_protection   = bool   # 예: false (Dev)
  })
  nullable = false
}

# 캐시 스위치입니다. 서버리스 캐시는 쓰지 않아도 시간당 요금이 붙습니다.
variable "enable_redis" {
  description = "Create the ElastiCache Valkey serverless cache; false removes it while the lab is idle (a prod root must keep it true)."
  type        = bool
  default     = true # 기본값: true (commerce-api 의 event bus · workflow engine · locking · cache 가 이 한 곳을 씁니다)
  nullable    = false
}

# 캐시 선택값입니다. 서버리스는 용량을 미리 사지 않고 상한만 정하므로, 저장량과 처리량의 상한을 제어합니다. 실행 시간·최소 과금·스냅샷 등의 비용은 별도로 확인합니다.
variable "redis" {
  description = "Valkey major engine version, the storage and ECPU usage ceilings, and the daily snapshot retention."
  type = object({
    major_engine_version    = string # 예: "8"
    max_data_storage_gb     = number # 예: 1 (GB)
    max_ecpu_per_second     = number # 예: 5000
    snapshot_retention_days = number # 예: 1 (Prod 는 1 이상)
  })
  default = {
    major_engine_version    = "8"  # 기본값: "8" (Valkey 8)
    max_data_storage_gb     = 1    # 기본값: 1 (GB, 실습 규모)
    max_ecpu_per_second     = 5000 # 기본값: 5000 (실습 규모)
    snapshot_retention_days = 1    # 기본값: 1 (하루치 스냅샷)
  }
  nullable = false
}

# 앱 네임스페이스에서 데이터에 닿는 ServiceAccount 두 개입니다. migration ServiceAccount 이름은 배포 플랫폼 계약에서 읽습니다.
variable "service_accounts" {
  description = "Runtime and operator ServiceAccount names created in the application namespace (앱 네임스페이스와 수집 허용)."
  type = object({
    runtime  = string # 예: "commerce-api"
    operator = string # 예: "database-operator"
  })
  default = {
    runtime  = "commerce-api"      # 기본값: 앱 Pod 의 ServiceAccount
    operator = "database-operator" # 기본값: 초기화 · 진단 Job 의 ServiceAccount
  }
  nullable = false
}
