# tests/contracts.tftest.hcl — modules/queue-managed
# mock provider 로 AWS API 호출 없이 계약 모양 · 인증 설정 · 입력 거부를 확인합니다. 테스트 통과는 실제 브로커 생성 · 접속의 증거가 아닙니다.
# 아래 가짜 ARN · ID 는 테스트 fixture 입니다.

mock_provider "aws" {
  override_during = apply # 예: computed 값(ARN · ID)을 mock apply 단계에서 채움

  # 형식만 맞는 JSON fixture 입니다. 키 정책의 문장은 data source 의 HCL 입력으로 따로 검사합니다.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111111111111" # 예: 계정 경계 검사가 보는 값
    }
  }

  mock_data "aws_security_group" {
    defaults = {
      vpc_id = "vpc-0123456789abcdef0" # 예: 브로커 SG 와 노드 SG 가 같은 VPC 인지 보는 검사용
    }
  }

  mock_resource "aws_msk_cluster" {
    defaults = {
      arn                          = "arn:aws:kafka:ap-northeast-2:111111111111:cluster/cp-testnet-traces-queue/0abc1234-5678-90ab-cdef-EXAMPLE11111-1" # 예: 고정 가짜 ARN
      bootstrap_brokers_sasl_scram = "b-1.example:9096,b-2.example:9096"                                                                                # 예: 접속 시작 주소 2개
      zookeeper_connect_string     = ""                                                                                                                 # 예: "" (KRaft; 계약의 zookeeper_free = true)
    }
  }

  mock_resource "aws_msk_configuration" {
    defaults = {
      arn             = "arn:aws:kafka:ap-northeast-2:111111111111:configuration/cp-dev-traces-queue-config/0abc1234-5678-90ab-cdef-EXAMPLE33333-2" # 예: 고정 가짜 구성 ARN
      latest_revision = 1                                                                                                                           # 예: 1 (첫 버전)
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:AmazonMSK_cp-dev-traces-queue_fixture-AbCdEf" # 예: 고정 가짜 시크릿 ARN (두 시크릿이 같은 값이어도 검사에는 영향 없음)
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:ap-northeast-2:111111111111:key/0abc1234-5678-90ab-cdef-EXAMPLE22222" # 예: 고정 가짜 키 ARN
    }
  }
}

# 테스트 fixture 입니다. provider 가 mock 이므로 이 계정에 접근하지 않습니다.
variables {
  expected_account_id = "111111111111"
  region              = "ap-northeast-2"
  environment         = "dev"
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
  workload_security_group_id = "sg-0abcdef012345678a"
  kafka_version              = "3.9.0"
}

run "managed_queue_contract" {
  command = apply

  assert {
    condition     = length(keys(output.queue_managed_contract)) == 11
    error_message = "queue_managed_contract must keep its eleven keys."
  }

  assert {
    condition     = output.queue_managed_contract.cluster_name == "cp-dev-traces-queue"
    error_message = "Cluster name must be cp-<environment>-traces-queue."
  }

  assert {
    condition     = output.queue_managed_contract.topic_name == "dev-tempo-traces-epoch-2" && output.queue_managed_contract.partitions == 3
    error_message = "The epoch 2 topic and its three partitions are part of the contract."
  }

  assert {
    condition     = output.queue_managed_contract.zookeeper_free
    error_message = "An empty zookeeper connect string must be reported as zookeeper_free = true."
  }

  assert {
    condition     = length(output.queue_managed_contract.broker_subnet_ids_by_az) == 3 && length(output.queue_managed_contract.secret_arns) == 2
    error_message = "The contract carries three broker subnets and two secret ARNs."
  }

  assert {
    condition     = output.queue_managed_contract.client_security_group_id == var.workload_security_group_id
    error_message = "The contract must publish the actual node security group, not the placeholder client group."
  }
}

run "cluster_is_scram_only_and_encrypted" {
  command = apply

  assert {
    condition     = aws_msk_cluster.traces.number_of_broker_nodes == 3
    error_message = "Three brokers, one per availability zone."
  }

  assert {
    condition     = aws_msk_cluster.traces.client_authentication[0].sasl[0].scram && !aws_msk_cluster.traces.client_authentication[0].sasl[0].iam && !aws_msk_cluster.traces.client_authentication[0].unauthenticated
    error_message = "Only SASL/SCRAM is enabled; IAM and unauthenticated access stay off."
  }

  assert {
    condition     = aws_msk_cluster.traces.encryption_info[0].encryption_in_transit[0].client_broker == "TLS" && aws_msk_cluster.traces.encryption_info[0].encryption_in_transit[0].in_cluster
    error_message = "Traffic must be TLS between clients and brokers and inside the cluster."
  }

  assert {
    condition     = length(regexall("auto.create.topics.enable=false", aws_msk_configuration.traces.server_properties)) == 1 && length(regexall("min.insync.replicas=2", aws_msk_configuration.traces.server_properties)) == 1
    error_message = "The broker configuration must disable topic auto creation and keep min ISR 2."
  }

  assert {
    condition     = alltrue([for key, secret in aws_secretsmanager_secret.queue_user : startswith(secret.name, "AmazonMSK_")])
    error_message = "Secret names must start with AmazonMSK_ or the association is rejected."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.broker_from_workload.from_port == 9096 && aws_vpc_security_group_egress_rule.workload_to_broker.to_port == 9096
    error_message = "Both node rules must use the 9096 client listener port."
  }
}

run "reject_two_availability_zones" {
  command = plan

  variables {
    kafka_network_contract = {
      broker_security_group_id = "sg-0b0adef012345678a"
      client_security_group_id = "sg-0c1adef012345678a"
      broker_subnet_ids_by_az = {
        "ap-northeast-2a" = "subnet-0iii1111111111111"
        "ap-northeast-2b" = "subnet-0iii2222222222222"
      }
      broker_port = 9096
    }
  }

  expect_failures = [var.kafka_network_contract]
}

run "reject_plaintext_port" {
  command = plan

  variables {
    kafka_network_contract = {
      broker_security_group_id = "sg-0b0adef012345678a"
      client_security_group_id = "sg-0c1adef012345678a"
      broker_subnet_ids_by_az = {
        "ap-northeast-2a" = "subnet-0iii1111111111111"
        "ap-northeast-2b" = "subnet-0iii2222222222222"
        "ap-northeast-2c" = "subnet-0iii3333333333333"
      }
      broker_port = 9092
    }
  }

  expect_failures = [var.kafka_network_contract]
}

run "reject_unsupported_broker_version" {
  command = plan

  variables {
    kafka_version = "3.6.0"
  }

  expect_failures = [var.kafka_version]
}



run "reject_min_isr_equal_to_replication" {
  command = plan

  variables {
    min_insync_replicas = 3
  }

  expect_failures = [var.min_insync_replicas]
}

run "reject_topic_of_another_environment" {
  command = plan

  variables {
    topic_name = "prod-tempo-traces-epoch-2"
  }

  expect_failures = [terraform_data.network_boundary]
}

run "reject_foreign_account" {
  command = plan

  variables {
    expected_account_id = "222222222222"
  }

  expect_failures = [terraform_data.network_boundary]
}
