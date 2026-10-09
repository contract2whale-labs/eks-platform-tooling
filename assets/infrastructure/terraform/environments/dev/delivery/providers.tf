# providers.tf — delivery 루트 모듈 (dev · prod 공통 코드)
# 루트 모듈과 적용: AWS API 만 사용합니다 (클러스터 안의 Argo CD 는 bootstrap/argocd/bootstrap.py 가 최소 bootstrap을 1회 설치하고, 나머지 컴포넌트는 Argo CD 가 gitops/ 에서 동기화). 리전 · 계정은 변수로 받고, 모듈의 terraform_data.contract 가 클러스터 ARN 의 계정 · 리전과 대조합니다.

provider "aws" {
  region              = var.region                # 예: "ap-northeast-2" (서울 리전; cluster_contract.region 과 같아야 함)
  allowed_account_ids = [var.expected_account_id] # 예: ["111111111111"] (다른 계정이면 실행을 거부)

  # 지원되는 AWS 리소스에 공통 분류 태그를 전달합니다. IAM 권한이 아닙니다.
  default_tags {
    tags = {
      ManagedBy   = "Terraform"     # 예: "Terraform" (수동 생성 리소스와 구분)
      Environment = var.environment # 예: "dev" (환경 구분)
      Component   = "delivery"      # 예: "delivery" (이 루트 모듈이 만든 리소스에 공통으로 붙는 값)
    }
  }
}
