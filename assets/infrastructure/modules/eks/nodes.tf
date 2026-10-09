# nodes.tf — modules/eks (dev · prod 루트 모듈이 공유하는 모듈)
# 패키지 최종 자산: 후속 Autoscaler 도입 뒤의 desired_size ignore_changes를 포함합니다. BU07 최초 작성·적용에는 BU07/05의 단계별 전체 source를 사용하며 lifecycle 변경은 Autoscaler 도입 PR에서 승인합니다.
# nodes(앞부분: locals · 시작 템플릿) + nodes(뒷부분: vpc-cni Add-on · 관리형 노드 그룹). 그룹 입력 map → for_each 키 "<이름>" 또는 "<이름>-<az>".
# EKS 가 AL2023 이미지와 nodeadm 부팅을 처리합니다. custom AMI(image_id) 와 user_data 를 지정하지 않습니다.
# 시작 템플릿은 IMDSv2 강제(http_tokens = required · hop limit 1)와 루트 볼륨 · 노드 SG 만 정합니다 (E3).
# vpc-cni 는 노드보다 먼저 설치합니다 (CNI 설정의 생성 순서이며 실제 prefix 및 kubelet maxPods는 부팅 뒤 확인). 노드 뒤에 설치하는 나머지 Add-on 4개는 addons.tf 입니다.

locals {
  # AZ 이름과 노드 서브넷을 순서대로 짝지어 AZ 하나에 서브넷 하나를 대응시킵니다 (network/vpc 의 두 출력은 같은 순서).
  node_subnet_by_az = zipmap(
    var.network_contract.availability_zones, # 예: ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
    var.network_contract.node_subnet_ids     # 예: ["subnet-0eks1...", "subnet-0eks2...", "subnet-0eks3..."] (같은 순서의 EKS 전용 서브넷)
  )

  # subnet_scope = "all" 인 항목은 그대로 그룹 하나가 되고 서브넷 전체를 받습니다.
  node_groups_all = {
    for name, group in var.node_groups : name => {
      source             = name                                 # 예: "system" (펼치기 전 입력 항목 이름)
      instance_types     = group.instance_types                 # 예: ["m7i.large"]
      scaling            = group.scaling                        # 예: { min = 2, max = 4, desired = 2 }
      disk_gib           = group.disk_gib                       # 예: 40
      labels             = group.labels                         # 예: { workload = "system" }
      taints             = group.taints                         # 예: []
      subnet_ids         = var.network_contract.node_subnet_ids # 예: 서브넷 3개 전체 (AZ 를 가리지 않음)
      availability_zones = keys(local.node_subnet_by_az)        # 예: ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
    } if group.subnet_scope == "all"                            # 예: "all" 인 항목만
  }

  # subnet_scope = "per_az" 인 항목은 AZ 마다 그룹 하나로 펼쳐지고 그 AZ 의 서브넷 하나만 받습니다 (scaling 은 AZ 당 값).
  node_groups_per_az = {
    for pair in flatten([
      for name, group in var.node_groups : [
        for az, subnet_id in local.node_subnet_by_az : {
          key = "${name}-${az}" # 예: "observability-ap-northeast-2a"
          value = {
            source             = name                 # 예: "observability"
            instance_types     = group.instance_types # 예: ["r7i.xlarge"]
            scaling            = group.scaling        # 예: { min = 1, max = 2, desired = 1 } (AZ 하나가 가지는 범위)
            disk_gib           = group.disk_gib       # 예: 50
            labels             = group.labels         # 예: { workload = "observability" }
            taints             = group.taints         # 예: [{ key = "workload", value = "observability", effect = "NoSchedule" }]
            subnet_ids         = [subnet_id]          # 예: ["subnet-0eks1..."] (그 AZ 의 서브넷 하나만)
            availability_zones = [az]                 # 예: ["ap-northeast-2a"]
          }
        }
      ] if group.subnet_scope == "per_az" # 예: "per_az" 인 항목만 AZ 수만큼
    ]) : pair.key => pair.value
  }

  # 펼친 결과를 하나로 합칩니다. 기본 입력은 키 system 1개입니다. node-outputs.tf 의 group_availability_zones 가 이 map 을 읽습니다.
  node_groups_expanded = merge(local.node_groups_all, local.node_groups_per_az) # 예: { system = {...} }

  # 입력은 Kubernetes 표기로 받고 AWS API 가 받는 표기로 바꿔 보냅니다.
  taint_effect_api = {
    NoSchedule       = "NO_SCHEDULE"        # 예: 견디지 못하는 Pod 을 새로 올리지 않음
    PreferNoSchedule = "PREFER_NO_SCHEDULE" # 예: 가능하면 피하고 자리가 없으면 올림
    NoExecute        = "NO_EXECUTE"         # 예: 해당 taint를 견디지 못하는 Pod의 배치와 기존 Pod 유지에 영향을 줌; tolerationSeconds도 확인
  }
}

# 그룹마다 루트 볼륨 크기와 Name 태그가 다르므로 시작 템플릿도 그룹마다 만듭니다.
resource "aws_launch_template" "nodes" {
  for_each = local.node_groups_expanded # 예: 기본 입력은 키 system 1개

  name                   = "${var.cluster_name}-${each.key}" # 예: "contract2whale-dev-eks-system" (describe-launch-templates 필터 contract2whale-dev-eks-*)
  update_default_version = true                              # 예: true (내용이 바뀌면 새 버전을 기본 버전으로 올림)
  vpc_security_group_ids = [aws_security_group.nodes.id]     # 예: ["sg-0nodes..."] (노드 SG 하나; EKS 기본 cluster SG 는 붙이지 않음)

  # IMDSv2를 요구하고 토큰 응답의 홉 제한을 1로 둡니다. 일반 Pod의 경로를 제한하지만 hostNetwork · 노드 프로세스 · 프록시를 포함한 모든 자격 증명 접근을 차단했다는 증거는 아닙니다. CNI · EBS는 전용 Role을 씁니다.
  metadata_options {
    http_endpoint               = "enabled"  # 예: "enabled" (kubelet · nodeadm 이 IMDS 를 씀)
    http_tokens                 = "required" # 예: "required" (토큰 없는 IMDSv1 요청 거부)
    http_put_response_hop_limit = 1          # 예: 1 (토큰 응답의 IP 홉 제한; 모든 Pod 접근 차단을 보장하지 않음)
    instance_metadata_tags      = "disabled" # 예: "disabled" (인스턴스 태그를 메타데이터로 내보내지 않음)
  }

  block_device_mappings {
    device_name = "/dev/xvda" # 예: "/dev/xvda" (AL2023 이미지의 루트 장치)

    ebs {
      volume_size           = each.value.disk_gib # 예: 40 (그룹마다 다른 루트 볼륨 크기, GiB)
      volume_type           = "gp3"               # 예: "gp3"
      encrypted             = true                # 예: true (EBS 암호화; 별도 kms_key_id를 지정하지 않아 계정·리전의 기본 EBS KMS키를 확인)
      delete_on_termination = true                # 예: true (인스턴스 종료 시 루트 볼륨 삭제 설정; 실제 삭제와 잔여 비용은 별도 조회)
    }
  }

  tag_specifications {
    resource_type = "instance" # 예: "instance" (EC2 인스턴스에 붙는 태그; describe-instances 의 tag:Name 필터가 읽음)

    tags = {
      Name = "${var.cluster_name}-${each.key}" # 예: "contract2whale-dev-eks-system"
    }
  }
}

# 노드 등록과 Pod 네트워크의 선행 조건입니다. ServiceAccount 의 AWS 권한은 전용 IRSA Role(node-iam.tf) 이며 노드 Role 이 아닙니다.
resource "aws_eks_addon" "cni" {
  cluster_name                = aws_eks_cluster.this.name  # 예: "contract2whale-dev-eks"
  addon_name                  = "vpc-cni"                  # 예: "vpc-cni" (AWS 가 정한 Add-on 이름)
  addon_version               = var.addon_versions.vpc-cni # 예: "v1.20.3-eksbuild.1" (형식 예시; describe-addon-versions 조회 값)
  service_account_role_arn    = aws_iam_role.cni.arn       # 예: "arn:aws:iam::111111111111:role/contract2whale-dev-eks-vpc-cni" (IRSA)
  resolve_conflicts_on_create = "OVERWRITE"                # 예: "OVERWRITE" (설치 시 기존 설정을 덮어씀)
  resolve_conflicts_on_update = "NONE"                     # 예: "NONE" (업데이트 충돌을 자동으로 덮어쓰지 않음)

  # prefix 위임: ENI에 /28 prefix를 할당하도록 설정하고 NetworkPolicy 기능을 켭니다. 실제 Pod 수용 수는 kubelet maxPods · 인스턴스 네트워크 한도 · 남은 prefix/IP · 자원 요청과 현재 실행 상태를 함께 확인합니다. 설정만으로 110 Pod 수용을 확정하지 않습니다.
  configuration_values = jsonencode({
    enableNetworkPolicy = "true" # 예: "true" (NetworkPolicy 적용 — core 정책 챕터가 씀)
    env = {
      ENABLE_PREFIX_DELEGATION      = "true"     # 예: "true" (보조 IP 대신 /28 prefix 할당)
      WARM_PREFIX_TARGET            = "1"        # 예: "1" (미리 확보해 둘 예비 prefix 수)
      NETWORK_POLICY_ENFORCING_MODE = "standard" # 예: "standard" (정책 적용 방식)
    }
  })

  depends_on = [aws_iam_role_policy_attachment.cni] # 예: CNI 정책 연결이 끝난 뒤 설치
}

# 펼쳐진 그룹 목록 하나로 관리형 노드 그룹을 한꺼번에 선언합니다. 주소는 aws_eks_node_group.groups["<키>"] 입니다.
resource "aws_eks_node_group" "groups" {
  for_each = local.node_groups_expanded # 예: 기본 입력은 키 system 1개

  cluster_name    = aws_eks_cluster.this.name         # 예: "contract2whale-dev-eks"
  node_group_name = "${var.cluster_name}-${each.key}" # 예: "contract2whale-dev-eks-system"
  node_role_arn   = aws_iam_role.nodes.arn            # 예: "arn:aws:iam::111111111111:role/contract2whale-dev-eks-nodes" (그룹 수와 무관하게 같은 Role)
  subnet_ids      = each.value.subnet_ids             # 예: 서브넷 3개 ("all") 또는 1개 ("per_az")
  ami_type        = "AL2023_x86_64_STANDARD"          # 예: "AL2023_x86_64_STANDARD" (AL2023 x86_64 표준 이미지; instance_types 가 모두 x86_64 여야 함)
  release_version = var.node_release_version          # 예: "1.36.0-20260815" (형식 예시; SSM recommended 조회 값)
  version         = var.kubernetes_version            # 예: "1.36" (클러스터와 같은 마이너 버전)
  capacity_type   = "ON_DEMAND"                       # 예: "ON_DEMAND" (Spot 회수 대상이 아님)
  instance_types  = each.value.instance_types         # 예: ["m7i.large"]
  labels          = each.value.labels                 # 예: { workload = "system" } (노드 label 로 그대로 나타남)

  scaling_config {
    min_size     = each.value.scaling.min     # 예: 2
    max_size     = each.value.scaling.max     # 예: 4
    desired_size = each.value.scaling.desired # 예: 2 (Cluster Autoscaler 도입 뒤에는 ignore_changes 검토 — operations)
  }

  update_config {
    max_unavailable = 1 # 예: 1 (업데이트 중 동시에 내릴 수 있는 노드 수)
  }

  node_repair_config {
    enabled = true # 예: true (상태 불량 노드를 EKS 가 교체)
  }

  launch_template {
    id      = aws_launch_template.nodes[each.key].id                       # 예: "lt-0123456789abcdef0" (같은 키의 시작 템플릿)
    version = tostring(aws_launch_template.nodes[each.key].latest_version) # 예: "1" (숫자를 문자열로)
  }

  dynamic "taint" {
    for_each = each.value.taints # 예: 목록이 비면 블록 0개

    content {
      key    = taint.value.key                            # 예: "workload"
      value  = taint.value.value                          # 예: "observability"
      effect = local.taint_effect_api[taint.value.effect] # 예: "NO_SCHEDULE" ("NoSchedule" 을 AWS 표기로)
    }
  }

  # 노드 그룹 식별 태그입니다. Cluster Autoscaler 가 읽는 실제 ASG 태그는 operations 가 별도로 관리합니다.
  tags = {
    "k8s.io/cluster-autoscaler/enabled"             = "true"  # 예: "true"
    "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned" # 예: "owned"
  }

  lifecycle {
    # 현재 대수는 Autoscaler가 관리하며 Terraform은 min/max 경계를 관리합니다.
    ignore_changes = [scaling_config[0].desired_size]

    # AMI release 의 마이너 버전이 클러스터 버전과 같아야 합니다 (1.36 클러스터에 1.35 이미지를 넣는 실수를 plan 에서 거부).
    precondition {
      condition     = startswith(var.node_release_version, "${var.kubernetes_version}.") # 예: "1.36.0-20260815" 은 "1.36." 으로 시작 → 통과 / "1.35.0-..." 거부
      error_message = "node_release_version must be an AMI release of the same Kubernetes minor as kubernetes_version."
    }
  }

  # 정책 · SG 규칙 · CNI 설정의 생성 순서를 노드 그룹 앞에 둡니다. 실제 등록 및 prefix·maxPods 적용은 부팅 후 확인합니다. CNI 선언은 이 노드 그룹을 참조하지 않습니다.
  depends_on = [
    aws_iam_role_policy_attachment.nodes,                               # 예: 노드 Role 에 정책 2개가 붙은 뒤
    aws_vpc_security_group_ingress_rule.control_plane_from_nodes,       # 예: 노드 → API 443 규칙 뒤
    aws_vpc_security_group_ingress_rule.nodes_from_control_plane,       # 예: control plane → 노드 1025-65535 규칙 뒤
    aws_vpc_security_group_ingress_rule.nodes_https_from_control_plane, # 예: control plane → 노드 443 규칙 뒤
    aws_vpc_security_group_ingress_rule.nodes_self,                     # 예: 노드 사이 규칙 뒤
    aws_vpc_security_group_egress_rule.nodes,                           # 예: 나가는 규칙 뒤
    aws_eks_addon.cni,                                                  # 예: vpc-cni 설정을 먼저 준비; 실제 prefix 및 maxPods는 노드에서 확인
  ]
}
