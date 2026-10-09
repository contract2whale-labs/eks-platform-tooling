# tools/database-operator/Dockerfile — 초기화(bootstrap.sh) · 진단(operator-check.sh) Job 의 실행 환경 (데이터베이스 운영자 이미지와 읽기 전용 진단). bash · jq · psql(PostgreSQL 17 클라이언트) · AWS CLI v2 · RDS CA 묶음만 들어 있고 python 은 없습니다.
# 빌드: bash tools/database-operator/build.sh (image.lock.env 의 digest · 해시를 --build-arg 로 전달, --platform linux/amd64; 빌드 컨텍스트는 build.sh 가 data/lib · data/operator 를 모아 만든 임시 디렉터리).
# 이미지 안에 AWS 자격 증명 · DB 비밀번호는 없습니다 — Pod Identity(Pod Identity 재사용 모듈 operator Role) 가 실행 시점에 줍니다.
ARG BASE_IMAGE=public.ecr.aws/amazonlinux/amazonlinux:2023
ARG BASE_IMAGE_DIGEST
FROM ${BASE_IMAGE}@${BASE_IMAGE_DIGEST}
ARG AWSCLI_VERSION
ARG AWSCLI_ZIP_SHA256
ARG POSTGRESQL_CLIENT_PACKAGE=postgresql17
ARG RDS_CA_BUNDLE_URL
ARG RDS_CA_BUNDLE_SHA256
# 예: 설치 스크립트(install-*.sh)와 잠금 파일을 한 곳에 (install-*.sh 는 해시가 다르면 빌드를 중단)
COPY image.lock.env install-awscli.sh install-rds-ca.sh smoke.sh /opt/contract2whale/tools/
RUN dnf -y install bash jq unzip tar gzip curl-minimal ca-certificates shadow-utils "${POSTGRESQL_CLIENT_PACKAGE}" && dnf clean all
RUN AWSCLI_VERSION="${AWSCLI_VERSION}" AWSCLI_ZIP_SHA256="${AWSCLI_ZIP_SHA256}" bash /opt/contract2whale/tools/install-awscli.sh
RUN RDS_CA_BUNDLE_URL="${RDS_CA_BUNDLE_URL}" RDS_CA_BUNDLE_SHA256="${RDS_CA_BUNDLE_SHA256}" bash /opt/contract2whale/tools/install-rds-ca.sh
# 예: 운영자 프로그램 (data/lib · data/operator 를 build.sh 가 컨텍스트에 복사)
COPY lib/ /opt/contract2whale/lib/
COPY operator/ /opt/contract2whale/operator/
# 예: 빌드 시점에 도구 버전을 한 번 확인 (네트워크 없이 실행 가능)
RUN bash /opt/contract2whale/tools/smoke.sh
RUN useradd --uid 1000 --create-home operator
USER operator
ENV OPERATOR_HOME=/opt/contract2whale/operator OPERATOR_LIB=/opt/contract2whale/lib/common.sh RDS_CA_BUNDLE=/opt/contract2whale/certs/rds-global-bundle.pem
WORKDIR /home/operator
CMD ["bash", "/opt/contract2whale/operator/operator-check.sh"]
