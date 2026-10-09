#!/usr/bin/env bash
# tools/database-operator/install-rds-ca.sh — RDS 전역 CA 묶음을 받아 해시를 확인하고 이미지에 넣습니다 (데이터베이스 운영자 이미지와 읽기 전용 진단). RDS_CA_BUNDLE_SHA256 과 다르면 중단합니다. Dockerfile 의 RUN 단계에서 실행됩니다.
set -euo pipefail
: "${RDS_CA_BUNDLE_URL:?}" "${RDS_CA_BUNDLE_SHA256:?RDS_CA_BUNDLE_SHA256 must be set in image.lock.env}"
mkdir -p /opt/contract2whale/certs
curl -fsSLo /opt/contract2whale/certs/rds-global-bundle.pem "$RDS_CA_BUNDLE_URL"                                # 예: 전역 묶음 (약 100 KB)
printf '%s  /opt/contract2whale/certs/rds-global-bundle.pem\n' "$RDS_CA_BUNDLE_SHA256" | sha256sum -c -           # 예: 해시가 다르면 여기서 종료 1
openssl crl2pkcs7 -nocrl -certfile /opt/contract2whale/certs/rds-global-bundle.pem | openssl pkcs7 -print_certs -noout # 승인한 bundle을 인증서로 파싱합니다. 실제 연결은 psql verify-full로 확인합니다.
chmod 0444 /opt/contract2whale/certs/rds-global-bundle.pem
