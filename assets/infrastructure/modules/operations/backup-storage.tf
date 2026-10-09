# backup-storage.tf — modules/operations (dev · prod 루트 모듈이 공유하는 모듈)
# EBS 볼륨 스냅샷 데이터는 이 버킷이 아니라 EC2 snapshot 으로 저장됩니다 (Terraform State 밖 — lab hook platform-operations 의 down 이 정리).

resource "aws_s3_bucket" "velero" {
  count = contains(var.enabled_services, "velero") ? 1 : 0 # 예: velero 를 켠 경우에만 1개

  bucket        = local.backup_bucket_name # 예: "velero-contract2whale-dev-eks-111111111111-ap-northeast-2" (원본 이름 유지 — P8 은 결정 3 대기)
  force_destroy = true                     # 예: true (실습 삭제 시 객체 · 버전까지 정리)

  lifecycle {
    prevent_destroy = false # 예: false (실습 삭제 허용)
  }

  depends_on = [terraform_data.contract] # 예: 계약 검사 통과 후 생성
}

resource "aws_s3_bucket_ownership_controls" "velero" {
  count  = contains(var.enabled_services, "velero") ? 1 : 0
  bucket = aws_s3_bucket.velero[0].id

  rule {
    object_ownership = "BucketOwnerEnforced" # 예: 버킷 소유자가 모든 객체를 소유 (ACL 비활성)
  }
}

resource "aws_s3_bucket_public_access_block" "velero" {
  count  = contains(var.enabled_services, "velero") ? 1 : 0
  bucket = aws_s3_bucket.velero[0].id

  block_public_acls       = true # 예: 공개 ACL 요청 거부
  block_public_policy     = true # 예: 공개 버킷 정책 등록 거부
  ignore_public_acls      = true # 예: 이미 붙은 공개 ACL 무시
  restrict_public_buckets = true # 예: 공개 정책이 있어도 접근 제한
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  count  = contains(var.enabled_services, "velero") ? 1 : 0
  bucket = aws_s3_bucket.velero[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # 예: "AES256" (S3 관리 키 암호화)
    }
  }
}

resource "aws_s3_bucket_versioning" "velero" {
  count  = contains(var.enabled_services, "velero") ? 1 : 0
  bucket = aws_s3_bucket.velero[0].id

  versioning_configuration {
    status = "Enabled" # 예: 덮어쓰기 · 삭제 시 이전 버전 보존 (기간 잠금인 Object Lock 과 다름)
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "velero" {
  count  = contains(var.enabled_services, "velero") ? 1 : 0
  bucket = aws_s3_bucket.velero[0].id

  rule {
    id     = "noncurrent-and-incomplete"
    status = "Enabled"

    filter {} # 예: 빈 filter (버킷 전체에 적용)

    noncurrent_version_expiration {
      noncurrent_days = 90 # 예: 이전 버전은 90일 후 삭제
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7 # 예: 끝나지 않은 멀티파트 업로드는 7일 후 정리
    }
  }

  depends_on = [aws_s3_bucket_versioning.velero] # 예: 버전 관리 활성화 이후 적용
}

resource "aws_s3_bucket_policy" "velero" {
  count  = contains(var.enabled_services, "velero") ? 1 : 0
  bucket = aws_s3_bucket.velero[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [try(aws_s3_bucket.velero[0].arn, null), "${try(aws_s3_bucket.velero[0].arn, "inactive")}/*"]
      Condition = {
        Bool = {
          "aws:SecureTransport"       = "false" # 예: 평문(HTTP) 요청이면서
          "aws:PrincipalIsAWSService" = "false" # 예: AWS 서비스 주체가 보낸 요청이 아닌 경우
        }
      }
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.velero] # 예: 공개 차단 적용 이후 정책 부착
}
