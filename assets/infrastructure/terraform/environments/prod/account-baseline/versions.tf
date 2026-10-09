# versions.tf — account-baseline 루트 모듈 (dev · prod 공통 코드)
# 계정 공통의 State 접근 역할 · 계정 옵션 · GitHub OIDC 를 관리하는 구성입니다. 공개 자식 Zone 은 account-baseline-dns 루트 모듈에 둡니다.

terraform {
  required_version = "= 1.16.0" # 예: "= 1.16.0" (등호로 정확한 버전 고정; >= 는 실행자마다 달라짐)

  required_providers {
    aws = {
      source  = "hashicorp/aws" # 예: "hashicorp/aws" (공식 레지스트리 경로)
      version = "= 6.62.0"      # 예: "= 6.62.0" (provider 기본값 변화로 인한 예기치 않은 교체 방지)
    }
  }
}
