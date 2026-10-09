# backend.tf — data 루트 모듈 (dev · prod 공통 코드)
# 데이터 루트 모듈과 PostgreSQL 버전 고정: backend 인자는 커밋하지 않는 backend.hcl 이 제공합니다 (terraform init -backend-config=backend.hcl).
# key 는 data/terraform.tfstate 로 실행 디렉터리 경로 규칙을 따릅니다 (P2; 버킷이 환경별이라 prod 도 같은 key). 이 State 에는 비밀값이 없지만 DB 주소 · ARN 이 있으므로 접근 권한은 다른 루트 모듈과 같게 관리합니다.

terraform {
  backend "s3" {}
}
