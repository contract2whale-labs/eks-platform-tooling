# main.tf — platform/queue 루트 모듈 (dev · prod 공통 코드)
# 관리형 큐·보안 키·Secret 컨테이너를 만듭니다. 값 발급은 보호된 operation, SCRAM 연결과 읽기 역할은 별도 association·secrets root가 관리합니다.

module "component" {
  source = "../../../../../modules/queue-managed" # 예: 이 루트 모듈에서 모듈까지의 상대 경로 (다섯 단계 위가 저장소 최상위)

  expected_account_id        = var.expected_account_id      # 예: "111111111111"
  region                     = var.region                   # 예: "ap-northeast-2"
  environment                = var.environment              # 예: "dev"
  kafka_network_contract     = local.kafka_network_contract # 예: 관리형 메시지 큐의 네트워크 경계 계약 네 키 (State 에서 읽음)
  workload_security_group_id = local.node_security_group_id # 예: "sg-0nodes..." (eks State 에서 읽음)
  broker_instance_type       = var.broker_instance_type     # 예: "kafka.t3.small"
  broker_storage_gib         = var.broker_storage_gib       # 예: 30
  kafka_version              = var.kafka_version            # 예: 조회로 확인한 3.9 계열 또는 4.0 계열의 버전
  writer_username            = var.writer_username          # 예: "tempo-distributor"
  reader_username            = var.reader_username          # 예: "tempo-consumer"
  topic_name                 = var.topic_name               # 예: "dev-tempo-traces-epoch-2"
  partitions                 = var.partitions               # 예: 3
  replication_factor         = var.replication_factor       # 예: 3
  min_insync_replicas        = var.min_insync_replicas      # 예: 2
}

# 이 디렉터리는 dev 만 받습니다. input 은 State 에 남는 표식이며 AWS 자원을 만들지 않습니다.
resource "terraform_data" "environment_boundary" {
  input = var.environment # 예: "dev"

  lifecycle {
    precondition {
      condition     = var.environment == "dev" # 예: "dev" 통과 / "prod" 거부 (prod 는 prod/platform/queue — 운영 환경)
      error_message = "This directory accepts only the dev environment."
    }

    precondition {
      condition     = terraform.workspace == "default" # 예: workspace 로 환경을 나누지 않음 (backend key 로 구분)
      error_message = "Use default workspace and a distinct backend key."
    }
  }
}
