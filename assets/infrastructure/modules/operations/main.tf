# main.tf — modules/operations (dev · prod 루트 모듈이 공유하는 모듈)
# Controller 신원과 저장소: 도구 선택(identities) · 백업 버킷 이름 · ASG 탐색 태그 조합을 계산하고, 플랫폼 로그 그룹 · 시크릿 메타데이터 · ASG 탐색 태그를 선언합니다 (리소스 3종).
# 로그 그룹 주소는 원본과 같이 aws_cloudwatch_log_group.platform 입니다 (application 이 아님). 앱 컨테이너 로그는 이 그룹으로 보내지 않습니다 (관측 파이프라인 수집 경로).

locals {
  # for_each 키가 Terraform 리소스 주소가 됩니다. 키를 바꾸면 Role · 연결이 삭제 후 재생성됩니다.
  all_identities = {
    fluent_bit       = { namespace = "logging", service_account = "fluent-bit" }                # 예: 플랫폼 컨테이너 로그 수집
    autoscaler       = { namespace = "kube-system", service_account = "cluster-autoscaler" }    # 예: 노드 수 자동 조절
    external_secrets = { namespace = "external-secrets", service_account = "external-secrets" } # 예: 시크릿 동기화
    velero           = { namespace = "velero", service_account = "velero" }                     # 예: 백업 · 복구
  }

  identities = { for name, identity in local.all_identities : name => identity if contains(var.enabled_services, name) }

  # 예: "velero-contract2whale-dev-eks-111111111111-ap-northeast-2" (57자, S3 이름 한도 63자 이내 — providers.tf 계약 검사가 확인)
  backup_bucket_name = "velero-${var.cluster_contract.name}-${var.expected_account_id}-${var.region}"

  asg_discovery_tags = {
    "k8s.io/cluster-autoscaler/enabled"                      = "true"  # 예: 자동 확장 대상 그룹 표시
    "k8s.io/cluster-autoscaler/${var.cluster_contract.name}" = "owned" # 예: 이 클러스터 소유 그룹 표시
  }

  # setproduct(ASG 이름 집합, 태그 키 집합) 조합마다 "<ASG 이름>:<태그 키>" 고유 키를 만듭니다.
  asg_tags = {
    for pair in setproduct(var.node_group_autoscaling_group_names, toset(keys(local.asg_discovery_tags))) :
    "${pair[0]}:${pair[1]}" => { asg = pair[0], key = pair[1], value = local.asg_discovery_tags[pair[1]] }
  }
}

# 로그 그룹의 수명 · 보존 기간은 Terraform 이, 로그 stream · event 는 Fluent Bit 가 소유합니다.
resource "aws_cloudwatch_log_group" "platform" {
  count = contains(var.enabled_services, "fluent_bit") ? 1 : 0 # 예: fluent_bit 을 켠 경우에만 1개

  name              = "/platform/${var.cluster_contract.name}/application" # 예: "/platform/contract2whale-dev-eks/application"
  retention_in_days = var.application_log_retention_days                   # 예: 90
  skip_destroy      = false                                                # 예: false (실습 삭제 시 로그 그룹도 삭제)

  depends_on = [terraform_data.contract] # 예: 계약 검사 통과 후 생성
}

resource "aws_secretsmanager_secret" "grafana" {
  count = contains(var.enabled_services, "external_secrets") ? 1 : 0 # 예: external_secrets 를 켠 경우에만 1개

  name                    = "${var.cluster_contract.name}/platform/grafana-admin" # 예: "contract2whale-dev-eks/platform/grafana-admin"
  description             = "Grafana admin bootstrap JSON; user supplies admin-user and admin-password outside Terraform"
  recovery_window_in_days = 0 # 예: 0 (복구 대기 없이 삭제, 실습 기본값)

  lifecycle {
    prevent_destroy = false # 예: false (실습 삭제 허용)
  }

  depends_on = [terraform_data.contract] # 예: 계약 검사 통과 후 생성
}

resource "aws_autoscaling_group_tag" "discovery" {
  for_each = local.asg_tags # 예: 필드 계약 ("<ASG 이름>:<태그 키>")

  autoscaling_group_name = each.value.asg # 예: "eks-contract2whale-dev-eks-system-0ac12345-..."

  tag {
    key                 = each.value.key   # 예: "k8s.io/cluster-autoscaler/enabled"
    value               = each.value.value # 예: "true"
    propagate_at_launch = false            # 예: false (새 인스턴스에 복사하지 않음)
  }

  depends_on = [terraform_data.contract] # 예: 계약 검사 통과 후 생성
}
