# outputs.tf — modules/queue-managed (dev · prod 루트 모듈이 공유하는 모듈)

output "queue_managed_contract" {
  description = "관리형 큐의 접속 · 신원 · 배치 · 토픽 값을 담은 접속·신원 계약입니다."
  value = {
    cluster_arn              = aws_msk_cluster.traces.arn                                                      # 예: "arn:aws:kafka:ap-northeast-2:111111111111:cluster/cp-dev-traces-queue/..."
    cluster_name             = aws_msk_cluster.traces.cluster_name                                             # 예: "cp-dev-traces-queue"
    bootstrap_brokers_scram  = aws_msk_cluster.traces.bootstrap_brokers_sasl_scram                             # 예: "b-1...:9096,b-2...:9096,b-3...:9096"
    zookeeper_free           = aws_msk_cluster.traces.zookeeper_connect_string == ""                           # 예: true (빈 값이면 브로커가 직접 보관 — KRaft)
    kafka_version            = aws_msk_cluster.traces.kafka_version                                            # 예: "3.9.0" (실제로 만들어진 브로커 버전)
    broker_subnet_ids_by_az  = var.kafka_network_contract.broker_subnet_ids_by_az                              # 예: { "ap-northeast-2a" = "subnet-0iii...", ... }
    client_security_group_id = var.workload_security_group_id                                                  # 예: "sg-0nodes..." (실제로 9096 을 여는 쪽)
    secret_arns              = { for key, secret in aws_secretsmanager_secret.queue_user : key => secret.arn } # 예: { reader = "arn:...", writer = "arn:..." }
    kms_key_arn              = aws_kms_key.queue_secrets.arn                                                   # 예: "arn:aws:kms:ap-northeast-2:111111111111:key/0abc..."
    topic_name               = var.topic_name                                                                  # 예: "dev-tempo-traces-epoch-2"
    partitions               = var.partitions                                                                  # 예: 3
  }
}

output "cluster_arn" {
  description = "조회 명령이 그대로 쓰는 클러스터 ARN 입니다."
  value       = aws_msk_cluster.traces.arn # 예: 계약의 같은 값
}

output "bootstrap_brokers_scram" {
  description = "접속 시작 주소입니다. 쉼표로 이어진 한 줄이며 전체 브로커 목록은 아닙니다."
  value       = aws_msk_cluster.traces.bootstrap_brokers_sasl_scram # 예: 계약의 같은 값
}
