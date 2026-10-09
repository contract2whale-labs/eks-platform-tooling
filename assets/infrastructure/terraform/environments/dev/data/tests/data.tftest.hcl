# tests/data.tftest.hcl — data 루트 모듈 (dev · prod 공통 코드)
# 모듈 안 리소스(module.component.terraform_data.guard)는 expect_failures 로 지정할 수 없으므로(Terraform 1.16.0) 계정 · 리전 · 버전 거부는 모듈 테스트(modules/data/tests)가 맡습니다.
# terraform_remote_state 는 override_data 로 가짜 출력을 줍니다. 실제 AWS · S3 API 를 호출하지 않습니다.

mock_provider "aws" {
  override_during = apply # 예: apply 단계에서 computed 값을 아래 defaults 로 채움

  mock_data "aws_rds_engine_version" {
    defaults = { version_actual = "17.6", parameter_group_family = "postgres17" }
  }

  mock_data "aws_rds_orderable_db_instance" {
    defaults = { instance_class = "db.t4g.micro", multi_az_capable = true }
  }

  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:ap-northeast-2:111111111111:key/00000000-0000-4000-8000-000000000000", key_id = "00000000-0000-4000-8000-000000000000" }
  }

  mock_resource "aws_db_instance" {
    defaults = {
      address               = "contract2whale-dev-eks-commercedb.abcdefghijkl.ap-northeast-2.rds.amazonaws.com"
      engine_version_actual = "17.6"
      master_user_secret    = [{ secret_arn = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:rds!db-00000000-0000-4000-8000-000000000000-AbCdEf", kms_key_id = "00000000-0000-4000-8000-000000000000", secret_status = "active" }]
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:contract2whale-fixture-AbCdEf" }
  }

  mock_resource "aws_elasticache_serverless_cache" {
    defaults = {
      endpoint            = [{ address = "contract2whale-dev-eks-data-redis-fixture.serverless.apn2.cache.amazonaws.com", port = 6379 }]
      full_engine_version = "8.1"
      status              = "available"
    }
  }
}

variables {
  expected_account_id = "111111111111"
  region              = "ap-northeast-2"
  environment         = "dev"
  state_bucket_name   = "company-dev-tfstate-111111111111"

  database = {
    name                  = "commercedb"
    engine_version        = "17.6"
    instance_class        = "db.t4g.micro"
    allocated_storage     = 20
    max_allocated_storage = 100
    backup_retention_days = 7
    multi_az              = false
    deletion_protection   = false
  }
}

# eks State 출력 (환경 root 와 모듈 연결 cluster_contract + 노드와 Add-on 노드 SG)
override_data {
  target = data.terraform_remote_state.eks
  values = {
    outputs = {
      cluster_contract = {
        name               = "contract2whale-dev-eks"
        arn                = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
        region             = "ap-northeast-2"
        vpc_id             = "vpc-0123456789abcdef0"
        kubernetes_version = "1.36"
      }
      node_security_group_id = "sg-0aaaabbbbccccdddd"
    }
  }
}

# network/vpc State 출력 (출력 계약과 계약 테스트)
override_data {
  target = data.terraform_remote_state.network
  values = {
    outputs = {
      vpc_id             = "vpc-0123456789abcdef0"
      vpc_cidr_block     = "172.20.0.0/16"
      private_subnet_ids = ["subnet-0ra0000000000000", "subnet-0rb0000000000000", "subnet-0rc0000000000000"]
      intra_subnet_ids   = ["subnet-0ia0000000000000", "subnet-0ib0000000000000", "subnet-0ic0000000000000"]
    }
  }
}

override_data {
  target = data.terraform_remote_state.delivery
  values = {
    outputs = {
      delivery_contract = {
        environment = "dev"
        kyverno     = { role_arn = "arn:aws:iam::111111111111:role/platform/contract2whale-dev-eks-delivery-kyverno" }
        application = {
          namespace = "contract2whale-demo"
          web       = { deployment = "commerce-web", container = "commerce-web" }
          api       = { deployment = "commerce-api", container = "commerce-api", migration_service_account = "delivery-migration" }
        }
      }
    }
  }
}

# 1. 세 State 출력에서 모듈 계약 세 개를 조립합니다 (입력 파일 없음).
run "assembles_contracts_from_state" {
  command = plan

  assert {
    condition     = local.cluster_contract.name == "contract2whale-dev-eks" && length(keys(local.cluster_contract)) == 4 && local.network_contract.node_security_group_id == "sg-0aaaabbbbccccdddd"
    error_message = "cluster_contract 4항목과 노드 Security Group 을 State 에서 조립해야 합니다."
  }

  assert {
    condition     = length(local.network_contract.database_subnet_ids) == 3 && length(local.network_contract.intra_subnet_ids) == 3 && local.application.namespace == "contract2whale-demo" && local.application.deployment == "commerce-api"
    error_message = "DB 서브넷 3개 · Intra 서브넷 3개 · 배포 플랫폼 앱 좌표를 State 에서 읽어야 합니다."
  }
}

run "first_apply_creates_contract" {
  command = apply

  assert {
    condition     = length(keys(output.data_contract)) == 12 && output.data_contract.database.identifier == "contract2whale-dev-eks-commercedb" && output.data_contract.export.prefix == "media/dev/commerce-api/"
    error_message = "첫 적용은 12키 계약 · <cluster>-commercedb 식별자 · media/dev/commerce-api/ 접두사를 내야 합니다."
  }

  assert {
    condition     = output.data_contract.credentials.runtime_secret_name == "contract2whale/dev/commerce-api/runtime" && output.data_contract.credentials.app_secret_name == "contract2whale/dev/commerce-api/app" && terraform_data.environment_boundary.input == "dev"
    error_message = "비밀 이름 3개와 환경 표식이 계약에 있어야 합니다."
  }

}

# 3. 이 디렉터리는 prod 를 거부합니다 (Prod 규격의 입력 · Prod 계약을 넣어도 디렉터리 경계가 먼저 막습니다).
run "reject_prod_in_dev_directory" {
  command = plan

  variables {
    environment = "prod"

    database = {
      name                  = "commercedb"
      engine_version        = "17.6"
      instance_class        = "db.t4g.micro"
      allocated_storage     = 20
      max_allocated_storage = 100
      backup_retention_days = 14
      multi_az              = true
      deletion_protection   = true
    }
  }

  override_data {
    target = data.terraform_remote_state.delivery
    values = {
      outputs = {
        delivery_contract = {
          environment = "prod"
          kyverno     = { role_arn = "arn:aws:iam::111111111111:role/platform/contract2whale-dev-eks-delivery-kyverno" }
          application = {
            namespace = "contract2whale-demo"
            web       = { deployment = "commerce-web", container = "commerce-web" }
            api       = { deployment = "commerce-api", container = "commerce-api", migration_service_account = "delivery-migration" }
          }
        }
      }
    }
  }

  expect_failures = [terraform_data.environment_boundary]
}

# 4. 배포 전달 State 가 아직 없으면(또는 다른 환경이면) 거부합니다 (배포 플랫폼 코드의 최초 적용 선행).
run "reject_delivery_state_of_other_environment" {
  command = plan

  override_data {
    target = data.terraform_remote_state.delivery
    values = {
      outputs = {
        delivery_contract = {
          environment = "prod"
          kyverno     = { role_arn = "arn:aws:iam::111111111111:role/platform/contract2whale-dev-eks-delivery-kyverno" }
          application = {
            namespace = "contract2whale-demo"
            web       = { deployment = "commerce-web", container = "commerce-web" }
            api       = { deployment = "commerce-api", container = "commerce-api", migration_service_account = "delivery-migration" }
          }
        }
      }
    }
  }

  expect_failures = [data.terraform_remote_state.delivery]
}

# 5. 네트워크 State 에 Private 서브넷이 하나뿐이면 거부합니다.
run "reject_network_without_two_subnets" {
  command = plan

  override_data {
    target = data.terraform_remote_state.network
    values = {
      outputs = {
        vpc_id             = "vpc-0123456789abcdef0"
        vpc_cidr_block     = "172.20.0.0/16"
        private_subnet_ids = ["subnet-0ra0000000000000"]
        intra_subnet_ids   = ["subnet-0ia0000000000000", "subnet-0ib0000000000000", "subnet-0ic0000000000000"]
      }
    }
  }

  expect_failures = [data.terraform_remote_state.network]
}

# 6. 네트워크 State 에 Intra 서브넷이 없으면 거부합니다 (서버리스 캐시가 앉을 자리가 없음 — 출력 계약과 계약 테스트 를 먼저 적용).
run "reject_network_without_intra_subnets" {
  command = plan

  override_data {
    target = data.terraform_remote_state.network
    values = {
      outputs = {
        vpc_id             = "vpc-0123456789abcdef0"
        vpc_cidr_block     = "172.20.0.0/16"
        private_subnet_ids = ["subnet-0ra0000000000000", "subnet-0rb0000000000000", "subnet-0rc0000000000000"]
        intra_subnet_ids   = []
      }
    }
  }

  expect_failures = [data.terraform_remote_state.network]
}
