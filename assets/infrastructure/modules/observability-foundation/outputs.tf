# outputs.tf — modules/observability-foundation (dev · prod 루트 모듈이 공유하는 모듈)

output "signal_bucket_names" {
  description = "Bucket name per signal."
  value       = { for key, bucket in aws_s3_bucket.signal : key => bucket.id } # 예: { metrics = "cp-dev-observability-metrics-…", logs = "…", traces = "…" }
}

output "signal_bucket_arns" {
  description = "Bucket ARN per signal."
  value       = { for key, bucket in aws_s3_bucket.signal : key => bucket.arn } # 예: { logs = "arn:aws:s3:::cp-dev-observability-logs-…", … }
}

output "object_prefix" {
  description = "Environment prefix used by prefixed buckets (metrics, traces)."
  value       = local.object_prefix # 예: "dev/" (metrics · traces 객체 key 앞에 붙는 환경 접두사)
}

output "signal_object_prefixes" {
  description = "Object key prefix per signal; empty for buckets used without a prefix (logs)."
  value       = local.signal_object_prefixes # 예: { metrics = "dev/", logs = "", traces = "dev/" }
}

output "storage_role_arns" {
  description = "Writer, reader and maintenance role ARNs."
  value       = local.storage_role_arns # 예: { writer = "…", reader = "…", maintenance = "…" }
}

output "pod_identity_association_ids" {
  description = "Association ID per pod identity key."
  value       = { for key, association in aws_eks_pod_identity_association.signal : key => association.association_id } # 예: { metrics_writer = "a-abcdefghijklmnop1", … }
}

output "signal_retention_days" {
  description = "Backstop expiration days per signal."
  value       = var.signal_retention_days # 예: { metrics = 400, logs = 90, traces = 40 }
}
