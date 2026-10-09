# backend.tf — platform/observability 루트 모듈 (dev · prod 공통 코드)
# 관측 루트 모듈과 계약: backend 인자는 커밋하지 않는 backend.hcl 이 제공합니다 (terraform init -backend-config=backend.hcl). key 는 platform/observability/terraform.tfstate (P2).

terraform {
  backend "s3" {}
}
