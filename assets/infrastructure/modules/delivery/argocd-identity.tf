# argocd-identity.tf — modules/delivery (dev · prod 루트 모듈이 공유하는 모듈)

resource "aws_secretsmanager_secret" "argocd_repo" {
  name                    = "delivery/argocd-repo-key"                                                                                     # 예: "delivery/argocd-repo-key" (계정마다 하나 — 환경 · 클러스터 이름을 넣지 않아 gitops 매니페스트가 환경 무관)
  description             = "Argo CD read-only deploy key for ${var.gitops_repository}; JSON {sshPrivateKey}; value set outside Terraform" # 예: 용도 · 형식 · 값의 출처
  recovery_window_in_days = 0                                                                                                              # 예: 0 (destroy 즉시 삭제 — 실습 재생성 허용)

  lifecycle {
    prevent_destroy = false # 예: false (실습 삭제 허용)
  }

  depends_on = [terraform_data.contract] # 예: 계약 검사 통과 후 생성
}

resource "aws_secretsmanager_secret" "argocd_oidc" {
  name                    = "delivery/argocd-oidc-client"                                               # 예: "delivery/argocd-oidc-client"
  description             = "Argo CD OIDC client secret (Cognito app client argocd-${var.environment})" # 예: 용도
  recovery_window_in_days = 0                                                                           # 예: 0

  lifecycle {
    prevent_destroy = false # 예: false
  }

  depends_on = [terraform_data.contract] # 예: 계약 검사 통과 후 생성
}



# 운영 도구 의 External Secrets controller Role 만 이 Role 을 맡을 수 있습니다. Pod Identity 세션 태그가 주체 태그(aws:PrincipalTag)로 전달되므로 controller 의 네임스페이스 · ServiceAccount 까지 조건으로 겁니다.
resource "aws_iam_role" "argocd_secrets" {
  name                 = "${local.name_prefix}-argocd-secrets" # 예: "contract2whale-dev-eks-delivery-argocd-secrets" (SecretStore spec.provider.aws.role)
  path                 = "/platform/"                          # 예: "/platform/"
  permissions_boundary = var.permissions_boundary_arn          # 예: null

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "ExternalSecretsControllerChaining"
      Effect    = "Allow"
      Principal = { AWS = var.external_secrets_role_arn } # 예: 운영 도구 controller Role (platform/operations 루트 모듈 출력 external_secrets_role_arn)
      Action    = ["sts:AssumeRole", "sts:TagSession"]    # 예: 역할 사용 + 세션 태그 전달
      Condition = {
        StringEquals = {
          "aws:PrincipalTag/kubernetes-namespace"       = "external-secrets" # 예: controller 가 도는 네임스페이스 (운영 도구)
          "aws:PrincipalTag/kubernetes-service-account" = "external-secrets" # 예: controller ServiceAccount (운영 도구 values serviceAccount.name)
        }
      }
    }]
  })

  depends_on = [terraform_data.contract] # 예: 계약 검사 통과 후 생성
}

resource "aws_iam_role_policy" "argocd_secrets" {
  name = "read-argocd-secrets"          # 예: "read-argocd-secrets"
  role = aws_iam_role.argocd_secrets.id # 예: 위 Role

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadDeliverySecrets"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]                     # 예: 읽기 2동작 (운영 도구 ESO 정책보다 좁음)
      Resource = [aws_secretsmanager_secret.argocd_repo.arn, aws_secretsmanager_secret.argocd_oidc.arn] # 예: deploy key · OIDC 시크릿 2개만
    }]
  })
}
