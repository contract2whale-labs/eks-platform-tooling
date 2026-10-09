# variables.tf — modules/data (dev · prod 루트 모듈이 공유하는 모듈)
# 원본의 `dataops.inputs` 검사기(JSON 입력 파일 + 종료 코드 2)는 변수 validation + terraform test 의 expect_failures 로 옮겼습니다 (P3 · 결정 8).

variable "expected_account_id" {
  description = "AWS account that owns the cluster, the database and the secrets; 12 digits."
  type        = string # 예: string (앞자리 0 이 사라지지 않도록 문자열)
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_account_id)) # 예: "111111111111" 통과
    error_message = "Account ID must be 12 digits."
  }
}

variable "region" {
  description = "AWS region for this module; only ap-northeast-2 is supported in this course."
  type        = string
  default     = "ap-northeast-2" # 기본값: "ap-northeast-2"
  nullable    = false

  validation {
    condition     = var.region == "ap-northeast-2" # 예: 단일 값 비교
    error_message = "This module supports ap-northeast-2 only."
  }
}

variable "environment" {
  description = "Environment name used in secret names, the export prefix and the Environment tag: dev or prod."
  type        = string
  nullable    = false

  validation {
    condition     = contains(["dev", "prod"], var.environment) # 예: "dev" 통과 / "staging" 거부
    error_message = "environment must be dev or prod."
  }
}

variable "cluster_contract" {
  description = "Cluster name, ARN, region and VPC of the EKS cluster whose Pods reach this database."
  type = object({
    name   = string # 예: "contract2whale-dev-eks"
    arn    = string # 예: "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
    region = string # 예: "ap-northeast-2"
    vpc_id = string # 예: "vpc-0123456789abcdef0"
  })
  nullable = false

  validation {
    condition     = can(regex("^arn:aws:eks:[a-z0-9-]+:[0-9]{12}:cluster/", var.cluster_contract.arn)) # 예: EKS 클러스터 ARN 형식
    error_message = "cluster_contract.arn must be an EKS cluster ARN."
  }
}

# 관련 구성 · 관련 구성 network/vpc 루트 모듈의 출력입니다. 데이터베이스는 일반 Private 서브넷(EKS 서브넷과 분리)에, 캐시는 Intra 서브넷에 둡니다.
variable "network_contract" {
  description = "VPC, CIDR, private subnets for the DB subnet group, intra subnets for the serverless cache and the node security group allowed to reach 5432 and 6379."
  type = object({
    vpc_id                 = string       # 예: "vpc-0123456789abcdef0"
    vpc_cidr               = string       # 예: "172.20.0.0/16"
    database_subnet_ids    = list(string) # 예: ["subnet-0ra…", "subnet-0rb…", "subnet-0rc…"] (AZ 2곳 이상)
    intra_subnet_ids       = list(string) # 예: ["subnet-0ia…", "subnet-0ib…", "subnet-0ic…"] (서버리스 캐시는 서브넷 그룹 대신 이 목록을 직접 받음)
    node_security_group_id = string       # 예: "sg-0aaaabbbbccccdddd" (노드와 Add-on node_security_group_id)
  })
  nullable = false

  validation {
    condition     = length(var.network_contract.database_subnet_ids) >= 2 # 예: 서브넷 2개 미만이면 DB 서브넷 그룹을 만들 수 없음
    error_message = "database_subnet_ids must list at least two subnets in different availability zones."
  }

  validation {
    condition     = length(distinct(var.network_contract.database_subnet_ids)) == length(var.network_contract.database_subnet_ids)
    error_message = "database_subnet_ids must not repeat the same subnet."
  }

  validation {
    condition     = length(var.network_contract.intra_subnet_ids) >= 2 && length(var.network_contract.intra_subnet_ids) <= 3 # 예: 서버리스 캐시는 AZ 2~3곳의 서브넷만 받습니다
    error_message = "intra_subnet_ids must list two or three subnets in different availability zones."
  }

  validation {
    condition     = length(distinct(var.network_contract.intra_subnet_ids)) == length(var.network_contract.intra_subnet_ids) # 예: 같은 서브넷 두 번 입력 거부
    error_message = "intra_subnet_ids must not repeat the same subnet."
  }

  validation {
    condition     = can(regex("^sg-[0-9a-f]{8,17}$", var.network_contract.node_security_group_id)) # 예: "sg-0aaaabbbbccccdddd"
    error_message = "node_security_group_id must be a security group ID."
  }
}

# 데이터베이스 선택값입니다. engine_version 은 리전 조회 결과를 그대로 적고(데이터 루트 모듈과 PostgreSQL 버전 고정), contract.tf 의 조회가 같은 값을 돌려주지 않으면 계획이 멈춥니다.
variable "database" {
  description = "PostgreSQL engine version resolved in this Region, instance class, storage window, backup retention and availability options."
  type = object({
    name                  = string # 예: "commercedb" (초기 데이터베이스 이름)
    engine_version        = string # 예: "17.6" (aws rds describe-db-engine-versions 조회 결과; 문서 표에서 옮겨 적지 않음)
    instance_class        = string # 예: "db.t4g.micro"
    allocated_storage     = number # 예: 20 (GiB)
    max_allocated_storage = number # 예: 100 (GiB, 자동 확장 상한)
    backup_retention_days = number
    multi_az              = bool # 예: false (Dev 는 단일 AZ)
    deletion_protection   = bool # 예: false (Dev 는 down.sh 가 지울 수 있어야 함)
  })
  nullable = false

  validation {
    condition     = can(regex("^[0-9]{1,2}[.][0-9]{1,2}$", var.database.engine_version)) # 예: "17.6" 통과 / "17" · "latest" 거부
    error_message = "Pin engine_version to the exact major.minor version returned by describe-db-engine-versions."
  }

  validation {
    condition     = can(regex("^db[.][a-z0-9]+[.][a-z0-9]+$", var.database.instance_class)) # 예: "db.t4g.micro" 통과 / "t4g.micro" 거부
    error_message = "instance_class must look like db.<family>.<size>."
  }

  validation {
    condition     = can(regex("^[a-z][a-z0-9_]{0,62}$", var.database.name)) # 예: "commercedb" 통과 / "commerce-db" 거부 (PostgreSQL 초기 DB 이름 규칙)
    error_message = "database name must be lower case letters, digits and underscores."
  }

  validation {
    condition     = var.database.backup_retention_days >= 1 && var.database.backup_retention_days <= 35 && floor(var.database.backup_retention_days) == var.database.backup_retention_days # 예: 0 거부 (자동 백업이 꺼짐)
    error_message = "backup_retention_days must be a whole number between 1 and 35; zero disables automated backups."
  }

  validation {
    condition     = var.database.allocated_storage >= 20 && var.database.max_allocated_storage >= var.database.allocated_storage # 예: 20 이상 · 상한이 시작값 이상
    error_message = "allocated_storage must be at least 20 GiB and max_allocated_storage must not be smaller."
  }
}

# 캐시 스위치입니다. 서버리스 캐시는 쓰지 않아도 시간당 요금이 붙으므로, 실습을 쉬는 동안 false 로 내렸다가 다시 true 로 올릴 수 있게 합니다.
variable "enable_redis" {
  description = "Create the ElastiCache Valkey serverless cache; false removes the cache, its security group and its rule (a prod environment must keep it true)."
  type        = bool
  default     = true # 기본값: true (commerce-api 의 event bus · workflow engine · locking · cache 네 모듈이 이 한 곳을 씁니다)
  nullable    = false
}

# 캐시 선택값입니다. 서버리스는 용량을 미리 사지 않고 상한만 정합니다 — 저장량과 처리량의 상한을 제어합니다. 실행 시간·최소 과금·스냅샷 등의 비용은 별도로 확인합니다.
variable "redis" {
  description = "Valkey major engine version, the storage and ECPU usage ceilings, and the daily snapshot retention."
  type = object({
    major_engine_version    = string # 예: "8" (ElastiCache 는 주 버전만 받습니다 — "8.0" 은 거부)
    max_data_storage_gb     = number # 예: 1 (GB, 저장 상한 — 최소 1)
    max_ecpu_per_second     = number # 예: 5000 (초당 ECPU 상한 — 최소 1000)
    snapshot_retention_days = number # 예: 1 (0 은 스냅샷을 만들지 않음; Prod 는 1 이상)
  })
  default = {
    major_engine_version    = "8"  # 기본값: "8" (Valkey 8)
    max_data_storage_gb     = 1    # 기본값: 1 (GB, 실습 규모)
    max_ecpu_per_second     = 5000 # 기본값: 5000 (실습 규모)
    snapshot_retention_days = 1    # 기본값: 1 (하루치 스냅샷)
  }
  nullable = false

  validation {
    condition     = can(regex("^[0-9]{1,2}$", var.redis.major_engine_version)) # 예: "8" 통과 / "8.0" · "latest" 거부
    error_message = "redis.major_engine_version must be the major version only, for example 8."
  }

  validation {
    condition     = var.redis.max_data_storage_gb >= 1 && var.redis.max_data_storage_gb <= 5000 && floor(var.redis.max_data_storage_gb) == var.redis.max_data_storage_gb # 예: 1 통과 / 0 거부
    error_message = "redis.max_data_storage_gb must be a whole number between 1 and 5000."
  }

  validation {
    condition     = var.redis.max_ecpu_per_second >= 1000 && var.redis.max_ecpu_per_second <= 15000000 && floor(var.redis.max_ecpu_per_second) == var.redis.max_ecpu_per_second # 예: 5000 통과 / 500 거부
    error_message = "redis.max_ecpu_per_second must be a whole number between 1000 and 15000000."
  }

  validation {
    condition     = var.redis.snapshot_retention_days >= 0 && var.redis.snapshot_retention_days <= 35 && floor(var.redis.snapshot_retention_days) == var.redis.snapshot_retention_days # 예: 1 통과 / 36 거부
    error_message = "redis.snapshot_retention_days must be a whole number between 0 and 35."
  }
}

# 앱 좌표입니다. 배포 플랫폼 delivery_contract.application 과 같은 값을 루트 모듈이 State 에서 읽어 넘깁니다 (같은 네임스페이스 · 같은 Deployment).
variable "application" {
  description = "Tenant namespace, Deployment and the three ServiceAccounts that reach the database or the export bucket."
  type = object({
    namespace                 = string # 예: "contract2whale-demo"
    deployment                = string # 예: "commerce-api"
    runtime_service_account   = string # 예: "commerce-api" (앱 Pod)
    operator_service_account  = string # 예: "database-operator" (초기화 · 진단 Job)
    migration_service_account = string # 예: "delivery-migration" (배포 플랫폼 배포 전달의 migration Job)
  })
  nullable = false

  validation {
    condition = alltrue([
      for name in [var.application.namespace, var.application.deployment, var.application.runtime_service_account, var.application.operator_service_account, var.application.migration_service_account] :
      can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", name)) # 예: Kubernetes 이름 규칙 (소문자 · 숫자 · 하이픈)
    ])
    error_message = "namespace, deployment and service account names must be RFC 1123 labels."
  }
}

# 운영자 이미지(초기화 · 진단 Job) 저장소입니다. 앱 · migration · 도구 저장소는 배포 플랫폼 delivery 모듈이 소유합니다.
variable "operator_repository_name" {
  description = "ECR repository holding the database operator image built in 데이터베이스 운영자 이미지와 읽기 전용 진단."
  type        = string
  default     = "contract2whale/database-operator" # 기본값: "contract2whale/database-operator"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$", var.operator_repository_name)) # 예: ECR 이름 규칙
    error_message = "operator_repository_name must be a valid ECR repository name."
  }
}

# 기존 delivery가 만든 검증 역할입니다. operator ECR 생성 후 읽기 권한만 추가합니다.
variable "kyverno_role_arn" {
  description = "Existing delivery Kyverno role receiving read-only access to the operator repository."
  type        = string # 예: arn:aws:iam::111111111111:role/platform/contract2whale-dev-eks-delivery-kyverno
  nullable    = false

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/platform/[A-Za-z0-9+=,.@_-]+$", var.kyverno_role_arn))
    error_message = "kyverno_role_arn must identify the existing platform role."
  }
}
