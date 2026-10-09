#!/usr/bin/env python3
"""Exercise the real evidence CLI; these checks never exercise AWS or a cluster."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


class EvidenceCLI(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="evidence-contract-")
        self.addCleanup(self.directory.cleanup)
        self.env = dict(os.environ, EVIDENCE_ROOT=self.directory.name,
                        INFRA_ROOT=self.directory.name,
                        EVIDENCE_KUBE_CONTEXT="local-fixture-no-cluster")

    def cli(self, *args):
        return subprocess.run([sys.executable, str(HERE / "evidence.py"), *args],
                              env=self.env, text=True, capture_output=True)

    def start(self):
        result = self.cli("start", "memory-limit")
        self.assertEqual(result.returncode, 0, result.stderr)
        path_result = self.cli("path", "memory-limit")
        self.assertEqual(path_result.returncode, 0, path_result.stderr)
        self.path = Path(path_result.stdout.strip())
        self.assertEqual(self.path.parent.name, "attempts")
        self.assertEqual(self.path.parent.parent.name, "memory-limit")

    def record(self):
        body = "# Local evidence contract fixture\n\n"
        for number in range(1, 8):
            body += f"## {number} Local decision\n\nOnly local CLI storage was exercised. AWS and service recovery were not run.\n\n"
        (self.path / "record.md").write_text(body)

    def observations(self):
        (self.path / "response.txt").write_text("local fixture observation; no remote API was called\n")
        result = subprocess.run([sys.executable, str(HERE / "incident-record.py"),
                                 "collect", "memory-limit", "--directory", str(self.path)],
                                env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("facts=REVIEW_REQUIRED", result.stdout)

    def test_start_path_observe_human_result_seal_check(self):
        self.start()
        self.record()
        (self.path / "scratch" / "non-secret.txt").write_text("preserve this raw note\n")
        self.observations()
        result = self.cli("set", "memory-limit", "result=UNKNOWN", "level=LOCAL_FIXTURE")
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.cli("seal", "memory-limit")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.path / "scratch" / "non-secret.txt").is_file())
        result = self.cli("check", "memory-limit")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("\tUNKNOWN", result.stdout)
        self.assertIn("problems=0", result.stdout)

    def test_legacy_id_and_judge_are_rejected(self):
        self.assertNotEqual(self.cli("start", "t5").returncode, 0)
        self.assertNotEqual(self.cli("judge", "memory-limit").returncode, 0)

    def test_open_attempt_is_not_overwritten(self):
        self.start()
        result = self.cli("start", "memory-limit")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("EVIDENCE_OPEN_ATTEMPT", result.stderr)

    def test_identity_cannot_be_rewritten(self):
        self.start()
        self.assertNotEqual(self.cli("set", "memory-limit", "kube_context=other").returncode, 0)

    def test_record_without_observations_cannot_be_sealed(self):
        self.start()
        self.record()
        self.cli("set", "memory-limit", "result=UNKNOWN")
        result = self.cli("seal", "memory-limit")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.path / "manifest.sha256").exists())

    def test_sealed_mutation_is_detected(self):
        self.start()
        self.record()
        self.observations()
        self.cli("set", "memory-limit", "result=UNKNOWN")
        self.assertEqual(self.cli("seal", "memory-limit").returncode, 0)
        (self.path / "response.txt").write_text("changed after sealing\n")
        result = self.cli("check", "memory-limit")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("mismatch", result.stdout)

    def test_case_inventory_uses_actual_registry(self):
        expected = {entry["case_id"] for entry in json.loads((HERE / "cases.json").read_text())["cases"]}
        result = self.cli("cases")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(result.stdout.splitlines()), expected)


if __name__ == "__main__":
    unittest.main()
