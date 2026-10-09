# tests/contract.tftest.hcl — modules/observability-foundation (dev · prod 루트 모듈이 공유하는 모듈)

mock_provider "aws" {
  override_during = apply # 예: apply 단계의 computed 값을 아래 defaults 로 채움 (plan 단계 검사는 그대로)

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" # 예: 빈 정책 JSON (형식만 유지)
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::111111111111:policy/platform/mock-policy" } # 예: attachment 의 policy_arn 형식 검사를 통과하는 fixture
  }

  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::mock-signal-bucket" } # 예: 버킷 정책 Resource 형식 fixture
  }
}

variables {
  expected_account_id    = "111111111111"
  region                 = "ap-northeast-2"
  environment            = "dev"
  cluster_contract       = { name = "contract2whale-dev-eks", arn = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks", region = "ap-northeast-2", kubernetes_version = "1.36" }
  trusted_principal_arns = ["arn:aws:iam::111111111111:role/PlatformOperator"]
  allowed_state_keys     = ["platform/observability/terraform.tfstate"]
  operations_contract = {
    account_id              = "111111111111"
    cluster_name            = "contract2whale-dev-eks"
    region                  = "ap-northeast-2"
    platform_log_group_name = "/platform/contract2whale-dev-eks/application"
    velero_bucket_name      = "velero-contract2whale-dev-eks-111111111111-ap-northeast-2"
    velero_bucket_arn       = "arn:aws:s3:::velero-contract2whale-dev-eks-111111111111-ap-northeast-2"
    alerts_topic_arn        = null
  }
  vpc_id                   = "vpc-0123456789abcdef0"
  network_logs_bucket_name = "cp-dev-network-logs-111111111111-ap-northeast-2"
  signal_retention_days    = { metrics = 400, logs = 90, traces = 40 }
}

override_resource {
  target = aws_iam_role.observability_writer
  values = { arn = "arn:aws:iam::111111111111:role/platform/cp-dev-observability-writer" }
}

override_resource {
  target = aws_iam_role.observability_reader
  values = { arn = "arn:aws:iam::111111111111:role/platform/cp-dev-observability-reader" }
}

override_resource {
  target = aws_iam_role.observability_maintenance
  values = { arn = "arn:aws:iam::111111111111:role/platform/cp-dev-observability-maintenance" }
}

override_data {
  target = data.aws_vpc_endpoint.s3
  values = { id = "vpce-0123456789abcdef0", state = "available" }
}

# mock apply 에서 버킷 이름을 실제 형식으로 고정합니다 (계약 출력의 *_bucket 확인용).
override_resource {
  target = aws_s3_bucket.signal["metrics"]
  values = { id = "cp-dev-observability-metrics-111111111111-ap-northeast-2", arn = "arn:aws:s3:::cp-dev-observability-metrics-111111111111-ap-northeast-2" }
}

override_resource {
  target = aws_s3_bucket.signal["logs"]
  values = { id = "cp-dev-observability-logs-111111111111-ap-northeast-2", arn = "arn:aws:s3:::cp-dev-observability-logs-111111111111-ap-northeast-2" }
}

override_resource {
  target = aws_s3_bucket.signal["traces"]
  values = { id = "cp-dev-observability-traces-111111111111-ap-northeast-2", arn = "arn:aws:s3:::cp-dev-observability-traces-111111111111-ap-northeast-2" }
}

run "contract_keys_and_values" {
  command = apply

  assert {
    condition     = length(keys(output.observability_contract)) == 17 && toset(keys(output.observability_contract)) == toset(["account", "region", "cluster", "namespace", "service_account", "role", "metrics_bucket", "logs_bucket", "traces_bucket", "retention", "prometheus_endpoint", "loki_endpoint", "tempo_endpoint", "active_trace_backend", "storage_epoch", "policy_version", "policy_hash"])
    error_message = "observability_contract must have exactly the 17 agreed keys."
  }

  assert {
    condition     = output.observability_contract.namespace == { metrics = "monitoring", logs = "logging", traces = "monitoring" } && length(output.observability_contract.service_account) == 9 && length(output.observability_contract.role) == 3
    error_message = "Namespaces come from the *_writer identities; nine service accounts and three roles."
  }

  assert {
    condition     = output.observability_contract.prometheus_endpoint == "http://platform-thanos-query.monitoring.svc.cluster.local:9090" && output.observability_contract.loki_endpoint == "http://platform-loki-gateway.logging.svc.cluster.local" && output.observability_contract.tempo_endpoint == "http://platform-tempo-active-query.monitoring.svc.cluster.local:3200"
    error_message = "Query endpoints are in-cluster Service names in the signal namespaces."
  }

  assert {
    condition     = output.observability_contract.active_trace_backend == "self-managed" && output.observability_contract.storage_epoch == 1 && output.observability_contract.policy_version == 1 && can(regex("^[0-9a-f]{64}$", output.observability_contract.policy_hash))
    error_message = "Initial trace backend state is self-managed / epoch 1 / version 1 with a sha256 policy hash."
  }

  assert {
    condition     = output.observability_contract.metrics_bucket == "cp-dev-observability-metrics-111111111111-ap-northeast-2" && output.observability_contract.retention == tomap({ metrics = 400, logs = 90, traces = 40 }) && output.observability_contract.cluster == "contract2whale-dev-eks"
    error_message = "Bucket names, retention and cluster must pass through the contract unchanged."
  }
}

run "endpoint_policy_statements" {
  command = plan

  assert {
    condition     = local.owned_bucket_names == tolist(["cp-dev-network-logs-111111111111-ap-northeast-2", "cp-dev-observability-logs-111111111111-ap-northeast-2", "cp-dev-observability-metrics-111111111111-ap-northeast-2", "cp-dev-observability-traces-111111111111-ap-northeast-2", "velero-contract2whale-dev-eks-111111111111-ap-northeast-2"])
    error_message = "Owned buckets are the network log bucket, the three signal buckets and the velero bucket, sorted."
  }

  assert {
    condition     = [for s in data.aws_iam_policy_document.s3_endpoint.statement : s.sid] == ["AllowOwnedObservabilityBuckets", "AllowAwsOwnedImageAndBootstrap", "DenyEverythingElse"] && [for s in data.aws_iam_policy_document.s3_endpoint.statement : s.effect] == ["Allow", "Allow", "Deny"]
    error_message = "The endpoint policy must be Allow owned / Allow AWS-owned image layers / Deny everything else."
  }

  assert {
    condition     = length(data.aws_iam_policy_document.s3_endpoint.statement[0].resources) == 10 && length(data.aws_iam_policy_document.s3_endpoint.statement[2].not_resources) == 11 && contains(data.aws_iam_policy_document.s3_endpoint.statement[1].resources, "arn:aws:s3:::prod-ap-northeast-2-starport-layer-bucket/*")
    error_message = "Allowed resources: 5 bucket ARNs + 5 object patterns; the deny statement excludes those 10 plus the image layer bucket."
  }

  assert {
    condition     = output.observability_network_contract.s3_endpoint_id == "vpce-0123456789abcdef0" && output.observability_network_contract.endpoint_policy_mode == "restricted" && length(output.observability_network_contract.allowed_bucket_prefixes) == 5
    error_message = "observability_network_contract must expose the endpoint id, restricted mode and the five allowed names."
  }
}

run "endpoint_policy_without_velero" {
  command = plan

  variables {
    operations_contract = {
      account_id              = "111111111111"
      cluster_name            = "contract2whale-dev-eks"
      region                  = "ap-northeast-2"
      platform_log_group_name = "/platform/contract2whale-dev-eks/application"
      velero_bucket_name      = null
      velero_bucket_arn       = null
      alerts_topic_arn        = null
    }
  }

  assert {
    condition     = length(local.owned_bucket_names) == 4 && !contains(local.owned_bucket_names, "velero-contract2whale-dev-eks-111111111111-ap-northeast-2")
    error_message = "A null velero bucket must simply drop out of the allow list."
  }
}

# 4. 트레이스 backend 값은 두 가지만 받습니다.
run "reject_unknown_trace_backend" {
  command = plan

  variables {
    active_trace_backend = "msk"
  }

  expect_failures = [var.active_trace_backend]
}

# 5. 뒤 챕터가 더하는 저장소(additional_bucket_names)는 허용 목록과 거부 문장의 예외에 함께 들어갑니다.
run "endpoint_policy_with_additional_bucket" {
  command = plan

  variables {
    additional_bucket_names = ["cp-dev-app-exports-111111111111-ap-northeast-2"]
  }

  assert {
    condition     = length(local.owned_bucket_names) == 6 && contains(local.owned_bucket_names, "cp-dev-app-exports-111111111111-ap-northeast-2") && contains(data.aws_iam_policy_document.s3_endpoint.statement[2].not_resources, "arn:aws:s3:::cp-dev-app-exports-111111111111-ap-northeast-2/*")
    error_message = "An additional bucket must join the allow list and the deny exception (bucket and object ARNs)."
  }
}
