# main.tf — modules/account-integrations (dev · prod 루트 모듈이 공유하는 모듈)
# 보고 버킷은 텍스트 · JSON 보고서용입니다. 운영 기반 구성의 Velero 백업 버킷과 네트워크 구성의 로그 버킷은 다시 선언하지 않습니다 (이름 · ARN 만 계약으로 받음).

# AWS 리소스를 만들지 않고, 잘못된 workspace · 계약 조합을 plan 단계에서 차단합니다 (모든 리소스가 depends_on 으로 이 검사를 기다림).
resource "terraform_data" "contract" {
  input = var.operations_contract.cluster_name # 예: "contract2whale-dev-eks" (값이 바뀌면 검사를 다시 실행합니다)

  lifecycle {
    precondition {
      # 예: default workspace 이고 계약의 계정 · 리전이 입력과 같아야 통과합니다
      condition     = terraform.workspace == "default" && var.operations_contract.account_id == var.expected_account_id && var.operations_contract.region == var.region
      error_message = "default workspace 및 동일 계정/리전의 운영 기반 구성 계약이 필요합니다."
    }

    precondition {
      # 예: "contract2whale-dev-eks" 는 통과하고(보고 버킷 이름 58자), 보고 버킷 이름이 63자를 넘거나 ARN 이 버킷 이름과 다르면 거부합니다
      condition     = can(regex("^[a-z][a-z0-9-]{1,98}[a-z0-9]$", var.operations_contract.cluster_name)) && length("reports-${var.operations_contract.cluster_name}-${var.expected_account_id}-${var.region}") <= 63 && var.network_logs_contract.bucket_arn == "arn:aws:s3:::${var.network_logs_contract.bucket_name}"
      error_message = "클러스터 이름(보고 버킷 이름 63자 이내)과 네트워크 로그 버킷 이름/ARN 계약을 확인하세요."
    }

    precondition {
      # 예: 기능을 끄면 항상 통과하고, 켜면 external_log_consumer 객체가 있어야 통과합니다
      condition     = !var.enable_external_log_consumer || var.external_log_consumer != null
      error_message = "외부 소비자를 켜려면 실제 principal_role_arn과 external_id가 필요합니다."
    }
  }
}

resource "aws_s3_bucket" "reports" {
  bucket        = "reports-${var.operations_contract.cluster_name}-${var.expected_account_id}-${var.region}" # 예: "reports-contract2whale-dev-eks-111111111111-ap-northeast-2" (계정 · 리전 접미사로 전역 이름 충돌 회피)
  force_destroy = true                                                                                       # 예: true (실습 삭제 기본값 — down.sh 가 객체가 있어도 지울 수 있음)

  lifecycle {
    prevent_destroy = false # 예: false (실습 삭제 기본값)
  }

  depends_on = [terraform_data.contract] # 예: 계약 검사를 통과한 뒤에 만듭니다
}

resource "aws_s3_bucket_ownership_controls" "reports" {
  bucket = aws_s3_bucket.reports.id # 예: "reports-contract2whale-dev-eks-111111111111-ap-northeast-2" (S3 는 이름이 곧 ID)

  rule {
    object_ownership = "BucketOwnerEnforced" # 예: "BucketOwnerEnforced" (객체 ACL 을 쓰지 않고 버킷 소유자가 가짐)
  }
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket                  = aws_s3_bucket.reports.id # 예: 버킷 이름
  block_public_acls       = true                     # 예: true (공개 ACL 요청을 거부합니다)
  block_public_policy     = true                     # 예: true (공개 버킷 정책을 거부합니다)
  ignore_public_acls      = true                     # 예: true (이미 있는 공개 ACL 을 무시합니다)
  restrict_public_buckets = true                     # 예: true (공개 정책이 있어도 접근을 제한합니다)
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id # 예: 버킷 이름

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # 예: "AES256" (S3 가 관리하는 키로 암호화)
    }
  }
}

resource "aws_s3_bucket_versioning" "reports" {
  bucket = aws_s3_bucket.reports.id # 예: 버킷 이름

  versioning_configuration {
    status = "Enabled" # 예: "Enabled" (같은 키를 덮어써도 이전 내용을 남깁니다)
  }
}

# HTTP(암호화되지 않은 전송) 요청만 거부합니다. AWS 서비스 주체의 요청은 예외입니다.
resource "aws_s3_bucket_policy" "reports" {
  bucket = aws_s3_bucket.reports.id # 예: 버킷 이름
  policy = jsonencode({
    Version = "2012-10-17" # 예: "2012-10-17" (정책 문법 버전, 날짜가 아닙니다)
    Statement = [{
      Effect    = "Deny"                                                        # 예: "Deny" (조건에 맞는 요청을 거부합니다)
      Principal = "*"                                                           # 예: "*" (요청 주체를 가리지 않습니다)
      Action    = "s3:*"                                                        # 예: "s3:*" (모든 S3 동작이 대상입니다)
      Resource  = [aws_s3_bucket.reports.arn, "${aws_s3_bucket.reports.arn}/*"] # 예: 버킷과 객체 두 범위
      Condition = {
        Bool = {
          "aws:SecureTransport"       = "false" # 예: HTTP 로 들어온 요청
          "aws:PrincipalIsAWSService" = "false" # 예: AWS 서비스가 아닌 주체
        }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.reports] # 예: 공개 차단을 먼저 붙인 뒤 정책을 붙입니다
}
