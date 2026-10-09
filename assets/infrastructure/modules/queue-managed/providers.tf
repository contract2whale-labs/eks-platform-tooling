# providers.tf — modules/queue-managed (dev · prod 루트 모듈이 공유하는 모듈)
# 고객 관리 키와 시크릿, 클러스터: provider 블록은 루트 모듈에만 둡니다. 이 파일은 계획 단계에서 "계약이 가리키는 대상이 이 실행과 같은 계정 · 같은 VPC 인가" 를 확인하는 조회와 검사입니다.

# 지금 실행하는 계정이 어디인지 조회합니다. 아래 검사가 이 값을 씁니다.
data "aws_caller_identity" "current" {}

# 계약이 준 브로커 Security Group 이 이 계정에 실제로 있는지, 그리고 어느 VPC 인지 봅니다.
data "aws_security_group" "broker" {
  id = var.kafka_network_contract.broker_security_group_id # 예: "sg-0broker..."

  filter {
    name   = "owner-id"                # 예: Security Group 을 소유한 계정
    values = [var.expected_account_id] # 예: ["111111111111"] (다른 계정의 SG 면 조회가 비어 실패)
  }
}

# 실제 노드 Security Group(eks State 출력)도 같은 방식으로 확인합니다.
data "aws_security_group" "workload" {
  id = var.workload_security_group_id # 예: "sg-0nodes..."

  filter {
    name   = "owner-id"
    values = [var.expected_account_id]
  }
}

# 계약이 가리키는 대상이 이 실행과 같은 곳인지 계획 단계에서 먼저 봅니다. AWS 자원을 만들지 않는 표식입니다.
resource "terraform_data" "network_boundary" {
  input = var.kafka_network_contract.broker_security_group_id # 예: "sg-0broker..." (값이 바뀌면 input 이 갱신됨)

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.expected_account_id # 예: 두 계정 번호가 같아야 통과
      error_message = "This directory is bound to a different AWS account."
    }

    precondition {
      condition     = data.aws_security_group.broker.vpc_id == data.aws_security_group.workload.vpc_id # 예: 두 SG 가 같은 VPC
      error_message = "Broker and actual workload SGs must belong to this account and VPC."
    }

    precondition {
      condition     = length(var.kafka_network_contract.broker_subnet_ids_by_az) == 3 # 예: 3 == 3 (영역이 3개가 아니면 중단)
      error_message = "Managed queue brokers need exactly three availability zones."
    }

    precondition {
      condition     = var.kafka_network_contract.broker_port == 9096 # 예: 9096 만 통과
      error_message = "The client listener port must match the network contract port."
    }

    precondition {
      condition     = startswith(var.topic_name, "${var.environment}-tempo-traces-epoch-") # 예: "dev-tempo-traces-epoch-2"
      error_message = "topic_name must start with <environment>-tempo-traces-epoch-."
    }
  }
}
