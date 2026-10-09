# versions.tf — platform/app-auth 루트 모듈 (dev · prod 공통 코드)
# 팀 로그인과 API 인가: 팀 로그인(Cognito user pool · hosted UI domain · resource server · client 2)과 M2M secret(Secrets Manager)을 이 루트 모듈이 직접 관리합니다 (모듈 없음; 원본 assets/access/auth/main.tf 의 재작성).

terraform {
  required_version = "= 1.16.0" # 예: "= 1.16.0" (등호로 정확한 버전 고정)

  required_providers {
    aws = {
      source  = "hashicorp/aws" # 예: "hashicorp/aws" (공식 레지스트리 경로)
      version = "= 6.62.0"      # 예: "= 6.62.0" (다른 루트 모듈과 같은 값)
    }
  }
}
