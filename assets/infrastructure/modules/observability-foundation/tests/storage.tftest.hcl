# tests/storage.tftest.hcl — modules/observability-foundation (dev · prod 루트 모듈이 공유하는 모듈)
# 연결의 role_arn 은 apply 단계에서 정해지므로 역할 ARN 을 override 한 mock apply 로 봅니다. 실제 AWS API 는 호출하지 않습니다.

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
  allowed_state_keys     = ["account-baseline/terraform.tfstate", "platform/observability/terraform.tfstate"]
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

run "buckets_and_protections" {
  command = apply

  assert {
    condition     = length(aws_s3_bucket.signal) == 3 && aws_s3_bucket.signal["logs"].bucket == "cp-dev-observability-logs-111111111111-ap-northeast-2" && aws_s3_bucket.signal["metrics"].force_destroy
    error_message = "Three signal buckets named by the naming rule with force_destroy for the lab."
  }

  assert {
    condition     = length(aws_s3_bucket_ownership_controls.signal) == 3 && length(aws_s3_bucket_public_access_block.signal) == 3 && length(aws_s3_bucket_server_side_encryption_configuration.signal) == 3 && length(aws_s3_bucket_versioning.signal) == 3 && length(aws_s3_bucket_lifecycle_configuration.signal) == 3 && length(aws_s3_bucket_policy.signal) == 3
    error_message = "Every bucket must carry the six protection resources (18 in total)."
  }

  assert {
    condition     = alltrue([for pab in aws_s3_bucket_public_access_block.signal : pab.block_public_acls && pab.block_public_policy && pab.ignore_public_acls && pab.restrict_public_buckets]) && alltrue([for v in aws_s3_bucket_versioning.signal : v.versioning_configuration[0].status == "Enabled"])
    error_message = "Public access must be blocked and versioning enabled on every bucket."
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.signal["metrics"].rule[0].expiration[0].days == 400 && aws_s3_bucket_lifecycle_configuration.signal["metrics"].rule[0].filter[0].prefix == "dev/" && aws_s3_bucket_lifecycle_configuration.signal["logs"].rule[0].expiration[0].days == 90 && aws_s3_bucket_lifecycle_configuration.signal["traces"].rule[0].expiration[0].days == 40 && aws_s3_bucket_lifecycle_configuration.signal["traces"].rule[0].filter[0].prefix == "dev/"
    error_message = "Expiration must follow signal_retention_days; metrics/traces scoped to dev/, logs to the whole bucket."
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.signal["metrics"].rule[1].noncurrent_version_expiration[0].noncurrent_days == 7 && aws_s3_bucket_lifecycle_configuration.signal["metrics"].rule[1].abort_incomplete_multipart_upload[0].days_after_initiation == 7
    error_message = "Noncurrent versions and incomplete multipart uploads must be cleaned after 7 days."
  }

  assert {
    condition     = length(jsondecode(aws_s3_bucket_policy.signal["metrics"].policy).Statement) == 2 && length(jsondecode(aws_s3_bucket_policy.signal["logs"].policy).Statement) == 1 && jsondecode(aws_s3_bucket_policy.signal["traces"].policy).Statement[1].Sid == "DenyObjectsOutsideEnvironmentPrefix" && jsondecode(aws_s3_bucket_policy.signal["logs"].policy).Statement[0].Sid == "DenyInsecureTransport"
    error_message = "Bucket policies: insecure transport denied everywhere; prefix boundary only on prefixed buckets."
  }
}

run "pod_identity_associations" {
  command = apply

  assert {
    condition     = length(aws_eks_pod_identity_association.signal) == 9 && alltrue([for a in aws_eks_pod_identity_association.signal : a.cluster_name == "contract2whale-dev-eks" && !a.disable_session_tags])
    error_message = "Nine associations on this cluster with session tags enabled."
  }

  assert {
    condition     = aws_eks_pod_identity_association.signal["metrics_writer"].role_arn == "arn:aws:iam::111111111111:role/platform/cp-dev-observability-writer" && aws_eks_pod_identity_association.signal["logs_reader"].role_arn == "arn:aws:iam::111111111111:role/platform/cp-dev-observability-reader" && aws_eks_pod_identity_association.signal["traces_maintainer"].role_arn == "arn:aws:iam::111111111111:role/platform/cp-dev-observability-maintenance"
    error_message = "Each association must map its role name to the matching storage role ARN."
  }

  assert {
    condition     = aws_eks_pod_identity_association.signal["logs_writer"].namespace == "logging" && aws_eks_pod_identity_association.signal["logs_writer"].service_account == "platform-loki-write" && aws_eks_pod_identity_association.signal["metrics_maintainer"].service_account == "platform-thanos-compact"
    error_message = "Default identities must keep the namespace and service account names used by observability consumers."
  }

  assert {
    condition     = length(output.pod_identity_association_ids) == 9 && output.storage_role_arns.reader == "arn:aws:iam::111111111111:role/platform/cp-dev-observability-reader" && output.signal_object_prefixes.logs == ""
    error_message = "Outputs must expose the nine association IDs, the role ARNs and the per-signal prefixes."
  }
}

run "reject_missing_state_key" {
  command = plan

  variables {
    allowed_state_keys = ["account-baseline/terraform.tfstate", "network/vpc/terraform.tfstate"]
  }

  expect_failures = [terraform_data.contract]
}

# 4. 다른 클러스터의 운영 기반 계약은 거부합니다.
run "reject_foreign_operations_contract" {
  command = plan

  variables {
    operations_contract = {
      account_id              = "111111111111"
      cluster_name            = "other-cluster"
      region                  = "ap-northeast-2"
      platform_log_group_name = "/platform/other-cluster/application"
      velero_bucket_name      = null
      velero_bucket_arn       = null
      alerts_topic_arn        = null
    }
  }

  expect_failures = [terraform_data.contract]
}

# 5. Kubernetes 1.36 이 아닌 클러스터 계약은 거부합니다.
run "reject_kubernetes_version_mismatch" {
  command = plan

  variables {
    cluster_contract = { name = "contract2whale-dev-eks", arn = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks", region = "ap-northeast-2", kubernetes_version = "1.35" }
  }

  expect_failures = [terraform_data.contract]
}

# 6. 한 ServiceAccount 에 역할 둘을 연결할 수 없습니다.
run "reject_duplicate_service_account" {
  command = plan

  variables {
    pod_identities = {
      metrics_writer = { namespace = "monitoring", service_account = "platform-monitoring-prometheus", role = "writer" }
      metrics_reader = { namespace = "monitoring", service_account = "platform-monitoring-prometheus", role = "reader" }
      logs_writer    = { namespace = "logging", service_account = "platform-loki-write", role = "writer" }
      traces_writer  = { namespace = "monitoring", service_account = "platform-tempo-block-builder", role = "writer" }
    }
  }

  expect_failures = [var.pod_identities]
}
