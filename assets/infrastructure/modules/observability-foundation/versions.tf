# versions.tf — modules/observability-foundation (dev · prod 루트 모듈이 공유하는 모듈)

terraform {
  required_version = "= 1.16.0" # 예: "= 1.16.0" (등호로 정확한 버전 고정; 루트 모듈과 같은 값)

  required_providers {
    aws = {
      source  = "hashicorp/aws" # 예: "hashicorp/aws" (공식 레지스트리 경로)
      version = "= 6.62.0"      # 예: "= 6.62.0" (앞 챕터 모듈과 같은 값)
    }
  }
}
