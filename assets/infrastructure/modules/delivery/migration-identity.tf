# migration-identity.tf — modules/delivery (dev · prod 루트 모듈이 공유하는 모듈)
# 권한과 승인 제어: 스키마 변경(마이그레이션) Job 의 Pod Identity Role 입니다. 이 파일은 Role 과 신뢰 정책만 만듭니다.
# 데이터 권한(인라인 정책 migration-secret)과 Pod Identity 연결은 애플리케이션 데이터 tenant-pod-identity 가 더합니다 — 비밀 ARN 과 ServiceAccount 가 애플리케이션 데이터 에서 생기기 때문입니다.
# 애플리케이션 데이터 identity 루트는 이 Role 을 이름(<cluster>-delivery-migration)으로 조회하고 경로 /platform/ 와 신뢰 주체 pods.eks.amazonaws.com 을 확인합니다.

resource "aws_iam_role" "migration" {
  name                 = "${local.name_prefix}-migration" # 예: "contract2whale-dev-eks-delivery-migration"
  path                 = "/platform/"                     # 예: "/platform/" (애플리케이션 데이터 identity 루트의 조회 조건)
  permissions_boundary = var.permissions_boundary_arn     # 예: null

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" } # 예: EKS Pod Identity 서비스 주체만 허용
      Action    = ["sts:AssumeRole", "sts:TagSession"]   # 예: 역할 사용 + 세션 태그 부착
      Condition = {
        StringEquals = {
          "aws:RequestTag/eks-cluster-arn"            = var.cluster_contract.arn                                # 예: 이 클러스터에서 발급된 세션만
          "aws:RequestTag/kubernetes-namespace"       = var.application_namespace                               # 예: "contract2whale-demo"
          "aws:RequestTag/kubernetes-service-account" = var.application_workloads.api.migration_service_account # 예: "delivery-migration"
        }
      }
    }]
  })

  depends_on = [terraform_data.contract] # 예: 계약 검사 통과 후 생성
}
