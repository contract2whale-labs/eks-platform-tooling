# locals.tf — platform/observability 루트 모듈 (dev · prod 공통 코드)
# 관측 루트 모듈과 계약: State 에서 읽은 출력을 모듈 입력 모양으로 조립합니다. 다섯 값 모두 이 루트 모듈이 직접 입력받지 않습니다.

locals {
  cluster_contract = {
    name               = data.terraform_remote_state.eks.outputs.cluster_contract.name               # 예: "contract2whale-dev-eks"
    arn                = data.terraform_remote_state.eks.outputs.cluster_contract.arn                # 예: "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
    region             = data.terraform_remote_state.eks.outputs.cluster_contract.region             # 예: "ap-northeast-2"
    kubernetes_version = data.terraform_remote_state.eks.outputs.cluster_contract.kubernetes_version # 예: "1.36"
  }

  operations_contract = data.terraform_remote_state.operations.outputs.operations_contract # 예: { account_id = "111111111111", cluster_name = "contract2whale-dev-eks", … }

  vpc_id                   = data.terraform_remote_state.vpc.outputs.vpc_id                         # 예: "vpc-0123456789abcdef0" (관련 구성 출력)
  network_logs_bucket_name = data.terraform_remote_state.vpc.outputs.network_logs_bucket_name       # 예: "cp-dev-network-logs-111111111111-ap-northeast-2" (네트워크 로그 수집 출력)
  allowed_state_keys       = data.terraform_remote_state.account_baseline.outputs.state_object_keys # 예: ["account-baseline/terraform.tfstate", …, "platform/observability/terraform.tfstate"] (관련 구성 출력)
}
