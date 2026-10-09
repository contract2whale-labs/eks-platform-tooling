# account-options.tf — account-baseline 루트 모듈 (dev · prod 공통 코드)
# 계정 전역 단일 설정 가운데 opt-in 으로만 관리하는 항목입니다. 기본값(false)에서는 리소스를 만들지 않습니다.

# 선택 가능한 계정 암호 정책입니다.
# IAM 사용자의 콘솔 암호에만 적용됩니다. SSO·MFA·access key 정책은 별개입니다.
resource "aws_iam_account_password_policy" "local_users" {
  count = var.manage_iam_password_policy ? 1 : 0 # 예: 기본 false → 0개 / true → 1개 (계정 전역 단일 설정)

  minimum_password_length        = 14    # 예: 14 (이 과정의 최소 길이 예시)
  require_lowercase_characters   = true  # 예: true (소문자 포함 필수)
  require_uppercase_characters   = true  # 예: true (대문자 포함 필수)
  require_numbers                = true  # 예: true (숫자 포함 필수)
  require_symbols                = true  # 예: true (특수문자 포함 필수)
  allow_users_to_change_password = true  # 예: true (사용자 스스로 변경 허용; 별도 IAM 허용도 가능)
  password_reuse_prevention      = 24    # 예: 24 (최근 24개 재사용 금지; AWS 최댓값)
  max_password_age               = 0     # 예: 0 (주기적 만료 없음; 강제 변경은 패턴화를 유발)
  hard_expiry                    = false # 예: false (만료 후에도 사용자가 스스로 변경 가능)
}
