# tests/contracts.tftest.hcl — modules/operations (dev · prod 루트 모듈이 공유하는 모듈)
# command = apply 도 로컬 테스트 state 에만 적용합니다. plan 단계 입력 검증은 tests/inputs_and_guards.tftest.hcl(Controller 신원과 저장소) 이 담당합니다. 아래 ARN 은 AWS 에 없는 fixture 입니다.

mock_provider "aws" {
  override_during = apply # 예: apply 단계에서 computed 값을 아래 defaults 로 채움

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/mock-controller", id = "mock-controller" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::velero-fixture", id = "velero-fixture" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:cp-live/platform/grafana-admin-AbCdEf" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:ap-northeast-2:111111111111:log-group:/platform/cp-live/application" }
  }
}

variables {
  enabled_services    = ["autoscaler", "external_secrets", "fluent_bit", "velero"]
  expected_account_id = "111111111111"
  cluster_contract = {
    name               = "cp-live"
    arn                = "arn:aws:eks:ap-northeast-2:111111111111:cluster/cp-live"
    region             = "ap-northeast-2"
    kubernetes_version = "1.36"
  }
  node_group_autoscaling_group_names = ["eks-fixture-system"]
}

run "pod_identity_boundaries" {
  command = apply

  assert {
    condition     = length(aws_eks_pod_identity_association.controller) == 4 && aws_eks_pod_identity_association.controller["external_secrets"].namespace == "external-secrets"
    error_message = "4개 독립 Pod Identity association의 namespace 계약이 맞아야 합니다."
  }

  assert {
    condition     = jsondecode(aws_iam_role.controller["velero"].assume_role_policy).Statement[0].Condition.StringEquals["aws:RequestTag/eks-cluster-arn"] == var.cluster_contract.arn
    error_message = "다른 EKS cluster에서 역할을 사용할 수 없어야 합니다."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.controller["external_secrets"].policy).Statement[0].Resource == aws_secretsmanager_secret.grafana[0].arn
    error_message = "ESO는 Grafana secret 하나만 읽어야 합니다."
  }

  assert {
    condition     = jsondecode(aws_iam_role_policy.controller["autoscaler"].policy).Statement[0].Condition.StringEquals["aws:ResourceTag/k8s.io/cluster-autoscaler/cp-live"] == "owned" && length(aws_autoscaling_group_tag.discovery) == 2
    error_message = "Autoscaler 쓰기 권한과 ASG discovery 태그가 같은 cluster를 가리켜야 합니다."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.velero[0].block_public_policy && aws_s3_bucket_versioning.velero[0].versioning_configuration[0].status == "Enabled" && aws_s3_bucket.velero[0].force_destroy
    error_message = "백업 저장소 보호 계약이 필요합니다."
  }
}

run "contract_outputs" {
  command = apply

  variables {
    alerts_topic_arn = "arn:aws:sns:ap-northeast-2:111111111111:cp-live-alerts"
  }

  assert {
    condition     = length(keys(output.operations_contract)) == 7 && !contains(keys(output.operations_contract), "grafana_secret_name")
    error_message = "operations_contract 는 정확히 7개 키(account_id · cluster_name · region · platform_log_group_name · velero_bucket_name · velero_bucket_arn · alerts_topic_arn)여야 합니다."
  }

  assert {
    condition     = output.operations_contract.platform_log_group_name == "/platform/cp-live/application" && output.operations_contract.velero_bucket_name == "velero-fixture" && output.operations_contract.alerts_topic_arn == "arn:aws:sns:ap-northeast-2:111111111111:cp-live-alerts"
    error_message = "계약이 로그 그룹 · 백업 버킷 · 경보 토픽 ARN 을 그대로 전달해야 합니다."
  }

  assert {
    condition     = output.grafana_secret_name == "cp-live/platform/grafana-admin"
    error_message = "grafana_secret_name 은 <cluster>/platform/grafana-admin 이어야 합니다."
  }
}

# 3. 다른 계정의 클러스터 ARN 을 거부합니다.
run "reject_wrong_cluster_account" {
  command = plan

  variables {
    cluster_contract = {
      name               = "cp-live"
      arn                = "arn:aws:eks:ap-northeast-2:999999999999:cluster/cp-live"
      region             = "ap-northeast-2"
      kubernetes_version = "1.36"
    }
  }

  expect_failures = [terraform_data.contract]
}

# 4. 경보 토픽 ARN 형식이 아니면 변수 검증이 거부합니다 (SNS 이름만 넣은 경우).
run "reject_topic_name_without_arn" {
  command = plan

  variables {
    alerts_topic_arn = "contract2whale-dev-alerts"
  }

  expect_failures = [var.alerts_topic_arn]
}
