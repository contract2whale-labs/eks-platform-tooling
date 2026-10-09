# providers.tf — modules/observability-foundation (dev · prod 루트 모듈이 공유하는 모듈)
# 관측 저장소와 Pod Identity 연결: 자격 증명은 루트 모듈의 provider 가 받습니다 (이 모듈은 provider 블록을 두지 않음). 다른 환경의 계약이 섞여 들어오면 저장소를 만들기 전에 멈춥니다.

resource "terraform_data" "contract" {
  input = var.cluster_contract.arn # 예: "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks" (State 에 남는 marker)

  lifecycle {
    precondition {
      condition     = terraform.workspace == "default" # 예: 작업 공간을 나누지 않음 (backend key 로 환경 구분)
      error_message = "Use the default workspace and a distinct backend key for this root."
    }

    precondition {
      # 예: 계약의 ARN 이 계정 · 리전 · 이름으로 조립한 값과 같고, 리전과 Kubernetes 버전이 입력과 같아야 통과
      condition     = var.cluster_contract.arn == "arn:aws:eks:${var.region}:${var.expected_account_id}:cluster/${var.cluster_contract.name}" && var.cluster_contract.region == var.region && var.cluster_contract.kubernetes_version == "1.36"
      error_message = "cluster_contract must describe an EKS 1.36 cluster in this account and region."
    }

    precondition {
      # 예: 운영 기반 계약이 같은 계정 · 리전 · 클러스터의 것이어야 통과
      condition     = var.operations_contract.account_id == var.expected_account_id && var.operations_contract.region == var.region && var.operations_contract.cluster_name == var.cluster_contract.name
      error_message = "operations_contract belongs to a different account, region or cluster."
    }

    precondition {
      # 예: 노드 시스템 로그 그룹 이름이 이 클러스터 이름으로 조립한 값과 같아야 통과 (운영 도구 fluent_bit 을 켠 상태)
      condition     = var.operations_contract.platform_log_group_name == "/platform/${var.cluster_contract.name}/application"
      error_message = "operations_contract.platform_log_group_name must be /platform/<cluster>/application (enable fluent_bit in 운영 도구)."
    }

    precondition {
      condition     = contains(var.allowed_state_keys, local.state_key)
      error_message = "Add platform/observability/terraform.tfstate to additional_state_object_keys of the account-baseline root first (관측 State key 와 저장소 역할)."
    }
  }
}

locals {
  state_key = "platform/observability/terraform.tfstate" # 예: 이 루트 모듈의 backend key (P2: 실행 디렉터리 경로 규칙; dev · prod 가 각자 버킷에서 같은 key 사용)
}
