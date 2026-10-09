# storage-roles.tf — modules/observability-foundation (dev · prod 루트 모듈이 공유하는 모듈)
# 쓰기에 삭제 없음, 읽기에 쓰기 · 삭제 없음, 정리에만 삭제 있음. 세 역할 모두 metrics·traces의 환경 접두사(dev/) 밖 목록 조회를 거부합니다. Loki logs는 환경별 전용 버킷 전체를 쓰므로 prefix 거부의 대상이 아닙니다.

locals {
  # 앞 챕터(관련 구성 네트워크 로그 버킷)와 같은 이름 규칙 cp-<환경>-<용도>-<계정>-<리전> 입니다. 값을 직접 적지 않고 규칙으로 계산합니다.
  signal_bucket_names = {
    metrics = "cp-${var.environment}-observability-metrics-${var.expected_account_id}-${var.region}" # 예: "cp-dev-observability-metrics-111111111111-ap-northeast-2"
    logs    = "cp-${var.environment}-observability-logs-${var.expected_account_id}-${var.region}"    # 예: "cp-dev-observability-logs-111111111111-ap-northeast-2"
    traces  = "cp-${var.environment}-observability-traces-${var.expected_account_id}-${var.region}"  # 예: "cp-dev-observability-traces-111111111111-ap-northeast-2"
  }

  # 객체 key 앞에 붙는 환경 접두사입니다. Resource 와 s3:prefix 조건이 같은 값을 씁니다.
  object_prefix = "${var.environment}/" # 예: "dev/" (prod 루트 모듈은 "prod/")

  # 신호별 접두사입니다. metrics(Thanos) · traces(Tempo) 는 prefix 설정이 있어 "dev/" 아래에 쓰고, logs(Loki) 는 접두사 없이 버킷 전체를 씁니다.
  signal_object_prefixes = {
    metrics = local.object_prefix # 예: "dev/" (Thanos objstore.yml 의 prefix: dev/metrics)
    logs    = ""                  # 예: "" (Loki 는 <tenant>/… · index/… 를 버킷 최상위에 둠)
    traces  = local.object_prefix # 예: "dev/" (Tempo 의 prefix: dev/traces; 후반부)
  }

  signal_bucket_arns = { for key, name in local.signal_bucket_names : key => "arn:aws:s3:::${name}" } # 예: { metrics = "arn:aws:s3:::cp-dev-observability-metrics-…", … }

  signal_object_arns = [
    for key, arn in local.signal_bucket_arns : "${arn}/${local.signal_object_prefixes[key]}*" # 예: "arn:aws:s3:::cp-dev-observability-logs-…/*" · "…-metrics-…/dev/*"
  ]

  # 목록 조회(s3:ListBucket)는 버킷 ARN 이 대상이고 s3:prefix 조건으로 좁힙니다. 접두사 유무로 두 묶음을 나눕니다.
  prefixed_bucket_arns   = [for key, arn in local.signal_bucket_arns : arn if local.signal_object_prefixes[key] != ""] # 예: metrics · traces 버킷 ARN 2개
  unprefixed_bucket_arns = [for key, arn in local.signal_bucket_arns : arn if local.signal_object_prefixes[key] == ""] # 예: logs 버킷 ARN 1개
}

# 신뢰 정책: 세 역할을 누가 맡을 수 있는가? (1) 점검용 영구 역할 (2) 이 클러스터의 Pod Identity.
data "aws_iam_policy_document" "observability_access_trust" {
  statement {
    sid     = "TrustObservabilityOperators" # 예: "TrustObservabilityOperators" (CloudTrail 에서 문장 식별용)
    effect  = "Allow"                       # 예: "Allow"
    actions = ["sts:AssumeRole"]            # 예: 신뢰 정책에서 의미를 갖는 유일한 액션

    principals {
      type        = "AWS"                                    # 예: "AWS" (IAM 주체)
      identifiers = sort(tolist(var.trusted_principal_arns)) # 예: ["arn:aws:iam::111111111111:role/PlatformOperator"] (정렬해 JSON 순서 고정)
    }
  }

  statement {
    sid     = "TrustObservabilityPodIdentity"      # 예: "TrustObservabilityPodIdentity"
    effect  = "Allow"                              # 예: "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"] # 예: 세션 태그를 붙이려면 두 동작이 함께 필요

    principals {
      type        = "Service"                  # 예: "Service" (AWS 서비스 주체)
      identifiers = ["pods.eks.amazonaws.com"] # 예: Pod Identity 가 쓰는 서비스 주체
    }

    condition {
      test     = "StringEquals"                   # 예: "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn" # 예: 세션에 붙는 클러스터 태그
      values   = [var.cluster_contract.arn]       # 예: ["arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"]
    }
  }
}

# 쓰는 역할의 권한: 객체 넣기와 멀티파트 관련 동작만 허용합니다. 삭제는 없습니다.
data "aws_iam_policy_document" "observability_writer" {
  statement {
    sid       = "PutObservabilitySignalObjects"                                                            # 예: 적재 문장
    effect    = "Allow"                                                                                    # 예: "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"] # 예: 존재 확인과 업로드에 필요한 4개; DeleteObject 없음
    resources = local.signal_object_arns                                                                   # 예: [".../metrics-.../dev/*", ".../logs-.../*", ".../traces-.../dev/*"]

    condition {
      test     = "StringEquals"            # 예: "StringEquals"
      variable = "aws:ResourceAccount"     # 예: 대상 버킷의 소유 계정
      values   = [var.expected_account_id] # 예: ["111111111111"] (다른 계정 소유 버킷이면 허용되지 않음)
    }
  }

  statement {
    sid       = "ListWriteTargetsInEnvironmentPrefix" # 예: 접두사 아래 목록 문장
    effect    = "Allow"                               # 예: "Allow"
    actions   = ["s3:ListBucket"]                     # 예: 환경 접두사 아래 객체 목록
    resources = local.prefixed_bucket_arns            # 예: metrics · traces 버킷 ARN (객체 경로 /* 를 붙이지 않음)

    condition {
      test     = "StringLike"                # 예: "StringLike" (와일드카드 비교)
      variable = "s3:prefix"                 # 예: 목록 요청의 접두사 인자
      values   = ["${local.object_prefix}*"] # 예: ["dev/*"] (prefix 를 생략하면 허용되지 않음)
    }
  }

  dynamic "statement" {
    for_each = length(local.unprefixed_bucket_arns) > 0 ? [1] : [] # 예: logs 버킷이 접두사 없이 쓰이므로 1개 문장
    content {
      sid       = "ListWriteTargetsInUnprefixedBuckets" # 예: 접두사 없는 버킷의 목록 문장
      effect    = "Allow"                               # 예: "Allow"
      actions   = ["s3:ListBucket"]                     # 예: 버킷 전체 목록 (Loki 는 index/ · <tenant>/ 를 최상위에서 나열)
      resources = local.unprefixed_bucket_arns          # 예: logs 버킷 ARN 1개

      condition {
        test     = "StringEquals"            # 예: "StringEquals"
        variable = "aws:ResourceAccount"     # 예: 대상 버킷의 소유 계정
        values   = [var.expected_account_id] # 예: ["111111111111"]
      }
    }
  }

  statement {
    sid       = "ListMultipartUploadsInEnvironmentBuckets" # 예: 진행 중 업로드 목록
    effect    = "Allow"                                    # 예: "Allow"
    actions   = ["s3:ListBucketMultipartUploads"]          # 예: 버킷의 진행 중 멀티파트 업로드 목록
    resources = values(local.signal_bucket_arns)           # 예: 이 환경의 버킷 ARN 3개

    condition {
      test     = "StringEquals"            # 예: "StringEquals"
      variable = "aws:ResourceAccount"     # 예: 대상 버킷의 소유 계정
      values   = [var.expected_account_id] # 예: ["111111111111"]
    }
  }

  statement {
    sid       = "DenyListingOutsideEnvironmentPrefix" # 예: 명시적 거부 문장 (다른 정책의 Allow 보다 우선)
    effect    = "Deny"                                # 예: "Deny"
    actions   = ["s3:ListBucket"]                     # 예: 객체 목록 동작만 거부 대상
    resources = local.prefixed_bucket_arns            # 예: 접두사가 있는 버킷 ARN 2개로 한정

    condition {
      test     = "StringNotLike"             # 예: "StringNotLike" (조건 키가 없으면 참이 되어 거부됨)
      variable = "s3:prefix"                 # 예: "s3:prefix"
      values   = ["${local.object_prefix}*"] # 예: ["dev/*"] (prod/ 목록 조회와 접두사 없는 조회를 거부)
    }
  }
}

# 읽는 역할의 권한: 객체 가져오기와 목록만 허용합니다.
data "aws_iam_policy_document" "observability_reader" {
  statement {
    sid       = "GetObservabilitySignalObjects" # 예: 조회 문장
    effect    = "Allow"                         # 예: "Allow"
    actions   = ["s3:GetObject"]                # 예: 넣기와 지우기를 주지 않음
    resources = local.signal_object_arns        # 예: 객체 ARN 패턴 3개

    condition {
      test     = "StringEquals"            # 예: "StringEquals"
      variable = "aws:ResourceAccount"     # 예: "aws:ResourceAccount"
      values   = [var.expected_account_id] # 예: ["111111111111"]
    }
  }

  statement {
    sid       = "ListReadTargetsInEnvironmentPrefix" # 예: 접두사 아래 목록 문장
    effect    = "Allow"                              # 예: "Allow"
    actions   = ["s3:ListBucket"]                    # 예: 멀티파트 목록은 조회 쪽에 필요 없음
    resources = local.prefixed_bucket_arns           # 예: metrics · traces 버킷 ARN

    condition {
      test     = "StringLike"                # 예: "StringLike"
      variable = "s3:prefix"                 # 예: "s3:prefix"
      values   = ["${local.object_prefix}*"] # 예: ["dev/*"]
    }
  }

  dynamic "statement" {
    for_each = length(local.unprefixed_bucket_arns) > 0 ? [1] : [] # 예: logs 버킷 1개
    content {
      sid       = "ListReadTargetsInUnprefixedBuckets" # 예: 접두사 없는 버킷의 목록 문장
      effect    = "Allow"                              # 예: "Allow"
      actions   = ["s3:ListBucket"]                    # 예: 버킷 전체 목록
      resources = local.unprefixed_bucket_arns         # 예: logs 버킷 ARN 1개

      condition {
        test     = "StringEquals"            # 예: "StringEquals"
        variable = "aws:ResourceAccount"     # 예: "aws:ResourceAccount"
        values   = [var.expected_account_id] # 예: ["111111111111"]
      }
    }
  }

  statement {
    sid       = "DenyListingOutsideEnvironmentPrefix" # 예: 명시적 거부 문장
    effect    = "Deny"                                # 예: "Deny"
    actions   = ["s3:ListBucket"]                     # 예: "s3:ListBucket"
    resources = local.prefixed_bucket_arns            # 예: 접두사가 있는 버킷 ARN 2개

    condition {
      test     = "StringNotLike"             # 예: "StringNotLike"
      variable = "s3:prefix"                 # 예: "s3:prefix"
      values   = ["${local.object_prefix}*"] # 예: ["dev/*"]
    }
  }
}

# 정리 역할의 권한: 기존 블록 읽기, 병합 결과 업로드, 오래된 블록 삭제를 허용합니다.
data "aws_iam_policy_document" "observability_maintenance" {
  statement {
    sid       = "CompactAndRetainObservabilityObjects"                                                                        # 예: 삭제가 있는 유일한 문장
    effect    = "Allow"                                                                                                       # 예: "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"] # 예: 블록 병합과 보존 기간 정리
    resources = local.signal_object_arns                                                                                      # 예: 객체 ARN 패턴 3개

    condition {
      test     = "StringEquals"            # 예: "StringEquals"
      variable = "aws:ResourceAccount"     # 예: "aws:ResourceAccount"
      values   = [var.expected_account_id] # 예: ["111111111111"]
    }
  }

  statement {
    sid       = "ListMaintenanceTargetsInEnvironmentPrefix" # 예: 지울 대상을 찾는 목록 문장
    effect    = "Allow"                                     # 예: "Allow"
    actions   = ["s3:ListBucket"]                           # 예: "s3:ListBucket"
    resources = local.prefixed_bucket_arns                  # 예: metrics · traces 버킷 ARN

    condition {
      test     = "StringLike"                # 예: "StringLike"
      variable = "s3:prefix"                 # 예: "s3:prefix"
      values   = ["${local.object_prefix}*"] # 예: ["dev/*"]
    }
  }

  dynamic "statement" {
    for_each = length(local.unprefixed_bucket_arns) > 0 ? [1] : [] # 예: logs 버킷 1개
    content {
      sid       = "ListMaintenanceTargetsInUnprefixedBuckets" # 예: 접두사 없는 버킷의 목록 문장
      effect    = "Allow"                                     # 예: "Allow"
      actions   = ["s3:ListBucket"]                           # 예: 버킷 전체 목록
      resources = local.unprefixed_bucket_arns                # 예: logs 버킷 ARN 1개

      condition {
        test     = "StringEquals"            # 예: "StringEquals"
        variable = "aws:ResourceAccount"     # 예: "aws:ResourceAccount"
        values   = [var.expected_account_id] # 예: ["111111111111"]
      }
    }
  }

  statement {
    sid       = "ListMaintenanceMultipartUploads" # 예: 진행 중 업로드 목록
    effect    = "Allow"                           # 예: "Allow"
    actions   = ["s3:ListBucketMultipartUploads"] # 예: "s3:ListBucketMultipartUploads"
    resources = values(local.signal_bucket_arns)  # 예: 버킷 ARN 3개

    condition {
      test     = "StringEquals"            # 예: "StringEquals"
      variable = "aws:ResourceAccount"     # 예: "aws:ResourceAccount"
      values   = [var.expected_account_id] # 예: ["111111111111"]
    }
  }

  statement {
    sid       = "DenyListingOutsideEnvironmentPrefix" # 예: 명시적 거부 문장
    effect    = "Deny"                                # 예: "Deny"
    actions   = ["s3:ListBucket"]                     # 예: "s3:ListBucket"
    resources = local.prefixed_bucket_arns            # 예: 접두사가 있는 버킷 ARN 2개

    condition {
      test     = "StringNotLike"             # 예: "StringNotLike"
      variable = "s3:prefix"                 # 예: "s3:prefix"
      values   = ["${local.object_prefix}*"] # 예: ["dev/*"]
    }
  }
}

resource "aws_iam_policy" "observability_writer" {
  name        = "cp-${var.environment}-observability-writer"                              # 예: "cp-dev-observability-writer" (변경 시 정책 교체 발생)
  path        = "/platform/"                                                              # 예: "/platform/" (ARN 에 반영됨)
  description = "Object checks and uploads in this environment's observability prefixes." # 예: 콘솔에 표시되는 용도 설명
  policy      = data.aws_iam_policy_document.observability_writer.json                    # 예: 문장 5개를 포함한 JSON 문자열
}

resource "aws_iam_policy" "observability_reader" {
  name        = "cp-${var.environment}-observability-reader"            # 예: "cp-dev-observability-reader"
  path        = "/platform/"                                            # 예: "/platform/"
  description = "Read-only object storage access for query components." # 예: 저장소 조회 구성 요소 전용
  policy      = data.aws_iam_policy_document.observability_reader.json  # 예: 문장 4개를 포함한 JSON 문자열
}

resource "aws_iam_policy" "observability_maintenance" {
  name        = "cp-${var.environment}-observability-maintenance"                  # 예: "cp-dev-observability-maintenance"
  path        = "/platform/"                                                       # 예: "/platform/"
  description = "Read, compact, upload and delete blocks within this environment." # 예: 정리 전용
  policy      = data.aws_iam_policy_document.observability_maintenance.json        # 예: 문장 5개를 포함한 JSON 문자열
}

resource "aws_iam_role" "observability_writer" {
  name        = "cp-${var.environment}-observability-writer"             # 예: "cp-dev-observability-writer" (변경 시 역할 교체 발생)
  path        = "/platform/"                                             # 예: "/platform/" (ARN 에 반영됨)
  description = "Checks and uploads signal objects; cannot delete them." # 예: 콘솔에 표시되는 용도 설명

  assume_role_policy   = data.aws_iam_policy_document.observability_access_trust.json # 예: 문장 2개(운영자 · Pod Identity)를 포함한 JSON
  permissions_boundary = var.permissions_boundary_arn                                 # 예: null (미부착)
  max_session_duration = 3600                                                         # 예: 3600 (초 단위 = 1시간; AWS 허용 범위 3600~43200)
}

resource "aws_iam_role" "observability_reader" {
  name        = "cp-${var.environment}-observability-reader"         # 예: "cp-dev-observability-reader"
  path        = "/platform/"                                         # 예: "/platform/"
  description = "Reads signal objects for storage query components." # 예: 조회 전용

  assume_role_policy   = data.aws_iam_policy_document.observability_access_trust.json # 예: 쓰기 역할과 같은 신뢰 정책
  permissions_boundary = var.permissions_boundary_arn                                 # 예: null (미부착)
  max_session_duration = 3600                                                         # 예: 3600
}

resource "aws_iam_role" "observability_maintenance" {
  name        = "cp-${var.environment}-observability-maintenance"     # 예: "cp-dev-observability-maintenance"
  path        = "/platform/"                                          # 예: "/platform/"
  description = "Compacts blocks and deletes expired signal objects." # 예: 정리 전용

  assume_role_policy   = data.aws_iam_policy_document.observability_access_trust.json # 예: 쓰기 역할과 같은 신뢰 정책
  permissions_boundary = var.permissions_boundary_arn                                 # 예: null (미부착)
  max_session_duration = 3600                                                         # 예: 3600
}

resource "aws_iam_role_policy_attachment" "observability_writer" {
  role       = aws_iam_role.observability_writer.name  # 예: "cp-dev-observability-writer" (ARN 이 아니라 역할 이름)
  policy_arn = aws_iam_policy.observability_writer.arn # 예: "arn:aws:iam::111111111111:policy/platform/cp-dev-observability-writer"
}

resource "aws_iam_role_policy_attachment" "observability_reader" {
  role       = aws_iam_role.observability_reader.name  # 예: "cp-dev-observability-reader"
  policy_arn = aws_iam_policy.observability_reader.arn # 예: "arn:aws:iam::111111111111:policy/platform/cp-dev-observability-reader"
}

resource "aws_iam_role_policy_attachment" "observability_maintenance" {
  role       = aws_iam_role.observability_maintenance.name  # 예: "cp-dev-observability-maintenance"
  policy_arn = aws_iam_policy.observability_maintenance.arn # 예: "arn:aws:iam::111111111111:policy/platform/cp-dev-observability-maintenance"
}
