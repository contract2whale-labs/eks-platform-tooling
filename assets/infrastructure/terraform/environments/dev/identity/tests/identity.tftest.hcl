# tests/identity.tftest.hcl — identity 루트 모듈 (dev · prod 공통 코드)
# 모듈 안 리소스(module.component.terraform_data.guard)는 expect_failures 로 지정할 수 없으므로 계정 · 접두사 거부는 모듈 테스트(modules/tenant-pod-identity/tests)가 맡습니다.

mock_provider "aws" {
  override_during = apply # 예: apply 단계에서 computed 값을 아래 defaults 로 채움

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/platform/contract2whale-dev-eks-app-fixture" }
  }

  mock_resource "aws_eks_pod_identity_association" {
    defaults = { association_id = "a-fixture0000000000" }
  }
}

variables {
  expected_account_id = "111111111111"
  region              = "ap-northeast-2"
  environment         = "dev"
  state_bucket_name   = "company-dev-tfstate-111111111111"
}

override_data {
  target = data.terraform_remote_state.data
  values = {
    outputs = {
      data_contract = {
        environment      = "dev"
        account_id       = "111111111111"
        region           = "ap-northeast-2"
        cluster_name     = "contract2whale-dev-eks"
        namespace        = "contract2whale-demo"
        service_accounts = { runtime = "commerce-api", operator = "database-operator", migration = "delivery-migration" }
        database         = { identifier = "contract2whale-dev-eks-commercedb", port = 5432, name = "commercedb" }
        redis            = { address = "contract2whale-dev-eks-data-redis-abcdef.serverless.apn2.cache.amazonaws.com", port = 6379, tls_enabled = true }
        credentials = {
          master_secret_arn    = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:rds!db-00000000-AbCdEf"
          migration_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:contract2whale/dev/commerce-api/migration-AbCdEf"
          runtime_secret_arn   = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:contract2whale/dev/commerce-api/runtime-AbCdEf"
          app_secret_arn       = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:contract2whale/dev/commerce-api/app-AbCdEf"
        }
        export      = { bucket_name = "cp-dev-app-exports-111111111111-ap-northeast-2", bucket_arn = "arn:aws:s3:::cp-dev-app-exports-111111111111-ap-northeast-2", prefix = "media/dev/commerce-api/" }
        kms_key_arn = "arn:aws:kms:ap-northeast-2:111111111111:key/00000000-0000-4000-8000-000000000000"
        operator    = { repository_url = "111111111111.dkr.ecr.ap-northeast-2.amazonaws.com/contract2whale/database-operator", repository_name = "contract2whale/database-operator" }
      }
    }
  }
}

# eks 루트 모듈 출력 (환경 root 와 모듈 연결)
override_data {
  target = data.terraform_remote_state.eks
  values = {
    outputs = {
      cluster_contract = {
        name = "contract2whale-dev-eks"
        arn  = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
      }
    }
  }
}

# 운영 도구 operations 루트 모듈 출력 (ESO controller Role)
override_data {
  target = data.terraform_remote_state.operations
  values = {
    outputs = {
      external_secrets_role_arn = "arn:aws:iam::111111111111:role/contract2whale-dev-eks-external-secrets"
    }
  }
}

# 배포 플랫폼이 만든 migration Role 조회 결과
override_data {
  target = data.aws_iam_role.migration
  values = {
    arn                = "arn:aws:iam::111111111111:role/platform/contract2whale-dev-eks-delivery-migration"
    name               = "contract2whale-dev-eks-delivery-migration"
    path               = "/platform/"
    assume_role_policy = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"pods.eks.amazonaws.com\"},\"Action\":[\"sts:AssumeRole\",\"sts:TagSession\"]}]}"
  }
}

# 1. 데이터 계약에서 모듈 입력을 추리고 migration Role 은 조회 결과를 씁니다.
run "assembles_contract_from_state_and_lookup" {
  command = plan

  assert {
    condition     = length(keys(local.data_contract)) == 9 && local.data_contract.export.prefix == "media/dev/commerce-api/" && local.cluster_contract.arn == "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
    error_message = "data_contract 9키와 클러스터 ARN 을 State 에서 조립해야 합니다."
  }

  assert {
    condition     = data.aws_iam_role.migration.name == "contract2whale-dev-eks-delivery-migration"
    error_message = "migration Role 은 <cluster>-delivery-migration 이름으로 조회해야 합니다."
  }
}

run "apply_creates_three_identities" {
  command = apply

  assert {
    condition     = length(keys(output.identity_contract)) == 7 && output.identity_contract.namespace == "contract2whale-demo" && output.identity_contract.migration.role_arn == "arn:aws:iam::111111111111:role/platform/contract2whale-dev-eks-delivery-migration"
    error_message = "identity_contract 는 7키이고 migration 은 배포 플랫폼 Role 을 가리켜야 합니다."
  }

}

# 3. 이 디렉터리는 prod 를 거부합니다 (Prod 계약을 함께 넣어도 디렉터리 경계가 막습니다).
run "reject_prod_in_dev_directory" {
  command = plan

  variables {
    environment = "prod"
  }

  override_data {
    target = data.terraform_remote_state.data
    values = {
      outputs = {
        data_contract = {
          environment      = "prod"
          account_id       = "111111111111"
          region           = "ap-northeast-2"
          cluster_name     = "contract2whale-dev-eks"
          namespace        = "contract2whale-demo"
          service_accounts = { runtime = "commerce-api", operator = "database-operator", migration = "delivery-migration" }
          credentials = {
            master_secret_arn    = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:rds!db-00000000-AbCdEf"
            migration_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:contract2whale/prod/commerce-api/migration-AbCdEf"
            runtime_secret_arn   = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:contract2whale/prod/commerce-api/runtime-AbCdEf"
            app_secret_arn       = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:contract2whale/prod/commerce-api/app-AbCdEf"
          }
          export      = { bucket_arn = "arn:aws:s3:::cp-prod-app-exports-111111111111-ap-northeast-2", prefix = "media/prod/commerce-api/" }
          kms_key_arn = "arn:aws:kms:ap-northeast-2:111111111111:key/00000000-0000-4000-8000-000000000000"
        }
      }
    }
  }

  expect_failures = [terraform_data.environment_boundary]
}

# 4. 데이터 루트 모듈이 아직 적용되지 않았으면 거부합니다.
run "reject_data_state_without_contract" {
  command = plan

  override_data {
    target = data.terraform_remote_state.data
    values = { outputs = { data_contract = { environment = "dev", account_id = "111111111111" } } }
  }

  expect_failures = [data.terraform_remote_state.data]
}

# 5. 조회한 Role 이 배포 플랫폼 의 Pod Identity Role 이 아니면 거부합니다 (같은 이름의 다른 Role).
run "reject_role_without_pod_identity_trust" {
  command = plan

  override_data {
    target = data.aws_iam_role.migration
    values = {
      arn                = "arn:aws:iam::111111111111:role/contract2whale-dev-eks-delivery-migration"
      name               = "contract2whale-dev-eks-delivery-migration"
      path               = "/"
      assume_role_policy = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"ec2.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}"
    }
  }

  expect_failures = [data.aws_iam_role.migration]
}
