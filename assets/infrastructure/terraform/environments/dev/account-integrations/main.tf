# main.tf — account-integrations 루트 모듈 (dev · prod 공통 코드)

module "component" {
  source = "../../../../modules/account-integrations" # 예: 이 루트 모듈에서 모듈까지의 상대 경로 (네 단계 위가 저장소 최상위)

  expected_account_id                  = var.expected_account_id                  # 예: "111111111111" (숫자 12자리 계정 번호)
  region                               = var.region                               # 예: "ap-northeast-2" (서울 리전)
  operations_contract                  = local.operations_contract                # 예: platform/operations State 출력으로 조립한 7항목 object
  network_logs_contract                = local.network_logs_contract              # 예: network/vpc State 출력으로 조립한 { bucket_name, bucket_arn }
  log_bytes_per_five_minutes_threshold = var.log_bytes_per_five_minutes_threshold # 예: 52428800 (기본값, 5분 50 MiB)
  enable_external_log_consumer         = var.enable_external_log_consumer         # 예: false (기본값)
  external_log_consumer                = var.external_log_consumer                # 예: null (기본값)
  notification_email_addresses         = var.notification_email_addresses         # 예: [] (기본값)
}

# 이 디렉터리는 dev 만 받습니다. input 은 State 에 남는 marker 이며 AWS 자원을 만들지 않습니다.
resource "terraform_data" "environment_boundary" {
  input = var.environment # 예: "dev" (input 변경은 in-place 갱신)

  lifecycle {
    precondition {
      condition     = var.environment == "dev" # 예: "dev" 통과 / "prod" 거부 (prod 는 prod/account-integrations 디렉터리 — 운영 환경)
      error_message = "This directory accepts only the dev environment."
    }

    precondition {
      condition     = terraform.workspace == "default" # 예: workspace 로 환경을 나누지 않음 (backend key 로 구분)
      error_message = "Use default workspace and a distinct backend key."
    }
  }
}
