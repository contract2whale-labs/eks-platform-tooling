# main.tf — platform/observability 루트 모듈 (dev · prod 공통 코드)
# 적용 결과(dev): 역할 3 · 정책 3 · 연결 3 · 저장소 3 · 보호 18 · Pod Identity 9 · 엔드포인트 정책 1 · 계약 검사 2 = 42 리소스 (mock plan 실측은 사양 참고).

module "component" {
  source = "../../../../../modules/observability-foundation" # 예: 이 루트 모듈에서 모듈까지의 상대 경로 (다섯 단계 위가 저장소 최상위)

  expected_account_id      = var.expected_account_id # 예: "111111111111"
  region                   = var.region              # 예: "ap-northeast-2"
  environment              = var.environment         # 예: "dev"
  cluster_contract         = local.cluster_contract  # 예: eks State 출력으로 조립한 {name, arn, region, kubernetes_version}
  trusted_principal_arns   = var.trusted_principal_arns
  permissions_boundary_arn = var.permissions_boundary_arn # 예: null
  allowed_state_keys       = local.allowed_state_keys
  operations_contract      = local.operations_contract # 예: platform/operations State 의 계약 7항목
  signal_retention_days    = var.signal_retention_days # 예: { metrics = 400, logs = 90, traces = 40 }
  vpc_id                   = local.vpc_id
  network_logs_bucket_name = local.network_logs_bucket_name
  active_trace_backend     = var.active_trace_backend    # 예: "self-managed"
  storage_epoch            = var.storage_epoch           # 예: 1
  policy_version           = var.policy_version          # 예: 1
  additional_bucket_names  = var.additional_bucket_names # 예: [] (애플리케이션 데이터 · 운영 환경 가 미디어 버킷을 더함)
}

# 이 디렉터리는 dev 만 받습니다. input 은 State 에 남는 marker 이며 AWS 자원을 만들지 않습니다.
resource "terraform_data" "environment_boundary" {
  input = var.environment # 예: "dev"

  lifecycle {
    precondition {
      condition     = var.environment == "dev" # 예: "dev" 통과 / "prod" 거부 (prod 는 prod/platform/observability 디렉터리 — 운영 환경)
      error_message = "This directory accepts only the dev environment."
    }

    precondition {
      condition     = terraform.workspace == "default" # 예: workspace 로 환경을 나누지 않음 (backend key 로 구분)
      error_message = "Use default workspace and a distinct backend key."
    }
  }
}
