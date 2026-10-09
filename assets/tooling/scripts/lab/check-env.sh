#!/usr/bin/env bash
# 사용: bash "$TOOLING_ROOT/scripts/lab/check-env.sh" KEY [KEY ...]
# 개인 설정 파일(work/lab.env)에서 지정한 키가 채워져 있고 형식이 맞는지 확인합니다.
# 모두 통과하면 ENV_OK, 하나라도 실패하면 종료 코드 2.
set -euo pipefail
file="${LAB_ENV_FILE:-${TOOLING_ROOT:?TOOLING_ROOT 를 먼저 export 하세요}/work/lab.env}"
[ -f "$file" ] || { echo "ENV_MISSING_FILE $file" >&2; exit 2; }
perm="$(ls -l "$file" | awk '{ print substr($1, 1, 10) }')" # 예: macOS 는 확장 속성·ACL 표시(@, +)가 붙으므로 앞 10자만 비교
set -a
# shellcheck disable=SC1090
. "$file"
set +a
status=0
[ "$perm" = "-rw-------" ] || { printf 'ENV_BAD_PERMISSION\t%s\t%s (chmod 600 필요)\n' "$file" "$perm"; status=2; }
for key in "$@"; do
  value="${!key:-}"
  if [ -z "$value" ] || [[ "$value" == /REPLACE* ]]; then
    printf 'ENV_EMPTY\t%s\n' "$key"; status=2; continue
  fi
  case "$key" in
    *_ACCOUNT_ID) pattern='^[0-9]{12}$' ;;
    *_ROLE_ARN) pattern='^arn:aws:iam::[0-9]{12}:role/.+$' ;;
    *_ZONE_ID) pattern='^Z[A-Z0-9]+$' ;;
    *_STATE_BUCKET) pattern='^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$' ;;
    AWS_REGION | SSO_REGION) pattern='^[a-z]{2}(-[a-z]+)+-[0-9]$' ;;
    GITHUB_ORG) pattern='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$' ;;
    SSO_START_URL) pattern='^https://.+' ;;
    TOOLING_ROOT | INFRA_ROOT | WEB_ROOT | API_ROOT) pattern='^/.+' ;;
    *) pattern='.+' ;;
  esac
  if [[ "$value" =~ $pattern ]]; then
    printf 'ENV_OK\t%s\n' "$key"
  else
    printf 'ENV_BAD_FORMAT\t%s\t%s\n' "$key" "$value"; status=2
  fi
done
exit "$status"
