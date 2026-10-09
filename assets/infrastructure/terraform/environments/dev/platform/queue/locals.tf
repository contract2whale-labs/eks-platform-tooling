# locals.tf — platform/queue 루트 모듈 (dev · prod 공통 코드)
# 권한 모델과 토픽 사전 생성: State 에서 읽은 출력을 모듈 입력 모양으로 조립하고, 클러스터 안 자료(NetworkPolicy · Tempo 값)가 쓰는 값을 한곳에 모읍니다.

locals {
  common_tags = {
    ManagedBy   = "Terraform"     # 예: "Terraform" (수동 생성 리소스와 구분)
    Environment = var.environment # 예: "dev"
    Component   = "queue-managed" # 예: "queue-managed" (어느 구성이 만든 것인지 표시)
  }

  kafka_network_contract = {
    broker_security_group_id = data.terraform_remote_state.network.outputs.kafka_network_contract.broker_security_group_id # 예: "sg-0broker..."
    client_security_group_id = data.terraform_remote_state.network.outputs.kafka_network_contract.client_security_group_id # 예: "sg-0client..."
    broker_subnet_ids_by_az  = data.terraform_remote_state.network.outputs.kafka_network_contract.broker_subnet_ids_by_az  # 예: AZ 3개
    broker_port              = data.terraform_remote_state.network.outputs.kafka_network_contract.broker_port              # 예: 9096
  }

  cluster_name               = data.terraform_remote_state.eks.outputs.cluster_name                                          # 예: "contract2whale-dev-eks"
  node_security_group_id     = data.terraform_remote_state.eks.outputs.node_security_group_id                                # 예: "sg-0nodes..."
  broker_subnet_cidrs_by_az  = data.terraform_remote_state.network.outputs.kafka_broker_subnet_cidrs_by_az                   # 예: {"ap-northeast-2a" = "172.20.12.0/28", ...}
  broker_subnet_cidrs_sorted = [for az in sort(keys(local.broker_subnet_cidrs_by_az)) : local.broker_subnet_cidrs_by_az[az]] # 예: ["172.20.12.0/28", ...]
}
