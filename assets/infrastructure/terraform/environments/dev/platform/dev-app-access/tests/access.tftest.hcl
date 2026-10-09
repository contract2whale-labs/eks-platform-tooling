# tests/access.tftest.hcl — platform/dev-app-access 루트 모듈 (dev 전용)

mock_provider "aws" {}

variables {
  expected_account_id               = "111111111111"
  region                            = "ap-northeast-2"
  environment                       = "dev"
  state_bucket_name                 = "company-dev-tfstate-111111111111"
  approved_identity_center_role_arn = "arn:aws:iam::111111111111:role/aws-reserved/sso.amazonaws.com/ap-northeast-2/AWSReservedSSO_CommerceDeveloper_0123456789abcdef"
}

# private-api State 출력 (Private API 접속 경로 준비 session_contract)
override_data {
  target = data.terraform_remote_state.private_api
  values = {
    outputs = {
      session_contract = {
        instance_id       = "i-0123456789abcdef0"
        security_group_id = "sg-0relay0123456789a"
        subnet_id         = "subnet-0ia00000000000001"
        proxy_port        = 3128
      }
    }
  }
}

override_data {
  target = data.terraform_remote_state.gateway
  values = {
    outputs = {
      gateway_contract = {
        cluster_name          = "contract2whale-dev-eks"
        nlb_security_group_id = "sg-0123456789abcdef0"
        exposure_mode         = "internal"
        namespace             = "platform-gateway"
        vpc_id                = "vpc-0123456789abcdef0"
      }
    }
  }
}

# controller 가 만든 NLB 와 중계 인스턴스의 조회 응답
override_data {
  target = data.aws_lb.gateway
  values = {
    internal           = true
    load_balancer_type = "network"
    dns_name           = "k8s-platfor-platform-0123456789-abcdef0123456789.elb.ap-northeast-2.amazonaws.com"
    security_groups    = ["sg-0123456789abcdef0"]
    arn                = "arn:aws:elasticloadbalancing:ap-northeast-2:111111111111:loadbalancer/net/k8s-platfor-platform-0123456789/abcdef0123456789"
  }
}

override_data {
  target = data.aws_instance.relay
  values = {
    vpc_security_group_ids = ["sg-0relay0123456789a"]
  }
}

override_resource {
  target = aws_ssm_document.dev_app_https
  values = { arn = "arn:aws:ssm:ap-northeast-2:111111111111:document/CommerceDevelopmentAppHttps" }
}

override_resource {
  target = aws_iam_role.dev_app_session
  values = { arn = "arn:aws:iam::111111111111:role/CommerceDevelopmentAppSession" }
}

# 1. 문서는 NLB DNS · 443 · 8443 만 허용하고, Role 은 승인 SSO Role 만 신뢰하며, SG 규칙은 중계 SG 출발지 443 입니다.
run "fixed_document_role_and_sg_rule" {
  command = plan

  assert {
    condition     = yamldecode(aws_ssm_document.dev_app_https.content).parameters.host.allowedValues == ["k8s-platfor-platform-0123456789-abcdef0123456789.elb.ap-northeast-2.amazonaws.com"] && yamldecode(aws_ssm_document.dev_app_https.content).parameters.portNumber.allowedValues == ["443"] && yamldecode(aws_ssm_document.dev_app_https.content).parameters.localPortNumber.allowedValues == ["8443"]
    error_message = "The session document must pin host, remote port and local port to single allowed values."
  }

  assert {
    condition     = yamldecode(aws_ssm_document.dev_app_https.content).sessionType == "Port" && aws_ssm_document.dev_app_https.document_type == "Session" && aws_ssm_document.dev_app_https.name == "CommerceDevelopmentAppHttps"
    error_message = "The document must be a Port session document named CommerceDevelopmentAppHttps."
  }

  assert {
    condition     = jsondecode(aws_iam_role.dev_app_session.assume_role_policy).Statement[0].Principal.AWS == var.approved_identity_center_role_arn && aws_iam_role.dev_app_session.name == "CommerceDevelopmentAppSession"
    error_message = "Only the approved Identity Center role may assume CommerceDevelopmentAppSession."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.relay_to_nlb.referenced_security_group_id == "sg-0relay0123456789a" && aws_vpc_security_group_ingress_rule.relay_to_nlb.security_group_id == "sg-0123456789abcdef0" && aws_vpc_security_group_ingress_rule.relay_to_nlb.from_port == 443 && aws_vpc_security_group_ingress_rule.relay_to_nlb.to_port == 443
    error_message = "The NLB SG must gain one TCP 443 rule whose source is the relay SG (no CIDR)."
  }
}

# 2. 정책은 인스턴스 하나 + 문서 하나 + 자기 세션만 자원으로 둡니다 (mock apply; 문서 ARN 참조).
run "policy_scopes_instance_and_document" {
  command = apply

  assert {
    condition     = jsondecode(aws_iam_role_policy.dev_app_session.policy).Statement[0].Resource == ["arn:aws:ec2:ap-northeast-2:111111111111:instance/i-0123456789abcdef0"] && jsondecode(aws_iam_role_policy.dev_app_session.policy).Statement[1].Resource == ["arn:aws:ssm:ap-northeast-2:111111111111:document/CommerceDevelopmentAppHttps"]
    error_message = "StartSession must be limited to the relay instance and the fixed document."
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.dev_app_session.policy).Statement) == 3 && jsondecode(aws_iam_role_policy.dev_app_session.policy).Statement[2].Resource == ["arn:aws:ssm:*:*:session/$${aws:userid}-*"]
    error_message = "The policy must have exactly three statements and only manage the caller's own sessions."
  }

  assert {
    condition     = output.session_contract.document_name == "CommerceDevelopmentAppHttps" && output.session_contract.local_port == 8443 && output.session_contract.instance_id == "i-0123456789abcdef0"
    error_message = "session_contract must carry the document name, local port and instance ID."
  }
}

# 3. internet-facing NLB 는 거부합니다.
run "reject_internet_facing_nlb" {
  command = plan

  override_data {
    target = data.aws_lb.gateway
    values = {
      internal           = false
      load_balancer_type = "network"
      dns_name           = "public-0123456789.elb.ap-northeast-2.amazonaws.com"
      security_groups    = ["sg-0123456789abcdef0"]
    }
  }

  expect_failures = [terraform_data.contract]
}

# 4. 다른 계정의 승인 Role 은 거부합니다.
run "reject_foreign_account_role" {
  command = plan

  variables {
    approved_identity_center_role_arn = "arn:aws:iam::222222222222:role/aws-reserved/sso.amazonaws.com/ap-northeast-2/AWSReservedSSO_CommerceDeveloper_0123456789abcdef"
  }

  expect_failures = [terraform_data.contract]
}

# 5. Identity Center 형식이 아닌 Role ARN 은 변수 검사가 거부합니다 (AdministratorAccess 같은 일반 Role 을 넣는 실수 방지).
run "reject_non_sso_role_arn" {
  command = plan

  variables {
    approved_identity_center_role_arn = "arn:aws:iam::111111111111:role/AdministratorAccess"
  }

  expect_failures = [var.approved_identity_center_role_arn]
}

# 6. 이 디렉터리는 dev 만 받습니다.
run "reject_non_dev_environment" {
  command = plan

  variables {
    environment = "prod"
  }

  expect_failures = [terraform_data.environment_boundary]
}
