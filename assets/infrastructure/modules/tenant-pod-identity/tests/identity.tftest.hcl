# tests/identity.tftest.hcl — modules/tenant-pod-identity (dev · prod 루트 모듈이 공유하는 모듈)
# 신원은 commerce-api 쪽에만 있습니다. 스토어프런트(commerce-web) 는 AWS 를 부르지 않아 이 모듈에 등장하지 않습니다.
# 모든 AWS 호출을 mock provider 로 대체합니다. 실제 Role · 연결이 생기지 않으며 아래 ARN · 계정 번호는 AWS 에 없는 fixture 입니다.

mock_provider "aws" {
  override_during = apply # 예: apply 단계에서 computed 값을 아래 defaults 로 채움

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/platform/cp-live-app-fixture", unique_id = "AROAFIXTUREFIXTURE00" }
  }

  mock_resource "aws_eks_pod_identity_association" {
    defaults = { association_id = "a-fixture0000000000", association_arn = "arn:aws:eks:ap-northeast-2:111111111111:podidentityassociation/cp-live/a-fixture0000000000" }
  }
}

variables {
  expected_account_id = "111111111111"
  region              = "ap-northeast-2"
  environment         = "dev"

  cluster_contract = {
    name = "cp-live"
    arn  = "arn:aws:eks:ap-northeast-2:111111111111:cluster/cp-live"
  }

  data_contract = {
    environment  = "dev"
    account_id   = "111111111111"
    region       = "ap-northeast-2"
    cluster_name = "cp-live"
    namespace    = "contract2whale-demo"

    service_accounts = {
      runtime   = "commerce-api"
      operator  = "database-operator"
      migration = "delivery-migration"
    }

    credentials = {
      master_secret_arn    = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:rds!db-00000000-0000-4000-8000-000000000000-AbCdEf"
      migration_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:contract2whale/dev/commerce-api/migration-AbCdEf"
      runtime_secret_arn   = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:contract2whale/dev/commerce-api/runtime-AbCdEf"
      app_secret_arn       = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:contract2whale/dev/commerce-api/app-AbCdEf"
    }

    export = {
      bucket_arn = "arn:aws:s3:::cp-dev-app-exports-111111111111-ap-northeast-2"
      prefix     = "media/dev/commerce-api/"
    }

    kms_key_arn = "arn:aws:kms:ap-northeast-2:111111111111:key/00000000-0000-4000-8000-000000000000"
  }

  migration_role_arn        = "arn:aws:iam::111111111111:role/platform/cp-live-delivery-migration"
  external_secrets_role_arn = "arn:aws:iam::111111111111:role/cp-live-external-secrets"
}

run "creates_three_roles_and_three_associations" {
  command = apply

  assert {
    condition     = aws_iam_role.runtime.name == "cp-live-app-runtime" && aws_iam_role.operator.name == "cp-live-app-database-operator" && aws_iam_role.secrets_reader.name == "cp-live-data-app-secrets" && aws_iam_role_policy.migration.role == "cp-live-delivery-migration"
    error_message = "runtime · operator · 앱 비밀 읽기 Role 을 새로 만들고 migration 은 배포 플랫폼 Role 에 정책만 붙여야 합니다."
  }

  assert {
    condition     = aws_eks_pod_identity_association.runtime.service_account == "commerce-api" && aws_eks_pod_identity_association.operator.service_account == "database-operator" && aws_eks_pod_identity_association.migration.role_arn == var.migration_role_arn
    error_message = "연결 세 개는 각각 commerce-api · database-operator · delivery-migration ServiceAccount 를 가리켜야 합니다."
  }

  assert {
    condition     = alltrue([for policy in [aws_iam_role.runtime.assume_role_policy, aws_iam_role.operator.assume_role_policy] : jsondecode(policy).Statement[0].Condition.StringEquals["aws:RequestTag/eks-cluster-arn"] == var.cluster_contract.arn])
    error_message = "신뢰 정책은 클러스터 ARN 세션 태그로 다른 클러스터의 같은 이름 ServiceAccount 를 막아야 합니다."
  }

  assert {
    condition     = jsondecode(aws_iam_role.secrets_reader.assume_role_policy).Statement[0].Principal.AWS == var.external_secrets_role_arn && jsondecode(aws_iam_role.secrets_reader.assume_role_policy).Statement[0].Condition.StringEquals["aws:PrincipalTag/kubernetes-service-account"] == "external-secrets" # 예: controller Role 과 그 ServiceAccount 태그만
    error_message = "앱 비밀 읽기 Role 은 External Secrets controller Role 만 신뢰해야 합니다 (assume-role chaining)."
  }
}

# 2. 권한 경계: runtime 은 관리 시크릿을 읽지 못하고, operator 는 내보내기 버킷을 만지지 못합니다.
run "identities_do_not_overlap" {
  command = apply

  assert {
    condition     = length([for statement in jsondecode(aws_iam_role_policy.runtime.policy).Statement : statement if contains(try(statement.Resource, []), var.data_contract.credentials.master_secret_arn)]) == 0
    error_message = "runtime 정책에 관리자(master) 시크릿이 들어가면 안 됩니다."
  }

  assert {
    condition     = [for statement in jsondecode(aws_iam_role_policy.runtime.policy).Statement : statement.Sid] == ["RuntimeSecret", "OwnExportObjects", "ListOwnExportPrefix", "ExportKeyViaS3", "RuntimeSecretKey"] && jsondecode(aws_iam_role_policy.runtime.policy).Statement[1].Resource[0] == "arn:aws:s3:::cp-dev-app-exports-111111111111-ap-northeast-2/media/dev/commerce-api/*"
    error_message = "runtime 정책은 다섯 문장이고 객체 권한은 자기 접두사로만 제한되어야 합니다."
  }

  assert {
    condition     = contains(jsondecode(aws_iam_role_policy.runtime.policy).Statement[1].Action, "s3:DeleteObject") && length([for statement in jsondecode(aws_iam_role_policy.migration.policy).Statement : statement if startswith(statement.Action[0], "s3:")]) == 0
    error_message = "runtime 은 미디어 객체를 지울 수 있어야 하고(관리자 화면), migration 에는 S3 권한이 없어야 합니다."
  }

  assert {
    condition     = length([for statement in jsondecode(aws_iam_role_policy.operator.policy).Statement : statement if startswith(statement.Action[0], "s3:")]) == 0 && [for statement in jsondecode(aws_iam_role_policy.migration.policy).Statement : statement.Sid] == ["MigrationSecret", "MigrationSecretKey"]
    error_message = "operator 는 S3 권한이 없고 migration 은 시크릿과 그 키만 써야 합니다."
  }

  # 앱 비밀(JWT_SECRET · COOKIE_SECRET)은 앱 Pod 과 마이그레이션 Job 이 읽고, 운영자는 실행 계정 비밀에 옮겨 적으려고 읽기만 합니다 (쓰기 없음).
  assert {
    condition     = contains(jsondecode(aws_iam_role_policy.runtime.policy).Statement[0].Resource, var.data_contract.credentials.app_secret_arn) && contains(jsondecode(aws_iam_role_policy.migration.policy).Statement[0].Resource, var.data_contract.credentials.app_secret_arn) && length([for statement in jsondecode(aws_iam_role_policy.operator.policy).Statement : statement if contains(try(statement.Resource, []), var.data_contract.credentials.app_secret_arn)]) == 1 && alltrue([for statement in jsondecode(aws_iam_role_policy.operator.policy).Statement : sort(statement.Action) == tolist(["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue"]) if contains(try(statement.Resource, []), var.data_contract.credentials.app_secret_arn)])
    error_message = "앱 비밀은 runtime · migration 이 읽고, operator 는 읽기 두 동작의 문장 하나로만 다뤄야 합니다."
  }

  # 후보 비밀번호 생성(get-random-password)은 operator 만 합니다. 리소스를 지정할 수 없는 동작이라 Resource 는 ["*"] 입니다.
  assert {
    condition     = length([for statement in jsondecode(aws_iam_role_policy.operator.policy).Statement : statement if statement.Sid == "GeneratePasswords" && statement.Action == ["secretsmanager:GetRandomPassword"] && statement.Resource == ["*"]]) == 1 && !strcontains(aws_iam_role_policy.runtime.policy, "GetRandomPassword") && !strcontains(aws_iam_role_policy.migration.policy, "GetRandomPassword")
    error_message = "operator 정책에만 GetRandomPassword 문장 하나(Resource [\"*\"])가 있어야 합니다."
  }

  # 앱 비밀 읽기 Role 은 ExternalSecret 두 개가 쓰는 세 비밀만 읽고 관리자 시크릿은 읽지 못합니다.
  assert {
    condition     = toset(jsondecode(aws_iam_role_policy.secrets_reader.policy).Statement[0].Resource) == toset([var.data_contract.credentials.runtime_secret_arn, var.data_contract.credentials.migration_secret_arn, var.data_contract.credentials.app_secret_arn]) && !strcontains(aws_iam_role_policy.secrets_reader.policy, var.data_contract.credentials.master_secret_arn)
    error_message = "앱 비밀 읽기 Role 은 실행 계정 · 스키마 변경 계정 · 앱 비밀 세 개만 읽어야 합니다."
  }
}

# 3. 계약: 세 신원의 Role ARN · ServiceAccount · 연결 ID 와 앱 비밀 읽기 Role ARN.
run "contract_carries_three_identities" {
  command = apply

  assert {
    condition     = length(keys(output.identity_contract)) == 7 && output.identity_contract.migration.role_arn == var.migration_role_arn && output.identity_contract.secrets_reader.role_arn == aws_iam_role.secrets_reader.arn && output.identity_contract.namespace == "contract2whale-demo"
    error_message = "identity_contract 는 7개 키(세 신원 · 앱 비밀 읽기 Role)를 실어야 합니다."
  }

}

# 4. 다른 환경의 데이터 계약을 거부합니다 (Prod 계약을 Dev 루트 모듈에 넣은 경우).
run "reject_contract_from_other_environment" {
  command = plan

  variables {
    data_contract = {
      environment  = "prod"
      account_id   = "111111111111"
      region       = "ap-northeast-2"
      cluster_name = "cp-live"
      namespace    = "contract2whale-demo"
      service_accounts = {
        runtime   = "commerce-api"
        operator  = "database-operator"
        migration = "delivery-migration"
      }
      credentials = {
        master_secret_arn    = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:rds!db-000-AbCdEf"
        migration_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:contract2whale/prod/commerce-api/migration-AbCdEf"
        runtime_secret_arn   = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:contract2whale/prod/commerce-api/runtime-AbCdEf"
      }
      export = {
        bucket_arn = "arn:aws:s3:::cp-prod-app-exports-111111111111-ap-northeast-2"
        prefix     = "media/prod/commerce-api/"
      }
      kms_key_arn = "arn:aws:kms:ap-northeast-2:111111111111:key/00000000-0000-4000-8000-000000000000"
    }
  }

  expect_failures = [terraform_data.guard]
}

# 5. 다른 클러스터의 계약을 거부합니다.
run "reject_contract_from_other_cluster" {
  command = plan

  variables {
    cluster_contract = {
      name = "cp-other"
      arn  = "arn:aws:eks:ap-northeast-2:111111111111:cluster/cp-other"
    }
  }

  expect_failures = [terraform_data.guard]
}

run "reject_secret_arn_from_other_account" {
  command = plan

  variables {
    data_contract = {
      environment  = "dev"
      account_id   = "111111111111"
      region       = "ap-northeast-2"
      cluster_name = "cp-live"
      namespace    = "contract2whale-demo"
      service_accounts = {
        runtime   = "commerce-api"
        operator  = "database-operator"
        migration = "delivery-migration"
      }
      credentials = {
        master_secret_arn    = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:rds!db-000-AbCdEf"
        migration_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:contract2whale/dev/commerce-api/migration-AbCdEf"
        runtime_secret_arn   = "arn:aws:secretsmanager:ap-northeast-2:222222222222:secret:contract2whale/dev/commerce-api/runtime-AbCdEf"
      }
      export = {
        bucket_arn = "arn:aws:s3:::cp-dev-app-exports-111111111111-ap-northeast-2"
        prefix     = "media/dev/commerce-api/"
      }
      kms_key_arn = "arn:aws:kms:ap-northeast-2:111111111111:key/00000000-0000-4000-8000-000000000000"
    }
  }

  expect_failures = [terraform_data.guard]
}

# 7. 다른 계정의 migration Role 을 거부합니다.
run "reject_migration_role_from_other_account" {
  command = plan

  variables {
    migration_role_arn = "arn:aws:iam::222222222222:role/platform/cp-live-delivery-migration"
  }

  expect_failures = [terraform_data.guard]
}

# 8. 배포 전달 Role 이 아닌 다른 Role 을 거부합니다 (이름 규약 검사).
run "reject_role_that_is_not_delivery_migration" {
  command = plan

  variables {
    migration_role_arn = "arn:aws:iam::111111111111:role/platform/cp-live-delivery-runner"
  }

  expect_failures = [terraform_data.guard]
}

# 9. Secrets Manager ARN 이 아닌 값을 변수 단계에서 거부합니다.
run "reject_non_secret_arn" {
  command = plan

  variables {
    data_contract = {
      environment  = "dev"
      account_id   = "111111111111"
      region       = "ap-northeast-2"
      cluster_name = "cp-live"
      namespace    = "contract2whale-demo"
      service_accounts = {
        runtime   = "commerce-api"
        operator  = "database-operator"
        migration = "delivery-migration"
      }
      credentials = {
        master_secret_arn    = "arn:aws:ssm:ap-northeast-2:111111111111:parameter/contract2whale/dev/master"
        migration_secret_arn = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:contract2whale/dev/commerce-api/migration-AbCdEf"
        runtime_secret_arn   = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:contract2whale/dev/commerce-api/runtime-AbCdEf"
      }
      export = {
        bucket_arn = "arn:aws:s3:::cp-dev-app-exports-111111111111-ap-northeast-2"
        prefix     = "media/dev/commerce-api/"
      }
      kms_key_arn = "arn:aws:kms:ap-northeast-2:111111111111:key/00000000-0000-4000-8000-000000000000"
    }
  }

  expect_failures = [var.data_contract]
}
