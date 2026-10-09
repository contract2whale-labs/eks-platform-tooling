# backend.tf — account-integrations 루트 모듈 (dev · prod 공통 코드)
# 환경 root 와 실제 적용: backend 인자는 커밋하지 않는 backend.hcl 이 제공합니다 (terraform init -backend-config=backend.hcl).
# key 는 account-integrations/terraform.tfstate 로 실행 디렉터리 경로 규칙을 따릅니다 (원본 account/integrations/dev/terraform.tfstate — P2; network/vpc · platform/operations 와 같은 버킷).

terraform {
  backend "s3" {}
}
