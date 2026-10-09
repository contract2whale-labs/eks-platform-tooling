# 사용: 호스트 앱 터미널에서 source "$TOOLING_ROOT/scripts/toolchain/app-env.sh"
# 로컬 Compose 포트와 앱 프로세스는 같은 호스트의 localhost를 사용합니다.
if [ "${PLATFORM_DEVCONTAINER:-0}" = 1 ]; then
  printf '%s\n' '앱 로컬 개발은 호스트 터미널에서 실행합니다. DevContainer는 플랫폼·SSM·Kubernetes 작업에 사용합니다.' >&2
  return 1 2>/dev/null || exit 1
fi
if [ -z "${TOOLING_ROOT:-}" ]; then
  printf '%s\n' 'Set TOOLING_ROOT to the host tooling checkout first.' >&2
  return 1 2>/dev/null || exit 1
fi
export PLATFORM_HOST_PREPARATION=1
. "$TOOLING_ROOT/scripts/toolchain/env.sh" || { return 1 2>/dev/null || exit 1; }
export ASDF_NODEJS_VERSION=22.12.0
_app_node_install="$(asdf where nodejs 22.12.0)" || { return 1 2>/dev/null || exit 1; }
export PATH="$_app_node_install/bin:$PATH"
unset _app_node_install
if [ "$(node --version)" != v22.12.0 ] || [ "$(pnpm --version)" != 10.11.1 ]; then
  printf '%s\n' '앱 계약 Node 22.12.0·pnpm 10.11.1을 먼저 설치한 뒤 app-env.sh를 다시 읽습니다.' >&2
  return 1 2>/dev/null || exit 1
fi
printf '%s\n' 'APP_TOOLCHAIN_OK node=22.12.0 pnpm=10.11.1 host_localhost=true'
