# gitops/apps/commerce-api/overlays/ — 환경별 선언 (dev · prod)

`<env>/kustomization.yaml` 은 앱 CI(application-delivery)가 `kustomize edit set image commerce-api=<repo>@<digest>` 로 다시 쓰는 파일입니다. `kustomize edit` 는 주석을 버리고 필드 순서를 canonical 형식으로 정렬하므로, 이 파일은 **주석 없이 canonical 형식**으로 커밋합니다. 설명은 여기에 둡니다. 이미지 전달 검사는 줄 수 대신 파싱한 필드를 대조해 선택한 digest 외 설정이 그대로인지 확인합니다.

필드별 뜻:

    namespace              contract2whale-demo — 앱 네임스페이스와 수집 허용 이 만드는 테넌트 네임스페이스 (AppProject delivery 의 destination 과 같은 값)
    resources              ../../base — 환경 무관 선언 (SecretStore + ExternalSecret 2 · Deployment · Service · HTTPRoute · PreSync Job)
    images[0]              name commerce-api → newName <account>.dkr.ecr.<region>.amazonaws.com/commerce-api, digest sha256:… — CI가 승인된 저장소의 digest 필드를 갱신합니다. 마이그레이션 Job도 같은 이름을 쓰므로 한 digest가 두 곳에 들어갑니다
    configMapGenerator     commerce-api-config — commerce-api 의 .env.example 에서 **공개 값만** 옮긴 것입니다. 비밀 4개(DATABASE_URL · REDIS_URL · JWT_SECRET · COOKIE_SECRET)는 ExternalSecret 이 만드는 Secret 에 있습니다
    DB_SSL                 true — RDS 연결의 TLS 를 정하는 유일한 자리입니다. 앱 이미지는 Amazon RDS CA 묶음을 담고 있고(`DB_SSL_CA_FILE` 은 이미지의 ENV), 이 값이 true 면 그 묶음으로 서버 인증서와 호스트 이름을 검증합니다. ExternalSecret 이 조립하는 DATABASE_URL 에는 sslmode 를 붙이지 않습니다 — node-postgres 는 URL 의 sslmode 를 드라이버 옵션 위에 덮어써 CA 설정을 버리므로, 앱은 그런 URL 을 받으면 기동을 거부합니다
    MEDUSA_BACKEND_URL     `medusa-config.ts` 가 읽는 이름이라 `.env.example` 과 같은 목록으로 둡니다. 관리자 화면(`/app`) 번들은 이미지 build 때 백엔드 주소를 `/`(번들을 내려 준 origin)로 구워 두므로, 이 값은 배포된 `/app` 이 부르는 주소를 바꾸지 않습니다. `/app` · `/auth` · `/admin` 이 같은 호스트의 HTTPRoute 로 들어오는 것이 그 전제이고, 그래서 한 digest 를 Dev · Prod 가 함께 씁니다
    DB_POOL_MAX            예산은 `tests/check-db-connection-budget.sh <env>` 가 렌더 결과와 `contracts/<env>.env`(서버에서 잰 max_connections)로 계산합니다: (복제본 + surge + 종료 중 복제본) × DB_POOL_MAX + 마이그레이션 Job + 운영 몫 + 그 밖의 사용자 ≤ 실측 max_connections × 정책 % (연결 고갈; medusa-config.ts 주석의 처음 식에 surge · 종료 중 Pod 를 더한 것). PR 은 workflow commerce-api-db-budget 이 검사합니다
    S3_*                   data 의 미디어 버킷. file-s3 모듈은 authentication_method: s3-iam-role 이라 키 없이 Pod Identity 로 붙고, 암호화는 버킷 기본 암호화(SSE-KMS)가 합니다
    replacements           Deployment image 의 @ 뒤(digest) → ConfigMap RELEASE_DIGEST (단일 원천 — 배포 증거)
    patches[0] (prod)      Deployment replicas 3 (dev 는 base 의 2)
    patches (hostnames)    HTTPRoute 의 hostnames — 스토어프런트와 같은 호스트 (경로로 나뉩니다)
    patches (SecretStore)  ESO controller 가 맡을 읽기 전용 IAM 역할 ARN (data 이 만드는 역할)
    patches (ExternalSecret) Secrets Manager 비밀 이름 — contract2whale/<env>/commerce-api/runtime · /migration (데이터베이스 · KMS 키 · 시크릿 · 미디어 버킷 가 그릇을 만들고 데이터베이스 초기화 Job 이 값을 채웁니다)

저장소 루트에서 `python3 automation/check_platform_sources.py --repo .`로 source 연결을 검사합니다. CRD를 포함한 kubeconform 검사는 실제 schema 위치와 잠근 버전의 schema를 준비한 뒤 별도로 실행하며, schema 미공급 상태는 미실행으로 기록합니다.
