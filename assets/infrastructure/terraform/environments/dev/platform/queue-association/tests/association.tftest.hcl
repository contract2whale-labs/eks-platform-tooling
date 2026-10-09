mock_provider "aws" {}
variables {
  expected_account_id = "111111111111"
  region              = "ap-northeast-2"
  environment         = "dev"
  state_bucket_name   = "fixture-dev-state"
  credentials_receipt = {
    request_id         = "fixture-request-001", environment = "dev", account_id = "111111111111", region = "ap-northeast-2"
    secret_version_ids = { reader = "fixture-reader-version", writer = "fixture-writer-version" }
  }
}
override_data {
  target = data.terraform_remote_state.queue
  values = { outputs = { queue_managed_contract = {
    cluster_arn = "arn:aws:kafka:ap-northeast-2:111111111111:cluster/fixture/uuid"
    secret_arns = { reader = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:AmazonMSK_reader-fixture", writer = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:AmazonMSK_writer-fixture" }
  } } }
}
run "associate_only_reviewed_secret_references" {
  command = plan
  assert {
    condition     = toset(aws_msk_scram_secret_association.queue_user.secret_arn_list) == toset(["arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:AmazonMSK_reader-fixture", "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:AmazonMSK_writer-fixture"])
    error_message = "Association must carry only the approved reader/writer secret ARNs."
  }
}
run "reject_receipt_from_other_account" {
  command = plan
  variables {
    credentials_receipt = {
      request_id         = "fixture-request-001", environment = "dev", account_id = "222222222222", region = "ap-northeast-2"
      secret_version_ids = { reader = "fixture-reader-version", writer = "fixture-writer-version" }
    }
  }
  expect_failures = [aws_msk_scram_secret_association.queue_user]
}
