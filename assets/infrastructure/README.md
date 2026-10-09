# Cloud Platform Infrastructure

이 저장소에서는 Dev와 Prod를 별도 AWS 계정과 Terraform 실행 디렉터리로 관리합니다. 먼저 변경할 계정과 root를 확인하고, 작업 브랜치에서 해당 파일을 IDE로 수정합니다. PR의 검사와 동료 리뷰가 끝나면 승인된 revision으로 적용할 계획을 다시 확인합니다.

```text
작업 브랜치의 파일 수정
          |
          v
PR -> CI 결과와 변경 영향 검토 -> main 병합
                                  |
                 +----------------+----------------+
                 |                                 |
                 v                                 v
      Terraform plan 확인과 적용          Argo diff 확인과 동기화
                 |                                 |
                 +----------------+----------------+
                                  |
                                  v
                   서비스 동작 확인 -> 결과 기록
```

AWS 인프라와 EKS managed add-on은 Terraform이 관리합니다. 각 root는 default workspace와 독립된 S3 State key를 사용합니다. `backend.hcl`, State, plan과 실제 credential은 커밋하지 않고, 비민감 설정과 예시 및 lockfile은 리뷰에 포함합니다.

이 번들의 `assets/infrastructure/`는 지원 도구와 후속 구성의 참고 파일입니다. 기초 VPC·EKS 등의 완전한 구성은 앞쪽 강의의 파일 위치와 코드를 따라 작성합니다. 예를 들어 여기의 `modules/eks/nodes.tf`는 나중에 Cluster Autoscaler를 도입하며 수정할 파일만 담고 있으므로, 이 참고 디렉터리 전체를 완성된 Terraform 저장소처럼 실행하지 않습니다. 최초 설치기는 지원 도구만 배치합니다. CI는 수강생이 실제 저장소에 작성한 root와 module을 검사하며, 아직 소비 root나 mock 테스트가 없는 모듈은 Draft 단계에서 완성합니다.

지속적으로 유지할 Kubernetes 선언은 `gitops/`에 저장하고 담당 Argo Application으로 변경합니다. Namespace는 공유 namespaces Application에서 관리하며, controller가 생성한 Pod와 StatefulSet은 상위 선언을 통해 변경합니다. 비밀 값은 외부 Secret 저장소에서 ESO로 동기화하고 Git이나 일반 로그에 기록하지 않습니다. 인증 정보가 없는 설정도 구성 요소의 API가 Secret 입력을 요구하면 그 제약과 용도를 원고에 명시합니다.

PR 검사는 현재 등록된 Application을 고정 버전의 Helm·Kustomize로 렌더링하고, 함께 선언된 CRD의 타입과 필드를 대조합니다. 렌더링 성공과 실제 Kubernetes API의 허용, controller가 만든 리소스의 준비 상태는 각각 확인합니다. 검사 대상이 아직 없거나 실제 기능을 실행하지 않은 경우 그 범위를 결과에 표시합니다.

일시 진단은 대상 namespace와 권한을 확인한 뒤 실행하고, 수집이 끝나면 진단 객체를 정리합니다. Dev에서 실제로 검증한 이미지 digest를 Prod 승격에 사용하며, 적용 후에는 rollout 상태뿐 아니라 사용자 요청이 성공하는지도 확인합니다. `docs/execution/`에는 source revision, 대상, 시각과 실제 결과를 남겨 다음 작업자가 같은 근거를 확인할 수 있게 합니다.
