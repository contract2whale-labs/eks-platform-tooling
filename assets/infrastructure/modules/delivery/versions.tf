# versions.tf — modules/delivery (dev · prod 루트 모듈이 공유하는 모듈)
# 이미지 리포지토리와 서명 키: 이미지 리포지토리(ECR) · 서명 키(KMS) · CI IAM 역할(GitHub OIDC Role) · 배포용 IAM 역할(Pod Identity) 을 Terraform 으로 관리합니다. 클러스터 안의 Argo CD · Argo Rollouts · Kyverno 는 고정 chart와 GitOps Application으로 설치합니다.
# 과정 내부 전용 모듈이라 루트 모듈과 같은 값을 등호로 고정합니다. provider 블록은 두지 않습니다 (인증 · 리전 · default_tags 는 루트 모듈의 providers.tf 가 담당).

terraform {
  required_version = "= 1.16.0" # 예: "= 1.16.0" (등호로 정확한 버전 고정)

  required_providers {
    aws = {
      source  = "hashicorp/aws" # 예: "hashicorp/aws" (공식 레지스트리 경로)
      version = "= 6.62.0"      # 예: "= 6.62.0" (aws_ecr_repository · aws_kms_key ECC_NIST_P256 · aws_eks_pod_identity_association 을 검증한 버전; 루트 모듈과 같은 값)
    }
  }
}
