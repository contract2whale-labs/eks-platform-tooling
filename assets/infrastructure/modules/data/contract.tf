# contract.tf — modules/data (dev · prod 루트 모듈이 공유하는 모듈)
# 원본의 `dataops.version_check`(AWS 조회 → JSON → 유효 기간 · 입력 해시 검사)는 plan 시점에 항상 다시 조회하는 data 두 개로 바뀌었습니다 (P3). 조회 결과가 입력과 다르면 apply 가 아니라 plan 이 멈춥니다.

locals {
  name_prefix   = "${var.cluster_contract.name}-data"                                       # 예: "contract2whale-dev-eks-data" (SG · 서브넷 그룹 · 파라미터 그룹 이름 접두사)
  bucket_prefix = "cp-${var.environment}-app"                                               # 예: "cp-dev-app" (버킷 이름 63자 제한 때문에 짧은 접두사 — 배포 플랫폼 의 cp-<env>-delivery-* 와 같은 방식)
  identifier    = "${var.cluster_contract.name}-${var.database.name}"                       # 예: "contract2whale-dev-eks-commercedb" (DB 인스턴스 식별자)
  secret_prefix = "contract2whale/${var.environment}/${var.application.deployment}"         # 예: "contract2whale/dev/commerce-api" (시크릿 이름 접두사)
  export_bucket = "${local.bucket_prefix}-exports-${var.expected_account_id}-${var.region}" # 예: "cp-dev-app-exports-111111111111-ap-northeast-2" (46자; 이름은 그대로 두고 쓰임만 미디어로 바뀝니다)
  export_prefix = "media/${var.environment}/${var.application.deployment}/"                 # 예: "media/dev/commerce-api/" (Medusa file-s3 의 S3_PREFIX · 앱이 쓸 수 있는 유일한 접두사)

  application_secrets = {
    migration = { name = "${local.secret_prefix}/migration", purpose = "schema migration database account" } # 예: "contract2whale/dev/commerce-api/migration" (스키마 변경 계정)
    runtime   = { name = "${local.secret_prefix}/runtime", purpose = "application database account" }        # 예: "contract2whale/dev/commerce-api/runtime" (앱 실행 계정)
    app       = { name = "${local.secret_prefix}/app", purpose = "Medusa JWT_SECRET and COOKIE_SECRET" }     # 예: "contract2whale/dev/commerce-api/app" (production 에서 둘이 없으면 Medusa 가 기동하지 않습니다)
  }
}

# 이 리전에서 실제로 제공되는 엔진 버전인지 확인합니다. version 은 정확한 값을 요구하고, 결과 version_actual 이 입력과 다르면 아래 precondition 이 멈춥니다.
data "aws_rds_engine_version" "postgres" {
  engine  = "postgres"                  # 예: "postgres" (Aurora 가 아닌 RDS PostgreSQL)
  version = var.database.engine_version # 예: "17.6" (루트 모듈 terraform.tfvars 의 조회 결과)
}

# 같은 리전에서 그 버전 · 인스턴스 유형 · 저장 방식 조합을 주문할 수 있는지 확인합니다. 원본의 "지원 조합" 검사와 같은 판정을 plan 에서 합니다.
data "aws_rds_orderable_db_instance" "postgres" {
  engine                     = "postgres"                                          # 예: "postgres"
  engine_version             = data.aws_rds_engine_version.postgres.version_actual # 예: 위 조회가 돌려준 실제 버전
  preferred_instance_classes = [var.database.instance_class]                       # 예: ["db.t4g.micro"] (이 목록에서 제공되는 첫 유형)
  storage_type               = "gp3"                                               # 예: "gp3" (이 모듈이 쓰는 저장 유형)
}

resource "terraform_data" "guard" {
  input = "${var.environment}:${local.identifier}" # 예: "dev:contract2whale-dev-eks-commercedb" (State 에 남는 표식)

  lifecycle {
    precondition {
      condition     = split(":", var.kyverno_role_arn)[4] == var.expected_account_id && endswith(var.kyverno_role_arn, "/${var.cluster_contract.name}-delivery-kyverno")
      error_message = "Use the existing delivery Kyverno role for this account and cluster."
    }

    precondition {
      condition     = terraform.workspace == "default" # 예: workspace 로 환경을 나누지 않음 (backend key · 버킷으로 구분)
      error_message = "Use default workspace and a distinct backend key."
    }

    precondition {
      condition     = split(":", var.cluster_contract.arn)[4] == var.expected_account_id # 예: ARN 의 5번째 항목(계정 12자리)
      error_message = "cluster_contract.arn must belong to expected_account_id (an environment mix-up)."
    }

    precondition {
      condition     = var.cluster_contract.region == var.region && split(":", var.cluster_contract.arn)[3] == var.region # 예: 계약 리전 · ARN 리전 · 모듈 리전이 모두 같아야 함
      error_message = "cluster_contract.region and the cluster ARN region must equal the module region."
    }

    precondition {
      condition     = var.network_contract.vpc_id == var.cluster_contract.vpc_id # 예: 다른 VPC 의 서브넷으로 DB 를 만들지 않음
      error_message = "network_contract.vpc_id must be the VPC of the cluster (cluster_contract.vpc_id)."
    }

    precondition {
      condition     = data.aws_rds_engine_version.postgres.version_actual == var.database.engine_version # 예: "17.6" == "17.6"
      error_message = "The Region does not offer the pinned engine_version; run the describe-db-engine-versions query again (데이터 루트 모듈과 PostgreSQL 버전 고정)."
    }

    precondition {
      condition     = data.aws_rds_orderable_db_instance.postgres.instance_class == var.database.instance_class && (!var.database.multi_az || data.aws_rds_orderable_db_instance.postgres.multi_az_capable) # 예: 유형 · Multi-AZ 조합 확인
      error_message = "The Region does not offer this engine version, instance class and storage combination (or Multi-AZ for it)."
    }

    precondition {
      condition     = var.environment != "prod" || var.enable_redis # 예: Dev 는 요금 때문에 캐시를 내릴 수 있지만 Prod 는 내릴 수 없음
      error_message = "A prod environment requires the cache (enable_redis); the event bus, workflow engine and locking modules have no in-memory fallback that survives more than one replica."
    }
  }
}
