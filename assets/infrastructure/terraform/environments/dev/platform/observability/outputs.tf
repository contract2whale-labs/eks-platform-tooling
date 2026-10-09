# outputs.tf — platform/observability 루트 모듈 (dev · prod 공통 코드)

output "observability_contract" {
  description = "Account, region, cluster, namespaces, service accounts, roles, buckets, retention, query endpoints, trace backend state and policy hash (17 keys)."
  value       = module.component.observability_contract
}

output "observability_network_contract" {
  description = "S3 gateway endpoint id, allowed bucket names and endpoint policy mode (private storage endpoint)."
  value       = module.component.observability_network_contract # 예: { s3_endpoint_id = "vpce-…", allowed_bucket_prefixes = [5개], endpoint_policy_mode = "restricted" }
}

output "signal_bucket_names" {
  description = "Bucket name per signal."
  value       = module.component.signal_bucket_names # 예: { metrics = "cp-dev-observability-metrics-…", logs = "…", traces = "…" }
}

output "storage_role_arns" {
  description = "Writer, reader and maintenance role ARNs."
  value       = module.component.storage_role_arns # 예: { writer = "…", reader = "…", maintenance = "…" }
}

output "pod_identity_association_ids" {
  description = "Association ID per pod identity key."
  value       = module.component.pod_identity_association_ids # 예: 신원 9개의 연결 식별자
}



output "platform_input_values" {
  description = "Typed noncredential storage settings for native platform inputs; never credentials."
  value = {
    metrics_bucket      = module.component.observability_contract.metrics_bucket
    logs_bucket         = module.component.observability_contract.logs_bucket
    traces_bucket       = module.component.observability_contract.traces_bucket
    region              = var.region
    s3_endpoint         = "s3.${var.region}.amazonaws.com"
    metrics_prefix      = "${module.component.signal_object_prefixes.metrics}metrics"
    trace_prefix        = "${module.component.signal_object_prefixes.traces}traces"
    trace_epoch2_prefix = "${module.component.signal_object_prefixes.traces}traces-epoch-2"
    trace_epoch3_prefix = "${module.component.signal_object_prefixes.traces}traces-epoch-3"
    cluster_name        = module.component.observability_contract.cluster
    prometheus_endpoint = module.component.observability_contract.prometheus_endpoint
    loki_endpoint       = module.component.observability_contract.loki_endpoint
    tempo_endpoint      = module.component.observability_contract.tempo_endpoint
  }
}

output "signal_object_prefixes" {
  value = module.component.signal_object_prefixes
}
