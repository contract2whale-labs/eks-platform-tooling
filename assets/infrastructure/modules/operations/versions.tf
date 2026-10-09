# versions.tf — modules/operations (dev · prod 루트 모듈이 공유하는 모듈)
# Controller 신원과 저장소: 운영 도구 4종(Cluster Autoscaler · External Secrets · Fluent Bit · Velero)의 AWS 리소스만 Terraform 으로 관리합니다. Helm · Kubernetes provider 는 사용하지 않습니다.
# 과정 내부 전용 모듈이라 루트 모듈과 같은 값을 등호로 고정합니다 (P7). provider 블록은 두지 않습니다 (인증 · 리전 · default_tags 는 루트 모듈의 providers.tf 가 담당).

terraform {
  required_version = "= 1.16.0" # 예: "= 1.16.0" (도구 저장소 tool-versions 고정값과 동일)

  required_providers {
    aws = {
      source  = "hashicorp/aws" # 예: "hashicorp/aws" (공식 레지스트리 경로)
      version = "= 6.62.0"      # 예: "= 6.62.0" (과정 전체의 provider 고정값)
    }
  }
}
