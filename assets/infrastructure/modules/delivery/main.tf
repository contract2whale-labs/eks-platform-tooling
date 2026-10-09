# main.tf — modules/delivery (dev · prod 루트 모듈이 공유하는 모듈)
# 리포지토리 이름은 앱 이미지 이름(commerce-web · commerce-api) 그대로입니다. 이미지 참조는 <계정>.dkr.ecr.<리전>.amazonaws.com/commerce-web@sha256:… 이며 CI 가 태그(v1.2.3)와 digest 를 함께 남깁니다.

locals {
  account_id   = split(":", var.cluster_contract.arn)[4]                          # 예: "111111111111" (클러스터 ARN 의 다섯 번째 조각)
  name_prefix  = "${var.cluster_contract.name}-delivery"                          # 예: "contract2whale-dev-eks-delivery" (KMS alias · Pod Identity Role 이름 접두사)
  ecr_registry = "${var.expected_account_id}.dkr.ecr.${var.region}.amazonaws.com" # 예: "111111111111.dkr.ecr.ap-northeast-2.amazonaws.com" (Kyverno 허용 레지스트리 · kustomize newName)
}

# 실행 전에 계정 · 리전 계약을 대조합니다. AWS 자원을 만들지 않으며 다른 리소스가 depends_on 으로 이 검사 뒤에 만들어집니다.
resource "terraform_data" "contract" {
  input = {
    account = var.expected_account_id   # 예: "111111111111"
    cluster = var.cluster_contract.name # 예: "contract2whale-dev-eks"
  }

  lifecycle {
    precondition {
      condition     = local.account_id == var.expected_account_id # 예: 클러스터 ARN 의 계정 = 기대 계정
      error_message = "cluster_contract.arn must belong to expected_account_id."
    }

    precondition {
      condition     = var.cluster_contract.region == var.region # 예: 계약 리전 = 모듈 리전
      error_message = "cluster_contract.region must equal region."
    }

    precondition {
      condition     = contains(var.ecr_repository_names, var.application_workloads.web.deployment) && contains(var.ecr_repository_names, var.application_workloads.api.deployment) # 예: 두 워크로드 이름이 모두 리포지토리 목록에 있는지 (이미지 이름 = 리포지토리 이름)
      error_message = "ecr_repository_names must contain both application workload names."
    }
  }
}

# 태그 불변: 같은 태그로 다시 push 하면 거부됩니다 (ImageTagAlreadyExistsException). 태그 v1.2.3 이 항상 같은 digest 를 가리키는 근거입니다.
resource "aws_ecr_repository" "app" {
  for_each = var.ecr_repository_names # 예: {"commerce-api" = "commerce-api", "commerce-web" = "commerce-web"}

  name                 = each.key                   # 예: "commerce-web" (이미지 이름 = 리포지토리 이름)
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION" # 예: 이미지 태그는 덮어쓰기 거부, 아래 두 무늬의 서명 · attestation 태그만 갱신 허용

  # cosign 의 legacy 형식은 한 digest 의 서명 전부를 sha256-<digest>.sig 태그 하나에(attestation 은 .att 에) 모아 둡니다.
  # 같은 digest 에 새 키의 서명을 더하면(서명 키 교체 · 증적과 복구) 그 태그의 manifest 가 바뀌므로, 이 두 무늬만 불변에서 뺍니다.
  # 이미지 태그(git-<sha> 등)는 여전히 덮어쓸 수 없습니다 — 배포는 digest 로 하므로 서명 태그의 갱신은 배포 대상을 바꾸지 못합니다.
  image_tag_mutability_exclusion_filter {
    filter      = "sha256-*.sig" # 예: cosign 서명 태그
    filter_type = "WILDCARD"     # 예: "WILDCARD" (ECR 이 지원하는 유일한 형식)
  }
  image_tag_mutability_exclusion_filter {
    filter      = "sha256-*.att" # 예: cosign attestation(SBOM) 태그
    filter_type = "WILDCARD"
  }
  force_delete = var.environment != "prod" # 예: dev true (실습 삭제 시 이미지가 남아 있어도 삭제) · prod false (이미지가 있으면 destroy 거부)

  image_scanning_configuration {
    scan_on_push = true # 예: true (push 마다 기본 스캔; CI 의 Trivy 판정과 별개로 AWS 가 기록)
  }

  encryption_configuration {
    encryption_type = "AES256" # 예: "AES256" (ECR 의 AES-256 저장 암호화; 서명 키(KMS)와 별개)
  }

  tags = {
    Name = "${local.name_prefix}-${each.key}" # 예: "contract2whale-dev-eks-delivery-commerce-web"
  }

  depends_on = [terraform_data.contract] # 예: 계약 검사 통과 후 생성
}

# 수명 주기: 태그 없는 이미지(중간 layer · 실패한 push)는 며칠 뒤 삭제, 릴리스 태그(v*)는 최근 N개만 보존. cosign 서명 · attestation 은 태그 sha256-<digest>.sig · .att 라 두 규칙의 대상이 아닙니다.
resource "aws_ecr_lifecycle_policy" "app" {
  for_each = aws_ecr_repository.app # 예: 리포지토리마다 정책 1개 (리포지토리 2개 → 정책 2개)

  repository = each.value.name # 예: "commerce-web"

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "expire untagged images after ${var.untagged_expire_days} days" # 예: "expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"         # 예: 태그 없는 이미지만
          countType   = "sinceImagePushed" # 예: push 시각 기준
          countUnit   = "days"
          countNumber = var.untagged_expire_days # 예: 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "keep the newest ${var.image_retention_count} release tags" # 예: "keep the newest 30 release tags"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v"]                     # 예: v1.2.3 처럼 v 로 시작하는 릴리스 태그만
          countType     = "imageCountMoreThan"      # 예: 개수 기준
          countNumber   = var.image_retention_count # 예: 30
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 3
        description  = "expire build tags after ${var.build_tag_expire_days} days" # 예: "expire build tags after 14 days" (CI 가 push 마다 남기는 build-<sha12> 태그)
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["build-"] # 예: build-3f2a9c1b0e7d (릴리스 v* · 서명 sha256-* 태그는 대상 아님)
          countType     = "sinceImagePushed"
          countUnit     = "days"
          countNumber   = var.build_tag_expire_days # 예: 14
        }
        action = { type = "expire" }
      }
    ]
  })
}

# 계정 · 리전 단위 스캔 설정: ENHANCED(Amazon Inspector v2) + 이 모듈의 리포지토리는 CONTINUOUS_SCAN — push 시점 스캔(scan_on_push)만으로는 배포 뒤 공개되는 CVE 를 볼 수 없습니다.
resource "aws_ecr_registry_scanning_configuration" "account" {
  count = var.manage_registry_scanning ? 1 : 0 # 예: 1 (이 모듈이 관리) · 0 (다른 루트 모듈이 관리)

  scan_type = "ENHANCED" # 예: "ENHANCED" (Inspector v2; BASIC 은 push 시점 · 수동 스캔만)

  rule {
    scan_frequency = "CONTINUOUS_SCAN" # 예: 저장 중인 이미지도 새 CVE 공개 시 재스캔
    repository_filter {
      filter      = "*"        # 예: 모든 리포지토리 (계정 단위 설정; 다른 팀 리포지토리 필터는 운영 규칙에 따라 좁힘)
      filter_type = "WILDCARD" # 예: WILDCARD
    }
  }

  depends_on = [terraform_data.contract] # 예: 계약 검사 통과 후 적용
}
