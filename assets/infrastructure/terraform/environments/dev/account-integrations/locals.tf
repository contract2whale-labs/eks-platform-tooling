# locals.tf — account-integrations 루트 모듈 (dev · prod 공통 코드)
# 환경 root 와 실제 적용: State 에서 읽은 출력을 모듈 입력 두 계약의 모양으로 조립합니다. 두 값 모두 이 루트 모듈이 직접 입력받지 않습니다.

locals {
  operations_contract = {
    account_id              = data.terraform_remote_state.operations.outputs.operations_contract.account_id              # 예: "111111111111"
    cluster_name            = data.terraform_remote_state.operations.outputs.operations_contract.cluster_name            # 예: "contract2whale-dev-eks"
    region                  = data.terraform_remote_state.operations.outputs.operations_contract.region                  # 예: "ap-northeast-2"
    platform_log_group_name = data.terraform_remote_state.operations.outputs.operations_contract.platform_log_group_name # 예: "/platform/contract2whale-dev-eks/application"
    velero_bucket_name      = data.terraform_remote_state.operations.outputs.operations_contract.velero_bucket_name      # 예: "velero-contract2whale-dev-eks-111111111111-ap-northeast-2"
    velero_bucket_arn       = data.terraform_remote_state.operations.outputs.operations_contract.velero_bucket_arn       # 예: "arn:aws:s3:::velero-contract2whale-dev-eks-111111111111-ap-northeast-2"
    alerts_topic_arn        = data.terraform_remote_state.operations.outputs.operations_contract.alerts_topic_arn        # 예: "arn:aws:sns:ap-northeast-2:111111111111:contract2whale-dev-alerts" 또는 null
  }

  # modules/account-integrations 의 network_logs_contract 객체입니다. network/vpc State 의 출력 두 개를 묶습니다.
  network_logs_contract = {
    bucket_name = data.terraform_remote_state.vpc.outputs.network_logs_bucket_name # 예: "cp-dev-network-logs-111111111111-ap-northeast-2"
    bucket_arn  = data.terraform_remote_state.vpc.outputs.network_logs_bucket_arn  # 예: "arn:aws:s3:::cp-dev-network-logs-111111111111-ap-northeast-2"
  }
}
