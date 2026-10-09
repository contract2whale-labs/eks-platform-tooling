# remote-state.tf — account-integrations 루트 모듈 (dev · prod 공통 코드)
# 환경 root 와 실제 적용: 앞 루트 모듈 두 곳(network/vpc · platform/operations)의 root 출력을 State 에서 직접 읽습니다 (P1). upstream.auto.tfvars.json 같은 입력 파일을 만들지 않습니다.
# 읽는 쪽에는 State 객체의 s3:GetObject 권한이 필요합니다 (관련 구성 의 State 역할 key 목록과 대조: network/vpc/terraform.tfstate · platform/operations/terraform.tfstate).
# network/transit State 는 읽지 않습니다 — 이 루트 모듈은 TGW · Firewall 의 존재를 요구하지 않으며 transit 은 down.sh 로 비워질 수 있습니다.

# 관련 구성 · 관련 구성 의 네트워크 루트 모듈입니다. locals.tf 가 로그 버킷 이름 · ARN 두 출력을 network_logs_contract 로 묶습니다.
data "terraform_remote_state" "vpc" {
  backend = "s3" # 예: "s3" (앞 루트 모듈이 State 를 둔 방식)

  config = {
    bucket = var.state_bucket_name           # 예: "company-dev-tfstate-111111111111"
    key    = "network/vpc/terraform.tfstate" # 예: network/vpc 루트 모듈의 key (루트 모듈 분리와 입력 계약)
    region = var.region                      # 예: "ap-northeast-2"
  }

  lifecycle {
    # 출력 계약과 계약 테스트 의 로그 버킷 출력 두 개가 모두 있어야 합니다 (flow/ · dns/ 로그를 받는 버킷).
    postcondition {
      condition     = can(self.outputs.network_logs_bucket_name) && can(self.outputs.network_logs_bucket_arn) # 예: 두 출력 모두 존재
      error_message = "network/vpc state must expose network_logs_bucket_name and network_logs_bucket_arn (apply 출력 계약과 계약 테스트 first)."
    }
  }
}

data "terraform_remote_state" "operations" {
  backend = "s3" # 예: "s3"

  config = {
    bucket = var.state_bucket_name                   # 예: "company-dev-tfstate-111111111111" (같은 버킷)
    key    = "platform/operations/terraform.tfstate" # 예: platform/operations 루트 모듈의 key (운영 기반 루트 모듈과 계약; 원본 platform/operations/dev/terraform.tfstate — P2)
    region = var.region                              # 예: "ap-northeast-2"
  }

  lifecycle {
    postcondition {
      condition = alltrue([
        for name in ["account_id", "cluster_name", "region", "platform_log_group_name", "velero_bucket_name", "velero_bucket_arn", "alerts_topic_arn"] :
        contains(keys(try(self.outputs.operations_contract, {})), name) # 예: 7개 모두 operations_contract 에 존재
      ])
      error_message = "platform/operations state must expose operations_contract with its seven items (apply 운영 기반 루트 모듈과 계약 first)."
    }

    # 로그량 알람의 dimension 이므로 fluent_bit 을 끈 운영 기반 구성(platform_log_group_name = null)은 받지 않습니다.
    postcondition {
      condition     = try(self.outputs.operations_contract.platform_log_group_name, null) != null # 예: "/platform/contract2whale-dev-eks/application"
      error_message = "operations_contract.platform_log_group_name must not be null (enable fluent_bit in platform/operations)."
    }
  }
}
