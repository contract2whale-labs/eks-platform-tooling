#!/usr/bin/env bash
# 사용: bash "$TOOLING_ROOT/scripts/toolchain/check-tools.sh" [도구 ...]   (인자가 없으면 전체 검사)
# tool-versions 의 고정 버전과 실제 실행 파일 버전을 비교합니다. 하나라도 다르면 종료 코드 2.
set -euo pipefail
DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS="$DIR/tool-versions"

binary_of() {
  case "$1" in
    awscli) printf aws ;; golang) printf go ;; nodejs) printf node ;; python) printf python3 ;; argo-rollouts) printf kubectl-argo-rollouts ;; *) printf '%s' "$1" ;;
  esac
}

actual_version() {
  case "$1" in
    session-manager-plugin) session-manager-plugin --version ;;
    terraform) terraform version | awk 'NR == 1 { sub(/^Terraform v/, ""); print }' ;;
    kubectl) kubectl version --client -o yaml | awk '/gitVersion:/ && !seen { sub(/^v/, "", $2); print $2; seen = 1 }' ;;
    helm) helm version --template '{{.Version}}' | sed 's/^v//' ;;
    awscli) aws --version 2>&1 | sed -E 's#^aws-cli/([^ ]+).*#\1#' ;;
    golang) go env GOVERSION | sed 's/^go//' ;;
    nodejs) node --version | sed 's/^v//' ;;
    python) python3 --version 2>&1 | awk '{ print $2 }' ;;
    istioctl) istioctl version --remote=false 2>/dev/null | sed -E 's/^client version: //' | head -1 ;;
    kubeconform) kubeconform -v 2>&1 | sed 's/^v//' | head -1 ;;
    argocd) argocd version --client --short 2>/dev/null | sed -E 's/^argocd: v([^+]+).*/\1/' ;;
    argo-rollouts) kubectl-argo-rollouts version --short 2>/dev/null | sed -E 's/^kubectl-argo-rollouts: v([^+]+).*/\1/' ;;
    kyverno) kyverno version 2>/dev/null | awk '/^Version:/ { sub(/^v/, "", $2); print $2 }' ;;
    cosign) cosign version 2>&1 | awk '/^GitVersion:/ { sub(/^v/, "", $2); print $2 }' ;;
    syft) syft version 2>/dev/null | awk '/^Version:/ { print $2 }' ;;
    trivy) trivy version 2>/dev/null | awk 'NR == 1 && /^Version:/ { print $2 }' ;;
    kustomize) kustomize version 2>/dev/null | sed -E 's/^v//' ;;
    actionlint) actionlint -version 2>/dev/null | head -1 ;;
    tflint) tflint --version | awk 'NR == 1 { print $3 }' ;;
    zizmor) zizmor --version | awk '{ print $2 }' ;;
    promtool) promtool --version | awk 'NR == 1 { print $3 }' ;;
    yq) yq --version | sed -E 's/.*version v//' ;;
    *) printf 'unknown' ;;
  esac
}

tools=("$@")
if [ ${#tools[@]} -eq 0 ]; then
  while read -r name _; do [ -n "$name" ] && tools+=("$name"); done < "$VERSIONS"
fi

status=0
shims="${ASDF_DATA_DIR:-$HOME/.asdf}/shims"
for tool in "${tools[@]}"; do
  want="$(awk -v t="$tool" '$1 == t { print $2 }' "$VERSIONS")"
  if [ -z "$want" ]; then
    printf 'TOOLCHAIN_UNKNOWN\t%s\n' "$tool"; status=2; continue
  fi
  bin="$(binary_of "$tool")"
  path="$(command -v "$bin" || true)"
  if [ -z "$path" ]; then
    printf 'TOOLCHAIN_MISSING\t%s\twant=%s\n' "$tool" "$want"; status=2; continue
  fi
  have="$(actual_version "$tool" 2>/dev/null || printf 'error')"
  if [ "$have" != "$want" ]; then
    printf 'TOOLCHAIN_MISMATCH\t%s\twant=%s\thave=%s\tpath=%s\n' "$tool" "$want" "$have" "$path"; status=2; continue
  fi
  case "$path" in
    "$shims"/*) printf 'TOOLCHAIN_OK\t%s\t%s\n' "$tool" "$have" ;;
    *) printf 'TOOLCHAIN_OK\t%s\t%s\t(asdf shim 이 아닌 경로: %s)\n' "$tool" "$have" "$path" ;;
  esac
done
if command -v jq > /dev/null; then printf 'SYSTEM_OK\tjq\t%s\n' "$(jq --version)"; else printf 'SYSTEM_MISSING\tjq\n'; status=2; fi
exit "$status"
