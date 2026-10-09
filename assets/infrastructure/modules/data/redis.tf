# redis.tf — modules/data (dev · prod 루트 모듈이 공유하는 모듈)
# commerce-api(Medusa) 의 event bus · workflow engine · locking · cache 네 모듈이 이 한 곳을 씁니다. 복제본이 둘 이상이면 이 네 가지가 Pod 밖에 있어야 하므로 Prod 는 캐시를 내릴 수 없습니다 (contract.tf 의 guard).

# 캐시 앞의 Security Group 입니다. 규칙은 노드 Security Group 에서 오는 6379 하나뿐이고 나가는 규칙은 두지 않습니다 (데이터베이스 SG 와 같은 방식).
resource "aws_security_group" "redis" {
  count = var.enable_redis ? 1 : 0 # 예: 1 (기본) / 0 (요금을 쉬는 동안)

  name        = "${local.name_prefix}-redis"           # 예: "contract2whale-dev-eks-data-redis"
  description = "Valkey access for cluster nodes only" # 예: 콘솔 설명 (변경하면 SG 가 교체됨)
  vpc_id      = var.network_contract.vpc_id            # 예: "vpc-0123456789abcdef0"

  tags = { Name = "${local.name_prefix}-redis" } # 예: 콘솔 목록에서 찾기 위한 이름 태그
}

# 노드 Security Group 을 출발지로 지정합니다. 서버리스 캐시는 접속을 TLS 로만 받으므로 평문 포트를 따로 열지 않습니다.
resource "aws_vpc_security_group_ingress_rule" "redis_from_nodes" {
  count = var.enable_redis ? 1 : 0 # 예: 캐시와 함께 생기고 함께 사라집니다

  security_group_id            = aws_security_group.redis[0].id              # 예: 규칙이 붙는 SG (캐시 SG)
  referenced_security_group_id = var.network_contract.node_security_group_id # 예: 상대 SG (노드와 Add-on 노드 SG)
  from_port                    = 6379                                        # 예: 6379 (Valkey · Redis)
  to_port                      = 6379                                        # 예: 6379
  ip_protocol                  = "tcp"                                       # 예: "tcp"
  description                  = "Valkey over TLS from cluster nodes"        # 예: 규칙 설명
}

# 서버리스 캐시입니다. 노드 수 · 샤드 · 파라미터 그룹이 없고, 서브넷 그룹 대신 subnet_ids 를 직접 받습니다 (AZ 2~3곳의 Intra 서브넷).
# 전송 암호화는 서버리스에서 항상 켜져 있어 끄는 인자가 없습니다 (접속 주소는 rediss:// 로만 열립니다). 저장 암호화는 kms_key_id 를 주지 않아 AWS 소유 기본 키를 씁니다.
resource "aws_elasticache_serverless_cache" "redis" {
  count = var.enable_redis ? 1 : 0 # 예: 1 (기본) / 0 (캐시 제거; 스냅샷 등 남은 자원 비용은 별도 확인)

  engine               = "valkey"                                                                     # 예: "valkey" (Redis OSS 를 잇는 오픈 소스 엔진; ElastiCache 에서 같은 프로토콜)
  name                 = "${local.name_prefix}-redis"                                                 # 예: "contract2whale-dev-eks-data-redis"
  description          = "Medusa event bus, workflow engine, locking and cache (${var.environment})." # 예: 콘솔에서 용도를 알아볼 설명
  major_engine_version = var.redis.major_engine_version                                               # 예: "8" (주 버전만 받습니다 — 부 버전은 AWS 가 올립니다)

  subnet_ids         = var.network_contract.intra_subnet_ids # 예: ["subnet-0ia…", "subnet-0ib…", "subnet-0ic…"] (인터넷 기본 경로가 없는 서브넷)
  security_group_ids = [aws_security_group.redis[0].id]      # 예: 위 SG 하나

  # 최소 용량은 정하지 않고 상한만 정합니다. 저장량과 처리량의 상한을 제어하며 실행 시간·최소 과금·스냅샷 등의 비용은 별도로 확인합니다.
  cache_usage_limits {
    data_storage {
      maximum = var.redis.max_data_storage_gb # 예: 1 (GB)
      unit    = "GB"                          # 예: "GB" (유일한 단위)
    }

    ecpu_per_second {
      maximum = var.redis.max_ecpu_per_second # 예: 5000 (초당 ECPU)
    }
  }

  snapshot_retention_limit = var.redis.snapshot_retention_days                      # 예: 1 (0 이면 스냅샷을 만들지 않음)
  daily_snapshot_time      = var.redis.snapshot_retention_days > 0 ? "17:00" : null # 예: "17:00" UTC (서울 새벽 2시 — RDS 백업 창과 같은 시간대)

  lifecycle {
    precondition {
      condition     = length("${local.name_prefix}-redis") <= 40 # 예: "contract2whale-dev-eks-data-redis" (30자) 통과 — 서버리스 캐시 이름은 40자까지
      error_message = "The cache name (<cluster>-data-redis) must not exceed 40 characters; shorten the cluster name."
    }

    precondition {
      condition     = var.environment != "prod" || var.redis.snapshot_retention_days >= 1 # 예: Prod 는 하루치 이상
      error_message = "A prod cache requires at least one day of snapshots."
    }
  }

  depends_on = [terraform_data.guard] # 예: 계약 검사를 통과한 뒤에 만듭니다
}
