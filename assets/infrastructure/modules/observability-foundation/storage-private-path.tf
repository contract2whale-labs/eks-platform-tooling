# storage-private-path.tf — modules/observability-foundation (dev · prod 루트 모듈이 공유하는 모듈)
# 뒤 챕터가 만드는 이 계정의 저장소(애플리케이션 데이터 · 운영 환경 의 앱 미디어 버킷)는 additional_bucket_names 로 허용 목록에 더합니다 — 더하지 않으면 그 버킷 요청은 이 정책의 거부 문장에 걸립니다.
# network/vpc State가 소유한 endpoint를 VPC ID와 서비스 이름으로 조회하고 이 저장소 State가 정책만 관리합니다.
# 이 정책 리소스의 destroy는 provider가 endpoint 정책을 기본 전체 허용으로 되돌릴 수 있습니다. 정상 검증 중 reset-policy를 실행하지 않습니다. 장애 복구는 BU10B05에서 이전 정책 백업·대상 계정/endpoint·확대 영향·복원 승인을 검토합니다.

# 아래 세 입력은 이 파일에서만 쓰입니다 (network/vpc State 의 vpc_id · network_logs_bucket_name, 루트 모듈 입력 additional_bucket_names).
variable "vpc_id" {
  description = "Workload VPC that owns the S3 gateway endpoint."
  type        = string # 예: "vpc-0123456789abcdef0" (network/vpc State 출력)
  nullable    = false

  validation {
    condition     = can(regex("^vpc-[0-9a-f]{8,17}$", var.vpc_id)) # "vpc-0123456789abcdef0" 통과
    error_message = "vpc_id must look like vpc-…"
  }
}

variable "network_logs_bucket_name" {
  description = "Network log bucket created by the network/vpc root; kept reachable through the endpoint."
  type        = string # 예: "cp-dev-network-logs-111111111111-ap-northeast-2" (network/vpc State 출력)
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.network_logs_bucket_name)) # S3 버킷 이름 규칙
    error_message = "network_logs_bucket_name must be a valid S3 bucket name."
  }
}

variable "additional_bucket_names" {
  description = "Other buckets of this account that must stay reachable through the endpoint (for example the application media bucket created later)."
  type        = list(string) # 예: ["cp-dev-app-exports-111111111111-ap-northeast-2"] (애플리케이션 데이터 미디어 버킷)
  default     = [] # 추가 소유 버킷 없음
  nullable    = false

  validation {
    condition     = alltrue([for name in var.additional_bucket_names : can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", name))]) # S3 버킷 이름 규칙
    error_message = "additional_bucket_names must contain valid S3 bucket names."
  }
}

# network/vpc의 기존 S3 Gateway endpoint를 조회합니다.
data "aws_vpc_endpoint" "s3" {
  vpc_id       = var.vpc_id # "vpc-0123456789abcdef0"
  service_name = "com.amazonaws.${var.region}.s3" # "com.amazonaws.ap-northeast-2.s3"

  filter {
    name   = "vpc-endpoint-type" # 엔드포인트 종류로 거름
    values = ["Gateway"]
  }

  lifecycle {
    postcondition {
      condition     = self.state == "available" # "available" (endpoint 서비스 상태; 각 노드 서브넷의 실제 라우팅은 별도 확인)
      error_message = "The S3 gateway endpoint must be available before its policy is restricted."
    }
  }
}

locals {
  # Velero null 값은 compact로 제외됩니다. 고정 개수 대신 성공 output의 실제 이름·owner 목록을 대조합니다.
  owned_bucket_names = sort(distinct(compact(concat(
    [var.network_logs_bucket_name, var.operations_contract.velero_bucket_name], # 관련 구성 로그 버킷 · 운영 도구 백업 버킷 (null 이면 compact 가 뺌)
    values(local.signal_bucket_names), # 모니터링 저장소 3개
    var.additional_bucket_names # 애플리케이션 데이터 미디어 버킷 (기본값 [])
  ))))

  owned_bucket_arns = [for name in local.owned_bucket_names : "arn:aws:s3:::${name}"] # 목록 계열 동작의 대상
  owned_object_arns = [for name in local.owned_bucket_names : "arn:aws:s3:::${name}/*"] # 객체 계열 동작의 대상

  # 컨테이너 이미지 계층이 실제로 내려오는 AWS 소유 저장소입니다 (private ECR의 starport layer 저장소). 이 endpoint 경로에서 새 layer를 받는 private ECR pull에 필요하며, ECR Public 전체 경로를 보장하지 않습니다.
  aws_owned_object_arns = [
    "arn:aws:s3:::prod-${var.region}-starport-layer-bucket/*", # 예: "arn:aws:s3:::prod-ap-northeast-2-starport-layer-bucket/*"
  ]
}

# 현재 정책의 Principal은 *이며 호출자 IAM 역할·bucket policy는 각각 평가됩니다.
# 엔드포인트 정책은 이 엔드포인트를 통과할 수 있는 요청의 범위만 정합니다. 새 권한을 주지 않으며 호출자 역할 권한과 버킷 정책은 따로 평가됩니다.
data "aws_iam_policy_document" "s3_endpoint" {
  statement {
    sid    = "AllowOwnedObservabilityBuckets"
    effect = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:GetObject", # 저장된 블록 읽기
      "s3:PutObject", # 새 블록 쓰기
      "s3:DeleteObject", # 보존 기간이 지난 블록 정리
      "s3:AbortMultipartUpload", # 중단된 대용량 업로드 정리
      "s3:ListMultipartUploadParts", # 특정 멀티파트 업로드의 조각 조회
      "s3:ListBucket", # 접두사 단위 목록 조회
      "s3:ListBucketMultipartUploads", # 진행 중인 대용량 업로드 조회
      "s3:GetBucketLocation", # 버킷 리전 확인 (SDK 가 먼저 호출함)
    ]

    resources = concat(local.owned_bucket_arns, local.owned_object_arns)

    condition {
      test     = "StringEquals"
      variable = "s3:ResourceAccount" # 대상 버킷을 소유한 계정
      values   = [var.expected_account_id] # 예: ["111111111111"] (다른 계정 저장소를 배제)
    }
  }

  # (2) 컨테이너 이미지 계층이 오는 AWS 소유 저장소를 읽기만 허용합니다.
  statement {
    sid    = "AllowAwsOwnedImageAndBootstrap"
    effect = "Allow"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:GetObject"] # 계층 바이너리 내려받기 한 가지만
    resources = local.aws_owned_object_arns # ["arn:aws:s3:::prod-ap-northeast-2-starport-layer-bucket/*"]
  }

  # (3) 위 두 문장이 지정하지 않은 대상은 모두 거부합니다 (여집합으로 적어 허용 목록만 관리).
  statement {
    sid    = "DenyEverythingElse"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions       = ["s3:*"] # 거부 문장이므로 동작을 넓게 적음
    not_resources = concat(local.owned_bucket_arns, local.owned_object_arns, local.aws_owned_object_arns) # 허용 목록만 거부 대상에서 제외
  }
}

resource "aws_vpc_endpoint_policy" "s3" {
  vpc_endpoint_id = data.aws_vpc_endpoint.s3.id                   # 예: "vpce-0123456789abcdef0"
  policy          = data.aws_iam_policy_document.s3_endpoint.json # 위 세 문장을 합친 JSON 문자열

  depends_on = [aws_s3_bucket_policy.signal] # 모니터링 저장소가 먼저 있은 뒤 통과 범위를 좁힙니다
}

# 후반부 · 메시지 큐 전환 가 같은 이름 규칙으로 저장소를 더할 때 대조하는 계약입니다.
output "observability_network_contract" {
  description = "S3 gateway endpoint id, allowed bucket names and endpoint policy mode."
  value = {
    s3_endpoint_id          = data.aws_vpc_endpoint.s3.id # 예: "vpce-0123456789abcdef0"
    allowed_bucket_prefixes = local.owned_bucket_names # null을 제외한 실제 소유 버킷 이름 목록
    endpoint_policy_mode    = "restricted"
  }
}
