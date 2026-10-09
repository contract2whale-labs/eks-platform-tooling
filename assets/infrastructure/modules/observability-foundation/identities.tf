# identities.tf — modules/observability-foundation (dev · prod 루트 모듈이 공유하는 모듈)

locals {
  storage_role_arns = {
    writer      = aws_iam_role.observability_writer.arn      # 예: "arn:aws:iam::111111111111:role/platform/cp-dev-observability-writer"
    reader      = aws_iam_role.observability_reader.arn      # 예: "arn:aws:iam::111111111111:role/platform/cp-dev-observability-reader"
    maintenance = aws_iam_role.observability_maintenance.arn # 예: "arn:aws:iam::111111111111:role/platform/cp-dev-observability-maintenance"
  }
}

resource "aws_eks_pod_identity_association" "signal" {
  for_each = var.pod_identities # 예: 신원 9개

  cluster_name         = var.cluster_contract.name                # 예: "contract2whale-dev-eks"
  namespace            = each.value.namespace                     # 예: "monitoring" (이 시점에 없어도 연결은 만들어집니다)
  service_account      = each.value.service_account               # 예: "platform-thanos-store" (뒤따르는 주제가 만듭니다)
  role_arn             = local.storage_role_arns[each.value.role] # 예: 읽기 역할의 ARN
  disable_session_tags = false                                    # 예: false (세션 태그를 붙여 신뢰 정책의 eks-cluster-arn 조건이 성립하게 합니다)

  depends_on = [
    aws_iam_role_policy_attachment.observability_writer,      # 예: 정책 부착 이후 연결 생성; IAM 전파와 실제 Pod 권한은 별도 확인
    aws_iam_role_policy_attachment.observability_reader,      # 예: 같은 이유
    aws_iam_role_policy_attachment.observability_maintenance, # 예: 같은 이유
  ]
}
