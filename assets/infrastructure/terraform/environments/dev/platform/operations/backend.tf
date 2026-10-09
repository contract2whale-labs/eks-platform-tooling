# backend.tf — platform/operations 루트 모듈 (dev · prod 공통 코드)
# 운영 기반 루트 모듈과 계약: backend 인자는 커밋하지 않는 backend.hcl 이 제공합니다 (terraform init -backend-config=backend.hcl).
# key 는 platform/operations/terraform.tfstate 로 실행 디렉터리 경로 규칙을 따릅니다 (원본 platform/operations/dev/terraform.tfstate — P2; eks · platform/core 와 같은 버킷).

terraform {
  backend "s3" {}
}
