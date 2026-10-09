mock_provider "aws" {}
variables {
  expected_account_id = "111111111111"
  region              = "ap-northeast-2"
  environment         = "dev"
  state_bucket_name   = "fixture-dev-state"
}
override_data {
  target = data.terraform_remote_state.queue
  values = { outputs = { queue_managed_contract = {
    secret_arns = {
      reader = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:AmazonMSK_reader-fixture"
      writer = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:AmazonMSK_writer-fixture"
    }
    kms_key_arn = "arn:aws:kms:ap-northeast-2:111111111111:key/fixture"
  } } }
}
override_data {
  target = data.terraform_remote_state.operations
  values = { outputs = { external_secrets_role_arn = "arn:aws:iam::111111111111:role/platform/fixture-eso" } }
}
run "trust_only_eso_identity" {
  command = plan
  assert {
    condition     = jsondecode(aws_iam_role.queue_secret_reader.assume_role_policy).Statement[0].Principal.AWS == "arn:aws:iam::111111111111:role/platform/fixture-eso" && jsondecode(aws_iam_role.queue_secret_reader.assume_role_policy).Statement[0].Condition.StringEquals["aws:PrincipalTag/kubernetes-namespace"] == "external-secrets"
    error_message = "Only the approved ESO identity may assume the reader."
  }
  assert {
    condition     = toset(jsondecode(aws_iam_role_policy.read_queue_credentials.policy).Statement[0].Resource) == toset(["arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:AmazonMSK_reader-fixture", "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:AmazonMSK_writer-fixture"]) && jsondecode(aws_iam_role_policy.read_queue_credentials.policy).Statement[1].Condition.StringEquals["kms:ViaService"] == "secretsmanager.ap-northeast-2.amazonaws.com"
    error_message = "Secret access must be limited to the queue credentials and the Secrets Manager KMS path."
  }
}
run "reject_other_environment" {
  command = plan
  variables { environment = "prod" }
  expect_failures = [var.environment]
}
