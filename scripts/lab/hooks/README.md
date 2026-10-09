# scripts/lab/hooks

`steps.tsv` 의 `hook` 단계가 실행하는 챕터별 스크립트입니다. 파일 이름은 `<target>.sh` 입니다.

- 첫 번째 인자로 `up` 또는 `down` 을 받습니다. 해당 동작이 없으면 아무것도 하지 않고 0 으로 끝냅니다.
- 여러 번 실행해도 결과가 같아야 합니다 (`helm upgrade --install`, `kubectl apply`, 존재 확인 후 삭제).
- `AWS_PROFILE` 은 lab.sh 가 단계의 계정에 맞춰 지정합니다. lab.env 값은 환경 변수로 전달됩니다.
- `steps.tsv`에 등록된 순서로 실행됩니다. 개별 hook을 실행하기 전에 해당 챕터의 입력과 선행 상태를 확인합니다.

## 등록된 hook

| hook | up | down |
|---|---|---|
| `platform-core` | BU08 설치 순서와 같은 명령 (cert-manager 등) | 설치 역순 삭제 |
| `platform-mesh` | Istio ambient 1.30.4 설치 | Istio 삭제 (CRD 포함) |
| `platform-gateway` | Gateway API CRD · LBC · Envoy Gateway · ExternalDNS | 역순 삭제 (NLB 소멸 대기) |
| `platform-operations` | BU10A-T2 `install.sh` 4종과 같은 순서 (metrics-server · Autoscaler · External Secrets · Fluent Bit · Velero) | Velero 백업 · EBS 스냅샷 정리까지 |
| `platform-alerting` | 다른 루트 모듈(`dev/platform/operations`)의 두 번째 `apply` 를 맡는 hook — `alerts_topic_arn` 을 채우며 리소스 변경 0 (클러스터 미접속) | 없음 |
| `platform-observability` | BU10B install.sh 순서와 같은 명령 (지표 · 로그 · 수집기 · Kafka · Tempo · 대시보드 · 발송 경로) | 발송 경로 → Tempo → Kafka(PVC · CRD 3종) → 수집기 → 전반부 역순 |
| `platform-queue` | BU10C T3~T6 스크립트 순서(주제 · ACL · 병렬 Tempo e2 · 세대 전환) | epoch 1 복원 → e3 · e2 uninstall → BU10C 객체 · 관리 비밀 정리 (MSK 자체는 tf 100) |
| `platform-delivery` | BU12-T10 `bootstrap.sh` 와 같은 명령(비밀 사본 3 · Argo CD helm install · AppProject 2 · 루트 Application) → App-of-Apps 자식 5개가 Healthy 될 때까지 대기 (deploy key 비밀 · gitops 커밋 필요) | 자식 Application(finalizer 로 chart · 정책 · 앱 리소스 삭제) → 루트 → AppProject → helm uninstall argocd → 잔존 CRD → 네임스페이스 4개 |
