# remote-state.tf — data 루트 모듈 (dev · prod 공통 코드)
# 데이터 루트 모듈과 PostgreSQL 버전 고정: 앞 루트 모듈 세 곳(eks · network/vpc · delivery)의 root 출력을 State 에서 직접 읽습니다 (P1). 입력 파일(upstream.auto.tfvars.json)을 만들지 않습니다.
# 읽는 쪽에는 State 객체 전체의 s3:GetObject 권한이 필요합니다 (관련 구성 의 State 역할 key 목록과 대조: eks · network/vpc · delivery 의 terraform.tfstate).

data "terraform_remote_state" "eks" {
  backend = "s3" # 예: "s3" (앞 루트 모듈이 State 를 둔 방식)

  config = {
    bucket = var.state_bucket_name   # 예: "company-dev-tfstate-111111111111"
    key    = "eks/terraform.tfstate" # 예: eks 루트 모듈의 key (클러스터 입력과 네트워크 계약)
    region = var.region              # 예: "ap-northeast-2"
  }

  lifecycle {
    postcondition {
      condition = alltrue([
        for name in ["name", "arn", "region", "vpc_id"] :
        contains(keys(try(self.outputs.cluster_contract, {})), name)         # 예: 4개 모두 cluster_contract 에 존재
      ]) && can(regex("^sg-", try(self.outputs.node_security_group_id, ""))) # 예: "sg-…" (노드와 Add-on 노드 SG)
      error_message = "eks state must expose cluster_contract (name, arn, region, vpc_id) and node_security_group_id (apply 생성 계획과 private API 검증 and 노드와 Add-on first)."
    }
  }
}

data "terraform_remote_state" "network" {
  backend = "s3" # 예: "s3"

  config = {
    bucket = var.state_bucket_name           # 예: 같은 버킷
    key    = "network/vpc/terraform.tfstate" # 예: network/vpc 루트 모듈의 key (출력 계약과 계약 테스트)
    region = var.region                      # 예: "ap-northeast-2"
  }

  lifecycle {
    postcondition {
      condition     = length(try(self.outputs.private_subnet_ids, [])) >= 2 && length(try(self.outputs.intra_subnet_ids, [])) >= 2 && can(regex("^vpc-", try(self.outputs.vpc_id, ""))) && can(cidrhost(try(self.outputs.vpc_cidr_block, ""), 0)) # 예: Private 3 · Intra 3 · "vpc-…" · "172.20.0.0/16"
      error_message = "network/vpc state must expose vpc_id, vpc_cidr_block, at least two private_subnet_ids and at least two intra_subnet_ids (apply 출력 계약과 계약 테스트 first)."
    }
  }
}

# 배포 플랫폼 의 배포 전달 루트 모듈입니다. 앱 좌표(네임스페이스 · Deployment · migration ServiceAccount)를 여기서 읽어 같은 값을 두 번 적지 않습니다.
# application 좌표와 기존 Kyverno 역할 ARN을 읽습니다. operator ECR 읽기 정책은 data apply에서 연결합니다
# migration Role은 identity root가 이름으로 별도 조회합니다.
data "terraform_remote_state" "delivery" {
  backend = "s3" # 예: "s3"

  config = {
    bucket = var.state_bucket_name        # 예: 같은 버킷
    key    = "delivery/terraform.tfstate" # 예: delivery 루트 모듈의 key (루트 모듈과 적용 에서 이미 적용)
    region = var.region                   # 예: "ap-northeast-2"
  }

  lifecycle {
    postcondition {
      condition = contains(keys(try(self.outputs.delivery_contract.application, {})), "namespace") && alltrue([
        for name in ["deployment", "migration_service_account"] :
        contains(keys(try(self.outputs.delivery_contract.application.api, {})), name)                                                                                                                # 예: 두 이름 모두 application.api 에 존재 (워크로드 둘 중 데이터에 닿는 쪽)
      ]) && can(regex("^arn:aws:iam::[0-9]{12}:role/platform/", try(self.outputs.delivery_contract.kyverno.role_arn, ""))) && try(self.outputs.delivery_contract.environment, "") == var.environment # 예: 같은 환경의 계약인지
      error_message = "delivery state must expose delivery_contract.application.namespace and application.api (deployment, migration_service_account) and kyverno.role_arn for this environment (apply dev/delivery first — 루트 모듈과 적용)."
    }
  }
}
