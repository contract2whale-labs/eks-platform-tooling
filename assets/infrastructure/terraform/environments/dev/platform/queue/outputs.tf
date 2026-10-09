# outputs.tf — platform/queue 루트 모듈 (dev · prod 공통 코드)

output "queue_managed_contract" {
  description = "Managed queue contract with endpoints, identity, placement and topic."
  value       = module.component.queue_managed_contract
}

output "cluster_arn" {
  description = "Cluster ARN used verbatim by aws kafka … --cluster-arn."
  value       = module.component.cluster_arn # 예: "arn:aws:kafka:ap-northeast-2:111111111111:cluster/cp-dev-traces-queue/0abc..."
}

output "bootstrap_brokers_scram" {
  description = "Comma separated SASL/SCRAM bootstrap endpoints (not the full broker list)."
  value       = module.component.bootstrap_brokers_scram # 예: "b-1...:9096,b-2...:9096,b-3...:9096"
}

output "diagnostic_coordinates" {
  description = "Noncredential coordinates for protected local operations."
  value = {
    account_id          = var.expected_account_id
    region              = var.region
    environment         = var.environment
    eks_cluster         = local.cluster_name
    broker_port         = local.kafka_network_contract.broker_port
    writer_username     = var.writer_username
    reader_username     = var.reader_username
    broker_subnet_cidrs = local.broker_subnet_cidrs_sorted
  }
}
