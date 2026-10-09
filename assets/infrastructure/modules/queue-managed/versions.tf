# versions.tf — modules/queue-managed (dev · prod 루트 모듈이 공유하는 모듈)
# 고객 관리 키와 시크릿, 클러스터: 관리형 메시지 큐(MSK Provisioned)의 고객 관리 키 · 사용자 시크릿 · 브로커 구성 · 클러스터를 한 모듈에서 관리합니다. Terraform 과 AWS provider 를 한 버전으로 고정합니다.

terraform {
  required_version = "= 1.16.0" # 예: "= 1.16.0" (등호로 정확한 버전 고정; 루트 모듈과 같은 값)

  required_providers {
    aws = {
      source  = "hashicorp/aws" # 예: "hashicorp/aws" (공식 레지스트리 경로)
      version = "= 6.62.0"      # 예: "= 6.62.0" (앞 챕터 모듈과 같은 값)
    }
  }
}
