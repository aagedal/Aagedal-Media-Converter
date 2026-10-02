import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "release_upload", Path(__file__).parents[1] / "upload-release-asset.py"
)
upload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upload)


class ReleaseUploadTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.asset = Path(temporary.name) / "source archive.tar"
        self.asset.write_bytes(b"test archive")
        self.release = {"databaseId": 42, "assets": []}
        self.commands = []
        self.status = 0
        self.response = {"state": "uploaded", "size": self.asset.stat().st_size}

    def run_command(self, command, **kwargs):
        self.commands.append(command)
        if command[0] == "curl":
            self.assertNotIn("test-token", " ".join(command))
            self.assertEqual(kwargs["input"], 'header = "Authorization: Bearer test-token"\n')
            self.assertIn("--progress-bar", command)
            self.assertIn("--upload-file", command)
            self.assertIn("name=source+archive.tar", command[-1])
            Path(command[command.index("--output") + 1]).write_text(json.dumps(self.response))
        return subprocess.CompletedProcess(command, self.status)

    def perform_upload(self):
        with patch.object(upload.subprocess, "check_output", side_effect=[
            json.dumps(self.release), "test-token\n",
        ]), patch.object(upload.subprocess, "run", side_effect=self.run_command), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            upload.upload_asset("owner/repo", "1.0", self.asset)
        return output.getvalue()

    def test_upload_reports_verified_completion(self):
        output = self.perform_upload()
        self.assertIn("MiB", output)
        self.assertIn("Uploaded source archive.tar", output)
        self.assertIn("MiB/s", output)

    def test_replacement_uses_rest_asset_url_before_upload(self):
        asset_url = "https://api.github.com/repos/owner/repo/releases/assets/123"
        self.release["assets"] = [{"name": self.asset.name, "id": "RA_node", "apiUrl": asset_url}]
        self.perform_upload()
        self.assertEqual(self.commands[0], ["gh", "api", "--method", "DELETE", asset_url])
        self.assertEqual(self.commands[1][0], "curl")

    def test_transfer_failure_stops_without_completion(self):
        self.status = 22
        with self.assertRaisesRegex(RuntimeError, "curl exit 22"):
            self.perform_upload()

    def test_incomplete_asset_is_rejected(self):
        self.response["state"] = "starter"
        with self.assertRaisesRegex(RuntimeError, "complete upload"):
            self.perform_upload()

    def test_wrong_size_is_rejected(self):
        self.response["size"] = 1
        with self.assertRaisesRegex(RuntimeError, "complete upload"):
            self.perform_upload()


if __name__ == "__main__":
    unittest.main()
