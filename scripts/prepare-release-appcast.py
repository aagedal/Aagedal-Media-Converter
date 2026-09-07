#!/usr/bin/env python3
"""Build a validated appcast candidate without changing the live feed."""

import argparse
import base64
import binascii
from pathlib import Path
import plistlib
import re
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def prepare(source, destination, item_xml, archive, info_plist):
    original = Path(source).read_text()
    root = ET.fromstring(original)
    channel = root.find("channel")
    if root.tag != "rss" or channel is None:
        raise ValueError("Appcast must contain an RSS channel")
    item = ET.fromstring(item_xml)
    if item.tag != "item":
        raise ValueError("Release entry must be an item")
    with Path(info_plist).open("rb") as handle:
        info = plistlib.load(handle)
    for key, plist_key in (("version", "CFBundleVersion"),
                           ("shortVersionString", "CFBundleShortVersionString"),
                           ("minimumSystemVersion", "LSMinimumSystemVersion")):
        value = item.findtext(f"{{{SPARKLE}}}{key}")
        if not value or value != str(info.get(plist_key, "")):
            raise ValueError(f"Appcast {key} does not match the exported app")
    version = item.findtext(f"{{{SPARKLE}}}version")
    if not re.fullmatch(r"[0-9]+", version):
        raise ValueError("Release build number must be an integer")
    for previous in channel.findall("item"):
        prior = previous.findtext(f"{{{SPARKLE}}}version")
        if prior and (not prior.isascii() or not prior.isdigit() or int(prior) >= int(version)):
            raise ValueError("Release build must be newer than every existing appcast build")
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("Release entry has no enclosure")
    if enclosure.get("length") != str(Path(archive).stat().st_size):
        raise ValueError("Appcast archive length is incorrect")
    if not enclosure.get("url", "").startswith("https://"):
        raise ValueError("Release download URL must use HTTPS")
    if enclosure.get("type") != "application/octet-stream":
        raise ValueError("Release archive MIME type is incorrect")
    try:
        signature = base64.b64decode(enclosure.get(f"{{{SPARKLE}}}edSignature", ""), validate=True)
        public_key = base64.b64decode(info.get("SUPublicEDKey", ""), validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("Invalid Sparkle signature or public key encoding") from error
    if len(signature) != 64 or len(public_key) != 32:
        raise ValueError("Missing or invalid Sparkle signature or public key")
    # Preserve existing release notes, CDATA, whitespace, and namespace prefixes.
    needle = "</channel>"
    if original.count(needle) != 1:
        raise ValueError("Expected exactly one appcast channel closing tag")
    candidate = original.replace(needle, item_xml + "\n    " + needle, 1)
    ET.fromstring(candidate)
    Path(destination).write_text(candidate)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source", "destination", "item", "archive", "info-plist"):
        parser.add_argument(f"--{name}", required=True)
    args = parser.parse_args()
    prepare(args.source, args.destination, Path(args.item).read_text(), args.archive, args.info_plist)


if __name__ == "__main__":
    main()
