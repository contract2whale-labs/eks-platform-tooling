# remote-state.tf — platform/operations 루트 모듈 (dev · prod 공통 코드)
# 운영 기반 루트 모듈과 계약: 앞 루트 모듈(eks)의 root 출력을 State 에서 직접 읽습니다 (P1). upstream.auto.tfvars.json 같은 입력 파일을 만들지 않으며, 노드 그룹이 늘면 다음 plan 에 ASG 태그가 자동으로 나타납니다 (D7).
# 경보 토픽 ARN은 기본 null인 공개 입력입니다. 아직 없는 alerting State를 읽지 않으므로 최초 적용과 재개가 순환하지 않습니다.
# 읽는 쪽에는 State 객체의 s3:GetObject 권한이 필요합니다 (관련 구성 의 State 역할 key 목록과 대조: eks/terraform.tfstate).

data "terraform_remote_state" "eks" {
  backend = "s3" # 예: "s3" (앞 루트 모듈이 State 를 둔 방식)

  config = {
    bucket = var.state_bucket_name   # 예: "company-dev-tfstate-111111111111"
    key    = "eks/terraform.tfstate" # 예: eks 루트 모듈의 key (클러스터 입력과 네트워크 계약; 노드와 Add-on 노드 구성도 같은 key)
    region = var.region              # 예: "ap-northeast-2"
  }

  lifecycle {
    # 모듈 계약에 넣을 네 항목이 모두 있어야 합니다 (환경 root 와 모듈 연결 의 cluster_contract 출력).
    postcondition {
      condition = alltrue([
        for name in ["name", "arn", "region", "kubernetes_version"] :
        contains(keys(try(self.outputs.cluster_contract, {})), name) # 예: 4개 모두 cluster_contract 에 존재
      ])
      error_message = "eks state must expose cluster_contract with name, arn, region and kubernetes_version (apply 생성 계획과 private API 검증 first)."
    }

    postcondition {
      condition     = length(try(self.outputs.node_contract.autoscaling_group_names, [])) > 0 # 예: ["eks-contract2whale-dev-eks-system-…"] (노드와 Add-on 시점 1개)
      error_message = "eks state must expose node_contract.autoscaling_group_names with at least one ASG (apply 적용과 배치 실측 first)."
    }
  }
}

