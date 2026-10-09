#!/usr/bin/env bash
# scripts/lab/lab.sh — 챕터 단위 실습 자원 삭제(down) · 재생성(up) · 상태(status)
#
#   sh scripts/down.sh <CHAPTER>              <CHAPTER> 까지 만든 자원을 역순으로 삭제 (보존 대상 제외)
#   sh scripts/up.sh   <CHAPTER>              마지막으로 삭제한 <CHAPTER> 까지 순서대로 재생성
#   sh scripts/status.sh [--resources]        체크포인트와 (선택) 계정별 잔여 과금 자원 조회
#
# 환경 변수
#   LAB_DRY_RUN=1        실행하지 않고 단계와 명령만 출력
#   LAB_ASSUME_YES=1     down 확인 입력 생략
#   LAB_ALLOW_PLANNED=1  재작성 문서와 아직 대조하지 않은(planned) 단계도 실행 (과정 작성자 검증용)
#   LAB_FORCE=1          체크포인트 챕터와 다른 챕터로 up 실행 허용
#   LAB_ENV_FILE         개인 설정 파일 경로 (기본: $TOOLING_ROOT/work/lab.env)
#   LAB_STEPS_FILE       단계 목록 경로 (기본: scripts/lab/steps.tsv)
#
# 의존 도구: bash 3.2+, terraform, aws, jq, (클러스터 정리 시) kubectl — python3 (이전 체크포인트 이름을 읽는 용도).
set -euo pipefail
umask 077

LAB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(dirname -- "$LAB_DIR")"
TOOLING_ROOT="${TOOLING_ROOT:-$(dirname -- "$SCRIPTS_DIR")}"
STEPS_FILE="${LAB_STEPS_FILE:-$LAB_DIR/steps.tsv}"
ENV_FILE="${LAB_ENV_FILE:-$TOOLING_ROOT/work/lab.env}"
TAB="$(printf '\t')"

CHAPTERS=(PREPARATION STATE_FOUNDATION VPC_NETWORK NETWORK_BOUNDARIES ACCOUNT_BASELINE TRANSIT_NETWORK CLUSTER_CONTROL NODE_CAPACITY CORE_GUARDRAILS SERVICE_MESH SERVICE_EXPOSURE OPERATIONS OBSERVABILITY QUEUE_TRANSITION ACCOUNT_INTEGRATIONS DELIVERY_PLATFORM APPLICATION_DATA RELEASE_PIPELINE PRODUCTION_PLATFORM INCIDENT_OPERATIONS)

LOG_FILE=/dev/null
ACTION=""
TARGET_CHAPTER=""
STEPS=""
STEPS_STARTED=0

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

die() {
  printf '중단: %s\n' "$*" >&2
  if [ "$STEPS_STARTED" = 1 ]; then
    printf '원인을 해결한 뒤 같은 명령을 다시 실행하면 완료한 단계는 건너뛰고 이어서 진행합니다.\n' >&2
  fi
  if [ "$LOG_FILE" != /dev/null ] && [ -s "$LOG_FILE" ]; then
    printf '로그: %s\n' "$LOG_FILE" >&2
  fi
  exit 2
}

dry_run() { [ "${LAB_DRY_RUN:-0}" = 1 ]; }

upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# ── 챕터 ────────────────────────────────────────────────────────────────
normalize_chapter() {
  local value chapter
  value="$(python3 "$LAB_DIR/canonical-milestone.py" "${1:-}")"
  [ "$value" != PLATFORM ] || die "PLATFORM 은 OPERATIONS · OBSERVABILITY · QUEUE_TRANSITION 중 실제 완료 지점을 지정하세요."
  for chapter in "${CHAPTERS[@]}"; do
    if [ "$chapter" = "$value" ]; then
      printf '%s' "$value"
      return 0
    fi
  done
  die "알 수 없는 챕터: ${1:-(없음)} — 사용 가능: ${CHAPTERS[*]}"
}

chapter_index() {
  local i
  for i in "${!CHAPTERS[@]}"; do
    if [ "${CHAPTERS[$i]}" = "$1" ]; then
      printf '%s' "$i"
      return 0
    fi
  done
  printf '%s' -1
}

# ── 설정 · 상태 ─────────────────────────────────────────────────────────
load_env() {
  [ -f "$ENV_FILE" ] || die "개인 설정 파일이 없습니다: $ENV_FILE (01-GITHUB-SETUP.md 6절에서 만듭니다)"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  [ -n "${INFRA_ROOT:-}" ] || die "lab.env 에 INFRA_ROOT 가 없습니다 (01-GITHUB-SETUP.md 6절에서 기록하고 repository-setup에서 만듭니다)"
  [ -n "${AWS_REGION:-}" ] || die "lab.env 에 AWS_REGION 이 없습니다"
  [ -d "$INFRA_ROOT/terraform/environments" ] || die "INFRA_ROOT/terraform/environments 가 없습니다: $INFRA_ROOT"
  LAB_HOME="$INFRA_ROOT/.labctl"
  mkdir -p "$LAB_HOME/logs" "$LAB_HOME/plans"
}

profile_for() {
  case "$1" in
    dev) [ -n "${DEV_PROFILE:-}" ] || die "lab.env 에 DEV_PROFILE 이 없습니다"; printf '%s' "$DEV_PROFILE" ;;
    prod) [ -n "${PROD_PROFILE:-}" ] || die "lab.env 에 PROD_PROFILE 이 없습니다"; printf '%s' "$PROD_PROFILE" ;;
    *) die "steps.tsv 의 알 수 없는 계정 구분: $1" ;;
  esac
}

account_id_for() {
  case "$1" in
    dev) printf '%s' "${DEV_ACCOUNT_ID:-}" ;;
    prod) printf '%s' "${PROD_ACCOUNT_ID:-}" ;;
  esac
}

kube_context_for() {
  case "$1" in
    dev) printf '%s' "${DEV_KUBE_CONTEXT:-}" ;;
    prod) printf '%s' "${PROD_KUBE_CONTEXT:-}" ;;
  esac
}

STATE_THROUGH=""
STATE_PHASE=""
STATE_UPDATED=""

read_state() {
  STATE_THROUGH=""
  STATE_PHASE=""
  STATE_UPDATED=""
  [ -f "$LAB_HOME/state" ] || return 0
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      THROUGH) STATE_THROUGH="$value" ;;
      PHASE) STATE_PHASE="$value" ;;
      UPDATED) STATE_UPDATED="$value" ;;
    esac
  done < "$LAB_HOME/state"
  if [ -n "$STATE_THROUGH" ]; then
    STATE_THROUGH="$(normalize_chapter "$STATE_THROUGH")"
  fi
}

write_state() {
  dry_run && return 0
  printf 'THROUGH=%s\nPHASE=%s\nUPDATED=%s\n' "$1" "$2" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$LAB_HOME/state.tmp"
  mv "$LAB_HOME/state.tmp" "$LAB_HOME/state"
}

acquire_lock() {
  dry_run && return 0
  mkdir "$LAB_HOME/lock" 2>/dev/null || die "다른 실행이 진행 중입니다 ($LAB_HOME/lock). 진행 중인 실행이 없다면 이 디렉터리를 지운 뒤 다시 실행하세요."
  trap 'rmdir "$LAB_HOME/lock" 2>/dev/null || true' EXIT
}

# ── 단계 목록 ───────────────────────────────────────────────────────────
# steps.tsv 열: weight  chapter  kind  target  account  status  note
select_steps() {
  local through_index="$1" order="$2" weight chapter kind target account status note index
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$STEPS_FILE" |
    while IFS="$TAB" read -r weight chapter kind target account status note; do
      index="$(chapter_index "$chapter")"
      [ "$index" -ge 0 ] || die "steps.tsv 의 알 수 없는 챕터: $chapter"
      [ "$index" -le "$through_index" ] || continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$weight" "$chapter" "$kind" "$target" "$account" "$status"
    done |
    if [ "$order" = asc ]; then sort -t "$TAB" -k1,1n -k4,4; else sort -t "$TAB" -k1,1nr -k4,4r; fi
}

check_supported() {
  local blocked
  blocked="$(printf '%s\n' "$1" | awk -F "$TAB" '$6 == "planned" { print "  " $2 "  " $3 "  " $4 }')"
  [ -n "$blocked" ] || return 0
  if [ "${LAB_ALLOW_PLANNED:-0}" = 1 ]; then
    log "경고: planned 단계를 LAB_ALLOW_PLANNED=1 로 실행합니다."
    return 0
  fi
  die "재작성 문서와 아직 대조하지 않은 단계(planned)가 범위에 있습니다:
$blocked
해당 챕터의 재작성이 끝나면 steps.tsv 의 상태가 ready 로 바뀝니다."
}

# ── 공통 실행기 ─────────────────────────────────────────────────────────
run() {
  if dry_run; then
    printf '    (dry-run) %s\n' "$*"
    return 0
  fi
  if ! "$@" < /dev/null >> "$LOG_FILE" 2>&1; then
    tail -n 20 "$LOG_FILE" >&2 || true
    die "명령 실패: $*"
  fi
}

plan_exit_code() {
  local rc=0
  terraform -chdir="$1" plan -input=false -lock-timeout=5m -detailed-exitcode < /dev/null >> "$LOG_FILE" 2>&1 || rc=$?
  printf '%s' "$rc"
}

plan_count() {
  local root="$1" plan="$2" mode="$3" json
  json="$(terraform -chdir="$root" show -json "$plan")"
  case "$mode" in
    delete) printf '%s' "$json" | jq '[.resource_changes[]? | select(any(.change.actions[]; . == "delete"))] | length' ;;
    write) printf '%s' "$json" | jq '[.resource_changes[]? | select(any(.change.actions[]; . == "create" or . == "update"))] | length' ;;
  esac
}

managed_count() {
  local listing
  listing="$(terraform -chdir="$1" state list 2>> "$LOG_FILE" < /dev/null)" || die "State 목록 조회 실패: $1"
  printf '%s\n' "$listing" | awk 'NF && $0 !~ /^data\./ { n++ } END { print n + 0 }'
}

root_of() { printf '%s' "$INFRA_ROOT/terraform/environments/$1"; }

tf_init() {
  local root="$1"
  [ -d "$root" ] || die "루트 모듈 디렉터리가 없습니다: $root"
  [ -f "$root/backend.hcl" ] || die "backend.hcl 이 없습니다: $root (backend.hcl.example 을 복사해 값을 채웁니다)"
  run terraform -chdir="$root" init -input=false -backend-config=backend.hcl
}

validate_lifecycle_for_root() {
  local destroy_flags=()
  [ "${2:-}" != destroy ] || destroy_flags=(--destroy)
  python3 "$LAB_DIR/validate_lifecycle_request.py" --request "$LAB_LIFECYCLE_REQUEST" \
    --environment "$LAB_ENVIRONMENT" --account "$(account_id_for "$LAB_ENVIRONMENT")" \
    --context "$LAB_KUBE_CONTEXT" --repo "$INFRA_ROOT" --target "$1" "${destroy_flags[@]}" ||
    die "lifecycle saved plan approval was withdrawn or changed"
}

# ── 단계 구현 ───────────────────────────────────────────────────────────
step_tf_up() {
  local target="$1" status="$2" root plan rc deletes
  root="$(root_of "$target")"
  tf_init "$root"
  if [ "$status" = retain ]; then
    dry_run && { printf '    (dry-run) 보존 루트 모듈 차이 확인: %s\n' "$target"; return 0; }
    rc="$(plan_exit_code "$root")"
    [ "$rc" = 0 ] || die "보존 루트 모듈에 차이가 있습니다 (plan exit $rc): $target — 보존 자원은 자동으로 바꾸지 않습니다."
    log "  보존 확인: 차이 없음"
    return 0
  fi
  local attempt
  attempt="$(python3 -c 'import uuid; print(uuid.uuid4())')" || die "plan attempt ID generation failed"
  [ -n "$attempt" ] || die "empty plan attempt ID"
  plan="$LAB_HOME/plans/up-${target//\//_}-$attempt.tfplan"
  [ ! -e "$plan" ] && [ ! -L "$plan" ] || die "saved plan path already exists: $plan"
  run terraform -chdir="$root" plan -input=false -lock-timeout=5m -out="$plan"
  dry_run && return 0
  deletes="$(plan_count "$root" "$plan" delete)"
  [ "$deletes" = 0 ] || die "재생성 계획에 삭제·교체가 ${deletes}건 있습니다: $target — 자동 적용하지 않습니다."
  terraform -chdir="$root" show -no-color "$plan"
  local reviewed plan_evidence reviewed_revision
  plan_evidence="${plan}.approval.json"
  reviewed_revision="$(git -C "$INFRA_ROOT" rev-parse HEAD)"
  python3 "$LAB_DIR/saved_plan_contract.py" record --root "$root" --plan "$plan" \
    --revision "$reviewed_revision" --evidence "$plan_evidence" || die "saved plan contract recording failed"
  printf 'Review the saved plan for %s. Type its root path to execute: ' "$target"
  read -r reviewed
  [ "$reviewed" = "$target" ] || die "saved plan approval does not match target"
  # Approval may be withdrawn while the operator reviews the saved plan.
  validate_lifecycle_for_root "$target"
  reviewed_revision="$(git -C "$INFRA_ROOT" rev-parse HEAD)"
  python3 "$LAB_DIR/saved_plan_contract.py" verify --root "$root" --plan "$plan" \
    --revision "$reviewed_revision" --evidence "$plan_evidence" || die "saved plan approval no longer matches"
  run terraform -chdir="$root" apply -input=false -lock-timeout=5m "$plan"
  rc="$(plan_exit_code "$root")"
  [ "$rc" = 0 ] || die "적용 뒤에도 차이가 남았습니다 (plan exit $rc): $target"
  rm -f "$plan"
  log "  재생성 완료: 차이 없음"
}

step_tf_down() {
  local target="$1" status="$2" root plan writes deletes left
  if [ "$status" = retain ]; then
    log "  보존 대상: 삭제하지 않음"
    return 0
  fi
  dry_run || validate_lifecycle_for_root "$target" destroy
  root="$(root_of "$target")"
  tf_init "$root"
  if ! dry_run; then
    left="$(managed_count "$root")" || die "State 조회가 실패했습니다: $target"
    if [ "$left" = 0 ]; then
      log "  이미 비어 있음"
      return 0
    fi
  fi
  local attempt
  attempt="$(python3 -c 'import uuid; print(uuid.uuid4())')" || die "plan attempt ID generation failed"
  [ -n "$attempt" ] || die "empty plan attempt ID"
  plan="$LAB_HOME/plans/down-${target//\//_}-$attempt.tfplan"
  [ ! -e "$plan" ] && [ ! -L "$plan" ] || die "saved plan path already exists: $plan"
  run terraform -chdir="$root" plan -destroy -input=false -lock-timeout=5m -out="$plan"
  dry_run && return 0
  writes="$(plan_count "$root" "$plan" write)"
  [ "$writes" = 0 ] || die "삭제 계획에 생성·수정이 ${writes}건 섞였습니다: $target"
  deletes="$(plan_count "$root" "$plan" delete)"
  log "  삭제 대상 ${deletes}건"
  terraform -chdir="$root" show -no-color "$plan"
  local reviewed plan_evidence reviewed_revision
  plan_evidence="${plan}.approval.json"
  reviewed_revision="$(git -C "$INFRA_ROOT" rev-parse HEAD)"
  python3 "$LAB_DIR/saved_plan_contract.py" record --root "$root" --plan "$plan" \
    --revision "$reviewed_revision" --evidence "$plan_evidence" || die "saved plan contract recording failed"
  printf 'Review the saved plan for %s. Type its root path to execute: ' "$target"
  read -r reviewed
  [ "$reviewed" = "$target" ] || die "saved plan approval does not match target"
  # Approval may be withdrawn while the operator reviews the saved plan.
  validate_lifecycle_for_root "$target" destroy
  reviewed_revision="$(git -C "$INFRA_ROOT" rev-parse HEAD)"
  python3 "$LAB_DIR/saved_plan_contract.py" verify --root "$root" --plan "$plan" \
    --revision "$reviewed_revision" --evidence "$plan_evidence" || die "saved plan approval no longer matches"
  run terraform -chdir="$root" apply -input=false -lock-timeout=5m "$plan"
  left="$(managed_count "$root")"
  [ "$left" = 0 ] || die "삭제 뒤 State 에 관리 자원 ${left}개가 남았습니다: $target"
  rm -f "$plan"
  log "  삭제 완료: State 비어 있음"
}

# 클러스터 안에서 컨트롤러가 만든 AWS 자원(Load Balancer, EBS)은 Terraform State 밖에 있으므로
# 클러스터를 지우기 전에 정리하거나(LB) 목록을 기록해 둡니다(EBS → step_vol_clean).
step_k8s_clean() {
  local env="$1" eks_root ctx list count
  eks_root="$(root_of "$env/eks")"
  if dry_run; then
    printf '    (dry-run) GitOps 퇴역 뒤 LoadBalancer 잔존 확인, 승인한 EBS 볼륨만 기록 (%s)\n' "$env"
    return 0
  fi
  tf_init "$eks_root"
  if [ "$(managed_count "$eks_root")" = 0 ]; then
    log "  클러스터 없음: 정리 생략"
    return 0
  fi
  ctx="$(kube_context_for "$env")"
  [ -n "$ctx" ] || die "lab.env 에 $(upper "$env")_KUBE_CONTEXT 가 없습니다 (CLUSTER_CONTROL 에서 기록합니다)"
  command -v kubectl > /dev/null || die "kubectl 이 PATH 에 없습니다"
  kubectl --context "$ctx" get --raw=/readyz < /dev/null >> "$LOG_FILE" 2>&1 ||
    die "클러스터 API 에 연결할 수 없습니다 (context: $ctx). CLUSTER_CONTROL 의 Private API 접속 세션을 연 뒤 다시 실행하세요."

  list="$(kubectl --context "$ctx" get service --all-namespaces -o json < /dev/null | jq -r '.items[] | select(.spec.type == "LoadBalancer") | .metadata.namespace + "/" + .metadata.name')"
  [ -z "$list" ] || die "LoadBalancer Services remain; complete reviewed GitOps retirement before destroying the cluster: $list"

  kubectl --context "$ctx" get persistentvolume -o json < /dev/null |
    jq -r '.items[] | select(.spec.csi.driver == "ebs.csi.aws.com") | .spec.csi.volumeHandle' > "$LAB_HOME/volumes-$env.txt"
  python3 - "$LAB_HOME/volumes-$env.txt" "${LAB_LIFECYCLE_REQUEST:?reviewed lifecycle request required}" <<'PYFILTER'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]);request=json.loads(Path(sys.argv[2]).read_text())
allowed=set(request.get('delete_volume_ids',[]))
observed=set(p.read_text().splitlines())
if allowed-observed:raise SystemExit('reviewed volume is not attached to the observed cluster')
p.write_text('\n'.join(sorted(allowed))+'\n' if allowed else '')
PYFILTER
  count="$(grep -c . "$LAB_HOME/volumes-$env.txt" || true)"
  log "  클러스터 삭제 뒤 정리할 EBS 볼륨 ${count}개 기록"
}

current_volume_approval() {
  python3 "$LAB_DIR/validate_lifecycle_request.py" \
    --request "${LAB_LIFECYCLE_REQUEST:?reviewed lifecycle request required}" \
    --environment "$1" --account "$(account_id_for "$1")" \
    --context "$(kube_context_for "$1")" --repo "$INFRA_ROOT" --volume-id "$2" ||
    die "current lifecycle approval does not permit deleting $2"
}

prepare_restored_kubeconfig() {
  local cluster proxy
  case "$LAB_ENVIRONMENT" in dev) proxy=http://127.0.0.1:18080 ;; prod) proxy=http://127.0.0.1:18081 ;; *) die "unsupported lifecycle environment" ;; esac
  cluster="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["cluster_name"])' "$LAB_LIFECYCLE_REQUEST")"
  [ -n "$cluster" ] || die "reviewed cluster name required"
  run aws eks update-kubeconfig --region "$AWS_REGION" --name "$cluster" --alias "$LAB_KUBE_CONTEXT" --proxy-url "$proxy"
  run kubectl config set-context "$LAB_KUBE_CONTEXT" --namespace=argocd
  # The private API session must already be open before the subsequent API checks.
}

step_vol_clean() {
  local env="$1" list vol state i
  list="$LAB_HOME/volumes-$env.txt"
  if [ ! -s "$list" ]; then
    log "  정리할 EBS 볼륨 없음"
    return 0
  fi
  if dry_run; then
    printf '    (dry-run) 기록된 EBS 볼륨 %s개 삭제\n' "$(grep -c . "$list" || true)"
    return 0
  fi
  while read -r vol; do
    [ -n "$vol" ] || continue
    # Re-read approval before querying each saved volume and immediately before deletion.
    current_volume_approval "$env" "$vol"
    state=unknown
    for i in $(seq 1 30); do
      # A separate protected file preserves every attempt, including retries.
      local error_file
      error_file="$(mktemp "$LAB_HOME/volume-query-$env-$vol-attempt-$i.XXXXXX")" || die "EBS error evidence allocation failed"
      if state="$(aws ec2 describe-volumes --region "$AWS_REGION" --volume-ids "$vol" \
        --query 'Volumes[0].State' --output text < /dev/null 2> "$error_file")"; then
        [ "$state" != None ] && [ -n "$state" ] || die "EBS 조회가 상태를 반환하지 않았습니다: $vol"
      elif grep -q 'InvalidVolume.NotFound' "$error_file"; then
        state=deleted
      else
        cat "$error_file" >&2
        die "EBS 조회 실패를 삭제 완료로 판정하지 않습니다: $vol"
      fi
      case "$state" in available | deleted | None) break ;; esac
      sleep 20
    done
    case "$state" in
      available) current_volume_approval "$env" "$vol"; run aws ec2 delete-volume --region "$AWS_REGION" --volume-id "$vol"; log "  EBS 볼륨 삭제: $vol" ;;
      deleted | None) log "  이미 없음: $vol" ;;
      *) die "EBS 볼륨이 분리되지 않았습니다 ($state): $vol" ;;
    esac
  done < "$list"
  rm -f "$list"
}

step_hook() {
  local name="$1" file
  file="$LAB_DIR/hooks/$name.sh"
  [ -f "$file" ] || die "hook 파일이 없습니다: $file"
  run bash "$file" "$ACTION"
}

# ── 사전 확인 ───────────────────────────────────────────────────────────
preflight() {
  local steps="$1" tool account profile expected actual
  for tool in terraform aws jq python3; do
    command -v "$tool" > /dev/null || die "$tool 이 PATH 에 없습니다 (01-GITHUB-SETUP.md 12절의 도구 준비를 확인하세요)"
  done
  dry_run && return 0
  for account in $(printf '%s\n' "$steps" | awk -F "$TAB" 'NF { print $5 }' | sort -u); do
    profile="$(profile_for "$account")"
    expected="$(account_id_for "$account")"
    actual="$(aws sts get-caller-identity --profile "$profile" --query Account --output text < /dev/null 2>/dev/null)" ||
      die "$profile 로그인 세션이 없습니다: aws sso login --profile $profile"
    [ -z "$expected" ] || [ "$actual" = "$expected" ] ||
      die "계정 불일치 ($profile): lab.env 는 $expected, 실제 로그인은 $actual"
  done
}

confirm_down() {
  local answer
  if dry_run || [ "${LAB_ASSUME_YES:-0}" = 1 ]; then return 0; fi
  printf '%s 까지 만든 자원을 역순으로 삭제합니다 (보존 대상 제외). 계속하려면 %s 를 입력하세요: ' "$1" "$1"
  read -r answer
  [ "$answer" = "$1" ] || die "입력이 일치하지 않아 중단했습니다."
}

# ── up / down ───────────────────────────────────────────────────────────
# 범위 선택 · 지원 여부 · 계정 확인은 체크포인트를 기록하기 전에 끝냅니다.
prepare() {
  local order
  if [ "$ACTION" = up ]; then order=asc; else order=desc; fi
  STEPS="$(select_steps "$(chapter_index "$TARGET_CHAPTER")" "$order")"
  check_supported "$STEPS"
  if [ "$ACTION" = up ] && printf '%s\n' "$STEPS" | awk -F "$TAB" '$3 == "hook" && $4 == "platform-observability" && $5 == "prod" { found=1 } END { exit !found }'; then
    die "운영 환경 전체 재개는 지원하지 않습니다. 운영 선언·이미지·데이터 복구 계획을 먼저 검토하고 단계별로 재구성하세요."
  fi
  preflight "$STEPS"
}

execute() {
  local progress weight chapter kind target account status key
  STEPS_STARTED=1
  progress="$LAB_HOME/progress-$ACTION-$TARGET_CHAPTER.list"
  local previous_name previous_progress
  previous_name="$(python3 "$LAB_DIR/canonical-milestone.py" "$TARGET_CHAPTER" --legacy)"
  previous_progress="$LAB_HOME/progress-$ACTION-$previous_name.list"
  if [ "$previous_progress" != "$progress" ] && [ -f "$previous_progress" ]; then
    [ ! -f "$progress" ] || die "이전·새 진행 기록이 함께 있습니다. 완료 단계와 대상 계정을 비교한 뒤 재개하세요."
    progress="$previous_progress"
  fi
  dry_run || touch "$progress"
  while IFS="$TAB" read -r weight chapter kind target account status <&3; do
    [ -n "$weight" ] || continue
    key="$kind:$account:$target" # 예: hook:prod:platform-observability — 같은 대상 이름의 Dev · Prod 행을 다른 단계로 셉니다 
    # up cleanup rows are no-ops: do not verify a cluster which has not been restored yet.
    case "$ACTION:$kind" in up:k8s-clean|up:vol-clean) continue ;; esac
    log "[$chapter] $ACTION · $kind · $target"
    AWS_PROFILE="$(profile_for "$account")"
    export AWS_PROFILE
    export LAB_ENVIRONMENT="$account"
    export LAB_KUBE_CONTEXT="$(kube_context_for "$account")"
    if ! dry_run; then
      local request_key
      request_key="LAB_LIFECYCLE_REQUEST_$(upper "$account")"
      export LAB_LIFECYCLE_REQUEST="${!request_key:-${LAB_LIFECYCLE_REQUEST:-}}"
      [ -n "$LAB_LIFECYCLE_REQUEST" ] || die "reviewed lifecycle request required for $account ($request_key)"
      local request_args
      request_args=(--request "$LAB_LIFECYCLE_REQUEST" --environment "$account" --account "$(account_id_for "$account")" --context "$LAB_KUBE_CONTEXT" --repo "$INFRA_ROOT")
      [ "$kind" != tf ] || request_args+=(--target "$target")
      if [ "$ACTION:$kind" = up:hook ]; then
        python3 "$LAB_DIR/validate_lifecycle_request.py" "${request_args[@]}" || die "lifecycle target was not approved"
        prepare_restored_kubeconfig
      fi
      case "$kind" in hook|k8s-clean) request_args+=(--verify-cluster) ;; esac
      python3 "$LAB_DIR/validate_lifecycle_request.py" "${request_args[@]}" || die "lifecycle target was not approved"
    fi
    if [ -f "$progress" ] && grep -qxF "$key" "$progress"; then
      log "건너뜀 (완료된 단계): $key"
      continue
    fi
    case "$ACTION:$kind" in
      up:tf) step_tf_up "$target" "$status" ;;
      down:tf) step_tf_down "$target" "$status" ;;
      down:k8s-clean) step_k8s_clean "$target" ;;
      down:vol-clean) step_vol_clean "$target" ;;
      up:k8s-clean | up:vol-clean) log "  up 에서는 실행하지 않는 단계" ;;
      up:hook | down:hook) step_hook "$target" ;;
      *) die "알 수 없는 단계 종류: $kind" ;;
    esac
    dry_run || printf '%s\n' "$key" >> "$progress"
  done 3<<< "$STEPS"
  dry_run || rm -f "$progress"
}

cmd_down() {
  read_state
  case "$STATE_PHASE" in
    down-done)
      [ "$STATE_THROUGH" != "$TARGET_CHAPTER" ] || { log "이미 삭제된 상태입니다: $TARGET_CHAPTER (재개: sh scripts/up.sh $TARGET_CHAPTER)"; return 0; }
      die "이미 $STATE_THROUGH 기준으로 삭제된 상태입니다. 먼저 sh scripts/up.sh $STATE_THROUGH 로 재생성하세요." ;;
    up-running)
      die "$STATE_THROUGH 재생성이 끝나지 않았습니다. sh scripts/up.sh $STATE_THROUGH 를 먼저 완료하세요." ;;
    down-running)
      [ "$STATE_THROUGH" = "$TARGET_CHAPTER" ] || die "$STATE_THROUGH 삭제가 진행 중입니다. sh scripts/down.sh $STATE_THROUGH 를 먼저 완료하세요." ;;
  esac
  prepare
  confirm_down "$TARGET_CHAPTER"
  acquire_lock
  write_state "$TARGET_CHAPTER" down-running
  execute
  write_state "$TARGET_CHAPTER" down-done
  log "DOWN_DONE: $TARGET_CHAPTER — 잔여 과금 자원 확인: sh scripts/status.sh --resources"
}

cmd_up() {
  read_state
  case "$STATE_PHASE" in
    down-done | up-running)
      if [ "$STATE_THROUGH" != "$TARGET_CHAPTER" ] && [ "${LAB_FORCE:-0}" != 1 ]; then
        die "마지막 삭제 지점은 $STATE_THROUGH 입니다. 저장소 코드가 그 시점 상태이므로 sh scripts/up.sh $STATE_THROUGH 로 재생성하세요."
      fi ;;
    down-running)
      die "$STATE_THROUGH 삭제가 끝나지 않았습니다. sh scripts/down.sh $STATE_THROUGH 를 먼저 완료하세요." ;;
    ready)
      log "현재 체크포인트: READY $STATE_THROUGH — 차이 확인 위주로 진행합니다." ;;
    "")
      log "체크포인트가 없습니다 — 현재 저장소 코드로 $TARGET_CHAPTER 까지 순서대로 적용합니다." ;;
  esac
  prepare
  acquire_lock
  write_state "$TARGET_CHAPTER" up-running
  execute
  write_state "$TARGET_CHAPTER" ready
  log "READY: $TARGET_CHAPTER — 다음 챕터부터 이어서 진행합니다."
}

# ── status ──────────────────────────────────────────────────────────────
count_query() {
  local profile="$1" label="$2" value
  shift 2
  value="$(aws "$@" --region "$AWS_REGION" --profile "$profile" --output text < /dev/null 2>/dev/null)" || value="조회 실패"
  printf '    %-28s %s\n' "$label" "$value"
}

cmd_status() {
  local account profile
  read_state
  printf 'THROUGH=%s\nPHASE=%s\nUPDATED=%s\n' "${STATE_THROUGH:-없음}" "${STATE_PHASE:-없음}" "${STATE_UPDATED:-없음}"
  [ "${1:-}" = --resources ] || return 0
  for account in dev prod; do
    case "$account" in dev) profile="${DEV_PROFILE:-}" ;; prod) profile="${PROD_PROFILE:-}" ;; esac
    [ -n "$profile" ] || continue
    printf '\n[%s] profile=%s region=%s\n' "$account" "$profile" "$AWS_REGION"
    if ! aws sts get-caller-identity --profile "$profile" > /dev/null 2>&1 < /dev/null; then
      printf '    로그인 세션 없음: aws sso login --profile %s\n' "$profile"
      continue
    fi
    printf '  현재 자원 (승인한 삭제·보존 목록과 대조)\n'
    count_query "$profile" "EKS clusters" eks list-clusters --query 'length(clusters)'
    count_query "$profile" "NAT gateways" ec2 describe-nat-gateways --query "length(NatGateways[?State=='available' || State=='pending'])"
    count_query "$profile" "Elastic IPs" ec2 describe-addresses --query 'length(Addresses)'
    count_query "$profile" "Load balancers (ELBv2)" elbv2 describe-load-balancers --query 'length(LoadBalancers)'
    count_query "$profile" "EBS volumes (available)" ec2 describe-volumes --query "length(Volumes[?State=='available'])"
    count_query "$profile" "Interface endpoints" ec2 describe-vpc-endpoints --query "length(VpcEndpoints[?VpcEndpointType=='Interface'])"
    count_query "$profile" "Transit gateways" ec2 describe-transit-gateways --query "length(TransitGateways[?State=='available' || State=='pending'])"
    count_query "$profile" "Network firewalls" network-firewall list-firewalls --query 'length(Firewalls)'
    count_query "$profile" "MSK clusters" kafka list-clusters-v2 --query 'length(ClusterInfoList)'
    count_query "$profile" "RDS instances" rds describe-db-instances --query 'length(DBInstances)'
    printf '  보존 자원 (down 뒤에도 남음)\n'
    count_query "$profile" "Route 53 hosted zones" route53 list-hosted-zones --query 'length(HostedZones)'
    count_query "$profile" "S3 buckets" s3api list-buckets --query 'length(Buckets)'
  done
}

usage() {
  cat >&2 << 'EOF'
사용법:
  sh scripts/down.sh <CHAPTER>        완료한 챕터까지의 자원을 역순으로 삭제
  sh scripts/up.sh <CHAPTER>          마지막으로 삭제한 챕터까지 순서대로 재생성
  sh scripts/status.sh [--resources]  체크포인트 확인 (--resources: 계정별 잔여 과금 자원 조회)
EOF
  exit 2
}

main() {
  [ $# -ge 1 ] || usage
  ACTION="$1"
  shift
  load_env
  case "$ACTION" in
    up | down)
      [ $# -eq 1 ] || usage
      TARGET_CHAPTER="$(normalize_chapter "$1")"
      LOG_FILE="$LAB_HOME/logs/$(date '+%Y%m%d-%H%M%S')-$ACTION-$TARGET_CHAPTER.log"
      dry_run && LOG_FILE=/dev/null
      log "$ACTION $TARGET_CHAPTER 시작 (INFRA_ROOT=$INFRA_ROOT)"
      if [ "$ACTION" = up ]; then cmd_up; else cmd_down; fi ;;
    status) cmd_status "${1:-}" ;;
    *) usage ;;
  esac
}

main "$@"
