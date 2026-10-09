# export.tf — modules/data (dev · prod 루트 모듈이 공유하는 모듈)
# 객체를 올리는 쪽은 commerce-api(Medusa) 의 file-s3 모듈입니다. 앱은 media/<env>/<deployment>/ 접두사 밖으로 쓰지 못하며, 접두사 제한은 IAM(Pod Identity 재사용 모듈) 과 이 버킷 정책 두 곳에서 겹쳐 막습니다.

resource "aws_s3_bucket" "exports" {
  bucket        = local.export_bucket # 예: "cp-dev-app-exports-111111111111-ap-northeast-2" (63자 제한 안)
  force_destroy = true                # 예: true (학습 환경에서 down.sh 가 객체까지 지움 — 실무 기본값이 아님)

  depends_on = [terraform_data.guard] # 예: 계약 검사를 통과한 뒤에 만듭니다
}

# Medusa file-s3 는 acl 을 false 로 두고 올립니다. BucketOwnerEnforced 버킷은 ACL 자체를 받지 않으므로 두 설정이 맞물립니다.
resource "aws_s3_bucket_ownership_controls" "exports" {
  bucket = aws_s3_bucket.exports.id

  rule {
    object_ownership = "BucketOwnerEnforced" # 예: ACL 을 쓰지 않음 (소유자는 언제나 버킷 계정)
  }
}

resource "aws_s3_bucket_public_access_block" "exports" {
  bucket                  = aws_s3_bucket.exports.id
  block_public_acls       = true # 예: true (공개 ACL 차단)
  block_public_policy     = true # 예: true (공개 정책 차단)
  ignore_public_acls      = true # 예: true (이미 붙은 공개 ACL 무시)
  restrict_public_buckets = true # 예: true (공개 접근 제한)
}

resource "aws_s3_bucket_versioning" "exports" {
  bucket = aws_s3_bucket.exports.id

  versioning_configuration {
    status = "Enabled" # 예: "Enabled" (같은 파일 이름을 덮어써도 이전 버전이 남음)
  }
}

# 버킷 기본 암호화입니다. Medusa file-s3 는 PutObject 에 암호화 헤더를 붙일 수 없어, 헤더 없는 업로드가 이 기본값으로 이 키에 암호화되는 것이 유일한 경로입니다.
resource "aws_s3_bucket_server_side_encryption_configuration" "exports" {
  bucket = aws_s3_bucket.exports.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"            # 예: "aws:kms" (고객 관리형 키로 암호화)
      kms_master_key_id = aws_kms_key.data.arn # 예: 데이터 키와 같은 키
    }

    bucket_key_enabled = true # 예: true (KMS 호출 수를 줄임; 암호화 컨텍스트가 버킷 ARN 이 됩니다)
  }
}

# 상품 이미지는 상품이 살아 있는 동안 남아야 하므로 현재 버전에는 만료를 두지 않습니다. 정리 대상은 덮어쓴 이전 버전과 끝나지 않은 멀티파트 업로드뿐입니다.
resource "aws_s3_bucket_lifecycle_configuration" "exports" {
  bucket = aws_s3_bucket.exports.id

  rule {
    id     = "expire-noncurrent-media" # 예: 규칙 이름
    status = "Enabled"                 # 예: "Enabled"

    filter {
      prefix = local.export_prefix # 예: "media/dev/commerce-api/"
    }

    noncurrent_version_expiration {
      noncurrent_days = 7 # 예: 7 (덮어쓴 이전 버전 보존일)
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7 # 예: 7 (끊긴 업로드 조각이 요금으로 남지 않게)
    }
  }

  depends_on = [aws_s3_bucket_versioning.exports] # 예: 버전 관리가 켜진 뒤에 규칙을 붙입니다
}

# TLS 없는 요청과 접두사 밖 쓰기를 버킷 쪽에서도 막습니다. IAM 정책(Pod Identity 재사용 모듈) 과 겹치는 두 번째 방어선입니다.
resource "aws_s3_bucket_policy" "exports" {
  bucket = aws_s3_bucket.exports.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport" # 예: http 요청 거부
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.exports.arn, "${aws_s3_bucket.exports.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid         = "DenyWritesOutsideMediaPrefix" # 예: media/<env>/<deployment>/ 밖의 쓰기 거부
        Effect      = "Deny"
        Principal   = "*"
        Action      = ["s3:PutObject", "s3:DeleteObject"]
        NotResource = ["${aws_s3_bucket.exports.arn}/${local.export_prefix}*"]
      },
      {
        # 헤더를 붙인 업로드만 검사합니다. Null 조건이 없으면 헤더 없는 업로드(Medusa 의 모든 업로드)까지 거부되어 버킷 기본 암호화가 쓰이지 못합니다.
        Sid       = "DenyUploadsWithAnotherKey" # 예: 다른 키를 지정한 업로드 거부
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.exports.arn}/*"
        Condition = {
          Null            = { "s3:x-amz-server-side-encryption-aws-kms-key-id" = "false" } # 예: 헤더가 있는 요청만 (없으면 기본 암호화가 이 키로 처리)
          StringNotEquals = { "s3:x-amz-server-side-encryption-aws-kms-key-id" = aws_kms_key.data.arn }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.exports] # 예: 공개 차단이 켜진 뒤에 정책을 붙입니다
}

# 운영자 이미지(데이터베이스 운영자 이미지와 읽기 전용 진단 에서 빌드) 저장소입니다. 태그는 불변이고 Job 은 항상 @sha256 digest 로 이미지를 가리킵니다.
resource "aws_ecr_repository" "operator" {
  name                 = var.operator_repository_name # 예: "contract2whale/database-operator"
  image_tag_mutability = "IMMUTABLE"                  # 예: 같은 태그 재게시 거부
  force_delete         = true                         # 예: true (이미지가 있어도 down.sh 가 지움 — 이미지는 다시 빌드)

  image_scanning_configuration {
    scan_on_push = true # 예: true (게시 시 취약점 스캔)
  }

  encryption_configuration {
    encryption_type = "AES256" # 예: "AES256" (ECR 기본 키)
  }

  depends_on = [terraform_data.guard] # 예: 계약 검사를 통과한 뒤에 만듭니다
}

# 실제 operator ECR이 생긴 data apply에서 기존 Kyverno 역할에 해당 저장소 읽기만 연결합니다.
resource "aws_iam_role_policy" "kyverno_operator_read" {
  name = "database-operator-ecr-read"
  role = basename(var.kyverno_role_arn) # 예: contract2whale-dev-eks-delivery-kyverno

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "OperatorEcrRead"
      Effect   = "Allow"
      Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability", "ecr:DescribeImages"]
      Resource = aws_ecr_repository.operator.arn # 예: 같은 계정·리전의 repository/contract2whale/database-operator
    }]
  })

  depends_on = [terraform_data.guard]
}
