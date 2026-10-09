#!/usr/bin/env bash
# tools/database-operator/build.sh — 운영자 이미지를 로컬에서 빌드하고 네트워크 없이 확인합니다 (데이터베이스 운영자 이미지와 읽기 전용 진단). ECR 게시는 하지 않습니다 (데이터 초기화와 Argo CD 배포 최초 적용의 별도 단계).
# 사용: bash tools/database-operator/build.sh [operator [태그]] — 기본 태그 database-operator:local. image.lock.env 의 digest · 해시가 비어 있으면 중단합니다.
# 별도의 migration 이미지는 없습니다: Medusa 의 스키마 변경은 Argo CD PreSync Job 이 앱 이미지(commerce-api)로 medusa db:migrate 를 돌려서 합니다 (마이그레이션 실행과 재기동).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)   # 예: <INFRA_ROOT>/tools/database-operator
REPO=$(cd "$ROOT/../.." && pwd)                      # 예: <INFRA_ROOT> (data/lib · data/operator 를 컨텍스트에 모음)
. "$ROOT/image.lock.env"
KIND="${1:-operator}"

case "$KIND" in
  operator)
    TAG="${2:-database-operator:local}"
    for v in BASE_IMAGE_DIGEST AWSCLI_ZIP_SHA256 RDS_CA_BUNDLE_SHA256; do eval "val=\${$v:-}"; [ -n "$val" ] || { echo "$v is empty in image.lock.env — record the official hash first" >&2; exit 2; }; done
    CONTEXT="$(mktemp -d "${TMPDIR:-/tmp}/database-operator-context.XXXXXX")"; trap 'rm -rf "$CONTEXT"' EXIT
    cp "$ROOT/image.lock.env" "$ROOT"/*.sh "$CONTEXT/" && cp -R "$REPO/data/lib" "$CONTEXT/lib" && cp -R "$REPO/data/operator" "$CONTEXT/operator" # 예: 저장소 전체가 아니라 필요한 파일만 컨텍스트로
    docker build --platform "$TARGET_PLATFORM" --tag "$TAG" --file "$ROOT/Dockerfile" \
      --build-arg BASE_IMAGE="$BASE_IMAGE" --build-arg BASE_IMAGE_DIGEST="$BASE_IMAGE_DIGEST" \
      --build-arg AWSCLI_VERSION="$AWSCLI_VERSION" --build-arg AWSCLI_ZIP_SHA256="$AWSCLI_ZIP_SHA256" \
      --build-arg POSTGRESQL_CLIENT_PACKAGE="$POSTGRESQL_CLIENT_PACKAGE" \
      --build-arg RDS_CA_BUNDLE_URL="$RDS_CA_BUNDLE_URL" --build-arg RDS_CA_BUNDLE_SHA256="$RDS_CA_BUNDLE_SHA256" "$CONTEXT" # 예: 빌드 로그는 호출자가 파일로 저장
    docker run --rm --platform "$TARGET_PLATFORM" --network none --entrypoint bash "$TAG" /opt/contract2whale/tools/smoke.sh # 예: {"bash":"5.2.…","jq":"1.7.1","awscli":"2.36.44","psql":"17.x","rds_ca_bundle":"present","programs":"bootstrap.sh operator-check.sh","arch":"x86_64","python3":"absent",…}
    ;;
  *) echo "usage: build.sh [operator [tag]]" >&2; exit 2 ;;
esac
docker image inspect "$TAG" --format '{{.Architecture}} {{.Os}} {{.Id}}' # 예: amd64 linux sha256:… (로컬 ID — ECR digest 가 아님)
