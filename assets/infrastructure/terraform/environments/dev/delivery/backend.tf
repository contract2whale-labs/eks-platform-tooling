# backend.tf — delivery 루트 모듈 (dev · prod 공통 코드)
# 루트 모듈과 적용: backend 인자는 커밋하지 않는 backend.hcl 이 제공합니다 (terraform init -backend-config=backend.hcl).
# key 는 delivery/terraform.tfstate 로 실행 디렉터리 경로 규칙을 따릅니다 (버킷이 환경별이라 prod 도 같은 key). State 잠금(S3 lockfile)은 Terraform 실행 사이의 잠금이고, 배포 적용 순서는 승인 revision의 Argo CD sync·wave·완료 상태로 확인합니다. Git 커밋 순서만으로 실제 완료 순서를 보장하지 않습니다.

terraform {
  backend "s3" {}
}
