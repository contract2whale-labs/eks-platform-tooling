#!/usr/bin/env bash
# platform/environments/dev/alerting/scripts/check-log-filters.sh
# 1) 오프라인: 실제 HCL과 GitOps values를 파싱해 필터 대상과 Fluent Bit 입력·병합·출력 설정을 대조합니다.
# 2) AWS(읽기 전용, 자원 생성 없음): aws logs test-metric-filter 로 표본마다 match/skip 기대와 대조. --offline 이면 2) 를 건너뜁니다.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)               # 예: <INFRA_ROOT>/platform/environments/dev/alerting
INFRA_ROOT=$(cd "$ROOT/../../../.." && pwd)                         # 예: <INFRA_ROOT>
ALARMS="$INFRA_ROOT/modules/alerting/alarms.tf"                     # 예: 패턴을 읽을 파일 (계정 이벤트 경보 모듈)
FLUENT="$INFRA_ROOT/gitops/platform/fluent-bit/values/dev.yaml" # 예: Argo Application이 읽는 실제 Dev values
EVENTS="$ROOT/checks/log-filter-events.txt"                         # 예: 표본 12건
RUN_ID="verify-0123456789abcdef0123456789abcdef"                    # 예: 시험에서만 쓰는 지정 점검 식별자
OFFLINE=false; [[ "${1:-}" == --offline ]] && OFFLINE=true
fail() { echo "FAIL: $*" >&2; exit 1; }

# 실제 source를 파싱합니다. 규칙 개수 대신 대상 필드와 값, AND 결합의 의미를 확인합니다.
PATTERNS=$(python3 - "$ALARMS" "$FLUENT" "$RUN_ID" <<'PYTHON'
import json, re, sys
from pathlib import Path
import hcl2
from ruamel.yaml import YAML
alarms, fluent, run_id = sys.argv[1:]
try:
    with Path(alarms).open() as stream:
        source = hcl2.load(stream)
    patterns = {}
    for resource in source.get("resource", []):
        for name, body in resource.get("aws_cloudwatch_log_metric_filter", {}).items():
            patterns[name] = body["pattern"].replace("${var.sample_delete_validation_run_id}", run_id)
    expected = {
        "pool_acquire_timeout": {
            "kubernetes.namespace_name": "kube-system", "kubernetes.container_name": "aws-node", "stream": "stderr"},
        "armed_sample_deletion": {
            "kubernetes.namespace_name": "kube-system", "event": "node_drain_probe", "phase": "not_ready", "validation_run_id": run_id},
    }
    predicate = r'\$\.([A-Za-z_.]+)\s*=\s*("(?:[^"\\]|\\.)*")'
    for name, fields in expected.items():
        pattern = patterns.get(name, "")
        if not re.fullmatch(r'\{\s*' + predicate + r'(?:\s*&&\s*' + predicate + r')*\s*\}', pattern):
            raise ValueError(f"{name}: only explicit AND equality conditions are allowed")
        pairs = re.findall(predicate, pattern)
        actual = {field: json.loads(value) for field, value in pairs}
        if len(pairs) != len(actual) or actual != fields:
            raise ValueError(f"{name}: unexpected field or value: {actual}")
    values = YAML(typ="safe").load(Path(fluent).read_text())
    config = values["config"]
    def section_fields(key, section):
        sections = re.split(r'^\s*\[' + section + r'\]\s*$', config[key], flags=re.M)
        if len(sections) != 2:
            raise ValueError(f"config.{key}: expected one [{section}] section")
        fields = {}
        for line in sections[1].splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, value = line.split(None, 1)
            fields[key] = value
        return fields
    inputs = section_fields("inputs", "INPUT")
    filters = section_fields("filters", "FILTER")
    outputs = section_fields("outputs", "OUTPUT")
    if inputs.get("Name") != "tail" or inputs.get("Exclude_Path") != "/var/log/containers/*_contract2whale-demo_*.log":
        raise ValueError("Dev Fluent Bit must exclude the application namespace from its tail input")
    if filters.get("Name") != "kubernetes" or filters.get("Merge_Log") != "On" or filters.get("Keep_Log") != "On":
        raise ValueError("Dev Fluent Bit must merge Kubernetes JSON and keep the original log line")
    if outputs.get("Name") != "cloudwatch_logs":
        raise ValueError("Dev Fluent Bit must deliver platform logs to CloudWatch Logs")
    print(json.dumps({name: patterns[name] for name in expected}))
except (OSError, KeyError, TypeError, ValueError) as exc:
    print(f"FAIL: {exc}", file=sys.stderr)
    sys.exit(1)
PYTHON
) || fail "HCL or native Fluent Bit values do not satisfy the log-filter contract"
POOL=$(printf '%s' "$PATTERNS" | jq -er '.pool_acquire_timeout')
ARMED=$(printf '%s' "$PATTERNS" | jq -er '.armed_sample_deletion')
echo "OFFLINE OK: filter subjects and native Fluent Bit tail/JSON/output settings match"
$OFFLINE && exit 0

# 2. AWS 검사: 표본마다 test-metric-filter 의 matches 개수(0 또는 1)를 기대와 대조합니다.
TOTAL=0
while read -r EXPECT FILTER EVENT; do
  [[ -n "$EXPECT" && "$EXPECT" != \#* ]] || continue
  case "$FILTER" in pool_acquire_timeout) PATTERN="$POOL" ;; armed_sample_deletion) PATTERN="$ARMED" ;; *) fail "unknown filter in fixture: $FILTER" ;; esac
  EVENT="${EVENT//RUN_ID/$RUN_ID}"
  MATCHES="$(aws logs test-metric-filter --filter-pattern "$PATTERN" --log-event-messages "$EVENT" --query 'length(matches)' --output text)" # 예: 1 또는 0
  case "$EXPECT:$MATCHES" in match:1 | skip:0) TOTAL=$((TOTAL + 1)) ;; *) fail "$FILTER expected $EXPECT but got $MATCHES matches for $EVENT" ;; esac
done < "$EVENTS"
echo "FILTER OK: $TOTAL sample records matched the expected result (aws logs test-metric-filter)" # 예: FILTER OK: 12 sample records …
