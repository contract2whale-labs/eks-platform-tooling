#!/usr/bin/env bash
set -euo pipefail
: "${KUBE_CONTEXT:?Set the intended EKS context}"
NAMESPACE=${NAMESPACE:-contract2whale-demo}
JOB_NAME=${JOB_NAME:-database-operator-check}
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" get job "$JOB_NAME" -o yaml
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" wait --for=condition=complete "job/$JOB_NAME" --timeout=200s
kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE" logs "job/$JOB_NAME"
# Preserve the Job evidence; remove the request through a reviewed operations lifecycle change.
