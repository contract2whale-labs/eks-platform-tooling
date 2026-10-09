# tests/inputs_and_guards.tftest.hcl — modules/operations (dev · prod 루트 모듈이 공유하는 모듈)
# 운영 기반 루트 모듈과 계약 의 tests/contracts.tftest.hcl 은 Pod Identity 경계와 정책 내용을 apply 모드로 확인하므로 역할이 겹치지 않습니다. 아래 ARN · ASG 이름은 AWS 에 없는 fixture 입니다.

mock_provider "aws" {
  # mock apply 가 만드는 무작위 문자열은 ARN 형식 검사(association.role_arn)를 통과하지 못하므로 ARN 형식의 fixture 를 둡니다 (Terraform 1.16.0 실측).
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/mock-controller", id = "mock-controller" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::velero-contract2whale-dev-eks-111111111111-ap-northeast-2", id = "velero-contract2whale-dev-eks-111111111111-ap-northeast-2" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:contract2whale-dev-eks/platform/grafana-admin-AbCdEf" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:ap-northeast-2:111111111111:log-group:/platform/contract2whale-dev-eks/application" }
  }
}

variables {
  expected_account_id = "111111111111"
  region              = "ap-northeast-2"
  cluster_contract = {
    name               = "contract2whale-dev-eks"
    arn                = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
    region             = "ap-northeast-2"
    kubernetes_version = "1.36"
  }
  node_group_autoscaling_group_names = ["eks-contract2whale-dev-eks-system-fixture"]
}

run "all_services_declared" {
  command = apply

  variables {
    enabled_services = ["autoscaler", "external_secrets", "fluent_bit", "velero"]
  }

  assert {
    condition     = length(aws_iam_role.controller) == 4 && length(aws_iam_role_policy.controller) == 4 && length(aws_eks_pod_identity_association.controller) == 4
    error_message = "controller 4종마다 Role · 정책 · Pod Identity 연결이 1개씩 선언되어야 합니다."
  }

  assert {
    condition     = length(aws_autoscaling_group_tag.discovery) == 2
    error_message = "ASG 1개 × 탐색 태그 2개 = 2개가 선언되어야 합니다 (D2)."
  }

  assert {
    condition     = alltrue([for name, association in aws_eks_pod_identity_association.controller : association.disable_session_tags == false])
    error_message = "세션 태그를 끄면 신뢰 정책의 aws:RequestTag 조건이 충족되지 않습니다."
  }

  assert {
    condition     = aws_s3_bucket.velero[0].bucket == "velero-contract2whale-dev-eks-111111111111-ap-northeast-2" && length(aws_s3_bucket.velero[0].bucket) <= 63
    error_message = "백업 버킷 이름이 계약 형식과 다르거나 63자를 넘습니다."
  }

  assert {
    condition     = aws_cloudwatch_log_group.platform[0].name == "/platform/contract2whale-dev-eks/application" && aws_cloudwatch_log_group.platform[0].retention_in_days == 90
    error_message = "플랫폼 로그 그룹의 이름 또는 보존 일수가 계약과 다릅니다."
  }

  assert {
    condition     = !strcontains(aws_iam_role_policy.controller["fluent_bit"].policy, "s3:") && !strcontains(aws_iam_role_policy.controller["velero"].policy, "logs:")
    error_message = "Fluent Bit 정책과 백업 정책의 권한이 서로 섞이면 안 됩니다."
  }
}

run "default_declares_autoscaler_only" {
  command = plan

  assert {
    condition     = length(aws_iam_role.controller) == 1 && contains(keys(aws_iam_role.controller), "autoscaler")
    error_message = "모듈 기본 입력에서는 autoscaler 신원만 선언되어야 합니다."
  }

  assert {
    condition     = length(aws_s3_bucket.velero) == 0 && length(aws_cloudwatch_log_group.platform) == 0 && length(aws_secretsmanager_secret.grafana) == 0
    error_message = "켜지 않은 도구의 리소스가 선언되면 안 됩니다."
  }
}

# 3. 실행 계정이 계약 ARN 의 계정과 다르면 terraform_data.contract 의 precondition 이 거부합니다.
run "reject_cross_account_contract" {
  command = plan

  variables {
    expected_account_id = "222222222222" # 예: 계약 ARN 의 계정(111111111111)과 다른 실행 계정
  }

  expect_failures = [terraform_data.contract]
}

# 4. 과정 고정 버전(1.36)이 아닌 클러스터 계약을 거부합니다.
run "reject_unsupported_kubernetes_version" {
  command = plan

  variables {
    cluster_contract = {
      name               = "contract2whale-dev-eks"
      arn                = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
      region             = "ap-northeast-2"
      kubernetes_version = "1.35" # 예: 과정 고정값(1.36)과 다른 버전
    }
  }

  expect_failures = [terraform_data.contract]
}

# 5. 이 모듈이 지원하지 않는 도구 이름을 거부합니다.
run "reject_unknown_service" {
  command = plan

  variables {
    enabled_services = ["karpenter"] # 예: 이 모듈이 지원하지 않는 도구
  }

  expect_failures = [var.enabled_services]
}

# 6. ASG 이름이 비면 탐색 태그를 붙일 대상이 없으므로 거부합니다.
run "reject_empty_asg_names" {
  command = plan

  variables {
    node_group_autoscaling_group_names = [] # 예: 빈 집합
  }

  expect_failures = [var.node_group_autoscaling_group_names]
}
