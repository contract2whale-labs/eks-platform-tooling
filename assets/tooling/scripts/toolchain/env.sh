# 사용: source "$TOOLING_ROOT/scripts/toolchain/env.sh"      (bash · zsh 공통)
# 1) 호스트 준비 모드에서는 이미 준비한 호스트 도구의 PATH를 유지합니다.
# 2) 일반 asdf 실행과 Dev Container에서는 고정 버전 기준을 내보냅니다.
# 3) 개인 설정(work/lab.env)이 있으면 불러와 내보냅니다.
if [ "${PLATFORM_DEVCONTAINER:-0}" != 1 ] && [ "${PLATFORM_HOST_PREPARATION:-0}" != 1 ]; then
  export PATH="${ASDF_DATA_DIR:-$HOME/.asdf}/shims:$HOME/.local/bin:$PATH"
fi
export AWS_PAGER=""
if { [ "${PLATFORM_HOST_PREPARATION:-0}" != 1 ] || [ "${PLATFORM_DEVCONTAINER:-0}" = 1 ]; } && [ -n "${TOOLING_ROOT:-}" ] && [ -f "$TOOLING_ROOT/scripts/toolchain/tool-versions" ]; then
  while read -r _lab_tool _lab_version; do
    [ -n "$_lab_tool" ] || continue
    _lab_var="ASDF_$(printf '%s' "$_lab_tool" | tr '[:lower:]-' '[:upper:]_')_VERSION"
    export "$_lab_var=$_lab_version"
  done < "$TOOLING_ROOT/scripts/toolchain/tool-versions"
  unset _lab_tool _lab_version _lab_var
fi
if [ -n "${TOOLING_ROOT:-}" ] && [ -f "$TOOLING_ROOT/work/lab.env" ]; then
  set -a
  . "$TOOLING_ROOT/work/lab.env"
  set +a
fi
if [ "${PLATFORM_DEVCONTAINER:-0}" = 1 ]; then
  export TOOLING_ROOT=/workspace/eks-platform-tooling
  export INFRA_ROOT=/workspace/cloud-platform-infrastructure
  export WEB_ROOT=/workspace/commerce-web
  export API_ROOT=/workspace/commerce-api
fi
