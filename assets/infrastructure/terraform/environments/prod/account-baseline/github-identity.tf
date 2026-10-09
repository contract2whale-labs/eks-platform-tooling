# github-identity.tf — account-baseline 루트 모듈 (dev · prod 공통 코드)
# 계정당 GitHub OIDC provider 는 한 소유자만 관리합니다. 이미 존재하면 새로 만들지 않고 기존 ARN 을 입력합니다.
# 신규 · 기존 선택은 aws iam list-open-id-connect-providers 조회 결과로 실행자가 정합니다 (account).

variable "create_github_oidc" {
  description = "Create the account-wide GitHub OIDC provider; set false when another root already owns it."
  type        = bool
  default     = false # 기본값: false (기존 소유자 확인 후 명시적으로 생성)
  nullable    = false # 예: false (null 입력 차단)
}

variable "existing_github_oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider already present in this account, or null."
  type        = string
  default     = null # 기본값: null (신규 생성 경로에서는 반드시 null 이어야 함)

  validation {
    condition = var.existing_github_oidc_provider_arn == null ? true : (
      var.existing_github_oidc_provider_arn == "arn:aws:iam::${var.expected_account_id}:oidc-provider/token.actions.githubusercontent.com" # 예: 이 계정의 ARN 과 문자열 전체 비교
    )
    error_message = "GitHub OIDC provider must belong to this AWS account."
  }
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc ? 1 : 0 # 예: 신규 계정은 1, 기존 provider 사용 시 0

  url            = "https://token.actions.githubusercontent.com" # 예: GitHub Actions 토큰 발급자 URL (고정값)
  client_id_list = ["sts.amazonaws.com"]                         # 예: ["sts.amazonaws.com"] (토큰의 aud 클레임과 비교할 값)

  lifecycle {
    precondition {
      condition     = var.existing_github_oidc_provider_arn == null # 예: 새로 만들 때는 기존 ARN 이 비어 있어야 함
      error_message = "Choose creation or an existing provider, not both."
    }
  }
}

output "github_oidc_provider_arn" {
  description = "Public identifier of the GitHub OIDC provider; not a token or access key."
  value       = var.create_github_oidc ? aws_iam_openid_connect_provider.github[0].arn : var.existing_github_oidc_provider_arn # 예: "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com"
}
