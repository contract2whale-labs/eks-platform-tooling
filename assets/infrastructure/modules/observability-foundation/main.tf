# main.tf — modules/observability-foundation (dev · prod 루트 모듈이 공유하는 모듈)

# 신호마다 저장소 하나씩 만듭니다. 키가 Terraform 주소가 되므로 키 이름을 바꾸지 않습니다.
resource "aws_s3_bucket" "signal" {
  for_each = local.signal_bucket_names # 예: metrics · logs · traces 세 항목

  bucket        = each.value # 예: "cp-dev-observability-logs-111111111111-ap-northeast-2"
  force_destroy = true       # 예: true (실습 삭제 기본값: 객체와 비현재 버전이 있어도 삭제)

  lifecycle {
    prevent_destroy = false # 예: false (실습 삭제 허용)
  }

  depends_on = [terraform_data.contract] # 예: 계약 검사를 통과한 뒤에 만듭니다
}

# (1) 소유권 설정: ACL 을 쓰지 않고 객체 소유자를 저장소 소유자로 고정합니다.
resource "aws_s3_bucket_ownership_controls" "signal" {
  for_each = aws_s3_bucket.signal # 예: 저장소 3개

  bucket = each.value.id # 예: 저장소 이름

  rule {
    object_ownership = "BucketOwnerEnforced" # 예: "BucketOwnerEnforced" (ACL 자체를 쓰지 않음)
  }
}

# (2) 공개 차단: ACL 과 정책으로 공개되는 경로를 저장소 수준에서 닫습니다.
resource "aws_s3_bucket_public_access_block" "signal" {
  for_each = aws_s3_bucket.signal # 예: 저장소 3개

  bucket                  = each.value.id # 예: 저장소 이름
  block_public_acls       = true          # 예: true (공개 ACL 설정을 거부)
  block_public_policy     = true          # 예: true (공개를 만드는 정책 설정을 거부)
  ignore_public_acls      = true          # 예: true (이미 붙은 공개 ACL 을 무시)
  restrict_public_buckets = true          # 예: true (공개 정책이 있어도 익명 접근을 막음)
}

# (3) 기본 암호화: 저장 시 암호화를 서버가 적용합니다.
resource "aws_s3_bucket_server_side_encryption_configuration" "signal" {
  for_each = aws_s3_bucket.signal # 예: 저장소 3개

  bucket = each.value.id # 예: 저장소 이름

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # 예: "AES256" (S3 관리 키로 암호화)
    }
  }
}

# (4) 버전 관리: 덮어쓰기와 삭제가 이전 버전을 남깁니다.
resource "aws_s3_bucket_versioning" "signal" {
  for_each = aws_s3_bucket.signal # 예: 저장소 3개

  bucket = each.value.id # 예: 저장소 이름

  versioning_configuration {
    status = "Enabled" # 예: "Enabled" (한 번 켜면 Suspended 로만 바꿀 수 있음)
  }
}

# (5) 수명 주기: 신호별 보존일과 비현재 버전 · 중단 조각 정리를 함께 둡니다.
resource "aws_s3_bucket_lifecycle_configuration" "signal" {
  for_each = aws_s3_bucket.signal # 예: 저장소 3개

  bucket = each.value.id # 예: 저장소 이름

  rule {
    id     = "expire-signal-objects" # 예: 보존 경계 밖 객체 정리 규칙
    status = "Enabled"               # 예: "Enabled"

    filter {
      prefix = local.signal_object_prefixes[each.key] != "" ? local.signal_object_prefixes[each.key] : null # 예: "dev/" (metrics · traces) / null = 저장소 전체 (logs)
    }

    expiration {
      days = var.signal_retention_days[each.key] # 예: 400 (지표 저장소의 기준일)
    }
  }

  rule {
    id     = "clean-noncurrent-and-incomplete" # 예: 남은 버전과 조각 정리 규칙
    status = "Enabled"                         # 예: "Enabled"

    filter {} # 예: 접두사를 가리지 않고 저장소 전체

    noncurrent_version_expiration {
      noncurrent_days = 7 # 예: 7 (비현재 버전을 7일 뒤 지움)
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7 # 예: 7 (중단된 대용량 업로드 조각을 7일 뒤 지움)
    }
  }

  depends_on = [aws_s3_bucket_versioning.signal] # 예: 버전 관리를 켠 뒤에 규칙을 붙입니다
}

# (6) 저장소 정책: 평문 전송을 거부하고, 접두사가 있는 저장소는 접두사 밖 객체 동작도 거부합니다.
resource "aws_s3_bucket_policy" "signal" {
  for_each = aws_s3_bucket.signal # 예: 저장소 3개

  bucket = each.value.id # 예: 저장소 이름
  policy = jsonencode({
    Version = "2012-10-17" # 예: 정책 문법 버전
    Statement = concat(
      [
        {
          Sid       = "DenyInsecureTransport"                        # 예: 평문 전송 거부 문장
          Effect    = "Deny"                                         # 예: "Deny" (명시적 거부는 모든 허용보다 우선)
          Principal = "*"                                            # 예: "*" (주체를 가리지 않음)
          Action    = "s3:*"                                         # 예: "s3:*" (거부 문장이므로 동작을 넓게 적음)
          Resource  = [each.value.arn, "${each.value.arn}/*"]        # 예: 저장소 ARN 과 객체 ARN 패턴
          Condition = { Bool = { "aws:SecureTransport" = "false" } } # 예: 암호화되지 않은 연결일 때만 성립
        }
      ],
      local.signal_object_prefixes[each.key] == "" ? [] : [
        {
          Sid         = "DenyObjectsOutsideEnvironmentPrefix"                            # 예: 접두사 밖 객체 동작 거부 문장 (metrics · traces 만)
          Effect      = "Deny"                                                           # 예: "Deny"
          Principal   = "*"                                                              # 예: "*"
          Action      = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]              # 예: 객체 단위 동작 세 가지
          NotResource = ["${each.value.arn}/${local.signal_object_prefixes[each.key]}*"] # 예: ".../dev/*" 만 제외
        }
      ]
    )
  })

  depends_on = [aws_s3_bucket_public_access_block.signal] # 예: 공개 차단을 먼저 켠 뒤 정책을 붙입니다
}
