# outputs.tf — platform/operations 루트 모듈 (dev · prod 공통 코드)

output "operations_contract" {
  description = "Account, cluster, region, platform log group, backup bucket and alerts topic ARN for native platform configuration and later roots."
  value       = module.component.operations_contract # 공개 필드: (account_id · cluster_name · region · platform_log_group_name · velero_bucket_name · velero_bucket_arn · alerts_topic_arn)
}



# 배포 플랫폼 의 delivery 루트 모듈이 terraform_remote_state 로 읽습니다 (assume-role chaining 의 신뢰 주체).
output "external_secrets_role_arn" {
  description = "IAM role of the cluster-wide External Secrets controller (read by the delivery root)."
  value       = module.component.external_secrets_role_arn # 예: "arn:aws:iam::111111111111:role/contract2whale-dev-eks-external-secrets"
}

output "grafana_secret_name" {
  value       = module.component.grafana_secret_name
  description = "External secret source name only; no credential data."
}
