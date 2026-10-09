# main.tf — platform/app-auth 루트 모듈 (dev · prod 공통 코드)
# 브라우저에서 이메일만 넣으면 누구나 가입하는 설정으로 바꾸지 않습니다 (allow_admin_create_user_only = true). 관리자는 콘솔에서 승인된 팀 사용자만 만듭니다.

locals {
  api_identifier = "course-api"                                                                               # 예: resource server identifier (scope 앞부분)
  api_scope      = "${local.api_identifier}/tasks"                                                            # 예: "course-api/tasks" (access token 의 scope 값)
  issuer         = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.team.id}"         # 예: JWT iss (SecurityPolicy jwt.providers[].issuer)
  hosted_ui      = "https://${aws_cognito_user_pool_domain.team.domain}.auth.${var.region}.amazoncognito.com" # 예: hosted UI · token endpoint 의 origin
}

resource "aws_cognito_user_pool" "team" {
  name                     = "course-${var.environment}-team" # 예: "course-dev-team"
  deletion_protection      = "INACTIVE"                       # 예: INACTIVE (실습 down 에서 삭제 가능; 운영 환경은 ACTIVE 검토)
  username_attributes      = ["email"]                        # 예: 이메일을 사용자 이름으로 사용
  auto_verified_attributes = ["email"]                        # 예: 이메일 확인 코드 사용

  admin_create_user_config {
    allow_admin_create_user_only = true # 예: true (self sign-up 차단; 미등록 사용자의 가입 시도는 거절됨)
  }

  password_policy {
    minimum_length                   = 12   # 예: 12자 이상
    require_lowercase                = true # 예: 소문자 필수
    require_uppercase                = true # 예: 대문자 필수
    require_numbers                  = true # 예: 숫자 필수
    require_symbols                  = true # 예: 기호 필수
    temporary_password_validity_days = 7    # 예: 관리자가 만든 임시 비밀번호 유효 기간
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email" # 예: 확인된 이메일로만 복구
      priority = 1
    }
  }
}

resource "aws_cognito_user_pool_domain" "team" {
  domain       = var.domain_prefix             # 예: "course-111111111111-dev" → https://course-111111111111-dev.auth.ap-northeast-2.amazoncognito.com
  user_pool_id = aws_cognito_user_pool.team.id # 예: "ap-northeast-2_AbCdEfGhI"
}

# access token 의 scope 는 resource server 의 <identifier>/<scope_name> 형식입니다. Gateway SecurityPolicy 가 이 값을 요구합니다.
resource "aws_cognito_resource_server" "api" {
  user_pool_id = aws_cognito_user_pool.team.id # 예: 같은 pool
  identifier   = local.api_identifier          # 예: "course-api"
  name         = local.api_identifier          # 예: "course-api"

  scope {
    scope_name        = "tasks" # 예: "tasks" → scope "course-api/tasks"
    scope_description = "Task list, create, complete, delete and export"
  }
}

# SPA client: secret 없음 + authorization code(PKCE). 브라우저는 /ui/config.json 의 auth 객체로 이 값을 읽습니다.
resource "aws_cognito_user_pool_client" "ui" {
  name                                 = "course-${var.environment}-ui" # 예: "course-dev-ui"
  user_pool_id                         = aws_cognito_user_pool.team.id
  generate_secret                      = false                                               # 예: false (public client; 브라우저에 secret 을 두지 않음)
  allowed_oauth_flows_user_pool_client = true                                                # 예: hosted UI OAuth 사용
  allowed_oauth_flows                  = ["code"]                                            # 예: authorization code (PKCE)
  allowed_oauth_scopes                 = ["openid", local.api_scope]                         # 예: ["openid", "course-api/tasks"]
  supported_identity_providers         = ["COGNITO"]                                         # 예: pool 사용자만 (외부 IdP 없음)
  callback_urls                        = ["${var.ui_origin}/ui/callback"]                    # 예: https://dev.playdevops.click:8443/ui/callback
  logout_urls                          = ["${var.ui_origin}/ui/"]                            # 예: https://dev.playdevops.click:8443/ui/
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_SRP_AUTH"] # 예: hosted UI 외 SRP 만 (평문 비밀번호 흐름 없음)
  prevent_user_existence_errors        = "ENABLED"                                           # 예: 존재 여부를 오류 문장으로 흘리지 않음
  access_token_validity                = 60                                                  # 예: 60분
  id_token_validity                    = 60                                                  # 예: 60분
  refresh_token_validity               = 8                                                   # 예: 8시간

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "hours"
  }

  depends_on = [aws_cognito_resource_server.api] # 예: scope 가 존재한 뒤에 client 를 만듦
}

# M2M client: secret 있음 + client_credentials. CodeBuild 자동 검증기(애플리케이션 데이터/14 delivery)만 Secrets Manager 에서 secret 을 읽습니다.


resource "aws_secretsmanager_secret" "verifier" {
  name                    = "course/${var.environment}/verifier-client" # 예: "course/dev/verifier-client"
  description             = "Cognito M2M client for the automated verifier (CodeBuild reads client_secret)."
  recovery_window_in_days = 0 # 예: 0 (실습 down 에서 즉시 삭제; 운영 환경은 7~30 검토)
}



# 이 디렉터리는 dev 만 받습니다. input 은 State 에 남는 marker 이며 AWS 자원을 만들지 않습니다.
resource "terraform_data" "environment_boundary" {
  input = var.environment # 예: "dev"

  lifecycle {
    precondition {
      condition     = var.environment == "dev" # 예: "dev" 통과 / "prod" 거부 (prod 는 prod/platform/app-auth 디렉터리)
      error_message = "This directory accepts only the dev environment."
    }

    precondition {
      condition     = terraform.workspace == "default" # 예: workspace 로 환경을 나누지 않음
      error_message = "Use default workspace and a distinct backend key."
    }
  }
}
