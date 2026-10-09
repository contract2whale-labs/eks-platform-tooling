# tests/contracts.tftest.hcl — modules/gateway (dev · prod 루트 모듈이 공유하는 모듈)
# 아래 ID 는 형식만 맞춘 fixture 이며 AWS 에 존재하지 않습니다. override_data 가 조회 응답을 대신하므로 자격 증명 · 네트워크가 필요 없습니다.

mock_provider "aws" {}

variables {
  nlb_subnet_ids      = ["subnet-00000000000000001", "subnet-00000000000000002", "subnet-00000000000000003"] # 예: 서로 다른 AZ 3곳의 서브넷 ID 3개 (개수와 형식만 맞춘 값)
  expected_account_id = "111111111111"                                                                       # 예: 12자리 계정 번호
  cluster_contract = {
    name   = "contract2whale-dev-eks"                                                 # 예: 대상 클러스터 이름
    arn    = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks" # 예: 계정 번호와 이름이 위 값과 맞는 ARN
    region = "ap-northeast-2"                                                         # 예: 이 구현이 확인한 리전
    vpc_id = "vpc-0123456789abcdef0"                                                  # 예: 클러스터가 있는 VPC
  }
  public_zone = { id = "ZPUBLIC", name = "dev.playdevops.click" } # 예: 위임된 공개 zone (계정 옵션과 공개 자식 DNS 루트 모듈 출력 모양)
}

override_data {
  target = data.aws_eks_cluster.this
  values = {
    arn        = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks"          # 예: cluster_contract.arn 과 같은 값
    vpc_config = [{ vpc_id = "vpc-0123456789abcdef0", subnet_ids = ["subnet-0123456789abcdef0"] }] # 예: 클러스터가 보고하는 VPC (계약의 vpc_id 와 같아야 함)
  }
}

override_data {
  target = data.aws_route53_zone.public
  values = { zone_id = "ZPUBLIC" } # 예: public_zone.id 와 같아야 함
}

override_data {
  target = data.aws_vpc.this
  values = { cidr_block = "172.20.0.0/16" } # 예: 송신 규칙이 쓰는 대역 (관련 구성 VPC CIDR)
}

override_data {
  target = data.aws_subnet.nlb["subnet-00000000000000001"]
  values = { vpc_id = "vpc-0123456789abcdef0", availability_zone = "ap-northeast-2a" } # 예: 계약의 VPC 와 서울 첫 번째 AZ
}

override_data {
  target = data.aws_subnet.nlb["subnet-00000000000000002"]
  values = { vpc_id = "vpc-0123456789abcdef0", availability_zone = "ap-northeast-2b" } # 예: 서울 두 번째 AZ
}

override_data {
  target = data.aws_subnet.nlb["subnet-00000000000000003"]
  values = { vpc_id = "vpc-0123456789abcdef0", availability_zone = "ap-northeast-2c" } # 예: 서울 세 번째 AZ
}

run "default_internal_is_closed" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.clients) == 0 && length(aws_vpc_security_group_ingress_rule.cloudfront) == 0 && length(aws_route53_zone.internal) == 1
    error_message = "Default must create private DNS and no inbound client rule."
  }

  assert {
    condition     = aws_eks_pod_identity_association.controller["lbc"].service_account == "aws-load-balancer-controller" && jsondecode(aws_iam_role.controller["dns"].assume_role_policy).Statement[0].Condition.StringEquals["aws:RequestTag/kubernetes-namespace"] == "kube-system"
    error_message = "Controller identities must match Helm service accounts."
  }

  assert {
    condition     = length(local.controllers) == 2 && length(aws_iam_role_policy.dns) == 1 && output.gateway_contract.external_dns_enabled == true
    error_message = "internal mode must create both controller identities and enable ExternalDNS."
  }
}

# 2. public 모드는 private zone 을 만들지 않고 ExternalDNS 권한을 공개 zone 하나로 한정합니다.
run "public_dns_is_scoped" {
  command = plan

  variables {
    exposure_mode        = "public"           # 예: 인터넷에서 직접 닿는 NLB 를 만드는 모드
    allowed_client_cidrs = ["203.0.113.7/32"] # 예: 승인한 접속 주소 하나
  }

  assert {
    condition     = length(aws_route53_zone.internal) == 0 && jsondecode(aws_iam_role_policy.dns[0].policy).Statement[2].Resource == ["arn:aws:route53:::hostedzone/ZPUBLIC"]
    error_message = "Public mode must use the declared public DNS zone."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.clients) == 1 && aws_vpc_security_group_ingress_rule.clients["203.0.113.7/32"].to_port == 443
    error_message = "Public mode must open TCP 443 only to the approved CIDR."
  }
}

# 3. waf 모드는 ExternalDNS 권한을 만들지 않고 CloudFront prefix list 규칙 하나만 엽니다.
run "waf_prevents_externaldns_bypass" {
  command = plan

  variables {
    exposure_mode = "waf" # 예: CloudFront 뒤에 두고 원본을 닫는 모드
  }

  assert {
    condition     = length(aws_iam_role_policy.dns) == 0 && length(aws_vpc_security_group_ingress_rule.cloudfront) == 1 && length(aws_vpc_security_group_ingress_rule.clients) == 0
    error_message = "WAF DNS is owned by edge Terraform and ingress must be CloudFront-only."
  }

  assert {
    condition     = length(local.controllers) == 1 && output.gateway_contract.external_dns_enabled == false
    error_message = "WAF mode must not create the ExternalDNS identity."
  }
}

# 4. waf 모드에 우회 CIDR 을 넣으면 계약 검사가 거부합니다.
run "reject_waf_bypass_cidr" {
  command = plan

  variables {
    exposure_mode        = "waf"         # 예: CloudFront 만 허용해야 하는 모드
    allowed_client_cidrs = ["0.0.0.0/0"] # 예: 거부되어야 하는 우회 입력
  }

  expect_failures = [terraform_data.contract]
}

# 5. 조회한 클러스터의 VPC 가 계약과 다르면 거부합니다.
run "reject_other_vpc" {
  command = plan

  override_data {
    target = data.aws_eks_cluster.this
    values = {
      arn        = "arn:aws:eks:ap-northeast-2:111111111111:cluster/contract2whale-dev-eks" # 예: ARN 은 그대로 두고 VPC 만 어긋나게 만듦
      vpc_config = [{ vpc_id = "vpc-other", subnet_ids = ["subnet-0123456789abcdef0"] }]    # 예: 계약의 vpc_id 와 다른 값
    }
  }

  expect_failures = [terraform_data.contract]
}

run "reject_same_az_subnets" {
  command = plan

  override_data {
    target = data.aws_subnet.nlb["subnet-00000000000000003"]
    values = { vpc_id = "vpc-0123456789abcdef0", availability_zone = "ap-northeast-2a" } # 예: 첫 번째와 같은 AZ (거부되어야 하는 조합)
  }

  expect_failures = [terraform_data.contract]
}
