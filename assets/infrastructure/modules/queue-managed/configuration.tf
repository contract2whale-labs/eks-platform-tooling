# configuration.tf — modules/queue-managed (dev · prod 루트 모듈이 공유하는 모듈)
# 아래 네 입력은 이 구성과 계약 출력에만 쓰이므로 같은 파일에 둡니다.

variable "topic_name" {
  description = "Topic of the new Kafka offset space (epoch 2); the self-managed epoch 1 topic is left untouched."
  type        = string
  default     = "dev-tempo-traces-epoch-2" # 기본값: "dev-tempo-traces-epoch-2" (이전 토픽 platform-traces 와 다른 이름)

  validation {
    condition     = can(regex("^(dev|prod)-tempo-traces-epoch-[0-9]+$", var.topic_name)) # 예: "dev-tempo-traces-epoch-2" 통과
    error_message = "topic_name must look like <environment>-tempo-traces-epoch-<number>."
  }
}

variable "partitions" {
  description = "Partition count of the topic; the per-instance-type limit is checked with a query."
  type        = number
  default     = 3 # 기본값: 3 (자체 구축 큐의 파티션 수 · Tempo block-builder · live-store 수와 같은 값)

  validation {
    condition     = var.partitions == 3 # 예: 3 통과 · 0 과 1.5 거부
    error_message = "This transition keeps three partitions (block-builder and live-store replicas match it)."
  }
}

variable "replication_factor" {
  description = "Default replication factor when a topic is created; equals the broker count."
  type        = number
  default     = 3 # 기본값: 3 (영역마다 복제본 하나)

  validation {
    condition     = var.replication_factor == 3 # 예: 3 (브로커 3대 = 복제 3)
    error_message = "replication_factor must be 3 (one replica per broker)."
  }
}

variable "min_insync_replicas" {
  description = "Minimum in-sync replicas for a successful write; must be lower than the replication factor."
  type        = number
  default     = 2 # 기본값: 2 (복제 3 중 최소 ISR 2; 장애 시 쓰기는 현재 ISR·leader·연결·가용 용량을 함께 확인)

  validation {
    condition     = var.min_insync_replicas >= 1 && floor(var.min_insync_replicas) == var.min_insync_replicas && var.min_insync_replicas < var.replication_factor # 예: 2 < 3 통과 · 3 < 3 거부
    error_message = "min_insync_replicas must be an integer below replication_factor."
  }
}

resource "aws_msk_configuration" "traces" {
  name           = "${local.cluster_name}-config"        # 예: "cp-dev-traces-queue-config" (계정 안에서 유일한 이름)
  kafka_versions = [var.kafka_version]                   # 예: ["3.9.0"] (이 구성을 쓸 수 있는 브로커 버전)
  description    = "Managed trace queue broker defaults" # 예: 콘솔 목록에서 용도를 구분하는 설명

  # 값마다 한 줄이며 줄 순서는 뜻에 영향을 주지 않습니다.
  server_properties = join("\n", [
    "auto.create.topics.enable=false",                      # 예: false (없는 토픽으로 보내도 만들어지지 않음)
    "default.replication.factor=${var.replication_factor}", # 예: 3 (토픽을 만들 때의 기본 Replication Factor)
    "min.insync.replicas=${var.min_insync_replicas}",       # 예: 2 (쓰기를 성공으로 볼 최소 동기 복제 수)
    "num.partitions=${var.partitions}",                     # 예: 3 (토픽을 만들 때의 기본 파티션 수)
    "unclean.leader.election.enable=false",                 # 예: false (뒤처진 복제본을 대표로 뽑지 않음)
  ])

  lifecycle {
    # 구성 이름이 바뀌면 새 구성이 만들어지고 클러스터가 그것을 다시 읽습니다.
    create_before_destroy = true # 예: true (새 구성을 만든 뒤에 옛 구성을 지움)
  }
}
