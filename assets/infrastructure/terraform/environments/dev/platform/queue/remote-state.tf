# remote-state.tf — platform/queue 루트 모듈 (dev · prod 공통 코드)
# 권한 모델과 토픽 사전 생성: 앞 루트 모듈 2곳(network/vpc · eks)의 root 출력을 State 에서 직접 읽습니다. upstream.auto.tfvars.json 같은 입력 파일을 만들지 않습니다 (P1).
# 읽는 쪽에는 State 객체의 s3:GetObject 권한이 필요합니다 (관련 구성 account-baseline 의 State 역할 key 목록과 대조).

# 관련 구성 · 관련 구성 워크로드 VPC 루트 모듈입니다. 관리형 메시지 큐의 네트워크 경계 이 더한 kafka_network_contract 와 브로커 서브넷 CIDR 을 읽습니다.
data "terraform_remote_state" "network" {
  backend = "s3" # 예: "s3"

  config = {
    bucket = var.state_bucket_name           # 예: "company-dev-tfstate-111111111111"
    key    = "network/vpc/terraform.tfstate" # 예: network/vpc 루트 모듈의 key
    region = var.region                      # 예: "ap-northeast-2"
  }

  lifecycle {
    postcondition {
      condition = alltrue([
        for name in ["broker_security_group_id", "client_security_group_id", "broker_subnet_ids_by_az", "broker_port"] :
        contains(keys(try(self.outputs.kafka_network_contract, {})), name) # 예: 네 키 모두 존재
      ])
      error_message = "network/vpc state must expose kafka_network_contract with its four fields (apply 관리형 메시지 큐의 네트워크 경계 first)."
    }

    postcondition {
      condition     = length(try(self.outputs.kafka_broker_subnet_cidrs_by_az, {})) == 3 # 예: AZ 3개의 CIDR
      error_message = "network/vpc state must expose kafka_broker_subnet_cidrs_by_az for three availability zones."
    }
  }
}

# 클러스터 접속 · 노드와 Add-on 의 EKS 루트 모듈입니다. 실제 Pod 트래픽이 쓰는 노드 Security Group 만 읽습니다.
data "terraform_remote_state" "eks" {
  backend = "s3" # 예: "s3"

  config = {
    bucket = var.state_bucket_name   # 예: 같은 Dev State 버킷
    key    = "eks/terraform.tfstate" # 예: eks 루트 모듈의 key (클러스터 입력과 네트워크 계약 · 노드와 Add-on 노드 구성도 같은 key)
    region = var.region
  }

  lifecycle {
    postcondition {
      condition     = can(regex("^sg-[0-9a-f]+$", try(self.outputs.node_security_group_id, ""))) # 예: "sg-0nodes..."
      error_message = "eks state must expose node_security_group_id (apply 루트 모듈 연결과 노드 계약 first)."
    }

    postcondition {
      condition     = try(self.outputs.cluster_name, "") != "" # 예: "contract2whale-dev-eks"
      error_message = "eks state must expose cluster_name (apply 생성 계획과 private API 검증 first)."
    }
  }
}
