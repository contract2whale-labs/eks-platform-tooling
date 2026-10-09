# outputs.tf — account-baseline 루트 모듈 (dev · prod 공통 코드)
# 후속 루트 모듈(apps CI 접근)과 검토용 조회가 terraform_remote_state · terraform output 으로 읽는 출력 4개입니다.
# 공개 자식 Zone 의 출력(public_zone_*)은 account-baseline-dns 루트 모듈에 있습니다.

output "account_id" {
  description = "Expected account checked by the AWS provider during live execution."
  value       = var.expected_account_id # 예: "111111111111" (provider 의 allowed_account_ids 가 실제 인증 계정과 일치함을 이미 보장)
}

output "state_access_role_arn" {
  description = "Use only in S3 backend assume_role; this role cannot provision EKS/VPC."
  value       = aws_iam_role.terraform_state_access.arn # 예: "arn:aws:iam::111111111111:role/platform/cp-dev-terraform-state" (path 포함 전체 ARN)
}

output "state_object_keys" {
  description = "Exact permitted state keys; lock keys have .tflock appended."
  value       = local.state_object_keys # 예: ["account-baseline-dns/terraform.tfstate", "account-baseline/terraform.tfstate", "network/vpc/terraform.tfstate"]
}

output "state_access_policy_json" {
  description = "Rendered policy for review; contains identifiers, not credentials."
  value       = data.aws_iam_policy_document.state_access.json # 예: Statement 3개를 포함한 JSON 문자열 (계정 ID 와 버킷 이름 포함)
}
