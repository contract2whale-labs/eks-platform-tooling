# tests/module.tftest.hcl — modules/data (dev · prod 루트 모듈이 공유하는 모듈)
# 모든 AWS 호출을 mock provider 로 대체합니다. 실제 DB · 키 · 버킷이 생기지 않으며 아래 이름 · ARN · 계정 번호는 AWS 에 없는 fixture 입니다 (terraform.tfvars 로 복사하지 않습니다).

mock_provider "aws" {
  override_during = apply # 예: apply 단계에서 computed 값을 아래 defaults 로 채움

  mock_data "aws_rds_engine_version" {
    defaults = { version_actual = "17.6", parameter_group_family = "postgres17", status = "available" }
  }

  mock_data "aws_rds_orderable_db_instance" {
    defaults = { instance_class = "db.t4g.micro", multi_az_capable = true, supports_storage_encryption = true, storage_type = "gp3" }
  }

  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:ap-northeast-2:111111111111:key/00000000-0000-4000-8000-000000000000", key_id = "00000000-0000-4000-8000-000000000000" }
  }

  mock_resource "aws_db_instance" {
    defaults = {
      address               = "cp-live-commercedb.abcdefghijkl.ap-northeast-2.rds.amazonaws.com"
      engine_version_actual = "17.6"
      master_user_secret    = [{ secret_arn = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:rds!db-00000000-0000-4000-8000-000000000000-AbCdEf", kms_key_id = "00000000-0000-4000-8000-000000000000", secret_status = "active" }]
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:ap-northeast-2:111111111111:secret:contract2whale-fixture-AbCdEf" }
  }

  mock_resource "aws_elasticache_serverless_cache" {
    defaults = {
      endpoint            = [{ address = "cp-live-data-redis-fixture.serverless.apn2.cache.amazonaws.com", port = 6379 }]
      reader_endpoint     = [{ address = "cp-live-data-redis-fixture-ro.serverless.apn2.cache.amazonaws.com", port = 6379 }]
      full_engine_version = "8.1"
      status              = "available"
    }
  }
}

variables {
  kyverno_role_arn    = "arn:aws:iam::111111111111:role/platform/cp-live-delivery-kyverno"
  expected_account_id = "111111111111"
  region              = "ap-northeast-2"
  environment         = "dev"

  cluster_contract = {
    name   = "cp-live"
    arn    = "arn:aws:eks:ap-northeast-2:111111111111:cluster/cp-live"
    region = "ap-northeast-2"
    vpc_id = "vpc-0123456789abcdef0"
  }

  network_contract = {
    vpc_id                 = "vpc-0123456789abcdef0"
    vpc_cidr               = "172.20.0.0/16"
    database_subnet_ids    = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb", "subnet-0ccccccccccccccc0"]
    intra_subnet_ids       = ["subnet-0ia0000000000000", "subnet-0ib0000000000000", "subnet-0ic0000000000000"]
    node_security_group_id = "sg-0aaaabbbbccccdddd"
  }

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

  application = {
    namespace                 = "contract2whale-demo"
    deployment                = "commerce-api"
    runtime_service_account   = "commerce-api"
    operator_service_account  = "database-operator"
    migration_service_account = "delivery-migration"
  }
}

# 1. 기본 생성: 사설 · 암호화 · 자동 백업 · 관리 Secret. 비밀번호를 만드는 리소스가 없습니다.
run "creates_private_encrypted_database" {
  command = apply

  assert {
    condition     = aws_db_instance.data.manage_master_user_password == true && aws_db_instance.data.storage_encrypted == true && aws_db_instance.data.publicly_accessible == false && aws_db_instance.data.backup_retention_period == 7
    error_message = "데이터베이스는 관리 Secret · 저장 암호화 · 사설 접근 · 자동 백업으로 만들어야 합니다."
  }

  assert {
    condition     = length(aws_secretsmanager_secret.application) == 3 && aws_secretsmanager_secret.application["runtime"].name == "contract2whale/dev/commerce-api/runtime" && aws_secretsmanager_secret.application["app"].name == "contract2whale/dev/commerce-api/app" && aws_secretsmanager_secret.application["migration"].kms_key_id == aws_kms_key.data.arn
    error_message = "앱 비밀 3개(migration · runtime · app)는 이름 규약과 고객 관리형 키를 써야 합니다 (값은 나중에 채웁니다)."
  }

  assert {
    condition     = aws_db_parameter_group.data.family == "postgres17" && length([for p in aws_db_parameter_group.data.parameter : p if p.name == "rds.force_ssl" && p.value == "1"]) == 1
    error_message = "파라미터 그룹 계열은 조회 결과에서 받고 rds.force_ssl 은 1 이어야 합니다."
  }
}

run "contract_exposes_names_without_secret_values" {
  command = apply

  assert {
    condition     = length(keys(output.data_contract)) == 12 && output.data_contract.export.prefix == "media/dev/commerce-api/" && output.data_contract.database.identifier == "cp-live-commercedb"
    error_message = "data_contract 는 12개 키 · media/<env>/<deployment>/ 접두사 · <cluster>-<db> 식별자를 실어야 합니다."
  }

  assert {
    condition     = can(regex("^arn:aws:secretsmanager:", output.data_contract.credentials.master_secret_arn)) && length(keys(output.data_contract.credentials)) == 7 && output.data_contract.credentials.app_secret_name == "contract2whale/dev/commerce-api/app" && output.data_contract.service_accounts.migration == "delivery-migration"
    error_message = "계약은 관리 Secret ARN · 앱 비밀 이름 7키 · 배포 플랫폼 migration ServiceAccount 이름을 실어야 합니다."
  }

}

# 3. 미디어 저장소: 공개 차단 · 버전 관리 · 접두사 밖 쓰기 거부 · 헤더 없는 업로드 허용(버킷 기본 암호화).
run "media_bucket_restricts_prefix_and_key" {
  command = apply

  assert {
    condition     = aws_s3_bucket_public_access_block.exports.block_public_policy == true && aws_s3_bucket_versioning.exports.versioning_configuration[0].status == "Enabled" && aws_s3_bucket_ownership_controls.exports.rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "미디어 버킷은 공개 차단 · 버전 관리 · BucketOwnerEnforced 를 켜야 합니다 (Medusa file-s3 는 acl = false 로 올립니다)."
  }

  assert {
    condition     = length(jsondecode(aws_s3_bucket_policy.exports.policy).Statement) == 3 && jsondecode(aws_s3_bucket_policy.exports.policy).Statement[1].NotResource[0] == "${aws_s3_bucket.exports.arn}/media/dev/commerce-api/*"
    error_message = "버킷 정책은 TLS · 접두사 · 암호화 키 세 문장이어야 합니다."
  }

  assert {
    condition     = jsondecode(aws_s3_bucket_policy.exports.policy).Statement[2].Condition.Null["s3:x-amz-server-side-encryption-aws-kms-key-id"] == "false" && length([for rule in aws_s3_bucket_server_side_encryption_configuration.exports.rule : rule if one(rule.apply_server_side_encryption_by_default).kms_master_key_id == aws_kms_key.data.arn]) == 1
    error_message = "헤더 없는 업로드는 버킷 기본 암호화(같은 고객 관리형 키)로 통과해야 합니다 — Medusa file-s3 는 KMS 헤더를 붙일 수 없습니다."
  }
}

run "creates_serverless_cache_in_intra_subnets" {
  command = apply

  assert {
    condition     = aws_elasticache_serverless_cache.redis[0].engine == "valkey" && length(aws_elasticache_serverless_cache.redis[0].subnet_ids) == 3 && aws_elasticache_serverless_cache.redis[0].security_group_ids == toset([aws_security_group.redis[0].id])
    error_message = "캐시는 Valkey 엔진 · Intra 서브넷 3개 · 전용 Security Group 으로 만들어야 합니다."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.redis_from_nodes[0].from_port == 6379 && aws_vpc_security_group_ingress_rule.redis_from_nodes[0].referenced_security_group_id == "sg-0aaaabbbbccccdddd" && aws_elasticache_serverless_cache.redis[0].cache_usage_limits[0].data_storage[0].maximum == 1
    error_message = "6379 은 노드 Security Group 에서만 열리고 저장 상한은 입력값이어야 합니다."
  }

  assert {
    condition = (
      toset(keys(output.data_contract.redis)) == toset(["security_group_id", "address", "port", "tls_enabled"]) &&
      output.data_contract.redis.security_group_id == aws_security_group.redis[0].id &&
      output.data_contract.redis.address == "cp-live-data-redis-fixture.serverless.apn2.cache.amazonaws.com" &&
      output.data_contract.redis.port == 6379 && output.data_contract.redis.tls_enabled == true
    )
    error_message = "Redis 공개 계약은 캐시 SG·실제 endpoint·6379·TLS를 전달해야 하며 credential 필드를 포함하면 안 됩니다."
  }
}

# 4. 다른 계정의 클러스터 계약을 거부합니다 (환경 혼입).
run "reject_account_mismatch" {
  command = plan

  variables {
    cluster_contract = {
      name   = "cp-live"
      arn    = "arn:aws:eks:ap-northeast-2:222222222222:cluster/cp-live"
      region = "ap-northeast-2"
      vpc_id = "vpc-0123456789abcdef0"
    }
  }

  expect_failures = [terraform_data.guard]
}

# 5. 다른 리전의 클러스터 계약을 거부합니다.
run "reject_region_mismatch" {
  command = plan

  variables {
    cluster_contract = {
      name   = "cp-live"
      arn    = "arn:aws:eks:us-east-1:111111111111:cluster/cp-live"
      region = "us-east-1"
      vpc_id = "vpc-0123456789abcdef0"
    }
  }

  expect_failures = [terraform_data.guard]
}

# 6. 클러스터와 다른 VPC 의 서브넷을 거부합니다.
run "reject_vpc_mismatch" {
  command = plan

  variables {
    network_contract = {
      vpc_id                 = "vpc-0fedcba9876543210"
      vpc_cidr               = "10.30.0.0/16"
      database_subnet_ids    = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]
      intra_subnet_ids       = ["subnet-0ia0000000000000", "subnet-0ib0000000000000"]
      node_security_group_id = "sg-0aaaabbbbccccdddd"
    }
  }

  expect_failures = [terraform_data.guard]
}

run "reject_duplicate_subnets" {
  command = plan

  variables {
    network_contract = {
      vpc_id                 = "vpc-0123456789abcdef0"
      vpc_cidr               = "172.20.0.0/16"
      database_subnet_ids    = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0aaaaaaaaaaaaaaaa"]
      intra_subnet_ids       = ["subnet-0ia0000000000000", "subnet-0ib0000000000000"]
      node_security_group_id = "sg-0aaaabbbbccccdddd"
    }
  }

  expect_failures = [var.network_contract]
}

run "reject_zero_backup_retention" {
  command = plan

  variables {
    database = {
      name                  = "commercedb"
      engine_version        = "17.6"
      instance_class        = "db.t4g.micro"
      allocated_storage     = 20
      max_allocated_storage = 100
      backup_retention_days = 0
      multi_az              = false
      deletion_protection   = false
    }
  }

  expect_failures = [var.database]
}

# 9. 리전이 제공하지 않는 엔진 버전을 거부합니다 (조회 결과가 입력과 다름 — 원본 version_check 의 판정).
run "reject_engine_version_not_offered" {
  command = plan

  override_data {
    target = data.aws_rds_engine_version.postgres
    values = { version_actual = "17.4", parameter_group_family = "postgres17" }
  }

  expect_failures = [terraform_data.guard]
}

# 10. Prod 환경은 Multi-AZ · 삭제 보호 · 7일 이상 백업을 요구합니다 (Dev 값을 Prod 에 그대로 쓰면 계획이 멈춤).
run "reject_dev_settings_in_prod" {
  command = plan

  variables {
    environment = "prod"
  }

  expect_failures = [aws_db_instance.data]
}

# 11. 같은 Intra 서브넷을 두 번 적은 입력을 거부합니다 (서버리스 캐시는 AZ 가 다른 서브넷을 요구합니다).
run "reject_duplicate_intra_subnets" {
  command = plan

  variables {
    network_contract = {
      vpc_id                 = "vpc-0123456789abcdef0"
      vpc_cidr               = "172.20.0.0/16"
      database_subnet_ids    = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb", "subnet-0ccccccccccccccc0"]
      intra_subnet_ids       = ["subnet-0ia0000000000000", "subnet-0ia0000000000000"]
      node_security_group_id = "sg-0aaaabbbbccccdddd"
    }
  }

  expect_failures = [var.network_contract]
}

# 12. Prod 는 캐시를 내릴 수 없습니다 (DB 값은 Prod 규격이라 여기서 멈추는 것은 guard 하나입니다).
run "reject_prod_without_redis" {
  command = plan

  variables {
    environment  = "prod"
    enable_redis = false

    database = {
      name                  = "commercedb"
      engine_version        = "17.6"
      instance_class        = "db.t4g.micro"
      allocated_storage     = 20
      max_allocated_storage = 100
      backup_retention_days = 7
      multi_az              = true
      deletion_protection   = true
    }
  }

  expect_failures = [terraform_data.guard]
}

# 13. Prod 는 스냅샷 없는 캐시를 거부합니다 (Dev 는 0 일로 둘 수 있습니다).
run "reject_prod_cache_without_snapshots" {
  command = plan

  variables {
    environment = "prod"

    redis = {
      major_engine_version    = "8"
      max_data_storage_gb     = 1
      max_ecpu_per_second     = 5000
      snapshot_retention_days = 0
    }

    database = {
      name                  = "commercedb"
      engine_version        = "17.6"
      instance_class        = "db.t4g.micro"
      allocated_storage     = 20
      max_allocated_storage = 100
      backup_retention_days = 7
      multi_az              = true
      deletion_protection   = true
    }
  }

  expect_failures = [aws_elasticache_serverless_cache.redis]
}

run "disabled_cache_leaves_null_contract" {
  command = apply

  variables {
    enable_redis = false
  }

  assert {
    condition     = length(aws_elasticache_serverless_cache.redis) == 0 && length(aws_security_group.redis) == 0 && length(aws_vpc_security_group_ingress_rule.redis_from_nodes) == 0
    error_message = "enable_redis = false 는 캐시 · Security Group · 규칙 셋을 모두 없애야 합니다."
  }

}

run "operator_read_is_scoped_to_existing_kyverno_role" {
  command = apply
  assert {
    condition     = aws_iam_role_policy.kyverno_operator_read.role == "cp-live-delivery-kyverno" && jsondecode(aws_iam_role_policy.kyverno_operator_read.policy).Statement[0].Resource == aws_ecr_repository.operator.arn && sort(jsondecode(aws_iam_role_policy.kyverno_operator_read.policy).Statement[0].Action) == tolist(["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:DescribeImages", "ecr:GetDownloadUrlForLayer"])
    error_message = "Only the existing Kyverno role may read the exact operator repository; no write or KMS permission is added."
  }
}

run "reject_cross_account_kyverno_role" {
  command = plan
  variables {
    kyverno_role_arn = "arn:aws:iam::222222222222:role/platform/cp-live-delivery-kyverno"
  }
  expect_failures = [terraform_data.guard]
}
