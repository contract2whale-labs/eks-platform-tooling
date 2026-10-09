# tests/gateway.tftest.hcl — platform/gateway 루트 모듈 (dev · prod 공통 코드)
# terraform_remote_state 는 override_data 로 가짜 출력을 주고, 모듈 안 aws data source 는 계약과 같은 값을 돌려주도록 override 합니다. 아래 ID 는 AWS 에 없는 fixture 입니다.
# 모듈 자체의 규칙(모드별 거부 · IAM JSON)은 modules/gateway/tests/contracts.tftest.hcl 이 확인합니다.

mock_provider "aws" {}

variables {
  expected_account_id = "111111111111"
  region              = "ap-northeast-2"
  environment         = "dev"
  state_bucket_name   = "company-dev-tfstate-111111111111"
}

override_data {
  target = data.terraform_remote_state.eks
  values = {
    outputs = {
      cluster_contract = {
        name               = "contract2whale-dev-eks"
        arn                = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
        region             = "ap-northeast-2"
        vpc_id             = "vpc-0123456789abcdef0"
        kubernetes_version = "1.36"
      }
    }
  }
}

# account-baseline-dns State 출력 (계정 옵션과 공개 자식 DNS 루트 모듈 공개 자식 Zone)
override_data {
  target = data.terraform_remote_state.dns
  values = {
    outputs = {
      public_zone_id   = "ZPUBLIC"
      public_zone_name = "dev.playdevops.click"
    }
  }
}

# network/vpc State 출력 (관련 구성 public 3 · private 3)
override_data {
  target = data.terraform_remote_state.network
  values = {
    outputs = {
      public_subnet_ids  = ["subnet-00000000000000101", "subnet-00000000000000102", "subnet-00000000000000103"]
      private_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000002", "subnet-00000000000000003"]
    }
  }
}

# 실제 AWS 조회 결과가 계약과 같다고 가정하는 override 입니다 (모듈 안 data source).
override_data {
  target = module.component.data.aws_eks_cluster.this
  values = {
    arn        = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
    vpc_config = [{ vpc_id = "vpc-0123456789abcdef0", subnet_ids = ["subnet-0123456789abcdef0"] }]
  }
}

override_data {
  target = module.component.data.aws_route53_zone.public
  values = { zone_id = "ZPUBLIC" }
}

override_data {
  target = module.component.data.aws_vpc.this
  values = { cidr_block = "172.20.0.0/16" }
}

override_data {
  target = module.component.data.aws_subnet.nlb["subnet-00000000000000001"]
  values = { vpc_id = "vpc-0123456789abcdef0", availability_zone = "ap-northeast-2a" }
}

override_data {
  target = module.component.data.aws_subnet.nlb["subnet-00000000000000002"]
  values = { vpc_id = "vpc-0123456789abcdef0", availability_zone = "ap-northeast-2b" }
}

override_data {
  target = module.component.data.aws_subnet.nlb["subnet-00000000000000003"]
  values = { vpc_id = "vpc-0123456789abcdef0", availability_zone = "ap-northeast-2c" }
}

# mock apply 에서 SG ID · private zone ID · IAM ARN 을 실제 형식으로 고정합니다 (출력 전달 확인용; ARN 형식 검사가 있는 attachment · association 을 통과시킴).
override_resource {
  target = module.component.aws_security_group.nlb
  values = { id = "sg-0123456789abcdef0" }
}

override_resource {
  target = module.component.aws_iam_policy.lbc
  values = { arn = "arn:aws:iam::111111111111:policy/contract2whale-dev-eks-load-balancer-controller" }
}

override_resource {
  target = module.component.aws_iam_role.controller["lbc"]
  values = { arn = "arn:aws:iam::111111111111:role/contract2whale-dev-eks-aws-load-balancer-controller" }
}

override_resource {
  target = module.component.aws_iam_role.controller["dns"]
  values = { arn = "arn:aws:iam::111111111111:role/contract2whale-dev-eks-external-dns" }
}

override_resource {
  target = module.component.aws_route53_zone.internal
  values = { zone_id = "Z0PRIVATE00000000000" }
}

# 1. State 출력 세 곳에서 모듈 계약을 조립합니다 (입력 파일 없음). 기본 모드(internal)는 관련 구성 private 서브넷을 고릅니다.
run "assembles_contract_from_state" {
  command = plan

  assert {
    condition     = local.cluster_contract == { name = "contract2whale-dev-eks", arn = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks", region = "ap-northeast-2", vpc_id = "vpc-0123456789abcdef0" }
    error_message = "cluster_contract must be assembled from the eks state outputs (name, arn, region, vpc_id only)."
  }

  assert {
    condition     = local.public_zone == { id = "ZPUBLIC", name = "dev.playdevops.click" }
    error_message = "public_zone must come from the account-baseline-dns state."
  }

  assert {
    condition     = local.nlb_subnet_ids == toset(["subnet-00000000000000001", "subnet-00000000000000002", "subnet-00000000000000003"])
    error_message = "internal mode must place the NLB in the 관련 구성 private subnets."
  }

  assert {
    condition     = terraform_data.environment_boundary.input == "dev"
    error_message = "The environment marker must record dev."
  }
}

run "public_mode_uses_public_subnets" {
  command = plan

  variables {
    exposure_mode = "public"
  }

  override_data {
    target = module.component.data.aws_subnet.nlb["subnet-00000000000000101"]
    values = { vpc_id = "vpc-0123456789abcdef0", availability_zone = "ap-northeast-2a" }
  }

  override_data {
    target = module.component.data.aws_subnet.nlb["subnet-00000000000000102"]
    values = { vpc_id = "vpc-0123456789abcdef0", availability_zone = "ap-northeast-2b" }
  }

  override_data {
    target = module.component.data.aws_subnet.nlb["subnet-00000000000000103"]
    values = { vpc_id = "vpc-0123456789abcdef0", availability_zone = "ap-northeast-2c" }
  }

  assert {
    condition     = local.nlb_subnet_ids == toset(["subnet-00000000000000101", "subnet-00000000000000102", "subnet-00000000000000103"])
    error_message = "public mode must place the NLB in the public subnets."
  }
}

run "outputs_match_module_contract" {
  command = apply

  assert {
    condition     = length(keys(output.gateway_contract)) == 13 && output.gateway_contract.exposure_mode == "internal" && output.gateway_contract.external_dns_enabled == true
    error_message = "gateway_contract must have 13 items with internal mode and ExternalDNS enabled."
  }

  assert {
    condition     = output.gateway_contract.nlb_security_group_id == "sg-0123456789abcdef0" && output.gateway_contract.dns_zone_id == "Z0PRIVATE00000000000" && output.gateway_contract.public_zone_id == "ZPUBLIC"
    error_message = "gateway_contract must carry the SG ID, the private zone ID and the public zone ID."
  }

}

# 4. 이 디렉터리는 dev 만 받습니다.
run "reject_non_dev_environment" {
  command = plan

  variables {
    environment = "prod"
  }

  expect_failures = [terraform_data.environment_boundary]
}

# 5. vpc_id 가 없는 cluster_contract(환경 root 와 모듈 연결 이전 형식) 는 거부됩니다.
run "reject_state_without_vpc_id" {
  command = plan

  override_data {
    target = data.terraform_remote_state.eks
    values = {
      outputs = {
        cluster_contract = {
          name   = "contract2whale-dev-eks"
          arn    = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"
          region = "ap-northeast-2"
        }
      }
    }
  }

  expect_failures = [data.terraform_remote_state.eks]
}

# 6. 공개 zone 이 꺼진(enabled = false) State 는 거부됩니다.
run "reject_state_without_public_zone" {
  command = plan

  override_data {
    target = data.terraform_remote_state.dns
    values = {
      outputs = {
        public_zone_id   = null
        public_zone_name = null
      }
    }
  }

  expect_failures = [data.terraform_remote_state.dns]
}
