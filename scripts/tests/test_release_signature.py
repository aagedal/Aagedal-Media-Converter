"""Real Ed25519 fixtures verify the public key used by installed Sparkle clients."""
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


class ReleaseSignatureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name)
        cls.verifier = cls.root / "verify-signature"
        subprocess.run(["xcrun", "swiftc", "-module-cache-path", str(cls.root / "cache"),
                        str(Path(__file__).parents[1] / "verify-update-signature.swift"),
                        "-o", str(cls.verifier)], check=True, capture_output=True, text=True)
        fixture = cls.root / "fixture.swift"
        fixture.write_text('''import Foundation
import CryptoKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
let data = Data("release fixture".utf8)
try data.write(to: root.appendingPathComponent("release.zip"))
let info = ["SUPublicEDKey": key.publicKey.rawRepresentation.base64EncodedString()]
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: root.appendingPathComponent("Info.plist"))
print(try key.signature(for: data).base64EncodedString())
''')
        cls.signature = subprocess.run(["xcrun", "swift", "-module-cache-path", str(cls.root / "cache"),
                                        str(fixture), str(cls.root)], check=True,
                                       capture_output=True, text=True).stdout.strip()

    def verify(self, archive=None, plist=None, signature=None):
        return subprocess.run([str(self.verifier), str(archive or self.root / "release.zip"),
                               str(plist or self.root / "Info.plist"), signature or self.signature],
                              capture_output=True, text=True)

    def test_valid_signature(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_tampered_archive(self):
        archive = self.root / "tampered.zip"
        archive.write_bytes(b"changed release")
        self.assertNotEqual(self.verify(archive=archive).returncode, 0)

    def test_different_embedded_public_key(self):
        plist = self.root / "wrong-key.plist"
        plist.write_bytes(plistlib.dumps({"SUPublicEDKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}))
        self.assertNotEqual(self.verify(plist=plist).returncode, 0)

    def test_malformed_signature(self):
        self.assertNotEqual(self.verify(signature="invalid").returncode, 0)


if __name__ == "__main__":
    unittest.main()
