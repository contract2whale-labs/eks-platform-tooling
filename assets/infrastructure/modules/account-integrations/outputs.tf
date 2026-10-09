# outputs.tf — modules/account-integrations (dev · prod 루트 모듈이 공유하는 모듈)
# 조건부 자원의 null 은 마지막으로 반영한 구성에서 그 자원이 없다는 뜻입니다. 실제 계정의 drift 는 aws cli 로 따로 조회합니다.

output "integration_contract" {
  description = "Account, region, reports bucket, alarm topic, optional external log consumer handles and the reused backup bucket ARN for later roots."
  value = {
    account_id                     = var.expected_account_id                              # 예: "111111111111" (이 구성을 적용한 계정 번호)
    region                         = var.region                                           # 예: "ap-northeast-2"
    reports_bucket_name            = aws_s3_bucket.reports.id                             # 예: "reports-contract2whale-dev-eks-111111111111-ap-northeast-2"
    reports_bucket_arn             = aws_s3_bucket.reports.arn                            # 예: "arn:aws:s3:::reports-contract2whale-dev-eks-111111111111-ap-northeast-2"
    alarm_topic_arn                = aws_sns_topic.platform.arn                           # 예: "arn:aws:sns:ap-northeast-2:111111111111:contract2whale-dev-eks-platform-operations"
    external_log_queue_url         = try(aws_sqs_queue.logs[0].url, null)                 # 예: null (기본값) 또는 큐 URL
    external_log_consumer_role_arn = try(aws_iam_role.external_log_consumer[0].arn, null) # 예: null (기본값) 또는 Role ARN
    backup_bucket_arn              = var.operations_contract.velero_bucket_arn            # 예: "arn:aws:s3:::velero-contract2whale-dev-eks-111111111111-ap-northeast-2" (운영 기반 구성의 버킷을 재사용)
  }
}
