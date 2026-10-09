# main.tf — data 루트 모듈 (dev · prod 공통 코드)
# 최초 적용(데이터 초기화와 Argo CD 배포 최초 적용)에서 키 · Security Group · 서브넷 그룹 · 파라미터 그룹 · 인스턴스 · 앱 시크릿 3 · 내보내기 저장소 · 운영자 저장소를 만듭니다. 데이터베이스 생성 시간은 실제 환경에서 확인합니다.

module "component" {
  source = "../../../../modules/data" # 예: 이 루트 모듈에서 모듈까지의 상대 경로 (네 단계 위가 저장소 최상위)

  expected_account_id = var.expected_account_id                                                         # 예: "111111111111"
  region              = var.region                                                                      # 예: "ap-northeast-2"
  environment         = var.environment                                                                 # 예: "dev" (시크릿 이름 · 내보내기 접두사에 들어감)
  cluster_contract    = local.cluster_contract                                                          # 예: eks State 로 조립한 4항목
  network_contract    = local.network_contract                                                          # 예: network/vpc · eks State 로 조립한 4항목
  database            = var.database                                                                    # 예: 리전 조회로 채운 엔진 버전 · 유형 · 저장 · 백업
  enable_redis        = var.enable_redis                                                                # 예: true (false 면 캐시 · SG · 규칙 3개가 사라짐)
  redis               = var.redis                                                                       # 예: Valkey 주 버전과 저장 · ECPU 상한
  kyverno_role_arn    = data.terraform_remote_state.delivery.outputs.delivery_contract.kyverno.role_arn # 예: 기존 delivery 검증 역할
  application         = local.application                                                               # 예: delivery 계약 + 이 루트 모듈의 ServiceAccount 이름
}

# 이 디렉터리는 dev 만 받습니다. input 은 State 에 남는 marker 이며 AWS 자원을 만들지 않습니다.
resource "terraform_data" "environment_boundary" {
  input = var.environment # 예: "dev" (input 변경은 in-place 갱신)

  lifecycle {
    precondition {
      condition     = var.environment == "dev" # 예: "dev" 통과 / "prod" 거부 (prod 는 prod/data 디렉터리)
      error_message = "This directory accepts only the dev environment."
    }

    precondition {
      condition     = terraform.workspace == "default" # 예: workspace 로 환경을 나누지 않음 (backend key · 버킷으로 구분)
      error_message = "Use default workspace and a distinct backend key."
    }
  }
}
