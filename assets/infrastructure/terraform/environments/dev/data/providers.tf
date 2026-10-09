# providers.tf — data 루트 모듈 (dev · prod 공통 코드)
# 데이터 루트 모듈과 PostgreSQL 버전 고정: AWS API 만 사용합니다 (Kubernetes 자료는 승인된 GitOps Application이 적용). 리전 · 계정은 State 조회 결과가 아니라 변수로 받고, 모듈의 terraform_data.guard 가 클러스터 계약과 대조합니다.

provider "aws" {
  region              = var.region                # 예: "ap-northeast-2" (서울 리전; cluster_contract.region 과 같아야 함)
  allowed_account_ids = [var.expected_account_id] # 예: ["111111111111"] (다른 계정이면 실행을 거부)

  # 지원되는 AWS 리소스에 공통 분류 태그를 전달합니다. IAM 권한이 아닙니다.
  default_tags {
    tags = {
      ManagedBy   = "Terraform" # 예: "Terraform" (수동 생성 리소스와 구분)
      Environment = var.environment
      Component   = "data" # 예: "data" (이 루트 모듈이 만든 리소스에 공통으로 붙는 값)
    }
  }
}
