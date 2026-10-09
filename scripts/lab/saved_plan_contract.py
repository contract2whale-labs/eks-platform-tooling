#!/usr/bin/env python3
"""Bind lifecycle approval evidence to plan bytes and current State metadata.

Used by lab.sh inside its existing interactive saved-plan review, not a manual CLI wrapper.
State content is read in memory; presence/lineage/serial and source/plan/input hashes are saved.
Default workspace and exact successful empty State are supported for first creation.
"""
import argparse
import hashlib
import json
import os
import subprocess
from datetime import datetime, timezone
from pathlib import Path


def file_hash(path):
    with Path(path).open("rb") as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def contract(root, plan, revision, run=subprocess.check_output):
    root = Path(root).resolve()
    workspace = run(["terraform", f"-chdir={root}", "workspace", "show"], stdin=subprocess.DEVNULL)
    if isinstance(workspace, bytes):
        workspace = workspace.decode("utf-8")
    if workspace.strip() != "default":
        raise ValueError("saved-plan workspace must be default")
    # Exact empty stdout with successful exit means no State. Errors and whitespace are not absence.
    raw_state = run(["terraform", f"-chdir={root}", "state", "pull"], stdin=subprocess.DEVNULL)
    if raw_state in (b"", ""):
        presence, lineage, serial = "absent", None, None
    else:
        state = json.loads(raw_state)
        if not isinstance(state, dict) or not isinstance(state.get("lineage"), str) or not state["lineage"]:
            raise ValueError("State lineage is missing")
        if type(state.get("serial")) is not int or state["serial"] < 0:
            raise ValueError("State serial is invalid")
        presence, lineage, serial = "present", state["lineage"], state["serial"]
    backend = root / "backend.hcl"
    if not backend.is_file():
        raise ValueError("backend.hcl is missing or unreadable")
    data_directory = Path(os.environ.get("TF_DATA_DIR", str(root / ".terraform")))
    if not data_directory.is_absolute():
        data_directory = root / data_directory
    backend_metadata = data_directory / "terraform.tfstate"
    if not backend_metadata.is_file():
        raise ValueError("initialized backend metadata is missing or unreadable")
    # Terraform automatic input files; names and bytes are bound, never the private contents.
    input_files = sorted(path for path in root.iterdir() if path.name in ("terraform.tfvars", "terraform.tfvars.json")
                         or path.name.endswith((".auto.tfvars", ".auto.tfvars.json")))
    input_hashes = {path.name: file_hash(path) for path in input_files}
    environment_inputs = {name: hashlib.sha256(value.encode()).hexdigest()
                          for name, value in sorted(os.environ.items())
                          if name.startswith("TF_VAR_") or name in ("TF_CLI_ARGS", "TF_CLI_ARGS_plan", "TF_CLI_ARGS_apply")}
    return {"root": str(root), "plan_sha256": file_hash(plan),
            "approved_revision": revision, "workspace": "default",
            "backend_sha256": file_hash(backend), "backend_metadata_sha256": file_hash(backend_metadata),
            "terraform_data_directory": str(data_directory.resolve()), "input_sha256": input_hashes,
            "environment_input_sha256": environment_inputs,
            "state_presence": presence, "state_lineage": lineage, "state_serial": serial}


CONTRACT_KEYS = ("root", "plan_sha256", "approved_revision", "workspace", "backend_sha256",
                 "backend_metadata_sha256", "terraform_data_directory", "input_sha256", "environment_input_sha256", "state_presence", "state_lineage", "state_serial")


def verify(expected, actual):
    for key in CONTRACT_KEYS:
        if key not in expected or key not in actual or expected[key] != actual[key]:
            raise ValueError(f"reviewed saved-plan contract changed: {key}; create and review a fresh plan")


def record(root, plan, revision, evidence, run=subprocess.check_output):
    evidence = Path(evidence)
    if evidence.exists() or evidence.is_symlink():
        raise FileExistsError(f"saved-plan evidence already exists: {evidence}")
    actual = contract(root, plan, revision, run=run)
    actual["recorded_at"] = datetime.now(timezone.utc).isoformat()
    descriptor = os.open(evidence, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        stream.write(json.dumps(actual, indent=2) + "\n")
    return actual


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("record", "verify"))
    parser.add_argument("--root", required=True)
    parser.add_argument("--plan", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--evidence", required=True)
    args = parser.parse_args()
    evidence = Path(args.evidence)
    if args.mode == "record":
        actual = record(args.root, args.plan, args.revision, evidence)
        print(json.dumps(actual, indent=2))
    else:
        actual = contract(args.root, args.plan, args.revision)
        verify(json.loads(evidence.read_text()), actual)
        print("SAVED_PLAN_CONTRACT_OK")


if __name__ == "__main__":
    main()
