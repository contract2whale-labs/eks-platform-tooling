# state-access-role.tf — account-baseline 루트 모듈 (dev · prod 공통 코드)
# S3 backend 전용 역할 1개와 inline 정책 1개를 선언합니다. 이 역할은 플랫폼 리소스를 배포하지 않습니다.

# 신뢰 정책: 누가 이 역할을 맡을 수 있는가?
# Principal 에는 사용자가 확인한 실제 IAM role ARN 만 넣습니다.
data "aws_iam_policy_document" "state_trust" {
  statement {
    sid     = "TrustExplicitOperators" # 예: "TrustExplicitOperators" (정책 문서와 계약 테스트의 문장 식별용)
    effect  = "Allow"                  # 예: "Allow" (이 주체들의 AssumeRole 을 허용)
    actions = ["sts:AssumeRole"]       # 예: ["sts:AssumeRole"] (이 역할의 IAM AssumeRole 요청에 필요한 액션)

    principals {
      type        = "AWS"                                    # 예: "AWS" (IAM 주체; 서비스는 "Service", 외부 발급자는 "Federated")
      identifiers = sort(tolist(var.trusted_principal_arns)) # 예: ["arn:aws:iam::111111111111:role/PlatformOperator"] (정렬해 JSON 순서 고정)
    }
  }
}

resource "aws_iam_role" "terraform_state_access" {
  name        = "cp-${var.environment}-terraform-state"                       # 예: "cp-dev-terraform-state" (변경 시 역할 교체 발생)
  path        = "/platform/"                                                  # 예: "/platform/" (ARN 에 반영됨; 변경 시 교체 발생)
  description = "S3 backend access only; does not deploy platform resources." # 예: 콘솔에 표시되는 용도 설명

  assume_role_policy   = data.aws_iam_policy_document.state_trust.json # 예: TrustExplicitOperators 문장을 포함한 JSON 문자열
  permissions_boundary = var.permissions_boundary_arn                  # 예: 기본 null (미부착), 사용 시 실제 IAM policy ARN
  max_session_duration = 3600                                          # 예: 3600 (초 단위 = 1시간; AWS 허용 범위 3600~43200)
}

# 권한 정책: 역할을 맡은 뒤 무엇을 할 수 있는가?
data "aws_iam_policy_document" "state_access" {
  # 버킷 목록 조회는 허용하되 객체 내용 접근은 아래 정확한 ARN 으로 제한합니다.
  # backend 의 workspace 열거를 지원합니다. 이 과정은 default workspace 만 사용합니다.
  statement {
    sid       = "ListStateBucket"        # 예: "ListStateBucket" (버킷 수준 목록 조회 문장)
    effect    = "Allow"                  # 예: "Allow"
    actions   = ["s3:ListBucket"]        # 예: ["s3:ListBucket"] (key 이름 목록만; 객체 내용 접근은 아님)
    resources = [local.state_bucket_arn] # 예: ["arn:aws:s3:::company-dev-tfstate-111111111111"] (객체 경로 /* 를 붙이지 않음)
  }

  # State 객체 자체의 DeleteObject 권한은 주지 않습니다.
  statement {
    sid       = "ReadWriteSelectedStates"        # 예: "ReadWriteSelectedStates" (State 본문 문장)
    effect    = "Allow"                          # 예: "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"] # 예: 읽기와 저장만; DeleteObject 를 의도적으로 제외
    resources = local.state_object_arns          # 예: [".../account-baseline/terraform.tfstate", ".../network/vpc/terraform.tfstate", ...]
  }

  # 정상 완료 시 잠금을 해제하려면 .tflock 삭제 권한이 필요합니다.
  statement {
    sid       = "ManageSelectedLocks"                               # 예: "ManageSelectedLocks" (잠금 객체 문장)
    effect    = "Allow"                                             # 예: "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"] # 예: 잠금 확인·생성·해제
    resources = local.lock_object_arns                              # 예: [".../terraform.tfstate.tflock" 목록]
  }
}

resource "aws_iam_role_policy" "state_access" {
  name   = "selected-state-and-lock-objects"              # 예: "selected-state-and-lock-objects" (inline policy 이름)
  role   = aws_iam_role.terraform_state_access.id         # 예: "cp-dev-terraform-state" (IAM Role 의 ID 는 역할 이름)
  policy = data.aws_iam_policy_document.state_access.json # 예: Statement 3개를 포함한 JSON 문자열
}
