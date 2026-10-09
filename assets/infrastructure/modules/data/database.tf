# database.tf — modules/data (dev · prod 루트 모듈이 공유하는 모듈)
# 비밀번호는 이 파일 어디에도 없습니다 — manage_master_user_password 로 RDS 가 관리하는 Secret 을 만듭니다 (random_password · aws_secretsmanager_secret_version 없음).

# 데이터베이스 저장 · 스냅샷 · 관리 Secret · 내보내기 객체가 모두 이 고객 관리형 키를 씁니다. 키를 지우면 스냅샷도 복원할 수 없습니다.
resource "aws_kms_key" "data" {
  description             = "Application data at rest: RDS storage, snapshots, secrets and export objects (${var.environment})." # 예: 콘솔에서 용도를 알아볼 설명
  enable_key_rotation     = true                                                                                                 # 예: true (해마다 자동 교체)
  deletion_window_in_days = 7                                                                                                    # 예: 7 (삭제 예약 뒤 최소 대기일; 되돌릴 수 있는 기간)

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableAccountAdministration" # 예: 계정 관리자가 키 정책을 고칠 수 있게 함 (없으면 키를 다시 만들 수 없음)
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${var.expected_account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowServiceUseThroughAwsServices" # 예: RDS · Secrets Manager · S3 를 거치는 호출만 허용 (이 Statement는 ViaService 조건을 요구; root 위임에 따른 IAM 허용은 별도 확인)
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
        Resource  = "*"
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = var.expected_account_id # 예: 같은 계정의 호출만
            "kms:ViaService" = [
              "rds.${var.region}.amazonaws.com",            # 예: RDS 저장 · 스냅샷
              "secretsmanager.${var.region}.amazonaws.com", # 예: 관리 Secret · 앱 시크릿
              "s3.${var.region}.amazonaws.com",             # 예: 내보내기 객체
            ]
          }
        }
      },
    ]
  })

  depends_on = [terraform_data.guard] # 예: 계약 검사를 통과한 뒤에 만듭니다
}

resource "aws_kms_alias" "data" {
  name          = "alias/${local.name_prefix}" # 예: "alias/contract2whale-dev-eks-data"
  target_key_id = aws_kms_key.data.key_id      # 예: 위 키
}

# 데이터베이스 앞의 Security Group 입니다. 규칙은 노드 Security Group 에서 오는 5432 하나뿐이고 나가는 규칙은 두지 않습니다.
resource "aws_security_group" "database" {
  name        = "${local.name_prefix}-db"                  # 예: "contract2whale-dev-eks-data-db"
  description = "PostgreSQL access for cluster nodes only" # 예: 콘솔 설명 (변경하면 SG 가 교체됨)
  vpc_id      = var.network_contract.vpc_id                # 예: "vpc-0123456789abcdef0"

  tags = { Name = "${local.name_prefix}-db" } # 예: 콘솔 목록에서 찾기 위한 이름 태그
}

# 노드 Security Group 을 출발지로 지정합니다. CIDR 이 아니라 SG 참조라 노드가 늘거나 IP 가 바뀌어도 규칙을 고치지 않습니다.
resource "aws_vpc_security_group_ingress_rule" "database_from_nodes" {
  security_group_id            = aws_security_group.database.id              # 예: 규칙이 붙는 SG (DB SG)
  referenced_security_group_id = var.network_contract.node_security_group_id # 예: 상대 SG (노드와 Add-on 노드 SG)
  from_port                    = 5432                                        # 예: 5432 (PostgreSQL)
  to_port                      = 5432                                        # 예: 5432
  ip_protocol                  = "tcp"                                       # 예: "tcp"
  description                  = "PostgreSQL from cluster nodes"             # 예: 규칙 설명
}

resource "aws_db_subnet_group" "data" {
  name        = local.name_prefix                              # 예: "contract2whale-dev-eks-data"
  description = "Private subnets for the application database" # 예: 콘솔 설명
  subnet_ids  = var.network_contract.database_subnet_ids       # 예: ["subnet-0ra…", "subnet-0rb…", "subnet-0rc…"]

  depends_on = [terraform_data.guard] # 예: 서브넷 중복 · VPC 불일치 검사를 통과한 뒤에
}

# 엔진 계열은 조회 결과에서 받습니다 (postgres17 처럼 손으로 적지 않음). force_ssl 은 평문 접속을 서버가 거부하게 합니다.
resource "aws_db_parameter_group" "data" {
  name        = "${local.name_prefix}-${replace(data.aws_rds_engine_version.postgres.parameter_group_family, ".", "-")}" # 예: "contract2whale-dev-eks-data-postgres17"
  family      = data.aws_rds_engine_version.postgres.parameter_group_family                                              # 예: "postgres17" (조회 결과)
  description = "TLS required, slow query and connection logging"                                                        # 예: 콘솔 설명

  parameter {
    name  = "rds.force_ssl" # 예: 평문 접속 거부 (동적 파라미터 — 값을 바꿀 때 재시작하지 않음)
    value = "1"             # 예: "1" (켬)
  }

  parameter {
    name  = "log_min_duration_statement" # 예: 느린 질의 기록 기준 (밀리초)
    value = "500"                        # 예: "500" (0.5초 이상 걸린 질의만)
  }

  parameter {
    name  = "log_connections" # 예: 접속 기록 (누가 언제 붙었는지)
    value = "1"               # 예: "1" (켬)
  }

  lifecycle {
    create_before_destroy = true # 예: 이름이 바뀌면 새 그룹을 먼저 만들고 인스턴스를 옮긴 뒤 지웁니다
  }
}

# 인스턴스입니다. 비밀번호 인자가 없습니다 — RDS 가 관리하는 Secret 하나를 만들고 이 모듈은 그 ARN 만 계약으로 전달합니다.
resource "aws_db_instance" "data" {
  identifier     = local.identifier            # 예: "contract2whale-dev-eks-commercedb"
  engine         = "postgres"                  # 예: "postgres"
  engine_version = var.database.engine_version # 예: "17.6" (조회 결과와 같은지 guard 가 확인)
  instance_class = var.database.instance_class # 예: "db.t4g.micro"
  db_name        = var.database.name           # 예: "commercedb" (초기 데이터베이스; app schema 는 데이터베이스 초기화 이 만듦)
  username       = "postgres"                  # 예: "postgres" (관리 계정 이름; 비밀번호는 아래 관리 Secret)

  manage_master_user_password   = true                 # 예: true (RDS 가 Secret 을 만들고 교체까지 관리 — Terraform 에 비밀번호가 없음)
  master_user_secret_kms_key_id = aws_kms_key.data.arn # 예: 관리 Secret 도 같은 고객 관리형 키로 암호화

  allocated_storage     = var.database.allocated_storage     # 예: 20 (GiB)
  max_allocated_storage = var.database.max_allocated_storage # 예: 100 (GiB, 자동 확장 상한 — 이미 늘어난 공간은 줄지 않음)
  storage_type          = "gp3"                              # 예: "gp3"
  storage_encrypted     = true                               # 예: true (저장 암호화; 만든 뒤에는 끌 수 없음)
  kms_key_id            = aws_kms_key.data.arn               # 예: 저장 · 스냅샷 암호화 키

  db_subnet_group_name   = aws_db_subnet_group.data.name    # 예: 위 서브넷 그룹
  vpc_security_group_ids = [aws_security_group.database.id] # 예: 위 SG 하나
  parameter_group_name   = aws_db_parameter_group.data.name # 예: 위 파라미터 그룹
  publicly_accessible    = false                            # 예: false (공인 주소를 받지 않음)
  network_type           = "IPV4"                           # 예: "IPV4"
  port                   = 5432                             # 예: 5432

  multi_az                            = var.database.multi_az              # 예: false (Dev; standby 는 읽기용 replica 가 아님)
  backup_retention_period             = var.database.backup_retention_days # 예: 7 (0 은 변수 validation 이 거부)
  backup_window                       = "17:00-18:00"                      # 예: "17:00-18:00" UTC (서울 새벽 2~3시)
  maintenance_window                  = "mon:18:00-mon:19:00"              # 예: 백업 창과 겹치지 않는 시간
  copy_tags_to_snapshot               = true                               # 예: true (스냅샷에도 Environment 태그가 남음)
  auto_minor_version_upgrade          = false                              # 예: false (버전은 데이터 루트 모듈과 PostgreSQL 버전 고정 의 조회 · 검토로만 올림)
  apply_immediately                   = false                              # 예: false (다음 유지 보수 창에 적용 — 모든 속성이 미뤄지는 것은 아님)
  deletion_protection                 = var.database.deletion_protection   # 예: false (Dev 는 down.sh 가 지울 수 있어야 함)
  skip_final_snapshot                 = true                               # 예: true (현재 공용 학습 모듈의 설정; Prod도 이 모듈을 사용합니다. 최종 스냅샷 보존은 별도의 승인된 정책 변경으로 구성합니다)
  iam_database_authentication_enabled = false                              # 예: false (이 과정은 Secrets Manager 의 비밀번호로 접속)
  performance_insights_enabled        = false                              # 예: false (무료 보존 7일도 인스턴스 유형에 따라 비용이 붙어 끕니다)

  lifecycle {
    precondition {
      condition     = var.environment != "prod" || (var.database.multi_az && var.database.deletion_protection && var.database.backup_retention_days >= 7) # 예: Prod 는 Multi-AZ · 삭제 보호 · 7일 이상
      error_message = "A prod database requires multi_az, deletion_protection and at least seven days of backups."
    }
  }
}
