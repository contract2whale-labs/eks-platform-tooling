# EKS Platform Tooling

강의 배포본 `eks-terraform-course-v6-194-revised-20261008(1).zip`의 tooling을 GitHub 게시용으로 구성한 패키지입니다.

## 구성

- 루트의 `scripts/`, `tests/`, `images/`, 도구 설정: 강의 `assets/tooling/` 원본 46개 파일
- `install-tooling.py`, `assets-manifest.json`: 원본 설치기와 SHA-256·권한 매니페스트
- `assets/`: 매니페스트 검증에 필요한 원본 전체 1,061개 파일. `assets/infrastructure/`도 의도적으로 포함합니다.
- 기존 공개 저장소에만 있던 hooks README 및 toolchain 스크립트 3개는 보존했습니다.
- `README.upstream.md`: 기존 README의 변경 없는 참고용 사본. 현재 패키지 사용 안내는 이 문서를 따르세요. 보존된 스크립트와 이전 README의 절차는 이번 강의 버전과의 호환성을 보장하지 않습니다.

## 사용

압축을 해제하면 `eks-platform-tooling/` 폴더가 생성됩니다. 루트 tooling은 이미 배치되어 있으므로 폴더 전체를 저장소 작업 트리로 사용할 수 있습니다. 기존 저장소에 반영할 때는 덮어쓰기 전에 diff를 검토하고, 압축 해제만으로 기존의 불필요한 파일이 제거되지는 않는다는 점에 유의하세요.

다른 위치에 원본 supporting tooling을 설치하려면 Python 3로 실행합니다.

```sh
python3 install-tooling.py --tooling-root /absolute/path/to/new-tooling
```

`--infra-root /absolute/path/to/infrastructure`는 별도로 생성한 Git 저장소에 지원 파일 일부를 설치하는 선택 옵션입니다. 전체 인프라 배포 명령이 아닙니다. 대상 파일이 다르면 설치기는 중단합니다. 내용을 검토하고 다른 쓰기 작업을 멈춘 뒤에만 `--replace-reviewed`를 사용하세요. 기존 파일의 `.before-course-update` 백업을 보존합니다.

설치기는 tooling만 설치할 때도 `assets/` 전체의 파일 목록과 해시를 검사합니다. 매니페스트에 포함된 파일을 삭제하거나 수정하지 마세요. 루트 tooling을 수정해도 `assets/tooling/`은 자동으로 동기화되지 않습니다.

## 게시 및 실행 주의

- 개인 `work/lab.env`, `.aws/`, Git 이력, 실제 Terraform state/plan/cache는 이 패키지에 포함하지 않습니다. `.example` 및 검증용 fixture는 의도적으로 유지합니다.
- AWS 계정·프로필·경로·GitHub 조직 이름을 본인 환경에 맞게 검토하세요. 원본 URL을 일괄 치환하지 않았습니다.
- 실제 AWS 작업, GitHub push, 태그 생성, 저장소 설정 변경은 수행하지 않았습니다. 라이프사이클 및 설치 스크립트 실행 전 해당 강의와 코드를 검토하세요.
- 파일 무결성 및 정적 검사는 실제 클라우드 배포 성공이나 비밀정보 부재의 절대적인 보장이 아닙니다.

## 원본

- 강의 ZIP SHA-256: `4e12b83082ad2fed75f5b4d8c8d8240f84b401c529e7466cf9351fdb0890e69e`
- 보존 파일 출처: https://github.com/contract2whale-labs/eks-platform-tooling/tree/3124cc8c4d81dec0a82ac06c205eea5604f5f2ef
