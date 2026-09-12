"""Run the production remote upload lease in separate macOS processes.

The lease and destination identity are extracted verbatim from production sources.
Only their model/error adapters are supplied here to avoid linking the full app
and its dependencies.
"""
from contextlib import contextmanager
from pathlib import Path
import selectors
import subprocess
import tempfile
import unittest


class RemoteUploadProcessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.executable = cls.root / "remote-lease"
        service = Path(__file__).parents[2] / "Aagedal Media Converter/Logic/Upload/RcloneService.swift"
        source = service.read_text()
        marker = "final class RemoteUploadLease: Sendable {"
        if source.count(marker) != 1:
            raise AssertionError("Update the harness extraction for the production lease declaration")
        models = service.with_name("UploadModels.swift").read_text()
        identity_marker = "struct UploadDestinationIdentity: Hashable, Sendable {"
        if models.count(identity_marker) != 1:
            raise AssertionError("Update the harness extraction for the destination identity")
        identity = models.split(identity_marker, 1)[1].split("// MARK: - Upload Profiles", 1)[0]
        lease = cls.root / "RemoteUploadLease.swift"
        lease.write_text("import Foundation\nimport CryptoKit\nimport Darwin\nimport os\n" +
                         identity_marker + identity +
                         marker + source.split(marker, 1)[1])
        driver = cls.root / "main.swift"
        driver.write_text('''import Foundation
import Darwin

enum UploadBackendType: String {
    case ftp, sftp, smb, s3, gdrive
    var defaultPort: Int {
        switch self {
        case .ftp: return 21
        case .sftp: return 22
        case .smb: return 445
        case .s3, .gdrive: return 0
        }
    }
}
struct UploadConfig {
    var backendType: UploadBackendType = .sftp
    var server = "media.example"
    var port = 22
    var remotePath = "/deliveries"
    var s3Endpoint: String? = nil
    var s3Bucket: String? = nil
    var smbShare: String? = nil
}
enum UploadError: Error { case uploadFailed(String) }

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let fileName = CommandLine.arguments[2]
let mode = CommandLine.arguments[3]
var config = UploadConfig()
switch CommandLine.arguments[4] {
case "sftp-host-alias":
    config.server = "MEDIA.EXAMPLE."
case "sftp-port-alias":
    config.port = 0
case "s3", "s3-alias":
    config.backendType = .s3
    config.s3Bucket = "media"
    config.s3Endpoint = CommandLine.arguments[4] == "s3" ? "https://s3.example" : "HTTPS://S3.EXAMPLE.:443/"
default: break
}
do {
    let lease = try RemoteUploadLease(config: config, fileName: fileName, lockDirectory: directory)
    FileHandle.standardOutput.write(Data("acquired\\n".utf8))
    if mode == "hold" { _ = readLine() }
    lease.release()
} catch {
    FileHandle.standardOutput.write(Data("rejected\\n".utf8))
    exit(1)
}
''')
        subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(cls.root / "cache"),
                        str(lease), str(driver), "-o", str(cls.executable)],
                       check=True, capture_output=True, text=True)

    def acquire(self, directory, name="clip.mov", config="sftp"):
        return subprocess.run([str(self.executable), str(directory), name, "once", config],
                              capture_output=True, text=True, timeout=10)

    @contextmanager
    def holder(self, directory, name="clip.mov", config="sftp"):
        process = subprocess.Popen([str(self.executable), str(directory), name, "hold", config],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                self.assertTrue(selector.select(timeout=10), "Lease holder did not become ready")
            self.assertEqual(process.stdout.readline().strip(), "acquired")
            yield process
        finally:
            if process.poll() is None:
                process.terminate()
            process.communicate(timeout=10)

    def test_same_destination_rejects_other_process_and_retries_after_release(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.holder(directory, "Clip.mov") as holder:
                result = self.acquire(directory)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(result.stdout.strip(), "rejected")
                holder.communicate(input="release\n", timeout=10)
                self.assertEqual(holder.returncode, 0)
                self.assertEqual(self.acquire(directory).returncode, 0)
            self.assertEqual(len(list(Path(directory).glob("*.lock"))), 1)

    def test_equivalent_endpoints_contend_across_processes(self):
        variants = (("sftp", "sftp-host-alias"), ("sftp", "sftp-port-alias"), ("s3", "s3-alias"))
        for backend, alias in variants:
            with self.subTest(alias=alias), tempfile.TemporaryDirectory() as directory:
                with self.holder(directory, config=backend):
                    result = self.acquire(directory, config=alias)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertEqual(result.stdout.strip(), "rejected")
                self.assertEqual(self.acquire(directory, config=alias).returncode, 0)
                self.assertEqual(len(list(Path(directory).glob("*.lock"))), 1)

    def test_s3_case_distinct_objects_can_upload_concurrently(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.holder(directory, "Clip.mov", config="s3"):
                result = self.acquire(directory, "clip.mov", config="s3")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_distinct_files_can_be_held_by_separate_processes(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.holder(directory):
                result = self.acquire(directory, "another.mov")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_process_death_releases_lock_without_removing_lock_file(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.holder(directory) as holder:
                lock = next(Path(directory).glob("*.lock"))
                inode = lock.stat().st_ino
                holder.kill()
                holder.communicate(timeout=10)
                self.assertEqual(self.acquire(directory).returncode, 0)
                self.assertEqual(lock.stat().st_ino, inode)


if __name__ == "__main__":
    unittest.main()
