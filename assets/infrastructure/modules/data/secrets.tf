# secrets.tf — modules/data (dev · prod 루트 모듈이 공유하는 모듈)
# aws_secretsmanager_secret_version · random_password 는 이 모듈에 없습니다 (있으면 비밀값이 State 에 남습니다). 관리자(master) 비밀은 RDS 가 만듭니다 — database.tf 의 manage_master_user_password.
# migration · runtime 은 데이터베이스 계정이라 초기화 Job 이 채우고, app 은 Medusa 의 JWT_SECRET · COOKIE_SECRET 이라 사람이 한 번 채웁니다 (둘 다 Terraform 이 만들지 않습니다).

resource "aws_secretsmanager_secret" "application" {
  for_each = local.application_secrets # 예: { migration = {…}, runtime = {…}, app = { name = "contract2whale/dev/commerce-api/app", purpose = "Medusa JWT_SECRET and COOKIE_SECRET" } }

  name                    = each.value.name                                                                           # 예: "contract2whale/dev/commerce-api/runtime"
  description             = "${each.value.purpose} for ${local.identifier}; written after apply, never by Terraform." # 예: "application database account for contract2whale-dev-eks-commercedb; …"
  kms_key_id              = aws_kms_key.data.arn                                                                      # 예: 데이터 키와 같은 고객 관리형 키
  recovery_window_in_days = 7                                                                                         # 예: 7 (삭제 예약 뒤 되돌릴 수 있는 기간; 0 으로 즉시 삭제하지 않음)

  depends_on = [terraform_data.guard] # 예: 계약 검사를 통과한 뒤에 만듭니다
}
