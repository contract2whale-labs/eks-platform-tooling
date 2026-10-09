# kms.tf — modules/queue-managed (dev · prod 루트 모듈이 공유하는 모듈)
# 고객 관리 키와 시크릿, 클러스터: 사용자 시크릿을 암호화할 고객 관리 키입니다. 기본 키(aws/secretsmanager)로 만든 시크릿은 관리형 큐에 연결되지 않으므로 이 키가 반드시 필요합니다.
# 같은 키가 브로커 저장 용량(EBS)의 암호화에도 쓰입니다 — 그래서 키 정책에 kafka.amazonaws.com 항목이 있습니다.

locals {
  cluster_name = "cp-${var.environment}-traces-queue" # 예: "cp-dev-traces-queue" (이 구성이 만드는 클러스터 이름)
}

data "aws_iam_policy_document" "queue_secrets_key" {
  # 이 계정의 IAM 정책이 키에 적용될 수 있게 하는 항목입니다. IAM Allow 위임을 열며 다른 직접 허용은 별개입니다.
  statement {
    sid       = "EnableAccountPermissions" # 예: 항목 이름 (정책 안에서 유일해야 함)
    effect    = "Allow"                    # 예: "Allow" (허용 항목)
    actions   = ["kms:*"]                  # 예: ["kms:*"] (계정 안의 IAM 정책이 범위를 다시 좁힘)
    resources = ["*"]                      # 예: ["*"] (키 정책의 대상은 그 키 자신)

    principals {
      type        = "AWS"                                            # 예: "AWS" (계정 주체)
      identifiers = ["arn:aws:iam::${var.expected_account_id}:root"] # 예: 이 계정 하나만
    }
  }

  # 시크릿 저장소를 거친 호출에만 키 사용을 허용합니다.
  statement {
    sid    = "AllowUseThroughSecretsManager" # 예: 항목 이름
    effect = "Allow"
    # 예: 시크릿을 넣고 읽고 다시 암호화할 때 필요한 동작들
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.expected_account_id}:root"]
    }

    condition {
      test     = "StringEquals"                                 # 예: 값이 정확히 같아야 함
      variable = "kms:ViaService"                               # 예: 어느 서비스를 거쳐 온 호출인지 보는 조건 키
      values   = ["secretsmanager.${var.region}.amazonaws.com"] # 예: 시크릿 저장소를 거친 호출만 허용
    }
  }

  # 브로커의 저장 용량을 암호화할 때 관리형 큐 서비스가 이 키를 쓸 수 있게 합니다.
  statement {
    sid    = "AllowManagedQueueServiceForStorage" # 예: 항목 이름
    effect = "Allow"
    # 예: 저장 용량을 암호화하고 읽을 때 서비스가 부르는 동작들
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey", "kms:CreateGrant"]
    resources = ["*"]

    principals {
      type        = "Service"               # 예: "Service" (서비스 주체)
      identifiers = ["kafka.amazonaws.com"] # 예: 관리형 큐 서비스 하나만
    }
  }
}

resource "aws_kms_key" "queue_secrets" {
  description             = "Customer managed key for the managed trace queue"  # 예: 콘솔 목록에서 용도를 구분하는 설명
  enable_key_rotation     = true                                                # 예: true (해마다 키 재료를 바꿈)
  deletion_window_in_days = 7                                                   # 예: 7 (실습 삭제 기본값; 최솟값 7 — 원본 30)
  policy                  = data.aws_iam_policy_document.queue_secrets_key.json # 예: 위에서 만든 세 항목짜리 키 정책

  tags = {
    Name = "${local.cluster_name}-key" # 예: "cp-dev-traces-queue-key"
  }
}

resource "aws_kms_alias" "queue_secrets" {
  name          = "alias/${local.cluster_name}-key" # 예: "alias/cp-dev-traces-queue-key" (사람이 읽는 이름)
  target_key_id = aws_kms_key.queue_secrets.key_id  # 예: 위 키의 식별자
}
