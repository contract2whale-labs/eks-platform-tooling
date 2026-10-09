# locals.tf — account-baseline 루트 모듈 (dev · prod 공통 코드)
# State 역할 정책이 참조할 버킷 · State 객체 · 잠금 객체 ARN 을 한 곳에서 계산합니다.

locals {
  # 이 구성 · 공개 DNS 구성 · 네트워크 구성의 확정 key 만 기본 허용하며, 후속 구성은 명시적으로 추가합니다.
  # 기본 실행 결과는 정렬된 문자열 3개 리스트입니다.
  state_object_keys = sort(tolist(setunion(
    toset([
      "account-baseline/terraform.tfstate",     # 예: 이 구성 자신의 State 경로
      "account-baseline-dns/terraform.tfstate", # 예: 공개 자식 Zone 구성(보존 루트 모듈)의 State 경로
      "network/vpc/terraform.tfstate",          # 예: 네트워크 구성의 State 경로
    ]),
    var.additional_state_object_keys # 예: ["network/extensions/terraform.tfstate"] (기본은 빈 집합)
  )))

  state_bucket_arn = data.terraform_remote_state.bootstrap.outputs.state_bucket_arn # 예: "arn:aws:s3:::company-dev-tfstate-111111111111" (state 출력을 그대로 사용)

  state_object_arns = [
    for key in local.state_object_keys : "${local.state_bucket_arn}/${key}" # 예: "arn:aws:s3:::company-dev-tfstate-111111111111/network/vpc/terraform.tfstate"
  ]

  lock_object_arns = [
    for arn in local.state_object_arns : "${arn}.tflock" # 예: "arn:aws:s3:::company-dev-tfstate-111111111111/network/vpc/terraform.tfstate.tflock"
  ]
}
