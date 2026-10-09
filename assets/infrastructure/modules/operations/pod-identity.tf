# pod-identity.tf — modules/operations (dev · prod 루트 모듈이 공유하는 모듈)

resource "aws_iam_role" "controller" {
  for_each = local.identities                                              # 예: 필드 계약 (enabled_services 로 걸러진 controller)
  name     = "${var.cluster_contract.name}-${replace(each.key, "_", "-")}" # 예: "contract2whale-dev-eks-fluent-bit"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" } # 예: EKS Pod Identity 서비스 주체만 허용
      Action    = ["sts:AssumeRole", "sts:TagSession"]   # 예: 역할 사용 + 세션 태그 부착
      Condition = {
        StringEquals = {
          "aws:RequestTag/eks-cluster-arn"            = var.cluster_contract.arn   # 예: 이 클러스터에서 발급된 세션만
          "aws:RequestTag/kubernetes-namespace"       = each.value.namespace       # 예: "logging"
          "aws:RequestTag/kubernetes-service-account" = each.value.service_account # 예: "fluent-bit"
        }
      }
    }]
  })

  depends_on = [terraform_data.contract] # 예: 계약 검사 통과 후 생성
}

resource "aws_iam_role_policy" "controller" {
  for_each = local.identities                                # 예: Role 과 같은 키
  name     = "controller-permissions"                        # 예: Role 마다 같은 이름 (소속 Role 이 달라 충돌 없음)
  role     = aws_iam_role.controller[each.key].id            # 예: 같은 키의 Role
  policy   = jsonencode(local.controller_policies[each.key]) # 예: 해당 controller 의 정책만 선택
}

resource "aws_eks_pod_identity_association" "controller" {
  for_each = local.identities # 예: Role 과 같은 키

  cluster_name         = var.cluster_contract.name             # 예: "contract2whale-dev-eks"
  namespace            = each.value.namespace                  # 예: "external-secrets"
  service_account      = each.value.service_account            # 예: "external-secrets"
  role_arn             = aws_iam_role.controller[each.key].arn # 예: "arn:aws:iam::111111111111:role/contract2whale-dev-eks-external-secrets"
  disable_session_tags = false                                 # 예: false (세션 태그가 있어야 신뢰 정책 조건이 성립)

  # IAM 반영 지연까지 보장하지는 않지만, 정책 부착 이후에 연결하도록 생성 순서를 고정합니다.
  depends_on = [aws_iam_role_policy.controller]
}

locals {
  controller_policies = {
    fluent_bit = {
      Version = "2012-10-17"
      Statement = [{
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"] # 예: 스트림 생성 · 기록 · 조회
        Resource = "${try(aws_cloudwatch_log_group.platform[0].arn, "inactive")}:*"         # 예: 플랫폼 로그 그룹의 스트림만
      }]
    }

    autoscaler = {
      Version = "2012-10-17"
      Statement = [
        {
          Effect = "Allow"
          Action = [
            "autoscaling:SetDesiredCapacity",                  # 예: 희망 대수 변경
            "autoscaling:TerminateInstanceInAutoScalingGroup", # 예: 그룹 안 인스턴스 종료
          ]
          Resource = "*" # 예: 아래 태그 조건으로 대상 ASG 를 좁힘
          Condition = {
            StringEquals = {
              "aws:ResourceTag/k8s.io/cluster-autoscaler/enabled"                      = "true"  # 예: 탐색 태그가 있는 ASG
              "aws:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_contract.name}" = "owned" # 예: 이 클러스터 소유 ASG
            }
          }
        },
        {
          Effect = "Allow"
          Action = [
            "autoscaling:DescribeAutoScalingGroups",
            "autoscaling:DescribeAutoScalingInstances",
            "autoscaling:DescribeLaunchConfigurations",
            "autoscaling:DescribeScalingActivities",
            "autoscaling:DescribeTags",
            "ec2:DescribeImages",
            "ec2:DescribeInstanceTypes",
            "ec2:DescribeLaunchTemplateVersions",
            "ec2:GetInstanceTypesFromInstanceRequirements",
            "eks:DescribeNodegroup",
          ]
          Resource = "*" # 예: 조회 전용 동작
        },
      ]
    }

    external_secrets = {
      Version = "2012-10-17"
      Statement = [{
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetResourcePolicy",
          "secretsmanager:ListSecretVersionIds",
        ]
        Resource = try(aws_secretsmanager_secret.grafana[0].arn, null) # 예: 대시보드 초기 시크릿 1개만
      }]
    }

    velero = {
      Version = "2012-10-17"
      Statement = [
        {
          # EC2 스냅샷 동작은 생성 · 조회 대상을 ARN 으로 좁히기 어려워 "*" 에 리전 조건을 겁니다 (최소 권한 검토 대상).
          Effect = "Allow"
          Action = [
            "ec2:DescribeVolumes",
            "ec2:DescribeSnapshots",
            "ec2:CreateTags",
            "ec2:CreateVolume",
            "ec2:CreateSnapshot",
            "ec2:DeleteSnapshot",
          ]
          Resource  = "*"
          Condition = { StringEquals = { "aws:RequestedRegion" = var.region } } # 예: "ap-northeast-2" 안에서만
        },
        {
          Effect   = "Allow"
          Action   = ["s3:ListBucket"]
          Resource = try(aws_s3_bucket.velero[0].arn, null) # 예: 백업 버킷 자체
        },
        {
          # s3:PutObjectTagging 은 없습니다 — Velero values 의 backupStorageLocation.config.tagging 을 켜면 이 문장도 함께 바꿉니다 (계획서 10장).
          Effect = "Allow"
          Action = [
            "s3:GetObject",
            "s3:DeleteObject",
            "s3:PutObject",
            "s3:AbortMultipartUpload",
            "s3:ListMultipartUploadParts",
          ]
          Resource = "${try(aws_s3_bucket.velero[0].arn, "inactive")}/*" # 예: 백업 버킷 안의 객체만
        },
      ]
    }
  }
}
