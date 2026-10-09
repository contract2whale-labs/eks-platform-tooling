# locals.tf — delivery 루트 모듈 (dev · prod 공통 코드)
# 루트 모듈과 적용: State 에서 읽은 출력을 모듈 입력의 모양으로 조립합니다. 어느 값도 이 루트 모듈이 직접 입력받지 않습니다 (P1 — 옮겨 적는 파일 없음).

locals {
  cluster_contract = {
    name   = data.terraform_remote_state.eks.outputs.cluster_contract.name   # 예: "contract2whale-dev-eks"
    arn    = data.terraform_remote_state.eks.outputs.cluster_contract.arn    # 예: "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
    region = data.terraform_remote_state.eks.outputs.cluster_contract.region # 예: "ap-northeast-2"
  }

  github_oidc_provider_arn  = data.terraform_remote_state.account_baseline.outputs.github_oidc_provider_arn # 예: "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com" (CI Role 신뢰 정책)
  external_secrets_role_arn = data.terraform_remote_state.operations.outputs.external_secrets_role_arn      # 예: "arn:aws:iam::111111111111:role/contract2whale-dev-eks-external-secrets" (delivery 비밀 Role 이 신뢰할 주체)
  cognito_issuer            = data.terraform_remote_state.app_auth.outputs.ui_auth.issuer                   # 예: "https://cognito-idp.ap-northeast-2.amazonaws.com/ap-northeast-2_AbCdEfGhI" (Argo CD SSO)
}
