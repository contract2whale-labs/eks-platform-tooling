# providers.tf — modules/operations (dev · prod 루트 모듈이 공유하는 모듈)
# Controller 신원과 저장소: 이 모듈은 provider 블록을 선언하지 않습니다. 계정 · 리전은 운영 기반 루트 모듈과 계약 루트 모듈의 provider 가 결정합니다.
# terraform_data.contract 는 AWS 리소스를 만들지 않고, 잘못된 workspace · 계약 조합을 plan 단계에서 차단합니다 (모든 리소스가 depends_on 으로 이 검사를 기다림).

resource "terraform_data" "contract" {
  input = var.cluster_contract.arn # 예: "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"

  lifecycle {
    precondition {
      condition     = terraform.workspace == "default" # 예: default workspace 에서만 통과
      error_message = "default workspace와 운영 기반 전용 state key를 사용하세요."
    }

    precondition {
      condition = (
        var.cluster_contract.arn == "arn:aws:eks:${var.region}:${var.expected_account_id}:cluster/${var.cluster_contract.name}" && # 예: 계약 ARN 을 리전 · 계정 · 이름으로 다시 조립해 비교
        var.cluster_contract.region == var.region &&                                                                               # 예: 계약 리전 = 입력 리전
        var.cluster_contract.kubernetes_version == "1.36" &&                                                                       # 예: 과정 고정 버전 (클러스터 업그레이드 시 함께 수정)
        (!contains(var.enabled_services, "velero") || length(local.backup_bucket_name) <= 63)                                      # 예: 백업 버킷 이름은 S3 한도 63자 이내 (과정 이름 22자 → 57자)
      )
      error_message = "앞 구성의 실제 cluster 계약의 계정/리전/이름, Kubernetes 1.36, 백업 버킷 이름 63자 이내를 확인하세요."
    }
  }
}
