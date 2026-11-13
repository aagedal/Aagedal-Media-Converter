#!/usr/bin/env python3
"""Collect license files and permissive source notices from an extracted source tree.

Writes a notice container in the format of the current MPVKit FFmpeg collection
(`docs/provenance/4.5-local-builds/mpvkit-n9.0.2/FFmpeg-NOTICES.txt`) and an
index recording each notice's origins and SHA-256. Upstream license files are
named explicitly; source notices are leading comment blocks that grant
permissive (MIT, BSD, ISC, Apache, Boost, public-domain) terms. Identical texts
are emitted once with all their origins. Inclusion does not assert that a file
is linked into a binary.

    scripts/collect-source-notices.py TREE OUT.txt INDEX.json \\
        --title "mpv 0.42.0 source notices" --source URL --revision REV \\
        --upstream Copyright LICENSE.GPL LICENSE.LGPL [--no-scan] [--prefix DIR/]
"""

import argparse
import hashlib
import json
import re
from pathlib import Path


SEPARATOR = "=" * 72 + "\n"
EXTENSIONS = {".c", ".h", ".m", ".mm", ".cc", ".cpp", ".hpp", ".S", ".s", ".asm", ".py", ".swift", ".lua", ".js"}
PERMISSIVE = re.compile(
    r"Permission to use, copy|Permission is hereby granted|Redistribution and use"
    r"|This is free and unencumbered|Boost Software License|Licensed under the Apache",
    re.IGNORECASE,
)
HEAD_LINES = 80
DIRECTIVES = ("#include", "#define", "#if", "#import", "#pragma", "#!")


def leading_comment_blocks(lines: list[str]):
    """Yield (first, last) line indexes of comment blocks near the top of a file."""
    index = 0
    while index < min(len(lines), HEAD_LINES):
        stripped = lines[index].lstrip()
        if stripped.startswith("/*"):
            end = index
            rest = stripped[2:]
            while "*/" not in rest and end + 1 < len(lines):
                end += 1
                rest = lines[end]
            yield index, end
            index = end + 1
        elif stripped.startswith(("//", "#", ";", "--")) and not stripped.startswith(DIRECTIVES):
            marker = stripped[0]
            end = index
            while end + 1 < len(lines) and lines[end + 1].strip() and lines[end + 1].lstrip().startswith(marker):
                end += 1
            yield index, end
            index = end + 1
        else:
            index += 1


def source_notices(tree: Path, prefix: str) -> list[tuple[str, list[str]]]:
    found: dict[str, list[str]] = {}
    for path in sorted(p for p in tree.rglob("*") if p.is_file() and p.suffix in EXTENSIONS):
        try:
            lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        except (UnicodeDecodeError, OSError):
            continue
        for first, last in leading_comment_blocks(lines):
            block = "".join(lines[first:last + 1]).rstrip("\n")
            if PERMISSIVE.search(block):
                origin = f"{prefix}{path.relative_to(tree).as_posix()}:{first + 1}"
                found.setdefault(block, []).append(origin)
    return list(found.items())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("tree", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("index", type=Path)
    parser.add_argument("--title", required=True)
    parser.add_argument("--source", required=True, help="URL of the exact source revision")
    parser.add_argument("--revision", required=True)
    parser.add_argument("--upstream", nargs="*", default=[], help="License files, relative to the tree")
    parser.add_argument("--prefix", default="", help="Prefix for recorded origins")
    parser.add_argument("--no-scan", action="store_true", help="Only collect the named license files")
    args = parser.parse_args()

    notices = [(args.prefix + name, (args.tree / name).read_text(encoding="utf-8")) for name in args.upstream]
    entries = [(text, [origin]) for origin, text in notices]
    if not args.no_scan:
        entries += source_notices(args.tree, args.prefix)

    parts = [
        f"{args.title}\nSource: {args.source}\n\n"
        "Collected license files and source permission notices include optional/unlinked components.\n\n"
    ]
    index = []
    for text, origins in entries:
        parts.append(f"{SEPARATOR}Origin: {', '.join(origins)}\n\n{text}\n\n")
        index.append({"sources": origins, "sha256": hashlib.sha256(text.encode("utf-8")).hexdigest()})
    container = "".join(parts).encode("utf-8")
    args.output.write_bytes(container)
    args.index.write_text(json.dumps({
        "revision": args.revision,
        "notices": index,
        "containerSHA256": hashlib.sha256(container).hexdigest(),
    }, indent=2) + "\n")
    print(f"Wrote {args.output} ({len(index)} notices, {len(container):,} bytes)")


if __name__ == "__main__":
    main()
