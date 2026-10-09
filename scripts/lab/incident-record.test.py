import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("record", Path(__file__).with_name("incident-record.py"))
record = importlib.util.module_from_spec(spec); spec.loader.exec_module(record)


class RecordTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.directory = Path(self.tmp.name) / "case/attempts/current-id"
        self.directory.mkdir(parents=True)
        (self.directory.parent.parent / "current").symlink_to(self.directory)
        (self.directory / "run.tsv").write_text("case\tcase\nattempt_id\tcurrent-id\nsealed_utc\t\n")
        self.addCleanup(self.tmp.cleanup)

    def invoke(self, action, *args):
        return record.run([action, "case", "--directory", str(self.directory), *args])

    def test_draft_does_not_overwrite_previous_investigation(self):
        self.invoke("draft")
        with self.assertRaises(FileExistsError): self.invoke("draft")

    def test_empty_decisions_cannot_be_finalized(self):
        self.invoke("draft")
        with self.assertRaisesRegex(ValueError, "decision 1"): self.invoke("finalize")

    def test_changed_evidence_cannot_be_finalized(self):
        self.invoke("draft")
        file = self.directory / "pod.json"; file.write_text('{}')
        self.invoke("observe", "--source", "pod.json", "--command", "kubectl get pod", "--exit-code", "0")
        text = (self.directory / "record.md").read_text().replace('<!-- 실제 관측과 근거 경로를 적으세요. 미확인은 이유·담당·다음 확인을 적습니다. -->', '실제 관측은 pod.json을 참조하며 다음 조회가 필요하다.')
        (self.directory / "record.md").write_text(text); file.write_text('{"changed":true}')
        with self.assertRaisesRegex(ValueError, "changed"): self.invoke("finalize")

    def test_sealed_attempt_is_read_only(self):
        (self.directory / "run.tsv").write_text("case\tcase\nattempt_id\tcurrent-id\nsealed_utc\t2026-10-06T00:00:00Z\n")
        with self.assertRaisesRegex(ValueError, "sealed"): self.invoke("draft")

    def test_symlink_evidence_is_rejected(self):
        source = self.directory / "source.json"; source.write_text('{}')
        (self.directory / "link.json").symlink_to(source)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.invoke("observe", "--source", "link.json", "--command", "get status", "--exit-code", "0")

    def test_external_evidence_is_rejected(self):
        self.invoke("draft")
        with self.assertRaises((ValueError, FileNotFoundError)):
            self.invoke("observe", "--source", "../outside", "--command", "get status", "--exit-code", "0")

    def test_secret_bearing_command_is_rejected(self):
        (self.directory / "response.json").write_text('{}')
        with self.assertRaisesRegex(ValueError, "secret"):
            self.invoke("observe", "--source", "response.json", "--command", "curl authorization=secret", "--exit-code", "0")


if __name__ == "__main__": unittest.main()
