# tests/edge.tftest.hcl — modules/edge (dev · prod 루트 모듈이 공유하는 모듈)
# provider 두 개(aws · aws.global)를 모두 mock 으로 둡니다. 아래 ARN · ID 는 형식만 맞춘 fixture 입니다.

mock_provider "aws" {}

mock_provider "aws" {
  alias = "global" # 예: ACM 과 WAF 를 만드는 us-east-1 provider 도 mock
}

variables {
  expected_account_id = "111111111111" # 예: 12자리 계정 번호
  gateway_contract = {
    cluster_name          = "contract2whale-dev-eks" # 예: 앞 루트 모듈 출력의 클러스터 이름
    vpc_id                = "vpc-0123456789abcdef0"  # 예: 원본 NLB 가 있는 VPC
    exposure_mode         = "waf"                    # 예: edge 를 켤 수 있는 유일한 모드
    nlb_security_group_id = "sg-0123456789abcdef0"   # 예: NLB 에 붙은 Security Group
    public_zone_id        = "ZPUBLIC"                # 예: 앱 레코드를 만들 공개 zone
    dns_zone_name         = "dev.playdevops.click"   # 예: 위임된 zone 이름
  }
  nlb_arn          = "arn:aws:elasticloadbalancing:ap-northeast-2:111111111111:loadbalancer/net/gateway/1111111111113456" # 예: 조회로 확인한 실제 NLB ARN 형식
  hostnames        = ["dev.playdevops.click"]                                                                             # 예: 공개할 FQDN 목록
  origin_tls_ready = true                                                                                                 # 예: 원본 인증서를 실제로 확인했다는 선언
}

override_data {
  target = data.aws_lb.origin
  values = {
    internal           = true                                                                                                 # 예: 내부 NLB 여야 함
    load_balancer_type = "network"                                                                                            # 예: NLB 여야 함
    vpc_id             = "vpc-0123456789abcdef0"                                                                              # 예: 계약의 vpc_id 와 같은 값
    security_groups    = ["sg-0123456789abcdef0"]                                                                             # 예: 계약의 Security Group 포함
    dns_name           = "internal-gateway.elb.ap-northeast-2.amazonaws.com"                                                  # 예: 원본으로 쓸 NLB 주소 형식
    arn                = "arn:aws:elasticloadbalancing:ap-northeast-2:111111111111:loadbalancer/net/gateway/1111111111113456" # 예: 위 nlb_arn 과 같은 값
  }
}

override_data {
  target = data.aws_lb_listener.https_tcp
  values = { protocol = "TCP" } # 예: TLS 종료는 Envoy 가 함
}

# for_each 의 ACM 검증 레코드 키를 mock 에서도 확정합니다.
override_resource {
  target = aws_acm_certificate.viewer
  values = {
    domain_validation_options = [{ domain_name = "dev.playdevops.click", resource_record_name = "_acm.dev.playdevops.click", resource_record_type = "CNAME", resource_record_value = "_validation.acm-validations.aws." }] # 예: 검증 레코드 한 벌
  }
}

# 1. 기본값(enabled = false)은 공개 자원을 하나도 만들지 않고 출력이 null 입니다.
run "disabled_creates_nothing" {
  command = plan

  variables {
    enabled          = false # 예: 기본값 그대로
    hostnames        = []    # 예: 비활성 기본값
    origin_tls_ready = false # 예: 비활성 기본값
    nlb_arn          = ""    # 예: 비활성 기본값
  }

  assert {
    condition     = length(aws_cloudfront_distribution.app) == 0 && length(aws_wafv2_web_acl.edge) == 0 && length(aws_acm_certificate.viewer) == 0 && length(terraform_data.contract) == 0
    error_message = "Default edge mode must not provision public resources."
  }

  assert {
    condition     = output.edge_contract == null
    error_message = "edge_contract must be null while disabled."
  }
}

run "enabled_has_waf_no_cache_and_https_origin" {
  command = plan

  variables {
    enabled = true # 예: edge 를 켠 상태로 계획
  }

  assert {
    condition     = aws_cloudfront_cache_policy.disabled[0].max_ttl == 0 && aws_cloudfront_vpc_origin.gateway[0].vpc_origin_endpoint_config[0].origin_protocol_policy == "https-only"
    error_message = "Private origin must use TLS; authenticated responses must not be shared-cached."
  }

  assert {
    condition     = length(aws_wafv2_web_acl.edge[0].rule) == 4 && aws_cloudfront_origin_request_policy.viewer[0].headers_config[0].header_behavior == "allViewer" && length(aws_route53_record.app_ipv4) == 1 && length(aws_route53_record.app_ipv6) == 1
    error_message = "WAF, preserved viewer Host and DNS alias must exist."
  }

  assert {
    condition     = aws_acm_certificate.viewer[0].domain_name == "dev.playdevops.click" && length(aws_route53_record.validation) == 1
    error_message = "The viewer certificate must cover the hostnames with one validation record each."
  }
}

# 3. internet-facing 원본은 거부합니다.
run "reject_internet_facing_origin" {
  command = plan

  variables {
    enabled = true # 예: 켠 상태에서 잘못된 원본을 넣음
  }

  override_data {
    target = data.aws_lb.origin
    values = {
      internal           = false                    # 예: 인터넷에 노출된 원본이므로 거부되어야 함
      load_balancer_type = "network"                # 예: 종류는 그대로
      vpc_id             = "vpc-0123456789abcdef0"  # 예: 계약의 vpc_id 와 같은 값
      security_groups    = ["sg-0123456789abcdef0"] # 예: 계약의 Security Group
    }
  }

  expect_failures = [terraform_data.contract]
}

# 4. NLB 가 TLS 를 끝내는 listener 는 거부합니다.
run "reject_nlb_tls_listener" {
  command = plan

  variables {
    enabled = true # 예: 켠 상태에서 listener 규약만 바꿈
  }

  override_data {
    target = data.aws_lb_listener.https_tcp
    values = { protocol = "TLS" } # 예: NLB 가 TLS 를 끝내면 거부되어야 함
  }

  expect_failures = [terraform_data.contract]
}

# 5. 원본 인증서 확인 선언이 없으면 거부합니다.
run "reject_unready_origin_certificate" {
  command = plan

  variables {
    enabled          = true  # 예: 켠 상태
    origin_tls_ready = false # 예: 원본 인증서를 아직 확인하지 않았다는 뜻
  }

  expect_failures = [terraform_data.contract]
}

# 6. internal 모드의 Gateway 위에서는 켤 수 없습니다 (Dev 에서 CloudFront 를 켜는 실수 방지; waf 모드만 허용).
run "reject_internal_gateway_mode" {
  command = plan

  variables {
    enabled = true # 예: 켠 상태
    gateway_contract = {
      cluster_name          = "contract2whale-dev-eks"
      vpc_id                = "vpc-0123456789abcdef0"
      exposure_mode         = "internal" # 예: Dev 의 실제 모드 (거부되어야 함)
      nlb_security_group_id = "sg-0123456789abcdef0"
      public_zone_id        = "ZPUBLIC"
      dns_zone_name         = "dev.playdevops.click"
    }
  }

  expect_failures = [terraform_data.contract]
}
