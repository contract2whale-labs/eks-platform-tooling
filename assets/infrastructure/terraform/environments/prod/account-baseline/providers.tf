# providers.tf — account-baseline 루트 모듈 (dev · prod 공통 코드)
# 리소스 생성은 기존 운영자의 임시 인증(AWS_PROFILE 의 SSO 세션)을 사용합니다.
# 이 구성에서 만드는 State 역할을 provider 역할로 쓰지 않습니다.

provider "aws" {
  region              = var.region                # 예: "ap-northeast-2" (API 호출 대상 리전; IAM · Route 53 은 글로벌 서비스)
  allowed_account_ids = [var.expected_account_id] # 예: ["111111111111"] (다른 계정 인증 시 즉시 중단)

  default_tags {
    tags = {
      ManagedBy   = "Terraform"        # 예: "Terraform" (관리 주체 표시)
      Component   = "account-baseline" # 예: "account-baseline" (어느 구성이 만든 것인지 표시)
      Environment = var.environment    # 예: "dev" (환경 구분; 비용 배분 태그로도 사용)
    }
  }
}
