# Cognito confidential client lifecycle belongs to automation/secrets/provision.py.
# Terraform consumes only the non-secret client ID and the secret container ARN.
locals {
  cognito_user_pool_id = element(split("/", var.cognito_issuer), length(split("/", var.cognito_issuer)) - 1)
}
