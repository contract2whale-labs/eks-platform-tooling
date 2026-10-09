# versions.tf — modules/account-integrations (dev · prod 루트 모듈이 공유하는 모듈)
# 상위 출력을 받는 입력과 보고 버킷: 플랫폼 구성(운영 도구 운영 기반) 이후에 계정 단위로 붙는 연동 리소스(보고 버킷 · 알람 · SNS · 선택 외부 로그 소비자)를 관리하는 모듈입니다.
# 과정 내부 전용 모듈이라 루트 모듈과 같은 값을 등호로 고정합니다 (P7). provider 블록은 두지 않습니다 (인증 · 리전 · default_tags 는 환경 root 와 실제 적용 루트 모듈의 providers.tf 가 담당).

terraform {
  required_version = "= 1.16.0" # 예: "= 1.16.0" (도구 저장소 tool-versions 고정값과 동일)

  required_providers {
    aws = {
      source  = "hashicorp/aws" # 예: "hashicorp/aws" (공식 레지스트리 경로)
      version = "= 6.62.0"      # 예: "= 6.62.0" (과정 전체의 provider 고정값)
    }
  }
}
