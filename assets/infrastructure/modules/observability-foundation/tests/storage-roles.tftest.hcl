# tests/storage-roles.tftest.hcl — modules/observability-foundation (dev · prod 루트 모듈이 공유하는 모듈)
# data.aws_iam_policy_document 의 json 은 mock 에서 임의 문자열이므로 입력 statement 를 검사합니다 (관련 구성 account.tftest.hcl 과 같은 방식). 아래 값은 AWS 에 없는 fixture 입니다.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" # 예: 빈 정책 JSON (형식만 유지)
    }
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
}

override_data {
  target = data.aws_vpc_endpoint.s3
  values = { id = "vpce-0123456789abcdef0", state = "available" }
}

# 1. 세 역할의 동작 경계와 접두사 규칙.
run "role_boundaries" {
  command = plan

  assert {
    condition     = !contains(one([for s in data.aws_iam_policy_document.observability_writer.statement : s if s.sid == "PutObservabilitySignalObjects"]).actions, "s3:DeleteObject")
    error_message = "The writer policy must not grant s3:DeleteObject."
  }

  assert {
    condition     = one([for s in data.aws_iam_policy_document.observability_reader.statement : s if s.sid == "GetObservabilitySignalObjects"]).actions == toset(["s3:GetObject"])
    error_message = "The reader policy must grant s3:GetObject only."
  }

  assert {
    condition     = contains(one([for s in data.aws_iam_policy_document.observability_maintenance.statement : s if s.sid == "CompactAndRetainObservabilityObjects"]).actions, "s3:DeleteObject")
    error_message = "The maintenance policy must grant s3:DeleteObject."
  }

  assert {
    condition = alltrue([
      for doc in [data.aws_iam_policy_document.observability_writer, data.aws_iam_policy_document.observability_reader, data.aws_iam_policy_document.observability_maintenance] :
      length([for s in doc.statement : s if s.sid == "DenyListingOutsideEnvironmentPrefix" && s.effect == "Deny"]) == 1
    ])
    error_message = "Every storage policy must carry the DenyListingOutsideEnvironmentPrefix statement."
  }

  assert {
    condition = alltrue([
      for doc in [data.aws_iam_policy_document.observability_writer, data.aws_iam_policy_document.observability_reader, data.aws_iam_policy_document.observability_maintenance] :
      alltrue([for s in doc.statement : !contains(s.actions, "s3:*") && !contains(s.resources, "*")])
    ])
    error_message = "Storage policies must not use s3:* or Resource *."
  }

  assert {
    condition     = local.signal_bucket_names.metrics == "cp-dev-observability-metrics-111111111111-ap-northeast-2" && local.signal_object_prefixes == { metrics = "dev/", logs = "", traces = "dev/" }
    error_message = "Bucket names follow cp-<env>-observability-<signal>-<account>-<region>; only logs is unprefixed."
  }

  assert {
    condition     = contains(local.signal_object_arns, "arn:aws:s3:::cp-dev-observability-metrics-111111111111-ap-northeast-2/dev/*") && contains(local.signal_object_arns, "arn:aws:s3:::cp-dev-observability-logs-111111111111-ap-northeast-2/*") && length(local.prefixed_bucket_arns) == 2 && length(local.unprefixed_bucket_arns) == 1
    error_message = "Object ARNs must use dev/* for metrics and traces and the whole bucket for logs."
  }

  assert {
    condition     = length(data.aws_iam_policy_document.observability_writer.statement) == 5 && length(data.aws_iam_policy_document.observability_reader.statement) == 4 && length(data.aws_iam_policy_document.observability_maintenance.statement) == 5
    error_message = "Statement counts must be writer 5, reader 4, maintenance 5 (unprefixed logs bucket adds one list statement)."
  }
}

# 2. 신뢰 정책: 운영자 역할 문장 + Pod Identity 문장(클러스터 ARN 조건).
run "trust_policy_and_role_shape" {
  command = plan

  assert {
    condition     = length(data.aws_iam_policy_document.observability_access_trust.statement) == 2 && one([for s in data.aws_iam_policy_document.observability_access_trust.statement : s if s.sid == "TrustObservabilityPodIdentity"]).actions == toset(["sts:AssumeRole", "sts:TagSession"])
    error_message = "The trust policy must have the operator statement and the Pod Identity statement with AssumeRole + TagSession."
  }

  assert {
    condition     = one([for c in one([for s in data.aws_iam_policy_document.observability_access_trust.statement : s if s.sid == "TrustObservabilityPodIdentity"]).condition : c]).values == tolist([var.cluster_contract.arn])
    error_message = "The Pod Identity statement must be limited to this cluster's ARN via aws:RequestTag/eks-cluster-arn."
  }

  assert {
    condition     = aws_iam_role.observability_writer.name == "cp-dev-observability-writer" && aws_iam_role.observability_reader.path == "/platform/" && aws_iam_role.observability_maintenance.max_session_duration == 3600 && aws_iam_policy.observability_writer.path == "/platform/"
    error_message = "Roles and policies must be named cp-<env>-observability-<role> under /platform/ with a 1 hour session."
  }
}

# 3. 환경 이름은 dev · prod 만 받습니다.
run "reject_unknown_environment" {
  command = plan

  variables {
    environment = "stage"
  }

  expect_failures = [var.environment]
}

# 4. STS 세션 ARN 은 신뢰 주체가 될 수 없습니다.
run "reject_session_arn_as_principal" {
  command = plan

  variables {
    trusted_principal_arns = ["arn:aws:sts::111111111111:assumed-role/PlatformOperator/session"]
  }

  expect_failures = [var.trusted_principal_arns]
}
