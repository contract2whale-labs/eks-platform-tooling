# tests/auth.tftest.hcl — platform/app-auth 루트 모듈 (dev · prod 공통 코드)

mock_provider "aws" {}

variables {
  verifier_client_id  = "4example5m2mclientid6"
  expected_account_id = "111111111111"
  region              = "ap-northeast-2"
  environment         = "dev"
  domain_prefix       = "course-111111111111-dev"
  ui_origin           = "https://dev.playdevops.click:8443"
}

# mock apply의 공개 pool ID를 고정해 issuer와 JWKS 주소의 연결을 확인합니다.
override_resource {
  target = aws_cognito_user_pool.team
  values = { id = "ap-northeast-2_AbCdEfGhI" }
}

override_resource {
  target = aws_secretsmanager_secret.verifier
  values = { arn = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:course/dev/verifier-client-AbCdEf" }
}

# 1. 가입은 관리자만 허용하고, Terraform이 만드는 SPA는 secret 없는 code client입니다.
run "clients_follow_public_and_confidential_roles" {
  command = plan

  assert {
    condition     = aws_cognito_user_pool.team.admin_create_user_config[0].allow_admin_create_user_only == true
    error_message = "Self sign-up must stay disabled (admin creates approved team users)."
  }

  assert {
    condition     = aws_cognito_user_pool_client.ui.generate_secret == false && aws_cognito_user_pool_client.ui.allowed_oauth_flows == toset(["code"]) && aws_cognito_user_pool_client.ui.allowed_oauth_scopes == toset(["openid", "course-api/tasks"])
    error_message = "The UI client must be a public PKCE client with openid + course-api/tasks."
  }


  assert {
    condition     = aws_cognito_user_pool_client.ui.callback_urls == toset(["https://dev.playdevops.click:8443/ui/callback"]) && aws_cognito_user_pool_client.ui.logout_urls == toset(["https://dev.playdevops.click:8443/ui/"])
    error_message = "Callback and logout URLs must derive from ui_origin."
  }
}

# 2. 공개 출력의 scope, issuer/JWKS 연결과 허용 필드를 확인합니다. M2M client의 실제 생성은 보호된 API 작업이 검증합니다.
run "outputs_expose_scopes_without_secret" {
  command = apply

  assert {
    condition     = output.ui_auth.scope == "openid course-api/tasks" && output.verifier_auth.scope == "course-api/tasks"
    error_message = "ui_auth.scope must be 'openid course-api/tasks' and verifier_auth.scope 'course-api/tasks'."
  }

  assert {
    condition     = output.ui_auth.issuer == "https://cognito-idp.ap-northeast-2.amazonaws.com/ap-northeast-2_AbCdEfGhI" && output.ui_auth.jwks_uri == "https://cognito-idp.ap-northeast-2.amazonaws.com/ap-northeast-2_AbCdEfGhI/.well-known/jwks.json"
    error_message = "issuer and jwks_uri must follow the Cognito issuer format."
  }

  assert {
    condition = (
      toset(keys(output.ui_auth)) == toset(["issuer", "client_id", "scope", "authorization_endpoint", "token_endpoint", "logout_endpoint", "jwks_uri", "redirect_uri"]) &&
      toset(keys(output.verifier_auth)) == toset(["client_id", "scope", "token_endpoint", "secret_arn"]) &&
      output.verifier_auth.client_id == var.verifier_client_id &&
      output.verifier_auth.secret_arn == aws_secretsmanager_secret.verifier.arn
    )
    error_message = "Public auth outputs must expose reviewed settings and a Secret ARN, never client_secret or credential values."
  }

}

# 3. 이 디렉터리는 dev 만 받습니다.
run "reject_non_dev_environment" {
  command = plan

  variables {
    environment = "prod"
  }

  expect_failures = [terraform_data.environment_boundary]
}

# 4. hosted UI 접두어에 예약어가 있으면 거부합니다.
run "reject_reserved_domain_prefix" {
  command = plan

  variables {
    domain_prefix = "aws-course-dev"
  }

  expect_failures = [var.domain_prefix]
}

# 5. 평문(http) UI origin 은 거부합니다.
run "reject_plaintext_ui_origin" {
  command = plan

  variables {
    ui_origin = "http://dev.playdevops.click:8443"
  }

  expect_failures = [var.ui_origin]
}
