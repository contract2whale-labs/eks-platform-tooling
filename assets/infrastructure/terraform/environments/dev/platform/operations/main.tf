# main.tf — platform/operations 루트 모듈 (dev · prod 공통 코드)

module "component" {
  source = "../../../../../modules/operations" # 예: 이 루트 모듈에서 모듈까지의 상대 경로 (다섯 단계 위가 저장소 최상위)

  enabled_services                   = var.enabled_services                     # 예: 네 도구 모두 (루트 모듈 기본값)
  expected_account_id                = var.expected_account_id                  # 예: "111111111111" (숫자 12자리 계정 번호)
  region                             = var.region                               # 예: "ap-northeast-2" (서울 리전)
  cluster_contract                   = local.cluster_contract                   # 예: eks State 출력으로 조립한 {name, arn, region, kubernetes_version}
  node_group_autoscaling_group_names = local.node_group_autoscaling_group_names # 예: eks State 의 node_contract.autoscaling_group_names (실제 ASG 이름 집합)
  application_log_retention_days     = var.application_log_retention_days       # 예: 90 (허용 목록에 있는 보존 기간)
  alerts_topic_arn                   = local.alerts_topic_arn                   # 예: null (첫 적용) 또는 검토한 alerts_topic_arn 입력
}

# 이 디렉터리는 dev 만 받습니다. input 은 State 에 남는 marker 이며 AWS 자원을 만들지 않습니다.
resource "terraform_data" "environment_boundary" {
  input = var.environment # 예: "dev" (input 변경은 in-place 갱신)

  lifecycle {
    precondition {
      condition     = var.environment == "dev" # 예: "dev" 통과 / "prod" 거부 (prod 는 prod/platform/operations 디렉터리 — 운영 환경)
      error_message = "This directory accepts only the dev environment."
    }

    precondition {
      condition     = terraform.workspace == "default" # 예: workspace 로 환경을 나누지 않음 (backend key 로 구분)
      error_message = "Use default workspace and a distinct backend key."
    }
  }
}
