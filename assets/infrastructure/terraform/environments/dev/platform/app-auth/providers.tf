# providers.tf — platform/app-auth 루트 모듈 (dev · prod 공통 코드)

provider "aws" {
  region              = var.region                # 예: "ap-northeast-2" (Cognito user pool 리전)
  allowed_account_ids = [var.expected_account_id] # 예: ["111111111111"] (다른 계정이면 실행을 거부)

  default_tags {
    tags = {
      ManagedBy   = "Terraform"         # 예: "Terraform"
      Environment = var.environment     # 예: "dev"
      Component   = "platform-app-auth" # 예: "platform-app-auth"
    }
  }
}
