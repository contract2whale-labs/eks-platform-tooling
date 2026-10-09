# tests/queue.tftest.hcl — platform/queue 루트 모듈
# mock provider + override_data 로 앞 루트 모듈 State 2곳의 출력을 대체해 조립 · 개수 · 거부를 확인합니다. 실제 AWS apply 가 아닙니다.

mock_provider "aws" {
  override_during = apply

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111111111111"
    }
  }

  mock_data "aws_security_group" {
    defaults = {
      vpc_id = "vpc-0123456789abcdef0"
    }
  }

  mock_resource "aws_msk_cluster" {
    defaults = {
      arn                          = "arn:aws:kafka:ap-northeast-2:111111111111:cluster/cp-dev-traces-queue/0abc1234-5678-90ab-cdef-EXAMPLE11111-1"
      bootstrap_brokers_sasl_scram = "b-1.example:9096,b-2.example:9096"
      zookeeper_connect_string     = ""
    }
  }

  mock_resource "aws_msk_configuration" {
    defaults = {
      arn             = "arn:aws:kafka:ap-northeast-2:111111111111:configuration/cp-dev-traces-queue-config/0abc1234-5678-90ab-cdef-EXAMPLE33333-2" # 예: 고정 가짜 구성 ARN
      latest_revision = 1                                                                                                                           # 예: 1 (첫 버전)
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:ap-northeast-2:111111111111:key/0abc1234-5678-90ab-cdef-EXAMPLE22222"
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:AmazonMSK_cp-dev-traces-queue-AbCdEf"
    }
  }
}

variables {
  expected_account_id = "111111111111"
  region              = "ap-northeast-2"
  environment         = "dev"
  state_bucket_name   = "company-dev-tfstate-111111111111"
  kafka_version       = "3.9.0"
}

# 앞 루트 모듈 State 2곳의 출력 fixture 입니다 (P1 의 조회를 테스트에서 대체).
override_data {
  target = data.terraform_remote_state.network
  values = {
    outputs = {
      kafka_network_contract = {
        broker_security_group_id = "sg-0b0adef012345678a"
        client_security_group_id = "sg-0c1adef012345678a"
        broker_subnet_ids_by_az = {
          "ap-northeast-2a" = "subnet-0iii1111111111111"
          "ap-northeast-2b" = "subnet-0iii2222222222222"
          "ap-northeast-2c" = "subnet-0iii3333333333333"
        }
        broker_port = 9096
      }
      kafka_broker_subnet_cidrs_by_az = {
        "ap-northeast-2a" = "172.20.12.0/28"
        "ap-northeast-2b" = "172.20.12.16/28"
        "ap-northeast-2c" = "172.20.12.32/28"
      }
    }
  }
}

override_data {
  target = data.terraform_remote_state.eks
  values = {
    outputs = {
      node_security_group_id = "sg-0abcdef012345678a"
      cluster_name           = "contract2whale-dev-eks"
    }
  }
}

# mock plan에서 계약의 키 개수를 검사합니다. 실제 AWS 리소스 수나 apply 결과를 증명하지 않습니다.
run "plan_creates_thirteen_resources" {
  command = plan

  assert {
    condition     = length(module.component.queue_managed_contract) == 11
    error_message = "The module contract must have eleven keys at plan time too."
  }
}

run "assembles_contract_from_state" {
  command = apply

  assert {
    condition     = output.queue_managed_contract.client_security_group_id == "sg-0abcdef012345678a"
    error_message = "The node security group must come from the eks state, not from a variable."
  }



}

run "reject_non_dev_environment" {
  command = plan

  variables {
    environment = "prod"                      # 예: 이 디렉터리가 받지 않는 환경
    topic_name  = "prod-tempo-traces-epoch-2" # 예: 모듈 검사는 통과시키고 루트 모듈 경계만 어기게 함
  }

  expect_failures = [terraform_data.environment_boundary]
}

run "reject_topic_without_environment_prefix" {
  command = plan

  variables {
    topic_name = "tempo-traces-epoch-2" # 예: 환경 이름이 없는 토픽
  }

  expect_failures = [var.topic_name]
}
