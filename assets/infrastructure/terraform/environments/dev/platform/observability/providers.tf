# providers.tf — platform/observability 루트 모듈 (dev · prod 공통 코드)
# 관측 루트 모듈과 계약: AWS API 만 사용합니다. Prometheus · Thanos · Loki의 chart와 정책은 승인 GitOps Application이 설치하며 Kubernetes provider는 두지 않습니다.
# 리전은 계약(cluster_contract.region)이 아니라 변수로 받습니다. provider 설정이 State 조회 결과에 의존하지 않게 하고, 변수 validation 과 모듈 validation 이 둘 다 ap-northeast-2 로 고정합니다.

provider "aws" {
  region              = var.region                # 예: "ap-northeast-2" (서울 리전; cluster_contract.region 과 같아야 함)
  allowed_account_ids = [var.expected_account_id] # 예: ["111111111111"] (다른 계정이면 실행을 거부)

  # 지원되는 AWS 리소스에 공통 분류 태그를 전달합니다. IAM 권한이 아닙니다.
  default_tags {
    tags = {
      ManagedBy   = "Terraform"              # 예: "Terraform" (수동 생성 리소스와 구분)
      Environment = var.environment          # 예: "dev" (환경 구분)
      Component   = "platform-observability" # 예: "platform-observability" (이 루트 모듈이 만든 리소스에 공통으로 붙는 값)
    }
  }
}
