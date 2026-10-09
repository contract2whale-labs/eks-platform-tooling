# remote-state.tf — platform/observability 루트 모듈 (dev · prod 공통 코드)
# 관측 루트 모듈과 계약: 앞 루트 모듈 4곳(eks · platform/operations · network/vpc · account-baseline)의 root 출력을 State 에서 직접 읽습니다. upstream.auto.tfvars.json 같은 입력 파일을 만들지 않습니다 (P1).
# 읽는 쪽에는 State 객체 전체의 s3:GetObject 권한이 필요합니다 (관련 구성 의 State 역할 key 목록과 대조).

data "terraform_remote_state" "eks" {
  backend = "s3" # 예: "s3" (앞 루트 모듈이 State 를 둔 방식)

  config = {
    bucket = var.state_bucket_name   # 예: "company-dev-tfstate-111111111111"
    key    = "eks/terraform.tfstate" # 예: eks 루트 모듈의 key (클러스터 입력과 네트워크 계약; 노드와 Add-on 노드 구성 · 관측 노드 그룹과 taint 관측 노드 그룹도 같은 key)
    region = var.region              # 예: "ap-northeast-2"
  }

  lifecycle {
    postcondition {
      condition = alltrue([
        for name in ["name", "arn", "region", "kubernetes_version"] :
        contains(keys(try(self.outputs.cluster_contract, {})), name) # 예: 4개 모두 cluster_contract 에 존재
      ])
      error_message = "eks state must expose cluster_contract with name, arn, region and kubernetes_version (apply 생성 계획과 private API 검증 first)."
    }
  }
}

data "terraform_remote_state" "operations" {
  backend = "s3" # 예: "s3"

  config = {
    bucket = var.state_bucket_name                   # 예: "company-dev-tfstate-111111111111" (같은 버킷)
    key    = "platform/operations/terraform.tfstate" # 예: platform/operations 루트 모듈의 key (운영 기반 루트 모듈과 계약)
    region = var.region                              # 예: "ap-northeast-2"
  }

  lifecycle {
    postcondition {
      condition = alltrue([
        for name in ["account_id", "cluster_name", "region", "platform_log_group_name", "velero_bucket_name", "velero_bucket_arn", "alerts_topic_arn"] :
        contains(keys(try(self.outputs.operations_contract, {})), name) # 예: 7개 모두 operations_contract 에 존재
      ])
      error_message = "platform/operations state must expose operations_contract with its seven fields (apply 운영 기반 루트 모듈과 계약 first)."
    }
  }
}

data "terraform_remote_state" "vpc" {
  backend = "s3" # 예: "s3"

  config = {
    bucket = var.state_bucket_name           # 예: "company-dev-tfstate-111111111111"
    key    = "network/vpc/terraform.tfstate" # 예: network/vpc 루트 모듈의 key
    region = var.region                      # 예: "ap-northeast-2"
  }

  lifecycle {
    postcondition {
      condition     = try(self.outputs.vpc_id != null && self.outputs.network_logs_bucket_name != null, false) # 예: "vpc-…" · "cp-dev-network-logs-…"
      error_message = "network/vpc state must expose vpc_id and network_logs_bucket_name (apply 네트워크 로그 수집 first)."
    }
  }
}

data "terraform_remote_state" "account_baseline" {
  backend = "s3" # 예: "s3"

  config = {
    bucket = var.state_bucket_name                # 예: "company-dev-tfstate-111111111111"
    key    = "account-baseline/terraform.tfstate" # 예: account-baseline 루트 모듈의 key (관련 구성)
    region = var.region                           # 예: "ap-northeast-2"
  }

  lifecycle {
    postcondition {
      condition     = try(length(self.outputs.state_object_keys) >= 3, false) # 예: 기본 key 3개 이상 (관련 구성 locals.state_object_keys)
      error_message = "account-baseline state must expose state_object_keys (apply 두 계정의 State 역할과 최소 객체 권한 first)."
    }
  }
}
