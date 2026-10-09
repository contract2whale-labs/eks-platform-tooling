# cluster.tf — modules/queue-managed (dev · prod 루트 모듈이 공유하는 모듈)
# 고객 관리 키와 시크릿, 클러스터: 브로커 3대를 앞 구성의 영역별 서브넷에 하나씩 둡니다. 클라이언트 인증은 SCRAM 하나만 켜고 무인증과 IAM 인증은 끕니다.
# Security Group 자체와 노드 Launch Template 은 앞 루트 모듈의 State 가 소유합니다. 여기서는 실제 노드 ↔ 브로커 규칙 두 개만 더합니다.

locals {
  # 예: keys 가 사전식으로 반환하는 영역 이름을 씁니다. sort 는 같은 순서를 유지합니다.
  broker_subnet_ids = [
    for az in sort(keys(var.kafka_network_contract.broker_subnet_ids_by_az)) :
    var.kafka_network_contract.broker_subnet_ids_by_az[az]
  ]
}

resource "aws_vpc_security_group_egress_rule" "workload_to_broker" {
  security_group_id            = var.workload_security_group_id                      # 예: "sg-0nodes..." (eks State 의 노드 SG)
  referenced_security_group_id = var.kafka_network_contract.broker_security_group_id # 예: "sg-0broker..."
  ip_protocol                  = "tcp"                                               # 예: "tcp"
  from_port                    = var.kafka_network_contract.broker_port              # 예: 9096
  to_port                      = var.kafka_network_contract.broker_port              # 예: 9096
  description                  = "Actual EKS nodes to managed Kafka SCRAM"           # 예: 규칙 목록에서 용도를 구분하는 설명

  depends_on = [terraform_data.network_boundary] # 예: 계정 · VPC 검사를 통과한 뒤에 만듭니다
}

resource "aws_vpc_security_group_ingress_rule" "broker_from_workload" {
  security_group_id            = var.kafka_network_contract.broker_security_group_id # 예: "sg-0broker..."
  referenced_security_group_id = var.workload_security_group_id                      # 예: "sg-0nodes..."
  ip_protocol                  = "tcp"
  from_port                    = var.kafka_network_contract.broker_port # 예: 9096
  to_port                      = var.kafka_network_contract.broker_port # 예: 9096
  description                  = "Managed Kafka SCRAM from actual EKS nodes"

  depends_on = [terraform_data.network_boundary]
}

resource "aws_msk_cluster" "traces" {
  cluster_name           = local.cluster_name              # 예: "cp-dev-traces-queue" (계정 안에서 유일한 이름)
  kafka_version          = var.kafka_version               # 예: 조회로 고른 3.9 계열 또는 4.0 계열의 버전
  number_of_broker_nodes = length(local.broker_subnet_ids) # 예: 3 (서브넷 수와 같게 두어 영역마다 한 대)

  broker_node_group_info {
    instance_type   = var.broker_instance_type                              # 예: "kafka.t3.small"
    client_subnets  = local.broker_subnet_ids                               # 예: 영역별 서브넷 3개 (정렬한 순서)
    security_groups = [var.kafka_network_contract.broker_security_group_id] # 예: ["sg-0broker..."]

    storage_info {
      ebs_storage_info {
        volume_size = var.broker_storage_gib # 예: 30 (브로커 한 대당 저장 용량)
      }
    }
  }

  # 클라이언트 인증은 사용자 이름과 비밀번호 하나만 켭니다.
  client_authentication {
    sasl {
      scram = true  # 예: true (사용자 이름과 비밀번호로 인증)
      iam   = false # 예: false (IAM 인증은 켜지 않음)
    }

    unauthenticated = false # 예: false (인증 없는 접속을 허용하지 않음)
  }

  # 암호화는 두 곳에 걸립니다. 저장된 자리와 오가는 구간입니다.
  encryption_info {
    encryption_at_rest_kms_key_arn = aws_kms_key.queue_secrets.arn # 예: 고객 관리 키 ARN (저장 용량 암호화)

    encryption_in_transit {
      client_broker = "TLS" # 예: "TLS" (클라이언트와 브로커 사이를 보호)
      in_cluster    = true  # 예: true (브로커끼리의 복제 구간도 보호)
    }
  }

  # 자동 토픽 생성을 막는 구성입니다. 선언은 configuration.tf 에 있습니다.
  configuration_info {
    arn      = aws_msk_configuration.traces.arn             # 예: 구성 ARN
    revision = aws_msk_configuration.traces.latest_revision # 예: 1 (구성의 버전 번호)
  }

  tags = {
    Name = local.cluster_name # 예: "cp-dev-traces-queue"
  }

  lifecycle {
    # 브로커는 영역 세 곳에 나눕니다. 장애 시 쓰기 지속은 현재 ISR·leader·연결·가용 용량으로 판정합니다.
    precondition {
      condition     = length(local.broker_subnet_ids) == 3 # 예: 3 == 3 (아니면 계획에서 중단)
      error_message = "Managed queue brokers need exactly three client subnets."
    }
  }

  depends_on = [terraform_data.network_boundary] # 예: 계정 · VPC · 포트 검사를 통과한 뒤에 만듭니다
}
