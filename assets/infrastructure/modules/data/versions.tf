# versions.tf — modules/data (dev · prod 루트 모듈이 공유하는 모듈)
# 데이터베이스 · KMS 키 · 시크릿 · 미디어 버킷: 앱 데이터 기반 — 키 · 데이터베이스 · 시크릿 · 내보내기 저장소 · 운영자 이미지 저장소를 관리하는 모듈입니다.
# 과정 내부 전용 모듈이라 루트 모듈과 같은 값을 등호로 고정합니다 (P7). provider 블록은 두지 않습니다 (인증 · 리전 · default_tags 는 데이터 루트 모듈과 PostgreSQL 버전 고정 루트 모듈의 providers.tf 가 담당).

terraform {
  required_version = "= 1.16.0" # 예: "= 1.16.0" (도구 저장소 tool-versions 고정값과 동일)

  required_providers {
    aws = {
      source  = "hashicorp/aws" # 예: "hashicorp/aws" (공식 레지스트리 경로)
      version = "= 6.62.0"      # 예: "= 6.62.0" (과정 전체의 provider 고정값)
    }
  }
}
