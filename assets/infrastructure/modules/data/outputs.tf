# outputs.tf — modules/data (dev · prod 루트 모듈이 공유하는 모듈)
# 읽는 쪽: 데이터 루트 모듈과 PostgreSQL 버전 고정 신원 루트 모듈(비밀 ARN · 미디어 접두사 · 키), 데이터베이스 초기화 Job, 앱 관측 계약 앱 선언, 릴리스 파이프라인 앱 저장소 · 릴리스, 운영 환경 두 워크로드의 env.

output "data_contract" {
  description = "Account, region, environment, cluster, namespace, service accounts, database coordinates, cache endpoint, secret ARNs, media location, KMS key and operator repository (12 keys)."
  value = {
    environment  = var.environment           # 예: "dev"
    account_id   = var.expected_account_id   # 예: "111111111111"
    region       = var.region                # 예: "ap-northeast-2"
    cluster_name = var.cluster_contract.name # 예: "contract2whale-dev-eks"
    namespace    = var.application.namespace # 예: "contract2whale-demo"

    service_accounts = {
      runtime   = var.application.runtime_service_account   # 예: "commerce-api"
      operator  = var.application.operator_service_account  # 예: "database-operator"
      migration = var.application.migration_service_account # 예: "delivery-migration" (배포 플랫폼이 만든 SA 이름)
    }

    database = {
      identifier            = aws_db_instance.data.identifier            # 예: "contract2whale-dev-eks-commercedb"
      address               = aws_db_instance.data.address               # 예: "contract2whale-dev-eks-commercedb.abcdefghij.ap-northeast-2.rds.amazonaws.com"
      port                  = aws_db_instance.data.port                  # 예: 5432
      name                  = aws_db_instance.data.db_name               # 예: "commercedb"
      schema                = "public"                                   # 예: "public" (Medusa 가 연결마다 지정하는 스키마 — 데이터베이스 초기화 Job 이 이 스키마 안에서 두 계정의 권한을 가름)
      engine_version_actual = aws_db_instance.data.engine_version_actual # 예: "17.6" (AWS 가 적용한 실제 버전)
      parameter_group       = aws_db_parameter_group.data.name           # 예: "contract2whale-dev-eks-data-postgres17"
      security_group_id     = aws_security_group.database.id             # 예: "sg-0db00000000000000"
      subnet_group          = aws_db_subnet_group.data.name              # 예: "contract2whale-dev-eks-data"
    }

    # enable_redis = false 면 null 입니다. 읽는 쪽은 null 을 "캐시 없음"으로 다루고, 주소는 rediss://<address>:<port> 로 조립합니다 (tls_enabled 가 true 라서 redis:// 는 열리지 않습니다).
    redis = var.enable_redis ? {
      security_group_id = aws_security_group.redis[0].id
      address           = aws_elasticache_serverless_cache.redis[0].endpoint[0].address # 예: "contract2whale-dev-eks-data-redis-abcdef.serverless.apn2.cache.amazonaws.com"
      port              = aws_elasticache_serverless_cache.redis[0].endpoint[0].port    # 예: 6379
      tls_enabled       = true                                                          # 예: true (서버리스는 전송 암호화를 끌 수 없음)
    } : null

    credentials = {
      master_secret_arn     = aws_db_instance.data.master_user_secret[0].secret_arn   # 예: "arn:aws:secretsmanager:…:secret:rds!db-…" (RDS 가 관리)
      migration_secret_arn  = aws_secretsmanager_secret.application["migration"].arn  # 예: 스키마 변경 계정 비밀 (값은 초기화 뒤에)
      migration_secret_name = aws_secretsmanager_secret.application["migration"].name # 예: "contract2whale/dev/commerce-api/migration"
      runtime_secret_arn    = aws_secretsmanager_secret.application["runtime"].arn    # 예: 앱 실행 계정 비밀
      runtime_secret_name   = aws_secretsmanager_secret.application["runtime"].name   # 예: "contract2whale/dev/commerce-api/runtime"
      app_secret_arn        = aws_secretsmanager_secret.application["app"].arn        # 예: Medusa JWT_SECRET · COOKIE_SECRET 비밀
      app_secret_name       = aws_secretsmanager_secret.application["app"].name       # 예: "contract2whale/dev/commerce-api/app"
    }

    # 이름은 내보내기 버킷 그대로지만 쓰임은 미디어(상품 이미지)입니다. prefix 는 Medusa file-s3 의 S3_PREFIX 와 같은 값입니다.
    export = {
      bucket_name = aws_s3_bucket.exports.bucket # 예: "cp-dev-app-exports-111111111111-ap-northeast-2"
      bucket_arn  = aws_s3_bucket.exports.arn    # 예: "arn:aws:s3:::cp-dev-app-exports-…"
      prefix      = local.export_prefix          # 예: "media/dev/commerce-api/" (앱이 쓸 수 있는 유일한 접두사)
    }

    kms_key_arn = aws_kms_key.data.arn # 예: "arn:aws:kms:ap-northeast-2:111111111111:key/…" (저장 · 비밀 · 미디어 공통 키)

    operator = {
      repository_url  = aws_ecr_repository.operator.repository_url # 예: "111111111111.dkr.ecr.ap-northeast-2.amazonaws.com/contract2whale/database-operator"
      repository_name = aws_ecr_repository.operator.name           # 예: "contract2whale/database-operator"
    }
  }
}

# enable_redis=false이면 data_contract.redis는 null입니다. 이 output은 ENV 줄을 생산하지 않으며, 소비자가 typed null을 캐시 없음으로 판정합니다.
