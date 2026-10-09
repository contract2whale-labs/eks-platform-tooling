# outputs.tf — account-integrations 루트 모듈 (dev · prod 공통 코드)

output "integration_contract" {
  description = "Account, region, reports bucket, alarm topic, optional external log consumer handles and the reused backup bucket ARN."
  value       = module.component.integration_contract # 예: 8개 키를 담은 object (account_id · region · reports_bucket_name · reports_bucket_arn · alarm_topic_arn · external_log_queue_url · external_log_consumer_role_arn · backup_bucket_arn)
}
