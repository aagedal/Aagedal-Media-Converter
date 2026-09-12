import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('avm_evidence', Path(__file__).parents[1] / 'verify-avm-evidence.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class AVMEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.evidence = self.root / 'evidence'
        self.source = self.root / 'source'
        self.evidence.mkdir()
        (self.source / 'third_party/example').mkdir(parents=True)
        (self.source / 'third_party/example/LICENSE').write_bytes(b'notice\r\n')
        (self.evidence / 'LICENSE').write_bytes(b'notice\r\n')
        self.input = self.source / 'third_party/example/source.c'
        self.input.write_bytes(b'original source')
        rows = {'third_party/example/source.c': MODULE.sha256(self.input.read_bytes())}
        component = {'directory': 'third_party/example', 'compilerReferencedFileCount': 1,
                     'compilerReferencedFilesSHA256': MODULE.fingerprint(rows.items()),
                     'retainedFiles': [{'sourcePath': 'third_party/example/LICENSE', 'snapshotPath': 'LICENSE',
                                        'bytes': 8, 'sha256': MODULE.sha256(b'notice\r\n')}]}
        inventory = {'components': [component], 'compilerDependencyFileCount': 0,
                     'compilerDependencyRecordSetSHA256': MODULE.fingerprint([])}
        (self.evidence / 'inventory.json').write_text(json.dumps(inventory))
        (self.evidence / 'compiler-inputs.json').write_text(json.dumps(
            {'schemaVersion': 1, 'components': {'third_party/example': rows}}))

    def test_snapshots_and_sources_match(self):
        self.assertEqual(MODULE.verify(self.evidence, self.source), (1, []))

    def test_snapshot_line_ending_changes_fail(self):
        (self.evidence / 'LICENSE').write_bytes(b'notice\n')
        self.assertIn('Snapshot changed: LICENSE', MODULE.verify(self.evidence)[1])

    def test_source_drift_is_reported_by_path(self):
        self.input.write_bytes(b'changed source')
        self.assertIn('Compiler input changed or missing: third_party/example/source.c',
                      MODULE.verify(self.evidence, self.source)[1])

    def test_dependency_record_addition_fails(self):
        (self.source / 'build_arm64').mkdir()
        (self.source / 'build_arm64/new.o.d').write_text('new input')
        self.assertIn('Compiler dependency record set changed', MODULE.verify(self.evidence, self.source)[1])

    def test_fingerprint_uses_path_component_order(self):
        rows = [('include/fp16.h', 'a'), ('include/fp16/file.h', 'b')]
        self.assertEqual(MODULE.fingerprint(rows), MODULE.sha256(
            b'include/fp16/file.h\tb\ninclude/fp16.h\ta\n'))

    def test_paths_cannot_escape_root(self):
        with self.assertRaises(ValueError):
            MODULE.contained(self.evidence, '../outside')


if __name__ == '__main__':
    unittest.main()
