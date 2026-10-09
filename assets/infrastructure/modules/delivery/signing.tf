# signing.tf — modules/delivery (dev · prod 루트 모듈이 공유하는 모듈)
# 이미지 리포지토리와 서명 키: cosign 이 쓰는 비대칭 서명 키(ECC_NIST_P256 · SIGN_VERIFY) 와 alias, 검증 쪽이 쓰는 공개 키 조회입니다.
# 키 정책은 계정 root 에게만 kms:* 를 주어 IAM 정책을 유효하게 합니다(AWS 기본 방식). CI Role 의 kms:Sign · kms:GetPublicKey 는 ci-identity.tf 의 IAM 정책이 좁혀 줍니다.
# 로컬 cosign verify --key signing-public.pem 은 저장한 공개 키를 씁니다. Kyverno keys.kms 는 alias 의 공개 키를 읽기 위해 kms:GetPublicKey 를 호출합니다. 비대칭 키는 자동 회전을 지원하지 않습니다 (enable_key_rotation 미선언).

resource "aws_kms_key" "signing" {
  description              = "cosign image signing key for ${var.cluster_contract.name} (${var.environment})" # 예: "cosign image signing key for contract2whale-dev-eks (dev)"
  key_usage                = "SIGN_VERIFY"                                                                    # 예: "SIGN_VERIFY" (암호화 키가 아니라 서명 키)
  customer_master_key_spec = "ECC_NIST_P256"                                                                  # 예: "ECC_NIST_P256" (cosign 기본 ECDSA P-256 · SHA-256)
  deletion_window_in_days  = 7                                                                                # 예: 7 (삭제 예약 후 대기 최소값; 실습 삭제 시 7일 PendingDeletion)
  multi_region             = false                                                                            # 예: false (리전 고정)

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "EnableIamPolicies"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${var.expected_account_id}:root" } # 예: 계정 root 위임 → IAM 정책(CI Role)이 유효
      Action    = "kms:*"
      Resource  = "*"
    }]
  })

  tags = {
    Name = "${local.name_prefix}-signing" # 예: "contract2whale-dev-eks-delivery-signing"
  }

  depends_on = [terraform_data.contract] # 예: 계약 검사 통과 후 생성
}

# cosign 과 Kyverno 는 alias 로 키를 가리킵니다 (awskms:///alias/delivery-signing). alias 이름에 환경 · 클러스터를 넣지 않으므로 Kyverno 정책 · CI 워크플로가 dev · prod 에서 같은 문자열을 씁니다 (계정이 다르면 alias 가 달라도 충돌 없음).
resource "aws_kms_alias" "signing" {
  name          = "alias/delivery-signing"   # 예: "alias/delivery-signing" (Kyverno keys.kms · cosign --key 가 참조)
  target_key_id = aws_kms_key.signing.key_id # 예: 위 키의 ID
}

resource "aws_kms_alias" "signing_previous" {
  count = var.previous_signing_key_id == null ? 0 : 1 # 예: 0 (평상시) · 1 (회전 중)

  name          = "alias/delivery-signing-previous" # 예: "alias/delivery-signing-previous"
  target_key_id = var.previous_signing_key_id       # 예: 이전 키의 ID
}

# 공개 키 PEM 은 로컬 cosign verify --key 의 입력이자 증적입니다 (비밀 아님). Kyverno 는 PEM 을 정책에 넣지 않고 keys.kms 로 alias 를 참조해 kms:GetPublicKey 로 읽습니다.
data "aws_kms_public_key" "signing" {
  key_id = aws_kms_key.signing.arn # 예: 키 ARN (apply 뒤 조회)
}
