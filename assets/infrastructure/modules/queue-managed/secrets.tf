# secrets.tf — modules/queue-managed (dev · prod 루트 모듈이 공유하는 모듈)
# 고객 관리 키와 시크릿, 클러스터: 사용자 시크릿 두 개입니다. 이름은 반드시 AmazonMSK_ 로 시작하고 값은 JSON 두 키(username · password)입니다. 다른 키 이름은 인식되지 않습니다.

locals {
  # 예: 쓰는 쪽과 읽는 쪽 두 항목입니다. 키가 Terraform 주소가 되므로 바꾸지 않습니다.
  queue_users = {
    writer = { username = var.writer_username } # 예: 쓰는 쪽 사용자와 비밀번호
    reader = { username = var.reader_username } # 예: 읽는 쪽 사용자와 비밀번호
  }
}

resource "aws_secretsmanager_secret" "queue_user" {
  for_each = local.queue_users # 예: writer 와 reader 두 항목

  name        = "AmazonMSK_${local.cluster_name}_${each.value.username}" # 예: "AmazonMSK_cp-dev-traces-queue_tempo-distributor"
  description = "SCRAM credential for the managed trace queue"           # 예: 콘솔 목록에서 용도를 구분하는 설명
  kms_key_id  = aws_kms_key.queue_secrets.arn                            # 예: 고객 관리 키 ARN (기본 키를 쓰면 연결이 거부됨)

  recovery_window_in_days = 0 # 예: 0 (실습 삭제 기본값: 즉시 삭제 — 7 이면 같은 이름으로 다시 만들 수 없음)

  tags = {
    Name      = "AmazonMSK_${local.cluster_name}_${each.value.username}" # 예: 콘솔 목록 식별용 Name 태그
    QueueRole = each.key                                                 # 예: "writer" 또는 "reader"
  }
}



# 클러스터가 만들어진 뒤에만 연결됩니다. 시크릿 리소스 정책이나 암호화 키를 바꾸면 다시 연결합니다. 비밀번호 값은 MSK 가 주기적으로 동기화합니다.
