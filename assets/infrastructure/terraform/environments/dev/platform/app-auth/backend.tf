# backend.tf — platform/app-auth 루트 모듈 (dev · prod 공통 코드)
# 팀 로그인과 API 인가: backend 인자는 커밋하지 않는 backend.hcl 이 제공합니다 (terraform init -backend-config=backend.hcl).
# key 는 platform/app-auth/terraform.tfstate 로 실행 디렉터리 경로 규칙을 따릅니다 (원본의 platform/app-auth/<환경>/… 를 P2 규칙으로 바꿈). 새 State에는 공개 client ID와 자원 좌표만 남습니다. 계정 보안 정보이므로 이 key의 읽기 권한은 승인된 구축 역할로 한정합니다.

terraform {
  backend "s3" {}
}
