# contract.tf — modules/observability-foundation (dev · prod 루트 모듈이 공유하는 모듈)

variable "active_trace_backend" {
  description = "Which message queue the trace pipeline uses now; the managed-queue transition root (메시지 큐 전환) changes it."
  type        = string # 예: string (두 값 중 하나)
  default     = "self-managed"
  nullable    = false

  validation {
    condition     = contains(["self-managed", "managed"], var.active_trace_backend) # 예: "managed" 통과 / "msk" 거부
    error_message = "active_trace_backend must be self-managed or managed."
  }
}

variable "storage_epoch" {
  description = "Trace backend transition generation; the transition root raises it when storage rules change."
  type        = number # 예: number (1 이상의 정수)
  default     = 1      # 기본값: 1 (전환 전의 초기 세대 번호)
  nullable    = false

  validation {
    condition     = var.storage_epoch >= 1 && floor(var.storage_epoch) == var.storage_epoch # 예: 1 통과 / 0 · 1.5 거부
    error_message = "storage_epoch must be a whole number of 1 or more."
  }
}

variable "policy_version" {
  description = "Contract rule version; raise only when readers must change how they interpret the contract."
  type        = number # 예: number (1 이상의 정수)
  default     = 1      # 기본값: 1 (첫 버전)
  nullable    = false

  validation {
    condition     = var.policy_version >= 1 && floor(var.policy_version) == var.policy_version # 예: 2 통과 / 0 거부
    error_message = "policy_version must be a whole number of 1 or more."
  }
}

locals {
  # 신호별 네임스페이스은 쓰는 쪽 신원에서 끌어옵니다. 같은 값을 두 번 적지 않습니다.
  signal_namespaces = {
    for signal in ["metrics", "logs", "traces"] : signal => var.pod_identities["${signal}_writer"].namespace # 예: { metrics = "monitoring", logs = "logging", traces = "monitoring" }
  }

  query_endpoints = {
    prometheus = "http://platform-thanos-query.${local.signal_namespaces["metrics"]}.svc.cluster.local:9090"
    loki       = "http://platform-loki-gateway.${local.signal_namespaces["logs"]}.svc.cluster.local"
    tempo      = "http://platform-tempo-active-query.${local.signal_namespaces["traces"]}.svc.cluster.local:3200"
  }

  # 해시 재료입니다. 이 값이 하나라도 바뀌면 policy_hash 가 바뀝니다.
  policy_material = {
    buckets       = local.signal_bucket_names    # 예: 저장소 이름 3개
    prefixes      = local.signal_object_prefixes # 예: 접두사 3개
    roles         = local.storage_role_arns      # 예: 역할 ARN 3개
    identities    = var.pod_identities           # 예: 신원 9개
    retention     = var.signal_retention_days    # 예: 보존일 3개
    trace_backend = var.active_trace_backend     # 예: "self-managed"
    epoch         = var.storage_epoch            # 예: 1
    version       = var.policy_version           # 예: 1
  }

  policy_hash = sha256(jsonencode(local.policy_material)) # 예: 64자리 16진수 (재료가 하나만 달라져도 값이 완전히 달라짐)
}

output "observability_contract" {
  description = "Account, region, cluster, namespaces, service accounts, roles, buckets, retention, in-cluster query endpoints, trace backend state and policy hash (17 keys)."
  value = {
    account              = var.expected_account_id                                           # 예: "111111111111"
    region               = var.region                                                        # 예: "ap-northeast-2"
    cluster              = var.cluster_contract.name                                         # 예: "contract2whale-dev-eks"
    namespace            = local.signal_namespaces                                           # 예: { metrics = "monitoring", logs = "logging", traces = "monitoring" }
    service_account      = { for key, id in var.pod_identities : key => id.service_account } # 예: { metrics_writer = "platform-monitoring-prometheus", … } (9개)
    role                 = local.storage_role_arns                                           # 예: { writer = "…", reader = "…", maintenance = "…" }
    metrics_bucket       = aws_s3_bucket.signal["metrics"].id                                # 예: "cp-dev-observability-metrics-111111111111-ap-northeast-2"
    logs_bucket          = aws_s3_bucket.signal["logs"].id                                   # 예: "cp-dev-observability-logs-111111111111-ap-northeast-2"
    traces_bucket        = aws_s3_bucket.signal["traces"].id                                 # 예: "cp-dev-observability-traces-111111111111-ap-northeast-2"
    retention            = var.signal_retention_days                                         # 예: { metrics = 400, logs = 90, traces = 40 }
    prometheus_endpoint  = local.query_endpoints["prometheus"]                               # 예: "http://platform-thanos-query.monitoring.svc.cluster.local:9090"
    loki_endpoint        = local.query_endpoints["loki"]                                     # 예: "http://platform-loki-gateway.logging.svc.cluster.local"
    tempo_endpoint       = local.query_endpoints["tempo"]                                    # 예: "http://platform-tempo-active-query.monitoring.svc.cluster.local:3200"
    active_trace_backend = var.active_trace_backend                                          # 예: "self-managed" (전환 구성이 바꾸는 값 1)
    storage_epoch        = var.storage_epoch                                                 # 예: 1 (전환 구성이 바꾸는 값 2)
    policy_version       = var.policy_version                                                # 예: 1 (계약의 규칙 버전)
    policy_hash          = local.policy_hash                                                 # 예: 재료로 계산한 64자리 16진수 문자열
  }
}
