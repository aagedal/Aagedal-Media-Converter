#!/usr/bin/env python3
"""Assemble the reviewed MPVKit offline notices without network access.

The index records the original source/archive member for every notice and the
SHA-256 of its verbatim UTF-8 text. Containers use byte offsets, not character
offsets, so non-ASCII copyright holders remain intact.
"""

import argparse
import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INDEX = ROOT / "docs/provenance/4.4-local-builds/mpvkit-sources/notice-index.json"
OUTPUT = ROOT / "Licenses/mpvkit-LICENSE.txt"
INTRO = """MPVKit and preview playback dependencies
=======================================

Aagedal Media Converter uses the MPVKit-GPL package for media preview playback.
The package is pinned to revision 230c3174f1515898f24599147ad61c2a277d0dc2.
Its custom libraries contain mpv 0.41.0 and FFmpeg n8.1.2 with local patches.

The following copyright notices and license texts cover the package, its
binary dependencies, and the accompanying source and build materials.
Additional notices for source examples and build tools are retained alongside
runtime notices. The source URLs identify each collection's origin.

The selected package contains these 29 binary targets:
Libmpv-GPL; Libavcodec-GPL; Libavdevice-GPL; Libavformat-GPL;
Libavfilter-GPL; Libavutil-GPL; Libswresample-GPL; Libswscale-GPL;
Libcrypto; Libssl; gmp; nettle; hogweed; gnutls; Libunibreak;
Libfreetype; Libfribidi; Libharfbuzz; Libass; Libsmbclient; Libbluray;
Libuavs3d; Libdovi; MoltenVK; Libshaderc_combined; lcms2; Libplacebo;
Libdav1d; Libuchardet.

Portions of this software are copyright (C) The FreeType Project
(https://freetype.org). All rights reserved.

"""


def render(index: Path = INDEX) -> bytes:
    document = json.loads(index.read_text())
    mapping = json.loads((index.parent / "target-notice-map.json").read_text())
    artifacts = json.loads((index.parent.parent / "mpvkit-archive-evidence.json").read_text())
    pins = {item["target"]: item["pinnedSHA256"] for item in artifacts["archives"]}
    if set(mapping) != set(pins):
        raise ValueError("MPVKit target notice coverage differs from the pinned graph")
    collections = {item["component"]: item["notices"] for item in document["components"]}
    for target, entry in mapping.items():
        if entry["archiveSHA256"] != pins[target]:
            raise ValueError(f"MPVKit archive pin changed: {target}")
        if not entry["noticeCollections"] or any(
            not collections.get(name) for name in entry["noticeCollections"]
        ):
            raise ValueError(f"MPVKit target has no retained notices: {target}")
    parts = [INTRO]
    emitted = {}
    containers = {}
    for component in document["components"]:
        if not component["notices"]:
            continue
        title = component["component"]
        parts.extend(["\n" + "=" * 72 + "\n", title + "\n", component["url"] + "\n\n"])
        for notice in component["notices"]:
            path = ROOT / notice["path"]
            if path not in containers:
                containers[path] = path.read_bytes()
            begin = notice["startByte"]
            text = containers[path][begin:begin + notice["byteLength"]]
            digest = hashlib.sha256(text).hexdigest()
            if digest != notice["sha256"]:
                raise ValueError(f"Notice hash mismatch: {path}, byte {begin}")
            parts.append("Origin: " + notice["sources"][0] + "\n")
            if digest in emitted:
                parts.append("Identical notice reproduced above under: " + emitted[digest] + "\n\n")
            else:
                emitted[digest] = title + " / " + notice["sources"][0]
                parts.extend(["\n", text.decode("utf-8"), "\n\n"])
    return "".join(parts).encode("utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if the bundled notices differ from the reviewed inputs")
    args = parser.parse_args()
    result = render()
    if args.check:
        if not OUTPUT.is_file() or OUTPUT.read_bytes() != result:
            raise SystemExit("MPVKit notices are stale; run scripts/generate-mpvkit-notices.py")
        print(f"MPVKit notices verified ({len(result):,} bytes)")
    else:
        OUTPUT.write_bytes(result)
        print(f"Wrote {OUTPUT.relative_to(ROOT)} ({len(result):,} bytes)")


if __name__ == "__main__":
    main()
