"""Protect source material integrity and companion packaging before release."""
import hashlib
import json
import importlib.util
from pathlib import Path
import tarfile
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("sources", Path(__file__).parents[1] / "package-attribution-sources.py")
sources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sources)


class AttributionSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "docs").mkdir()
        (self.root / "docs/attribution-sources.md").write_text("Source rebuild instructions\n")
        self.path = self.root / "component.tar.xz"
        self.path.write_bytes(b"reviewed source material")
        self.manifest = {"archives": [{"component": "Example", "path": self.path.name,
            "bytes": self.path.stat().st_size, "sha256": hashlib.sha256(self.path.read_bytes()).hexdigest()}]}

    def test_packages_exact_bytes_and_instructions(self):
        output = self.root / "sources.tar"
        sources.package_sources(self.root, self.manifest, output)
        with tarfile.open(output) as archive:
            self.assertEqual(archive.extractfile(self.path.name).read(), self.path.read_bytes())
            self.assertIn("README.md", archive.getnames())
            metadata = json.load(archive.extractfile("AttributionSources.json"))
            self.assertEqual(metadata["archives"][0]["path"], self.path.name)

    def test_changed_material_rejected_without_replacing_existing_companion(self):
        output = self.root / "sources.tar"
        output.write_bytes(b"previous verified package")
        self.path.write_bytes(b"changed source material!")
        with self.assertRaisesRegex(ValueError, "differs"):
            sources.package_sources(self.root, self.manifest, output)
        self.assertEqual(output.read_bytes(), b"previous verified package")

    def test_missing_material_rejected(self):
        self.path.unlink()
        with self.assertRaisesRegex(ValueError, "Missing source"):
            sources.verify_sources(self.root, self.manifest)

    def test_external_symlink_rejected(self):
        self.path.unlink()
        self.path.symlink_to(Path(__file__).resolve())
        with self.assertRaisesRegex(ValueError, "escapes"):
            sources.verify_sources(self.root, self.manifest)

    def test_duplicate_or_reserved_member_names_rejected(self):
        self.manifest["archives"].append(dict(self.manifest["archives"][0]))
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            sources.verify_sources(self.root, self.manifest)
        self.manifest["archives"] = [{**self.manifest["archives"][0], "path": "README.md"}]
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            sources.verify_sources(self.root, self.manifest)

    def test_cannot_overwrite_source_input(self):
        with self.assertRaisesRegex(ValueError, "overwrite"):
            sources.package_sources(self.root, self.manifest, self.path)
        self.assertEqual(self.path.read_bytes(), b"reviewed source material")
