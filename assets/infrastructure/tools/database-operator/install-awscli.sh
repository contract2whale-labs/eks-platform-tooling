#!/usr/bin/env bash
# tools/database-operator/install-awscli.sh — AWS CLI v2 를 공식 zip 으로 설치합니다 (데이터베이스 운영자 이미지와 읽기 전용 진단; tools/delivery-tools 와 같은 방식). zip 의 SHA-256 이 AWSCLI_ZIP_SHA256 과 다르면 중단합니다. Dockerfile 의 RUN 단계에서 실행됩니다.
set -euo pipefail
: "${AWSCLI_VERSION:?}" "${AWSCLI_ZIP_SHA256:?AWSCLI_ZIP_SHA256 must be set in image.lock.env}"
tmp="$(mktemp -d)"; cd "$tmp"
curl -fsSLo awscli.zip "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWSCLI_VERSION}.zip" # 예: 버전 고정 URL
printf '%s  awscli.zip\n' "$AWSCLI_ZIP_SHA256" | sha256sum -c -                                        # 예: 해시가 다르면 여기서 종료 1
unzip -q awscli.zip && ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli          # 예: /usr/local/bin/aws
cd / && rm -rf "$tmp"
aws --version | grep -q "aws-cli/${AWSCLI_VERSION} " # 예: aws-cli/2.36.44 …
