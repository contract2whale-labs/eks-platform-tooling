# signal-variables.tf — modules/observability-foundation (dev · prod 루트 모듈이 공유하는 모듈)

variable "operations_contract" {
  description = "Seven fields of the upstream operations contract; verified against this root's account, region and cluster."
  type = object({
    account_id              = string # 예: "111111111111"
    cluster_name            = string # 예: "contract2whale-dev-eks"
    region                  = string # 예: "ap-northeast-2"
    platform_log_group_name = string # 예: "/platform/contract2whale-dev-eks/application" (fluent_bit 을 끄면 null)
    velero_bucket_name      = string
    velero_bucket_arn       = string # 예: "arn:aws:s3:::velero-contract2whale-dev-eks-111111111111-ap-northeast-2"
    alerts_topic_arn        = string # 예: "arn:aws:sns:ap-northeast-2:111111111111:contract2whale-dev-alerts" 또는 null
  })
  nullable = false
}

# 저장소 수명 주기가 객체를 지우는 기준일입니다. 구성 요소의 보존 설정(Thanos 367일 · Loki 30일 · Tempo 30일)보다 길게 둡니다.
variable "signal_retention_days" {
  description = "Backstop expiration days per signal bucket; must exceed each component's own retention."
  type        = map(number) # 예: map(number) (신호 이름을 키로 하는 숫자 map)
  default = {
    metrics = 400 # 기본값: 400 (압축과 다운샘플을 거친 지표 블록까지 남기는 기간; Thanos 1h 요약 365일 + 삭제 지연 2일 보다 김)
    logs    = 90  # 기본값: 90 (로그 청크을 남기는 기간; Loki 보존 30일보다 김)
    traces  = 30  # 기본값: 30 (트레이스 블록을 남기는 기간; dev 루트 모듈은 40 으로 올려 Tempo 30일보다 길게 둠)
  }
  nullable = false

  validation {
    condition     = toset(keys(var.signal_retention_days)) == toset(["metrics", "logs", "traces"]) # 예: 키가 정확히 세 개
    error_message = "signal_retention_days must have exactly the keys metrics, logs and traces."
  }

  validation {
    condition     = alltrue([for days in values(var.signal_retention_days) : days >= 1 && floor(days) == days]) # 예: 1 이상의 정수 (Expiration Days 는 0 이 아닌 양의 정수)
    error_message = "Every retention value must be a positive whole number of days."
  }
}

variable "pod_identities" {
  description = "Service accounts that receive a storage role; the key becomes the association address."
  type = map(object({
    namespace       = string # 예: "monitoring" (서비스 메시 메시 편입 제외 목록에 있는 이름)
    service_account = string # 예: "platform-monitoring-prometheus" (뒤따르는 주제가 만들 ServiceAccount)
    role            = string # 예: "writer" (writer · reader · maintenance 중 하나)
  }))

  default = {
    metrics_writer     = { namespace = "monitoring", service_account = "platform-monitoring-prometheus", role = "writer" }
    metrics_reader     = { namespace = "monitoring", service_account = "platform-thanos-store", role = "reader" }
    metrics_maintainer = { namespace = "monitoring", service_account = "platform-thanos-compact", role = "maintenance" }
    logs_writer        = { namespace = "logging", service_account = "platform-loki-write", role = "writer" }
    logs_reader        = { namespace = "logging", service_account = "platform-loki-read", role = "reader" }
    logs_maintainer    = { namespace = "logging", service_account = "platform-loki-backend", role = "maintenance" }
    traces_writer      = { namespace = "monitoring", service_account = "platform-tempo-block-builder", role = "writer" }
    traces_reader      = { namespace = "monitoring", service_account = "platform-tempo-querier", role = "reader" }
    traces_maintainer  = { namespace = "monitoring", service_account = "platform-tempo-backend-worker", role = "maintenance" }
  }
  nullable = false

  validation {
    condition     = alltrue([for id in values(var.pod_identities) : contains(["writer", "reader", "maintenance"], id.role)]) # 예: 모든 항목의 role 이 세 값 중 하나
    error_message = "Every pod identity role must be writer, reader or maintenance."
  }

  validation {
    condition     = alltrue([for id in values(var.pod_identities) : contains(["monitoring", "logging"], id.namespace)]) # 예: 메시 편입 제외 네임스페이스 두 개만
    error_message = "Pod identity namespaces are limited to monitoring and logging (mesh enrollment exclusions)."
  }

  validation {
    condition     = length(distinct([for id in values(var.pod_identities) : "${id.namespace}/${id.service_account}"])) == length(var.pod_identities) # 예: (namespace, SA) 짝이 겹치지 않음
    error_message = "A service account can be associated with only one storage role."
  }

  validation {
    condition     = alltrue([for signal in ["metrics", "logs", "traces"] : contains(keys(var.pod_identities), "${signal}_writer")]) # 예: 계약의 신호별 namespace 를 *_writer 에서 끌어오므로 세 키가 필수
    error_message = "pod_identities must keep the keys metrics_writer, logs_writer and traces_writer."
  }
}
