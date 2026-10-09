# remote-state.tf — account-baseline 루트 모듈 (dev · prod 공통 코드)
# 앞 루트 모듈(bootstrap/state)의 root 출력을 State 에서 직접 읽습니다. 출력을 복사한 입력 파일을 만들지 않습니다.
# 버킷 이름은 backend.hcl 과 같은 값이라 변수로 받고, 읽은 출력의 버킷 이름 · 계정 ID 가 입력과 같은지 대조합니다.

data "terraform_remote_state" "bootstrap" {
  backend = "s3" # 예: "s3" (bootstrap/state 가 state 에서 State 를 이관한 backend)

  config = {
    bucket = var.state_bucket_name               # 예: "company-dev-tfstate-111111111111" (backend.hcl 의 bucket 과 같은 값)
    key    = "bootstrap/state/terraform.tfstate" # 예: bootstrap/state 루트 모듈의 backend.hcl key (실행 디렉터리 경로 규칙)
    region = var.region                          # 예: "ap-northeast-2" (버킷이 있는 리전)
  }

  lifecycle {
    # 읽은 State 가 이 루트 모듈과 같은 버킷 · 같은 계정의 bootstrap 인지 plan 단계에서 확인합니다.
    postcondition {
      condition     = self.outputs.state_bucket_name == var.state_bucket_name # 예: "company-dev-tfstate-111111111111" 양쪽 일치
      error_message = "bootstrap/state output state_bucket_name must equal var.state_bucket_name (the backend bucket)."
    }

    postcondition {
      condition     = self.outputs.expected_account_id == var.expected_account_id # 예: "111111111111" 양쪽 일치
      error_message = "bootstrap/state output expected_account_id must equal var.expected_account_id."
    }
  }
}
