# locals.tf — platform/operations 루트 모듈 (dev · prod 공통 코드)
# 운영 기반 루트 모듈과 계약: State 에서 읽은 출력을 모듈 입력 모양으로 조립합니다. 클러스터와 ASG는 EKS State에서, 선택적인 알림 ARN은 검토한 공개 입력에서 받습니다.

locals {
  cluster_contract = {
    name               = data.terraform_remote_state.eks.outputs.cluster_contract.name               # 예: "contract2whale-dev-eks"
    arn                = data.terraform_remote_state.eks.outputs.cluster_contract.arn                # 예: "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
    region             = data.terraform_remote_state.eks.outputs.cluster_contract.region             # 예: "ap-northeast-2"
    kubernetes_version = data.terraform_remote_state.eks.outputs.cluster_contract.kubernetes_version # 예: "1.36"
  }

  # 모든 노드 그룹의 ASG 이름입니다 (D7: system 전용 출력이 아니라 node_contract 의 전체 목록; 관측 파이프라인 · 메시지 큐 전환 · 애플리케이션 데이터 이 그룹을 더하면 plan 에 태그가 추가됨).
  node_group_autoscaling_group_names = toset(data.terraform_remote_state.eks.outputs.node_contract.autoscaling_group_names) # 예: ["eks-contract2whale-dev-eks-system-0ac12345-…"] (운영 도구 시점 1개)

  # 알림 루트 모듈(알림 루트 모듈과 설치 검사)이 만든 경보 토픽 ARN 입니다. 공개 ARN 입력의 기본값은 null이며, 알림 적용 후 입력을 검토하여 연결합니다.
  alerts_topic_arn = var.alerts_topic_arn # 예: "arn:aws:sns:ap-northeast-2:111111111111:contract2whale-dev-alerts" 또는 null
}
