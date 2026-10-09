# versions.tf — platform/queue 루트 모듈 (dev · prod 공통 코드)
# 권한 모델과 토픽 사전 생성: 실행 파일과 provider 버전을 모듈과 같은 값으로 고정합니다.

terraform {
  required_version = "= 1.16.0" # 예: "= 1.16.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws" # 예: "hashicorp/aws"
      version = "= 6.62.0"      # 예: "= 6.62.0"
    }
  }
}
