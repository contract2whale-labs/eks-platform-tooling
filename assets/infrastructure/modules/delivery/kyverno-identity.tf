# operator ECR의 추가 읽기 정책은 후속 data apply가 exact repository ARN으로 연결합니다.
# kyverno-identity.tf — modules/delivery (dev · prod 루트 모듈이 공유하는 모듈)
# 서명 검증은 정책의 keys.kms(awskms:///alias/delivery-signing)가 가리키는 키의 공개 키를 kms:GetPublicKey 로 읽어 합니다 — kms:Sign · Decrypt 는 없습니다. 쓰기(PutImage) 도 없습니다.

locals {
  kyverno_service_accounts = toset(["kyverno-admission-controller", "kyverno-reports-controller"]) # 예: chart 기본 SA 이름 2개 (어드미션 검증 · 백그라운드 보고서)
}

resource "aws_iam_role" "kyverno" {
  name                 = "${local.name_prefix}-kyverno" # 예: "contract2whale-dev-eks-delivery-kyverno"
  path                 = "/platform/"                   # 예: "/platform/"
  permissions_boundary = var.permissions_boundary_arn   # 예: null

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" } # 예: EKS Pod Identity 서비스 주체만 허용
      Action    = ["sts:AssumeRole", "sts:TagSession"]   # 예: 역할 사용 + 세션 태그 부착
      Condition = {
        StringEquals = {
          "aws:RequestTag/eks-cluster-arn"      = var.cluster_contract.arn # 예: 이 클러스터에서 발급된 세션만
          "aws:RequestTag/kubernetes-namespace" = var.kyverno_namespace    # 예: "kyverno"
        }
        "ForAnyValue:StringEquals" = {
          "aws:RequestTag/kubernetes-service-account" = tolist(local.kyverno_service_accounts) # 예: 두 SA 중 하나
        }
      }
    }]
  })

  depends_on = [terraform_data.contract] # 예: 계약 검사 통과 후 생성
}

resource "aws_iam_role_policy" "kyverno" {
  name = "ecr-read-signatures"   # 예: "ecr-read-signatures"
  role = aws_iam_role.kyverno.id # 예: 위 Role

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"] # 예: 레지스트리 토큰 (리소스 지정 불가 → *)
        Resource = "*"
      },
      {
        Sid    = "EcrRead"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",               # 예: 이미지 · 서명 · attestation manifest 읽기
          "ecr:GetDownloadUrlForLayer",      # 예: attestation 본문(layer) 읽기
          "ecr:BatchCheckLayerAvailability", # 예: layer 존재 확인
          "ecr:DescribeImages",              # 예: digest 조회
        ]
        Resource = [for repository in aws_ecr_repository.app : repository.arn] # 예: 이 모듈의 리포지토리만
      },
      {
        Sid      = "KmsPublicKey"
        Effect   = "Allow"
        Action   = ["kms:GetPublicKey", "kms:DescribeKey"]                                                                                                                                   # 예: 공개 키 조회 (서명 · 복호화 없음)
        Resource = concat([aws_kms_key.signing.arn], var.previous_signing_key_id == null ? [] : ["arn:aws:kms:${var.region}:${var.expected_account_id}:key/${var.previous_signing_key_id}"]) # 예: 현재 키 (+ 회전 중 이전 키)
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "kyverno" {
  for_each = local.kyverno_service_accounts # 예: SA 2개 → 연결 2개

  cluster_name         = var.cluster_contract.name # 예: "contract2whale-dev-eks"
  namespace            = var.kyverno_namespace     # 예: "kyverno"
  service_account      = each.key                  # 예: "kyverno-admission-controller"
  role_arn             = aws_iam_role.kyverno.arn  # 예: 같은 Role
  disable_session_tags = false                     # 예: false

  depends_on = [aws_iam_role_policy.kyverno] # 예: 정책 부착 뒤 연결
}
