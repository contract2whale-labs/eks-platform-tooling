# kafka-network.tf — network/vpc 루트 모듈 (dev · prod 공통 코드)
# 브로커 자체는 만들지 않습니다 (dev/platform/queue 루트 모듈이 이 계약을 입력으로 받습니다). 관련 구성 · 관련 구성 이 만든 파일은 고치지 않고 이 파일만 더합니다.

locals {
  # 관리형 브로커의 네트워크 인터페이스를 놓을 서브넷입니다. 인터넷 경로가 없는 Intra 서브넷을 AZ 마다 하나씩 씁니다.
  # AZ 이름을 키로 두어 목록 순서가 바뀌어도 대응이 흔들리지 않게 합니다.
  kafka_broker_subnet_ids_by_az = {
    for index, az in var.availability_zones : az => module.vpc.intra_subnets[index] # 예: {"ap-northeast-2a" = "subnet-0iii..."} (AZ 별 Intra 서브넷 1개)
  }

  # 브로커 서브넷의 주소 범위입니다. 클러스터 안 클라이언트의 NetworkPolicy(egress 9096)가 이 값을 씁니다.
  kafka_broker_subnet_cidrs_by_az = {
    for index, az in var.availability_zones : az => local.intra_subnets[index] # 예: {"ap-northeast-2a" = "172.20.12.0/28"}
  }

  # TLS 위의 SASL/SCRAM 사용자 인증 리스너의 포트입니다. 인증 방식이 다르면 포트도 다릅니다 (무인증 9092 · TLS 9094 · IAM 9098).
  kafka_client_port = 9096 # 예: 9096 (이 과정이 쓰는 클라이언트 경로 포트)
}

# 관리형 브로커의 네트워크 인터페이스에 붙일 Security Group 입니다.
# 이 루트 모듈에서 만들고 브로커를 만드는 구성이 입력으로 받습니다.
resource "aws_security_group" "kafka_brokers" {
  name        = "${local.vpc_name}-kafka-brokers"         # 예: "cp-dev-kafka-brokers" (계정 · VPC 안 식별용 이름, 생성 후 변경 불가)
  description = "Managed Kafka broker network interfaces" # 예: 콘솔 설명 (생성 후 변경 시 교체 발생)
  vpc_id      = module.vpc.vpc_id                         # 예: "vpc-0123456789abcdef0" (Security Group 이 소속될 VPC)

  tags = merge(local.common_tags, {
    Name = "${local.vpc_name}-kafka-brokers" # 예: "cp-dev-kafka-brokers" (콘솔 목록 식별용 Name 태그)
  })

  lifecycle {
    # 브로커 배치 대상은 3 AZ에 나눕니다. 쓰기 지속은 실제 ISR·leader·클라이언트 연결·가용 용량으로 따로 판정합니다.
    precondition {
      condition     = length(local.kafka_broker_subnet_ids_by_az) == 3                # 예: 3 == 3 (AZ 가 3개가 아니면 계획 단계에서 중단)
      error_message = "This course requires exactly three broker availability zones." # 예: 실패 시 표시할 문장
    }
  }
}

# 브로커에 접속하는 쪽(노드와 Pod)에 붙일 Security Group 입니다.
resource "aws_security_group" "kafka_clients" {
  name        = "${local.vpc_name}-kafka-clients"         # 예: "cp-dev-kafka-clients" (계정 · VPC 안 식별용 이름)
  description = "Workloads that connect to Kafka brokers" # 예: 콘솔 설명 (생성 후 변경 시 교체 발생)
  vpc_id      = module.vpc.vpc_id                         # 예: "vpc-0123456789abcdef0" (Security Group 이 소속될 VPC)

  tags = merge(local.common_tags, {
    Name = "${local.vpc_name}-kafka-clients" # 예: "cp-dev-kafka-clients" (콘솔 목록 식별용 Name 태그)
  })
}

# 클라이언트가 브로커로 들어오는 경로입니다.
# 출발지를 주소 범위가 아니라 Security Group 참조로 적어 접속 주체를 이름으로 남깁니다.
resource "aws_vpc_security_group_ingress_rule" "brokers_from_clients" {
  security_group_id            = aws_security_group.kafka_brokers.id                      # 예: "sg-0broker..." (규칙이 붙을 브로커 Security Group)
  description                  = "Kafka clients to brokers on the TLS user auth listener" # 예: 규칙 목록에서 용도를 구분하는 설명
  referenced_security_group_id = aws_security_group.kafka_clients.id                      # 예: "sg-0client..." (출발지를 소속으로 지정)
  ip_protocol                  = "tcp"                                                    # 예: "tcp" (프로토콜 번호 6)
  from_port                    = local.kafka_client_port                                  # 예: 9096 (단일 포트이므로 to 와 같은 값)
  to_port                      = local.kafka_client_port                                  # 예: 9096 (단일 포트이므로 from 과 같은 값)
}

# 클라이언트가 브로커로 연결을 시작할 수 있게 나가는 경로를 엽니다.
# Security Group 은 상태를 기억하므로 응답은 규칙 없이 돌아갑니다.
resource "aws_vpc_security_group_egress_rule" "clients_to_brokers" {
  security_group_id            = aws_security_group.kafka_clients.id                      # 예: "sg-0client..." (규칙이 붙을 클라이언트 Security Group)
  description                  = "Kafka clients to brokers on the TLS user auth listener" # 예: 규칙 목록에서 용도를 구분하는 설명
  referenced_security_group_id = aws_security_group.kafka_brokers.id                      # 예: "sg-0broker..." (목적지를 소속으로 지정)
  ip_protocol                  = "tcp"                                                    # 예: "tcp" (프로토콜 번호 6)
  from_port                    = local.kafka_client_port                                  # 예: 9096 (클라이언트 경로 포트)
  to_port                      = local.kafka_client_port                                  # 예: 9096 (단일 포트)
}

# 브로커끼리의 복제와 내부 조정 경로입니다. 자기 Security Group 을 참조합니다.
# 내부 리스너의 정확한 포트 번호는 검증 불가이므로 대상이 브로커 인터페이스로 한정된 TCP 전체 범위입니다.
# GetBootstrapBrokers 의 9096 으로 내부 포트를 추정하지 않습니다.
resource "aws_vpc_security_group_ingress_rule" "brokers_between" {
  security_group_id            = aws_security_group.kafka_brokers.id             # 예: "sg-0broker..." (규칙이 붙을 브로커 Security Group)
  description                  = "Broker to broker replication and coordination" # 예: 규칙 목록에서 용도를 구분하는 설명
  referenced_security_group_id = aws_security_group.kafka_brokers.id             # 예: "sg-0broker..." (같은 Security Group 을 출발지로 지정)
  ip_protocol                  = "tcp"                                           # 예: "tcp" (프로토콜 번호 6)
  from_port                    = 0                                               # 예: 0 (조회로 확인하기 전의 시작 포트)
  to_port                      = 65535                                           # 예: 65535 (내부 경로 근거 확보 전 임의 축소 금지)
}

# 브로커를 만드는 구성이 이 계약 하나만 받으면 됩니다.
output "kafka_network_contract" {
  description = "Kafka broker and client security groups, broker subnets by AZ and the client listener port."
  value = {
    broker_security_group_id = aws_security_group.kafka_brokers.id # 예: "sg-0broker..." (브로커 인터페이스에 붙일 Security Group)
    client_security_group_id = aws_security_group.kafka_clients.id # 예: "sg-0client..." (접속하는 쪽에 붙일 Security Group)
    broker_subnet_ids_by_az  = local.kafka_broker_subnet_ids_by_az # 예: {"ap-northeast-2a" = "subnet-0iii...", ...} (AZ 3개)
    broker_port              = local.kafka_client_port             # 예: 9096 (설정과 규칙이 같은 값을 쓰게 함)
  }
}

# 클러스터 안 클라이언트의 정책(egress 9096)이 쓰는 주소 범위입니다. 계약과 달리 ID 가 아니라 CIDR 이므로 따로 냅니다.
output "kafka_broker_subnet_cidrs_by_az" {
  description = "IPv4 CIDR of each broker subnet, keyed by availability zone."
  value       = local.kafka_broker_subnet_cidrs_by_az # 예: {"ap-northeast-2a" = "172.20.12.0/28", ...}
}
