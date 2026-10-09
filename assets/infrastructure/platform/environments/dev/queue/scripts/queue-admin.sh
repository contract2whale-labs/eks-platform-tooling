#!/usr/bin/env bash
# 승인된 한시적 요청만 적용/제거합니다. diff와 개별 Prune 확인 승인은 먼저 수행합니다.
set +x
set -uo pipefail
: "${KUBE_CONTEXT:?Set approved context}" "${EXPECTED_ACCOUNT_ID:?Set approved account}" "${AWS_REGION:?Set approved region}"
: "${QUEUE_EKS_CLUSTER:?Set approved EKS}" "${APPROVED_GIT_REVISION:?Set approved full SHA}"
ENVIRONMENT=${ENVIRONMENT:-dev}
[[ "$ENVIRONMENT" = dev || "$ENVIRONMENT" = prod ]] || exit 2
[[ "$APPROVED_GIT_REVISION" =~ ^[0-9a-f]{40}$ ]] || exit 2
APP="platform-queue-admin-$ENVIRONMENT"
hold() { printf 'INCONCLUSIVE %s\n' "$1" >&2; exit 2; }
ACCOUNT=$(aws sts get-caller-identity --query Account --output text) || hold account-query
[ "$ACCOUNT" = "$EXPECTED_ACCOUNT_ID" ] || hold account-boundary
EKS_API=$(aws eks describe-cluster --region "$AWS_REGION" --name "$QUEUE_EKS_CLUSTER" --query cluster.endpoint --output text) || hold eks-query
CONTEXT_API=$(kubectl config view --context "$KUBE_CONTEXT" --minify -o jsonpath='{.clusters[0].cluster.server}') || hold context-query
[ -n "$EKS_API" ] && [ "$EKS_API" = "$CONTEXT_API" ] || hold context-boundary
KUBE_UID=$(kubectl --context "$KUBE_CONTEXT" -n argocd get application "$APP" -o jsonpath='{.metadata.uid}') || hold application-query
ARGO_JSON=$(argocd app get "$APP" -o json) || hold argo-query
ARGO_UID=$(printf '%s' "$ARGO_JSON" | jq -er '.metadata.uid') || hold argo-parse
[ -n "$KUBE_UID" ] && [ "$KUBE_UID" = "$ARGO_UID" ] || hold application-boundary
SOURCE_PATH=$(printf '%s' "$ARGO_JSON" | jq -er '.spec.source.path') || hold source-parse
[ "$SOURCE_PATH" = "gitops/platform/queue-admin/requests/$ENVIRONMENT" ] || hold source-boundary
unset ARGO_JSON
# 성공한 승인 SHA의 렌더 원문을 보호된 임시 파일에 저장합니다. 실패를 없음으로 처리하지 않습니다.
umask 077
WORK=$(mktemp -d "${TMPDIR:-/tmp}/queue-admin-review.XXXXXX") || hold tempdir
finish() { local rc=$?; trap - EXIT; rm -rf -- "$WORK" || rc=2; exit "$rc"; }
trap finish EXIT
trap 'exit 2' INT TERM
argocd app manifests "$APP" --revision "$APPROVED_GIT_REVISION" > "$WORK/manifests.yaml" || hold manifests-query
COUNT=$(yq ea '[select(.kind == "Pod" and .metadata.name == "queue-admin" and .metadata.namespace == "monitoring")] | length' "$WORK/manifests.yaml") || hold manifests-parse
[[ "$COUNT" =~ ^[0-9]+$ ]] || hold manifests-count
current_app() {
  local CURRENT
  CURRENT=$(kubectl --context "$KUBE_CONTEXT" -n argocd get application "$APP" -o jsonpath='{.metadata.uid}') || return 2
  [ "$CURRENT" = "$KUBE_UID" ]
}
diff_review() {
  local rc=0
  argocd app diff "$APP" --revision "$APPROVED_GIT_REVISION" || rc=$?
  [ "$rc" -le 1 ] || hold diff-query
  # 호출자는 이 정확한 SHA의 diff·삭제 범위와 개별 Prune 승인을 먼저 검토합니다.
  current_app || hold application-changed
}
case "${1:-}" in
  up)
    [ "$COUNT" = 1 ] || hold request-pod-not-single
    diff_review
    argocd app sync "$APP" --revision "$APPROVED_GIT_REVISION" || hold sync-failed
    argocd app wait "$APP" --operation --health --timeout 300 || hold wait-failed
    kubectl --context "$KUBE_CONTEXT" -n monitoring wait pod/queue-admin --for=condition=Ready --timeout=180s || hold pod-not-ready
    ;;
  down)
    : "${QUEUE_ADMIN_APPROVED_POD_UID:?Set UID from removal approval}" "${QUEUE_ADMIN_APPROVED_TRACKING_ID:?Set current owner tracking ID from approval}"
    [ "$COUNT" = 0 ] || hold pod-still-desired
    CURRENT_POD=$(kubectl --context "$KUBE_CONTEXT" -n monitoring get pod queue-admin -o json) || hold pod-query
    printf '%s' "$CURRENT_POD" | jq -e --arg uid "$QUEUE_ADMIN_APPROVED_POD_UID" --arg owner "$QUEUE_ADMIN_APPROVED_TRACKING_ID" '.metadata.uid == $uid and .metadata.annotations["argocd.argoproj.io/tracking-id"] == $owner' >/dev/null || hold pod-owner-changed
    [[ "$QUEUE_ADMIN_APPROVED_TRACKING_ID" == "$APP:/Pod:monitoring/queue-admin" ]] || hold pod-owner-boundary
    diff_review
    # UID 재조회와 Argo prune은 원자적 UID 조건 삭제가 아닙니다. 배타 승인 창을 유지합니다.
    CURRENT_UID=$(kubectl --context "$KUBE_CONTEXT" -n monitoring get pod queue-admin -o jsonpath='{.metadata.uid}') || hold pod-uid-query
    [ "$CURRENT_UID" = "$QUEUE_ADMIN_APPROVED_POD_UID" ] || hold pod-changed
    argocd app sync "$APP" --revision "$APPROVED_GIT_REVISION" --prune || hold prune-failed
    argocd app wait "$APP" --operation --timeout 300 || hold wait-failed
    ;;
  *) hold usage-up-or-down ;;
esac
RESULT=$(argocd app get "$APP" -o json) || hold result-query
REVISION=$(printf '%s' "$RESULT" | jq -er '.status.operationState.syncResult.revision') || hold result-parse
PHASE=$(printf '%s' "$RESULT" | jq -er '.status.operationState.phase') || hold result-phase-parse
[ "$REVISION" = "$APPROVED_GIT_REVISION" ] && [ "$PHASE" = Succeeded ] || hold result-revision
printf 'PASS app=%s revision=%s operation=%s; prune absence requires separate current query\n' "$APP" "$REVISION" "${1:-}"
