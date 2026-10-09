# outputs.tf — modules/operations (dev · prod 루트 모듈이 공유하는 모듈)
# 계약 필드 하나(alerts_topic_arn)에만 쓰이는 입력을 같은 파일에 선언합니다 (원본 배치 유지). 경보 토픽는 알림 루트 모듈(알림 루트 모듈과 설치 검사)이 만들고 이 계약은 그 ARN 을 실어 나르기만 합니다.

variable "alerts_topic_arn" {
  description = "알림 구성이 만든 경보 토픽의 ARN 입니다. 토픽을 만들기 전에는 null 입니다."
  type        = string # 예: string (ARN 을 문자열로 받습니다)
  default     = null   # 예: null (경보 토픽를 아직 만들지 않은 상태; 루트 모듈은 검토한 공개 입력으로 전달)

  validation {
    # 예: null 통과, "arn:aws:sns:ap-northeast-2:111111111111:contract2whale-dev-alerts" 통과, "contract2whale-dev-alerts" 거부
    condition     = var.alerts_topic_arn == null ? true : can(regex("^arn:aws:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$", var.alerts_topic_arn))
    error_message = "경보 토픽 ARN 형식이 필요합니다."
  }
}

output "operations_contract" {
  description = "Account, cluster, region, log group, backup bucket and alerts topic that native platform configuration and later roots (관측 파이프라인 · 계정 통합 · 운영 환경) read; no secret values."
  value = {
    account_id              = var.expected_account_id                              # 예: "111111111111"
    cluster_name            = var.cluster_contract.name                            # 예: "contract2whale-dev-eks" (앞 클러스터 계약의 name)
    region                  = var.region                                           # 예: "ap-northeast-2"
    platform_log_group_name = try(aws_cloudwatch_log_group.platform[0].name, null) # 예: "/platform/contract2whale-dev-eks/application" (fluent_bit 을 끄면 null)
    velero_bucket_name      = try(aws_s3_bucket.velero[0].id, null)                # 예: "velero-contract2whale-dev-eks-111111111111-ap-northeast-2" (velero 를 끄면 null)
    velero_bucket_arn       = try(aws_s3_bucket.velero[0].arn, null)               # 예: "arn:aws:s3:::velero-contract2whale-dev-eks-111111111111-ap-northeast-2"
    alerts_topic_arn        = var.alerts_topic_arn                                 # 예: "arn:aws:sns:ap-northeast-2:111111111111:contract2whale-dev-alerts" 또는 null (첫 적용)
  }
}

output "grafana_secret_name" {
  description = "Secrets Manager secret name that External Secrets syncs into monitoring/grafana-admin; null when external_secrets is disabled."
  value       = try(aws_secretsmanager_secret.grafana[0].name, null) # 예: "contract2whale-dev-eks/platform/grafana-admin"
}

# 배포 플랫폼이 assume-role chaining 으로 쓰는 값입니다: 클러스터 전체 External Secrets controller 의 Role. delivery 의 시크릿 읽기 Role 이 이 Role 만 신뢰합니다 (SecretStore spec.provider.aws.role).
output "external_secrets_role_arn" {
  description = "IAM role of the cluster-wide External Secrets controller; downstream SecretStores chain to their own read-only roles from it (null when external_secrets is disabled)."
  value       = try(aws_iam_role.controller["external_secrets"].arn, null) # 예: "arn:aws:iam::111111111111:role/contract2whale-dev-eks-external-secrets"
}
