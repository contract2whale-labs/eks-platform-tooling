# ci-identity.tf — modules/delivery (dev · prod 루트 모듈이 공유하는 모듈)

locals {
  ci_role_name = "cp-${var.environment}-ci-delivery" # 예: "cp-dev-ci-delivery" (관측 파이프라인 의 cp-<env>-observability-* 와 같은 접두사 규칙)

  app_repositories = sort([var.github_app_repositories.web.name, var.github_app_repositories.api.name]) # 예: ["contract2whale-labs/commerce-api", "contract2whale-labs/commerce-web"] (정렬해 sub 목록 순서를 고정)
  app_repository_ids = {
    (var.github_app_repositories.web.name) = var.github_app_repositories.web.id # 예: "contract2whale-labs/commerce-web" = "1012345601"
    (var.github_app_repositories.api.name) = var.github_app_repositories.api.id # 예: "contract2whale-labs/commerce-api" = "1012345602"
  }
  # 2026-07-15 이후 만든 저장소의 sub 형식: repo:<owner>@<owner ID>/<이름>@<저장소 ID>:ref:<ref> (GitHub Docs OIDC reference 의 immutable subject claim)
  github_subjects = flatten([
    for repository in local.app_repositories : [
      for ref in var.github_release_refs :
      "repo:${split("/", repository)[0]}@${var.github_app_repositories.owner_id}/${split("/", repository)[1]}@${local.app_repository_ids[repository]}:ref:${ref}"
    ]
  ]) # 예: 저장소 2 × ref 1 = sub 2개 ["repo:contract2whale-labs@201234567/commerce-api@1012345602:ref:refs/heads/main", "repo:contract2whale-labs@201234567/commerce-web@1012345601:ref:refs/heads/main"]
}

resource "aws_iam_role" "ci" {
  name                 = local.ci_role_name           # 예: "cp-dev-ci-delivery"
  path                 = "/platform/"                 # 예: "/platform/" (관련 구성 State 역할 · 관측 파이프라인 저장소 역할과 같은 경로)
  permissions_boundary = var.permissions_boundary_arn # 예: null
  max_session_duration = 3600                         # 예: 3600 (Actions job 하나의 상한; 기본값)

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "GitHubActionsOidc"
      Effect    = "Allow"
      Principal = { Federated = var.github_oidc_provider_arn } # 예: 계정의 GitHub OIDC provider (Dev GitHub OIDC 연결과 Prod 코드 배치)
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }   # 예: aud 고정 (aws-actions/configure-aws-credentials 기본값)
        StringLike   = { "token.actions.githubusercontent.com:sub" = local.github_subjects } # 예: 앱 저장소 2개의 main 만 (PR 브랜치 · 태그 · 다른 저장소 · ID 가 다른 같은 이름 저장소 거부; 와일드카드가 없어 정확히 일치해야 함)
      }
    }]
  })

  lifecycle {
    precondition {
      condition     = split(":", var.github_oidc_provider_arn)[4] == var.expected_account_id # 예: provider 가 이 계정 것인지
      error_message = "github_oidc_provider_arn must belong to expected_account_id."
    }
  }

  depends_on = [terraform_data.contract] # 예: 계약 검사 통과 후 생성
}

resource "aws_iam_role_policy" "ci" {
  name = "ecr-push-and-kms-sign" # 예: "ecr-push-and-kms-sign" (Role 안 인라인 정책 이름)
  role = aws_iam_role.ci.id      # 예: "cp-dev-ci-delivery"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"] # 예: docker login 토큰 (리소스 지정 불가 → *)
        Resource = "*"
      },
      {
        Sid    = "EcrPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", # 예: layer 존재 확인
          "ecr:InitiateLayerUpload",         # 예: layer 업로드 시작
          "ecr:UploadLayerPart",             # 예: layer 조각 업로드
          "ecr:CompleteLayerUpload",         # 예: layer 업로드 완료
          "ecr:PutImage",                    # 예: manifest 기록 (이미지 · cosign 서명 · attestation)
          "ecr:BatchGetImage",               # 예: manifest 읽기 (cosign 이 대상 digest 조회)
          "ecr:GetDownloadUrlForLayer",      # 예: layer 읽기 (Trivy 가 ECR 이미지를 스캔할 때)
          "ecr:DescribeImages",              # 예: digest · 스캔 상태 조회
        ]
        Resource = [for repository in aws_ecr_repository.app : repository.arn] # 예: ["arn:aws:ecr:ap-northeast-2:111111111111:repository/commerce-api", "…:repository/commerce-web"] (이 모듈이 만든 2개만)
      },
      {
        Sid      = "KmsSign"
        Effect   = "Allow"
        Action   = ["kms:Sign", "kms:GetPublicKey", "kms:DescribeKey"] # 예: 서명 · 공개 키 · 키 사양 조회 (Decrypt · Encrypt 없음)
        Resource = aws_kms_key.signing.arn                             # 예: 서명 필드 계약만
      }
      ], var.previous_signing_key_id == null ? [] : [
      {
        # 키 교체 중에만 생깁니다(증적과 복구): resign 워크플로가 새 서명을 더하기 **전에** 이전 키의 서명 · attestation 을 검증합니다.
        # cosign 은 검증할 때 GetPublicKey 와 DescribeKey 를 모두 부릅니다. kms:Sign 은 주지 않습니다 — 이전 키로는 검증만 합니다.
        Sid      = "KmsVerifyPrevious"
        Effect   = "Allow"
        Action   = ["kms:GetPublicKey", "kms:DescribeKey"]
        Resource = "arn:aws:kms:${var.region}:${var.expected_account_id}:key/${var.previous_signing_key_id}" # 예: alias ARN 이 아니라 key ARN (IAM 은 alias 로 키 권한을 줄 수 없음)
      }
    ])
  })
}
