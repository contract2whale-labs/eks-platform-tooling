#!/usr/bin/env python3
"""Keep observations immutable enough for comparison, without fabricating a diagnosis."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import re
import sys

HEADINGS = ["무엇이 실패했나", "왜 이 원인인가", "왜 이 복구인가", "무엇까지 회복했나",
            "무엇으로 개선했나", "효과를 어떻게 확인했나", "무엇이 미확인인가"]


def run(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["draft", "observe", "collect", "finalize"])
    parser.add_argument("case")
    parser.add_argument("--directory", required=True)
    parser.add_argument("--source")
    parser.add_argument("--command")
    parser.add_argument("--exit-code", type=int)
    for name in ["context", "account", "resource-uid", "revision", "digest", "window-start", "window-end", "http-status"]:
        parser.add_argument("--" + name)
    args = parser.parse_args(argv)
    directory = Path(args.directory).resolve(strict=True)
    if not directory.is_dir():
        raise ValueError("attempt directory required")
    identity = {}
    for line in (directory / "run.tsv").read_text().splitlines():
        key, separator, value = line.partition("\t")
        if separator: identity[key] = value
    if identity.get("case") != args.case or identity.get("attempt_id") != directory.name:
        raise ValueError("case or attempt identity mismatch")
    if identity.get("sealed_utc"):
        raise ValueError("sealed attempt is read only")
    current = directory.parent.parent / "current"
    if directory.parent.name != "attempts" or current.resolve(strict=True) != directory:
        raise ValueError("only the current attempt may be edited")
    record = directory / "record.md"
    observations = directory / "observations.jsonl"
    if args.action == "draft":
        with record.open("x", encoding="utf-8") as output:
            output.write("# 장애 조사·복구 기록\n\n")
            output.write("관측 파일·조회 시각을 근거로 판단을 작성합니다. 예상 결과를 실행 사실로 적지 않습니다.\n\n")
            for number, heading in enumerate(HEADINGS, 1):
                output.write(f"## {number} {heading}\n\n<!-- 실제 관측과 근거 경로를 적으세요. 미확인은 이유·담당·다음 확인을 적습니다. -->\n\n")
        print("INCIDENT_RECORD_DRAFT " + str(record))
    elif args.action == "collect":
        rows = []
        for source in sorted(directory.rglob("*")):
            if source.is_symlink(): raise ValueError("evidence symlinks are not allowed")
            if not source.is_file() or source.name in ("record.md", "run.tsv", "observations.jsonl", "manifest.sha256"):
                continue
            if any(parent.is_symlink() for parent in source.parents if directory in parent.parents):
                raise ValueError("evidence symlinks are not allowed")
            rows.append({"schema_version":1, "case":args.case, "attempt_directory":directory.name,
                         "collected_at_utc":datetime.datetime.now(datetime.timezone.utc).isoformat(),
                         "observed_at_utc":None, "evidence_path":str(source.relative_to(directory)),
                         "sha256":hashlib.sha256(source.read_bytes()).hexdigest(),
                         "command":None, "exit_code":None, "source_fact_status":"review_required"})
        if not rows: raise ValueError("no raw evidence in this attempt")
        # Reindexing before sealing is deliberate; it never substitutes for the seven human decisions.
        with observations.open("w", encoding="utf-8") as output:
            for row in rows: output.write(json.dumps(row, ensure_ascii=False) + "\n")
        print("INCIDENT_OBSERVATIONS_INDEXED files=" + str(len(rows)) + " facts=REVIEW_REQUIRED")
    elif args.action == "observe":
        if not args.source or not args.command or args.exit_code is None:
            raise ValueError("source, command and exit-code are required")
        candidate = directory / args.source
        if candidate.is_symlink() or any(parent.is_symlink() for parent in candidate.parents if parent != directory and directory in parent.parents):
            raise ValueError("evidence symlinks are not allowed")
        source = candidate.resolve(strict=True)
        if source == directory or directory not in source.parents or not source.is_file():
            raise ValueError("source must be a regular file inside this attempt")
        # A credentials-bearing command must not be persisted as diagnostic evidence.
        if re.search(r"(?i)(password|authorization|cookie|secret-access-key)\s*[=:]", args.command):
            raise ValueError("command must not contain secret values")
        observation = {"schema_version": 1, "case": args.case,
                       "attempt_directory": directory.name,
                       "observed_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                       "evidence_path": str(source.relative_to(directory)),
                       "sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                       "command": args.command, "exit_code": args.exit_code}
        for field in ["context", "account", "resource_uid", "revision", "digest", "window_start", "window_end", "http_status"]:
            observation[field] = getattr(args, field)
        with observations.open("a", encoding="utf-8") as output:
            output.write(json.dumps(observation, ensure_ascii=False) + "\n")
        print("INCIDENT_OBSERVATION_RECORDED " + observation["evidence_path"])
    else:
        content = record.read_text(encoding="utf-8")
        sections = re.split(r"^## [1-7] .+$", content, flags=re.M)[1:]
        if len(sections) != 7:
            raise ValueError("record requires seven numbered decisions")
        for number, section in enumerate(sections, 1):
            body = re.sub(r"<!--.*?-->", "", section, flags=re.S).strip()
            if not body or re.search(r"(?i)TODO|PLACEHOLDER|작성하세요|여기에 입력", body):
                raise ValueError(f"decision {number} is incomplete")
        rows = [json.loads(line) for line in observations.read_text().splitlines() if line.strip()]
        if not rows:
            raise ValueError("no observations were collected")
        for row in rows:
            candidate = directory / row["evidence_path"]
            if candidate.is_symlink(): raise ValueError("evidence symlinks are not allowed")
            source = candidate.resolve(strict=True)
            if row.get("case") != args.case or row.get("attempt_directory") != directory.name:
                raise ValueError("observation belongs to a different attempt")
            if directory not in source.parents or hashlib.sha256(source.read_bytes()).hexdigest() != row["sha256"]:
                raise ValueError("observation changed after collection")
        print("INCIDENT_RECORD_VALIDATED observations=" + str(len(rows)) + " result=UNSET")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(run(sys.argv[1:]))
    except (OSError, ValueError, KeyError) as error:
        print("INCIDENT_RECORD_REJECTED " + str(error), file=sys.stderr)
        sys.exit(2)
