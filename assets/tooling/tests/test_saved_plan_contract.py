import importlib.util
import json
import stat
import os
import subprocess
from unittest.mock import patch
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('saved_plan_contract', Path(__file__).parents[1] / 'scripts/lab/saved_plan_contract.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class SavedPlanContract(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.plan = Path(self.directory.name) / 'reviewed.tfplan'
        self.plan.write_bytes(b'approved-plan')
        self.backend = Path(self.directory.name) / 'backend.hcl'
        self.backend.write_text('bucket = "approved"\nkey = "eks/state"\n')
        self.data_directory = Path(self.directory.name) / '.terraform'
        self.data_directory.mkdir()
        self.backend_metadata = self.data_directory / 'terraform.tfstate'
        self.backend_metadata.write_text('{"backend":{"type":"s3","config":{"key":"eks/state"}}}')
        self.environment = patch.dict(os.environ, {})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        os.environ.pop('TF_DATA_DIR', None)
        self.workspace = b'default\n'
        self.state = {'lineage': '7b597e42-8429-4bfa-8935-98a9f77196d6', 'serial': 4, 'resources': [{'secret': 'must-not-save'}]}

    def fake_run(self, command, **kwargs):
        if command[-2:] == ['workspace', 'show']:
            return self.workspace
        return json.dumps(self.state).encode()

    def current(self):
        return module.contract(self.directory.name, self.plan, 'a' * 40,
                               run=self.fake_run)

    def test_same_and_no_secrets(self):
        result = self.current()
        module.verify(result, self.current())
        self.assertNotIn('secret', json.dumps(result))
        self.assertEqual(len(result['plan_sha256']), 64)

    def test_plan_changed(self):
        approved = self.current()
        self.plan.write_bytes(b'replaced-plan')
        with self.assertRaisesRegex(ValueError, 'plan_sha256'):
            module.verify(approved, self.current())

    def test_state_or_lineage_changed(self):
        approved = self.current()
        for key, value in [('serial', 5), ('lineage', 'other')]:
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, key):
                module.verify(approved, dict(approved, **{f'state_{key}': value}))

    def test_revision_or_root_changed(self):
        approved = self.current()
        for key in ('approved_revision', 'root'):
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, key):
                module.verify(approved, dict(approved, **{key: 'changed'}))

    def test_required_metadata(self):
        for state in ({}, {'lineage': 'ok', 'serial': True}):
            self.state = state
            with self.assertRaises(ValueError):
                self.current()

    def test_record_existing_file_and_broken_symlink_stop_before_state(self):
        for kind in ('file', 'symlink'):
            with self.subTest(kind=kind):
                evidence = Path(self.directory.name) / kind
                if kind == 'file':
                    evidence.write_text('original')
                else:
                    evidence.symlink_to('missing-target')
                def unexpected(*args, **kwargs):
                    self.fail('State must not be read for an existing evidence path')
                with self.assertRaises(FileExistsError):
                    module.record(self.directory.name, self.plan, 'a' * 40, evidence, run=unexpected)
                if kind == 'file':
                    self.assertEqual(evidence.read_text(), 'original')
                else:
                    self.assertTrue(evidence.is_symlink())

    def test_record_fresh_evidence_is_private(self):
        evidence = Path(self.directory.name) / 'fresh.json'
        result = module.record(self.directory.name, self.plan, 'a' * 40, evidence,
                               run=self.fake_run)
        self.assertEqual(json.loads(evidence.read_text()), result)
        self.assertEqual(stat.S_IMODE(evidence.stat().st_mode), 0o600)
        self.assertNotIn('must-not-save', evidence.read_text())

    def test_record_late_collision_preserves_other_writer(self):
        evidence = Path(self.directory.name) / 'race.json'
        def collision(command, **kwargs):
            evidence.write_text('other writer')
            return self.fake_run(command, **kwargs)
        with self.assertRaises(FileExistsError):
            module.record(self.directory.name, self.plan, 'a' * 40, evidence, run=collision)
        self.assertEqual(evidence.read_text(), 'other writer')

    def test_exact_empty_state_first_creation_and_presence_change(self):
        def absent(command, **kwargs):
            return b'default\n' if command[-2:] == ['workspace', 'show'] else b''
        approved = module.contract(self.directory.name, self.plan, 'a' * 40, run=absent)
        self.assertEqual(approved['state_presence'], 'absent')
        self.assertIsNone(approved['state_lineage'])
        self.assertIsNone(approved['state_serial'])
        module.verify(approved, module.contract(self.directory.name, self.plan, 'a' * 40, run=absent))
        with self.assertRaisesRegex(ValueError, 'state_presence'):
            module.verify(approved, self.current())
        with self.assertRaisesRegex(ValueError, 'state_presence'):
            module.verify(self.current(), approved)

    def test_state_error_and_malformed_are_not_absence(self):
        def failed(command, **kwargs):
            if command[-2:] == ['workspace', 'show']:
                return b'default\n'
            raise subprocess.CalledProcessError(1, command, output=b'')
        with self.assertRaises(subprocess.CalledProcessError):
            module.contract(self.directory.name, self.plan, 'a' * 40, run=failed)
        for raw in (b'\n', b'null', b'[]', b'{', b'{"lineage":"ok","serial":-1}'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                module.contract(self.directory.name, self.plan, 'a' * 40,
                                run=lambda command, **kwargs: b'default\n' if command[-2:] == ['workspace', 'show'] else raw)

    def test_workspace_backend_and_inputs_change(self):
        approved = self.current()
        self.workspace = b'prod\n'
        with self.assertRaisesRegex(ValueError, 'workspace'):
            self.current()
        self.workspace = b'default\n'
        self.backend.write_text('bucket = "other"')
        with self.assertRaisesRegex(ValueError, 'backend_sha256'):
            module.verify(approved, self.current())
        self.backend.write_text('bucket = "approved"\nkey = "eks/state"\n')
        original_metadata = self.backend_metadata.read_text()
        self.backend_metadata.write_text('{"backend":{"type":"s3","config":{"key":"other/state"}}}')
        with self.assertRaisesRegex(ValueError, 'backend_metadata_sha256'):
            module.verify(approved, self.current())
        self.backend_metadata.write_text(original_metadata)
        for name in ('terraform.tfvars', 'terraform.tfvars.json', 'nodes.auto.tfvars', 'extra.auto.tfvars.json'):
            path = Path(self.directory.name) / name
            with self.subTest(name=name):
                path.write_text('private-input')
                with self.assertRaisesRegex(ValueError, 'input_sha256'):
                    module.verify(approved, self.current())
                first = self.current()
                path.write_text('changed-private-input')
                with self.assertRaisesRegex(ValueError, 'input_sha256'):
                    module.verify(first, self.current())
                self.assertNotIn('private-input', json.dumps(first))
                path.unlink()

    def test_environment_input_and_legacy_evidence_fail_closed(self):
        with patch.dict(os.environ, {'TF_VAR_example': 'private-secret'}):
            approved = self.current()
            self.assertNotIn('private-secret', json.dumps(approved))
            with patch.dict(os.environ, {'TF_VAR_example': 'other-secret'}):
                with self.assertRaisesRegex(ValueError, 'environment_input_sha256'):
                    module.verify(approved, self.current())
        legacy = self.current()
        del legacy['state_presence']
        with self.assertRaisesRegex(ValueError, 'state_presence'):
            module.verify(legacy, self.current())

    def test_missing_backend_and_broken_input_link_stop(self):
        self.backend.unlink()
        with self.assertRaisesRegex(ValueError, 'backend.hcl'):
            self.current()
        self.backend.write_text('bucket = "approved"')
        (Path(self.directory.name) / 'broken.auto.tfvars').symlink_to('missing')
        with self.assertRaises(FileNotFoundError):
            self.current()

if __name__ == '__main__':
    unittest.main()
