# outputs.tf — platform/app-auth 루트 모듈 (dev · prod 공통 코드)

output "ui_auth" {
  description = "Public OAuth settings the SPA needs (issuer, client_id, scope, endpoints, redirect URI); no secret."
  value = {
    issuer                 = local.issuer                            # 예: https://cognito-idp.ap-northeast-2.amazonaws.com/ap-northeast-2_AbCdEfGhI
    client_id              = aws_cognito_user_pool_client.ui.id      # 예: "1example2uiclientid3"
    scope                  = "openid ${local.api_scope}"             # 예: "openid course-api/tasks"
    authorization_endpoint = "${local.hosted_ui}/oauth2/authorize"   # 예: hosted UI 로그인 주소
    token_endpoint         = "${local.hosted_ui}/oauth2/token"       # 예: code → token 교환 주소
    logout_endpoint        = "${local.hosted_ui}/logout"             # 예: 로그아웃 주소
    jwks_uri               = "${local.issuer}/.well-known/jwks.json" # 예: 공개 키 목록
    redirect_uri           = "${var.ui_origin}/ui/callback"          # 예: https://dev.playdevops.click:8443/ui/callback
  }
}

output "verifier_auth" {
  description = "M2M client settings for the automated verifier; the secret stays in Secrets Manager (secret_arn only)."
  value = {
    client_id      = var.verifier_client_id                 # 예: "4example5m2mclientid6"
    scope          = local.api_scope                        # 예: "course-api/tasks"
    token_endpoint = "${local.hosted_ui}/oauth2/token"      # 예: client_credentials 토큰 주소
    secret_arn     = aws_secretsmanager_secret.verifier.arn # 예: arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:course/dev/verifier-client-AbCdEf
  }
}

output "application_input_values" {
  description = "Public application origin and API scope for native routing and browser configuration."
  value = {
    ui_origin          = var.ui_origin
    ui_hostname        = split(":", trimprefix(var.ui_origin, "https://"))[0]
    api_scope          = local.api_scope
    backend_literal    = "MEDUSA_BACKEND_URL=${var.ui_origin}"
    store_cors_literal = "STORE_CORS=${var.ui_origin}"
    admin_cors_literal = "ADMIN_CORS=${var.ui_origin}"
    auth_cors_literal  = "AUTH_CORS=${var.ui_origin}"
  }
}

output "user_pool_id" {
  description = "Public Cognito user pool identifier for bounded diagnosis."
  value       = aws_cognito_user_pool.team.id
}
