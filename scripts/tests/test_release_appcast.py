import base64
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("appcast", Path(__file__).parents[1] / "prepare-release-appcast.py")
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


class ReleaseAppcastTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.source = root / "appcast.xml"
        self.destination = root / "candidate.xml"
        self.archive = root / "release.zip"
        self.plist = root / "Info.plist"
        self.original = f'<rss xmlns:sparkle="{appcast.SPARKLE}"><channel><item><sparkle:version>9</sparkle:version><description><![CDATA[<p>Keep me</p>]]></description></item></channel></rss>'
        self.source.write_text(self.original)
        self.archive.write_bytes(b"archive")
        self.info = dict(CFBundleVersion="10", CFBundleShortVersionString="1.2.3", LSMinimumSystemVersion="15.0", SUPublicEDKey=base64.b64encode(bytes(32)).decode())
        self.plist.write_bytes(plistlib.dumps(self.info))
        signature = base64.b64encode(bytes(64)).decode()
        self.item = f'''<item xmlns:sparkle="{appcast.SPARKLE}">
<sparkle:version>10</sparkle:version><sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
<enclosure url="https://example.com/release.zip" length="7" type="application/octet-stream" sparkle:edSignature="{signature}"/>
</item>'''

    def prepare(self):
        appcast.prepare(self.source, self.destination, self.item, self.archive, self.plist)

    def test_valid_candidate_preserves_feed_and_existing_notes(self):
        self.prepare()
        self.assertEqual(self.source.read_text(), self.original)
        self.assertIn("<![CDATA[<p>Keep me</p>]]>", self.destination.read_text())
        self.assertEqual(len(appcast.ET.parse(self.destination).findall("channel/item")), 2)

    def test_invalid_release_never_mutates_source_or_candidate(self):
        changes = [
            ("<sparkle:version>10", "<sparkle:version>11"),
            ("1.2.3", "1.2.4"), ("15.0", "14.0"),
            ('length="7"', 'length="8"'), ("https://", "http://"),
            ("application/octet-stream", "text/plain"),
            (base64.b64encode(bytes(64)).decode(), "invalid"),
            ("<enclosure", "<missing"),
        ]
        original_item = self.item
        for before, after in changes:
            with self.subTest(change=before):
                self.item = original_item.replace(before, after)
                self.destination.write_text("previous candidate")
                with self.assertRaises(ValueError):
                    self.prepare()
                self.assertEqual(self.source.read_text(), self.original)
                self.assertEqual(self.destination.read_text(), "previous candidate")

    def test_duplicate_or_older_release_is_rejected(self):
        for prior in ("10", "11", "invalid"):
            with self.subTest(prior=prior):
                self.source.write_text(self.original.replace(">9<", f">{prior}<"))
                with self.assertRaisesRegex(ValueError, "newer"):
                    self.prepare()

    def test_missing_public_key_is_rejected(self):
        del self.info["SUPublicEDKey"]
        self.plist.write_bytes(plistlib.dumps(self.info))
        with self.assertRaisesRegex(ValueError, "public key"):
            self.prepare()

    def test_malformed_existing_feed_is_rejected(self):
        self.source.write_text("<rss>")
        with self.assertRaises(appcast.ET.ParseError):
            self.prepare()
        self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()
