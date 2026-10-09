# remote-state.tf — delivery 루트 모듈 (dev · prod 공통 코드)
# 루트 모듈과 적용: 앞 루트 모듈 네 곳(eks · account-baseline · platform/operations · platform/app-auth)의 출력을 State 에서 직접 읽습니다 (P1). 값을 옮겨 적는 입력 파일을 만들지 않습니다.
# 읽는 쪽에는 네 State 객체의 s3:GetObject 권한이 필요합니다 (관련 구성 의 State 역할 key 목록과 대조). 관측 State 는 읽지 않습니다 — 릴리스 판정(Argo Rollouts AnalysisTemplate)이 쓰는 Prometheus 주소는 gitops/ 의 고정값입니다.

data "terraform_remote_state" "eks" {
  backend = "s3" # 예: "s3" (앞 루트 모듈이 State 를 둔 방식)

  config = {
    bucket = var.state_bucket_name   # 예: "company-dev-tfstate-111111111111"
    key    = "eks/terraform.tfstate" # 예: eks 루트 모듈의 key (클러스터 입력과 네트워크 계약)
    region = var.region              # 예: "ap-northeast-2"
  }

  lifecycle {
    postcondition {
      condition = alltrue([
        for name in ["name", "arn", "region"] :
        contains(keys(try(self.outputs.cluster_contract, {})), name) # 예: 3개 모두 cluster_contract 에 존재
      ])
      error_message = "eks state must expose cluster_contract with name, arn and region (apply 생성 계획과 private API 검증 and 노드와 Add-on first)."
    }
  }
}

# Dev GitHub OIDC 연결과 Prod 코드 배치 의 계정 기준선 루트 모듈입니다. 계정당 하나인 GitHub OIDC provider 의 ARN 을 읽어 CI Role 의 신뢰 정책에 넣습니다.
data "terraform_remote_state" "account_baseline" {
  backend = "s3" # 예: "s3"

  config = {
    bucket = var.state_bucket_name                # 예: 같은 버킷
    key    = "account-baseline/terraform.tfstate" # 예: account-baseline 루트 모듈의 key (두 계정 baseline 의 입력과 실행 계약)
    region = var.region                           # 예: "ap-northeast-2"
  }

  lifecycle {
    postcondition {
      condition     = can(regex("^arn:aws:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", try(self.outputs.github_oidc_provider_arn, ""))) # 예: GitHub provider ARN 형식
      error_message = "account-baseline state must expose github_oidc_provider_arn (apply Dev GitHub OIDC 연결과 Prod 코드 배치 with create_github_oidc or existing_github_oidc_provider_arn first)."
    }
  }
}

# 운영 도구 의 운영 기반 루트 모듈입니다. 클러스터 전체 External Secrets controller 의 Role ARN 을 읽어 delivery 의 비밀 읽기 Role 이 신뢰할 주체로 넣습니다 (assume-role chaining).
data "terraform_remote_state" "operations" {
  backend = "s3" # 예: "s3"

  config = {
    bucket = var.state_bucket_name                   # 예: 같은 버킷
    key    = "platform/operations/terraform.tfstate" # 예: operations 루트 모듈의 key (운영 기반 루트 모듈과 계약)
    region = var.region                              # 예: "ap-northeast-2"
  }

  lifecycle {
    postcondition {
      condition     = can(regex("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9_+=,.@/-]+$", try(self.outputs.external_secrets_role_arn, ""))) # 예: IAM Role ARN 형식
      error_message = "operations state must expose external_secrets_role_arn (apply 운영 도구 with external_secrets enabled first)."
    }
  }
}

# 팀 로그인과 API 인가 의 앱 인증 루트 모듈입니다. Cognito user pool 의 issuer 를 읽어 Argo CD SSO 클라이언트를 같은 pool 에 만듭니다.
data "terraform_remote_state" "app_auth" {
  backend = "s3" # 예: "s3"

  config = {
    bucket = var.state_bucket_name                 # 예: 같은 버킷
    key    = "platform/app-auth/terraform.tfstate" # 예: app-auth 루트 모듈의 key (팀 로그인과 API 인가)
    region = var.region                            # 예: "ap-northeast-2"
  }

  lifecycle {
    postcondition {
      condition     = can(regex("^https://cognito-idp\\.[a-z0-9-]+\\.amazonaws\\.com/[a-z]{2}-[a-z]+-[0-9]_[A-Za-z0-9]+$", try(self.outputs.ui_auth.issuer, ""))) # 예: issuer URL 형식
      error_message = "app-auth state must expose ui_auth.issuer (apply 팀 로그인과 API 인가 first)."
    }
  }
}
