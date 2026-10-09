#!/usr/bin/env bash
# platform/environments/dev/observability/tests/check-rules.sh
# 대시보드 연결: PrometheusRule(gitops/platform/monitoring-resources/overlays/dev/80-application-rules.yaml)의 spec.groups 를 promtool 규칙 파일로 뽑아 문법 검사(promtool check rules)와 단위 시험(promtool test rules; tests/application-rules.test.yaml)을 돌립니다. 클러스터 · AWS 호출 없음.
# promtool 이 PATH 에 없으면 docker 의 공식 Prometheus 이미지로 대신 돌립니다 (둘 다 없으면 INCONCLUSIVE 2).
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REPO=$(cd "$ROOT/../../../.." && pwd) # 예: cloud-platform-infrastructure 저장소 루트
PROMETHEUS_IMAGE="${PROMETHEUS_IMAGE:-quay.io/prometheus/prometheus:v3.9.1}" # 예: docker 대체 실행용 (현재 승인한 Prometheus 버전과 맞춰 고정; 도구 부재는 미실행으로 기록)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/prometheus-rules.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
yq '{"groups": .spec.groups}' "$REPO/gitops/platform/monitoring-resources/overlays/dev/80-application-rules.yaml" > "$WORK/application-rules.yaml" # 예: PrometheusRule → promtool 형식
cp "$ROOT/tests/application-rules.test.yaml" "$WORK/"
if command -v promtool > /dev/null; then
  RUN=(promtool)
elif command -v docker > /dev/null && docker info > /dev/null 2>&1; then
  RUN=(docker run --rm -v "$WORK:/work:ro" -w /work --entrypoint promtool "$PROMETHEUS_IMAGE") # 예: 이미지 안의 promtool
  WORK_IN=/work
else
  echo 'INCONCLUSIVE promtool or docker is required'; exit 2
fi
cd "$WORK"
"${RUN[@]}" check rules "${WORK_IN:-.}/application-rules.yaml"
"${RUN[@]}" test rules "${WORK_IN:-.}/application-rules.test.yaml"
echo "check-rules: PASS (groups=$(yq '.groups | length' application-rules.yaml), rules=$(yq '[.groups[].rules[]] | length' application-rules.yaml), tests=$(yq '.tests | length' application-rules.test.yaml))"
