#!/usr/bin/env bash
# tools/database-operator/smoke.sh — 이미지 안 도구 버전을 네트워크 없이 JSON 한 줄로 냅니다 (데이터베이스 운영자 이미지와 읽기 전용 진단). docker run --network none … 으로 실행하며 Dockerfile 빌드 마지막에도 한 번 실행됩니다.
set -euo pipefail
jq -cn --arg bash "$(bash --version | head -1 | sed 's/.*version \([0-9.]*\).*/\1/')" --arg jq "$(jq --version | sed 's/^jq-//')" \
  --arg aws "$(aws --version 2>&1 | sed 's#^aws-cli/\([0-9.]*\) .*#\1#')" --arg psql "$(psql --version | awk '{print $3}')" \
  --arg ca "$( [ -f /opt/contract2whale/certs/rds-global-bundle.pem ] && printf present || printf absent)" \
  --arg programs "$(ls /opt/contract2whale/operator/*.sh 2> /dev/null | xargs -n1 basename | tr '\n' ' ' | sed 's/ $//')" \
  --arg arch "$(uname -m)" --arg python "$(command -v python3 > /dev/null 2>&1 && printf present || printf absent)" \
  '{bash: $bash, jq: $jq, awscli: $aws, psql: $psql, rds_ca_bundle: $ca, programs: $programs, arch: $arch, python3: $python, network: "not required"}'
