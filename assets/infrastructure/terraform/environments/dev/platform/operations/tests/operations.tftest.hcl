# tests/operations.tftest.hcl — platform/operations 루트 모듈 (dev · prod 공통 코드)
# terraform_remote_state 는 override_data 로 가짜 출력을 줍니다. 실제 AWS · S3 API 를 호출하지 않습니다. 모듈 자체의 규칙은 modules/operations/tests/*.tftest.hcl 이 확인합니다. 아래 ID 는 AWS 에 없는 fixture 입니다.

mock_provider "aws" {
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
  environment         = "dev"
  state_bucket_name   = "company-dev-tfstate-111111111111"
}

override_data {
  target = data.terraform_remote_state.eks
  values = {
    outputs = {
      cluster_contract = {
        name               = "contract2whale-dev-eks"
        arn                = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
        region             = "ap-northeast-2"
        kubernetes_version = "1.36"
        endpoint           = "https://ABCD1234.gr7.ap-northeast-2.eks.amazonaws.com"
      }
      node_contract = {
        autoscaling_group_names = ["eks-contract2whale-dev-eks-system-0ac12345-6789-abcd-ef01-23456789abcd"]
        group_labels            = { system = { workload = "system" } }
      }
    }
  }
}

# 최초 적용에는 알림 ARN 입력이 없으며 기본 null을 사용합니다.

# 1. eks State 출력에서 모듈 계약을 조립합니다 (입력 파일 없음).
run "assembles_contract_from_state" {
  command = plan

  assert {
    condition     = local.cluster_contract == { name = "contract2whale-dev-eks", arn = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks", region = "ap-northeast-2", kubernetes_version = "1.36" }
    error_message = "cluster_contract must be assembled from the eks state outputs (name, arn, region, kubernetes_version only)."
  }

  assert {
    condition     = local.node_group_autoscaling_group_names == toset(["eks-contract2whale-dev-eks-system-0ac12345-6789-abcd-ef01-23456789abcd"])
    error_message = "ASG names must come from node_contract.autoscaling_group_names (D7; one group at 운영 도구 time)."
  }

  assert {
    condition     = local.alerts_topic_arn == null && terraform_data.environment_boundary.input == "dev"
    error_message = "Without an alerting state the topic ARN must be null and the environment marker must record dev."
  }
}

run "first_apply_without_alerting_state" {
  command = apply

  assert {
    condition     = length(keys(output.operations_contract)) == 7 && output.operations_contract.alerts_topic_arn == null
    error_message = "operations_contract must have seven items and a null alerts_topic_arn before 알림 루트 모듈과 설치 검사."
  }


}

# 3. 두 번째 적용: alerting 적용 뒤 공개 ARN 입력을 전달하면 계약이 그 값을 전달합니다 (리소스 변경 없이 출력만 바뀜).
run "second_apply_reads_alerting_topic" {
  command = apply

  variables {
    alerts_topic_arn = "arn:aws:sns:ap-northeast-2:111111111111:contract2whale-dev-alerts"
  }
  assert {
    condition     = output.operations_contract.alerts_topic_arn == var.alerts_topic_arn
    error_message = "The reviewed public topic ARN must be passed to the operations output."
  }

}

# 4. 이 디렉터리는 dev 만 받습니다.
run "reject_non_dev_environment" {
  command = plan

  variables {
    environment = "prod"
  }

  expect_failures = [terraform_data.environment_boundary]
}

# 5. node_contract 가 없는 eks State(루트 모듈 연결과 노드 계약 이전) 는 거부됩니다.
run "reject_state_without_node_contract" {
  command = plan

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_contract = {
          name               = "contract2whale-dev-eks"
          arn                = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
          region             = "ap-northeast-2"
          kubernetes_version = "1.36"
        }
      }
    }
  }

  expect_failures = [data.terraform_remote_state.eks]
}

# 6. cluster_contract 출력이 없는 eks State(환경 root 와 모듈 연결 이전) 는 거부됩니다.
run "reject_state_without_cluster_contract" {
  command = plan

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_name = "contract2whale-dev-eks"
      }
    }
  }

  expect_failures = [data.terraform_remote_state.eks]
}
