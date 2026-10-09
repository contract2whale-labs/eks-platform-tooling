# locals.tf — data 루트 모듈 (dev · prod 공통 코드)
# 데이터 루트 모듈과 PostgreSQL 버전 고정: State 에서 읽은 출력을 모듈 입력 세 객체의 모양으로 조립합니다. 어느 값도 이 루트 모듈이 직접 입력받지 않습니다.

locals {
  cluster_contract = {
    name   = data.terraform_remote_state.eks.outputs.cluster_contract.name   # 예: "contract2whale-dev-eks"
    arn    = data.terraform_remote_state.eks.outputs.cluster_contract.arn    # 예: "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
    region = data.terraform_remote_state.eks.outputs.cluster_contract.region # 예: "ap-northeast-2"
    vpc_id = data.terraform_remote_state.eks.outputs.cluster_contract.vpc_id # 예: "vpc-0123456789abcdef0"
  }

  network_contract = {
    vpc_id                 = data.terraform_remote_state.network.outputs.vpc_id             # 예: "vpc-0123456789abcdef0"
    vpc_cidr               = data.terraform_remote_state.network.outputs.vpc_cidr_block     # 예: "172.20.0.0/16"
    database_subnet_ids    = data.terraform_remote_state.network.outputs.private_subnet_ids # 예: 일반 Private 서브넷 3개 (EKS 서브넷과 분리)
    intra_subnet_ids       = data.terraform_remote_state.network.outputs.intra_subnet_ids   # 예: Intra 서브넷 3개 (인터넷 기본 경로 없음 — 서버리스 캐시 자리)
    node_security_group_id = data.terraform_remote_state.eks.outputs.node_security_group_id # 예: "sg-0aaaabbbbccccdddd" (5432 · 6379 를 여는 유일한 출발지)
  }

  # 워크로드 둘 중 데이터에 닿는 쪽은 api 하나입니다 — commerce-web 은 AWS 를 부르지 않고 commerce-api 만 호출하므로 비밀 · 미디어 접두사에 이름이 들어가지 않습니다.
  application = {
    namespace                 = data.terraform_remote_state.delivery.outputs.delivery_contract.application.namespace                     # 예: "contract2whale-demo"
    deployment                = data.terraform_remote_state.delivery.outputs.delivery_contract.application.api.deployment                # 예: "commerce-api" (비밀 접두사 contract2whale/<env>/commerce-api · 미디어 접두사 media/<env>/commerce-api/)
    runtime_service_account   = var.service_accounts.runtime                                                                             # 예: "commerce-api"
    operator_service_account  = var.service_accounts.operator                                                                            # 예: "database-operator"
    migration_service_account = data.terraform_remote_state.delivery.outputs.delivery_contract.application.api.migration_service_account # 예: "delivery-migration"
  }
}
