# backend.tf — platform/queue 루트 모듈 (dev · prod 공통 코드)
# 환경별 bucket 과 key 는 backend.hcl 로 전달합니다 (P2).

terraform {
  backend "s3" {} # 예: 빈 블록 (값은 terraform init -backend-config=backend.hcl 로 전달)
}
