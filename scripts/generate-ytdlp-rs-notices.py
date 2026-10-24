#!/usr/bin/env python3
"""Audit the bundled yt-dlp-rs dependency closure and retain its notices.

Maintainer-only (called by scripts/update-ytdlp-rs.sh). Downloads the tagged
yt-dlp-rs source, resolves its locked aarch64-apple-darwin dependency closure
with Cargo, and writes:

- Licenses/yt-dlp-rs-LICENSE.txt (packaged; shown in About > Licenses)
- docs/provenance/yt-dlp-rs/dependencies.json (reviewed inventory)
- build/attribution/yt-dlp-rs-mpl-crate-sources.tar.gz (exact crates.io
  sources of the MPL-2.0 crates, for the release source companion) and its
  AttributionSources.json entry.

Requires network access, Cargo, and the Rust toolchain that built the release
(its standard-library notice is retained).
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
from html.parser import HTMLParser
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import tomllib
import urllib.request

REPOSITORY = Path(__file__).resolve().parent.parent
PROVENANCE = REPOSITORY / "docs/provenance/yt-dlp-rs"
LICENSE_OUTPUT = REPOSITORY / "Licenses/yt-dlp-rs-LICENSE.txt"
SOURCE_ARCHIVE = Path("build/attribution/yt-dlp-rs-mpl-crate-sources.tar.gz")
SOURCE_COMPONENT = "yt-dlp-rs MPL-2.0 crate sources"
UPSTREAM = "https://github.com/aagedal/yt-dlp-rs"
TARGET = "aarch64-apple-darwin"
# SPDX expressions reviewed for GPLv3 compatibility. A new expression requires
# review instead of silently licensing a new dependency.
REVIEWED_LICENSES = {
    "(Apache-2.0 OR MIT) AND BSD-3-Clause", "(MIT OR Apache-2.0) AND Unicode-3.0",
    "0BSD OR MIT OR Apache-2.0", "Apache-2.0", "Apache-2.0 AND ISC",
    "Apache-2.0 OR BSL-1.0", "Apache-2.0 OR ISC OR MIT", "Apache-2.0 OR MIT",
    "Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT", "Apache-2.0/MIT",
    "BSD-3-Clause", "CDLA-Permissive-2.0", "ISC", "MIT", "MIT / Apache-2.0",
    "MIT OR Apache-2.0", "MIT OR Apache-2.0 OR Zlib", "MIT OR Zlib OR Apache-2.0",
    "MIT/Apache-2.0", "MPL-2.0", "Unicode-3.0", "Unlicense", "Unlicense OR MIT",
    "Zlib", "Zlib OR Apache-2.0 OR MIT",
}
NOTICE_PREFIXES = ("license", "licence", "copying", "copyright", "notice")


class PlainHTML(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []

    def handle_data(self, data):
        self.parts.append(data)

    def handle_starttag(self, tag, attrs):
        if tag in {"p", "div", "h1", "h2", "h3", "li", "pre", "br"}:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in {"p", "div", "h1", "h2", "h3", "li", "pre"}:
            self.parts.append("\n")


def download_source(tag: str, directory: Path) -> Path:
    archive = directory / "source.tar.gz"
    with urllib.request.urlopen(f"{UPSTREAM}/archive/refs/tags/{tag}.tar.gz") as response:
        archive.write_bytes(response.read())
    with tarfile.open(archive) as handle:
        handle.extractall(directory / "source", filter="data")
    roots = [p for p in (directory / "source").iterdir() if p.is_dir()]
    if len(roots) != 1:
        raise ValueError("Unexpected source archive layout")
    return roots[0]


def selected_packages(metadata: dict) -> tuple[dict, dict, list[dict]]:
    packages = {p["id"]: p for p in metadata["packages"]}
    nodes = {n["id"]: n for n in metadata["resolve"]["nodes"]}
    root = next(p["id"] for p in packages.values() if p["name"] == "yt-dlp-rs")
    selected: set[str] = set()

    def visit(package_id):
        if package_id in selected:
            return
        selected.add(package_id)
        for dependency in nodes[package_id]["deps"]:
            if any(kind["kind"] != "dev" for kind in dependency["dep_kinds"]):
                visit(dependency["pkg"])

    visit(root)
    ordered = sorted((packages[i] for i in selected), key=lambda p: (p["name"], p["version"]))
    return packages, nodes, ordered


def rust_notice(binary: Path | None) -> tuple[str, str]:
    verbose = subprocess.run(["rustc", "--version", "--verbose"], check=True,
                             capture_output=True, text=True).stdout
    commit = re.search(r"commit-hash: ([0-9a-f]{40})", verbose).group(1)
    version = verbose.splitlines()[0]
    if binary is not None and f"rustc/{commit}".encode() not in binary.read_bytes():
        raise ValueError(f"Local {version} differs from the toolchain that built {binary}; "
                         "install the matching toolchain for its standard-library notice")
    sysroot = subprocess.run(["rustc", "--print", "sysroot"], check=True,
                             capture_output=True, text=True).stdout.strip()
    parser = PlainHTML()
    parser.feed((Path(sysroot) / "share/doc/rust/COPYRIGHT-library.html").read_text(encoding="utf-8"))
    return version, "".join(parser.parts)


def crate_archive(package: dict, lock_checksums: dict) -> tuple[str, bytes]:
    name, version = package["name"], package["version"]
    checksum = lock_checksums[(name, version)]
    caches = sorted((Path.home() / ".cargo/registry/cache").glob(f"*/{name}-{version}.crate"))
    for cache in caches:
        data = cache.read_bytes()
        if hashlib.sha256(data).hexdigest() == checksum:
            return f"{name}-{version}.crate", data
    raise ValueError(f"No cached crate matching the Cargo.lock checksum for {name} {version}")


def write_deterministic_archive(path: Path, files: list[tuple[str, bytes]]) -> None:
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for name, data in sorted(files):
            info = tarfile.TarInfo(f"yt-dlp-rs-mpl-crate-sources/{name}")
            info.size = len(data)
            info.mode = 0o644
            info.mtime = 0
            info.uname = info.gname = ""
            archive.addfile(info, io.BytesIO(data))
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as gz:
        gz.write(buffer.getvalue())


def record_source_archive(path: Path, tag: str) -> None:
    manifest_path = REPOSITORY / "AttributionSources.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    data = path.read_bytes()
    entry = {
        "component": SOURCE_COMPONENT,
        "path": SOURCE_ARCHIVE.as_posix(),
        "bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "url": f"{UPSTREAM}/blob/{tag}/Cargo.lock",
    }
    archives = [a for a in manifest["archives"] if a["component"] != SOURCE_COMPONENT]
    archives.append(entry)
    manifest["archives"] = archives
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def generate(tag: str, binary: Path | None) -> None:
    with tempfile.TemporaryDirectory(prefix="amc-ytdlp-rs-source-") as temporary:
        source = download_source(tag, Path(temporary))
        manifest = tomllib.loads((source / "Cargo.toml").read_text(encoding="utf-8"))
        version = manifest["package"]["version"]
        if f"v{version}" != tag:
            raise ValueError(f"Tag {tag} does not match Cargo.toml version {version}")
        metadata = json.loads(subprocess.run(
            ["cargo", "metadata", "--manifest-path", str(source / "Cargo.toml"), "--locked",
             "--filter-platform", TARGET, "--format-version", "1"],
            check=True, capture_output=True, text=True).stdout)
        lock = tomllib.loads((source / "Cargo.lock").read_text(encoding="utf-8"))
        lock_checksums = {(p["name"], p["version"]): p.get("checksum") for p in lock["package"]}
        _, nodes, packages = selected_packages(metadata)
        rust_version, rust_text = rust_notice(binary)

        ejs = source / "vendor/ejs"
        ejs_manifest = json.loads((ejs / "manifest.json").read_text(encoding="utf-8"))
        ejs_header = re.match(r"/\*!.*?\*/", (ejs / "yt.solver.lib.js").read_text(encoding="utf-8"), re.DOTALL)

        notices = [
            "yt-dlp-rs web-video downloader and dependencies\n\n"
            f"yt-dlp-rs {version}, {TARGET}, built by upstream CI with {rust_version}.\n"
            f"Upstream: {UPSTREAM}\nRelease: {UPSTREAM}/releases/tag/{tag}\n"
            "yt-dlp-rs is released into the public domain (Unlicense).\n"
            "Normal and build dependency notices are retained below. Sources of the\n"
            "MPL-2.0 crates are included in the release source companion and are\n"
            "available unmodified from crates.io at the listed versions.\n"
            "The app remains GPL-3.0-or-later; upstream terms remain intact.\n",
            "\n" + "=" * 72 + f"\nyt-dlp-rs {version}\n{UPSTREAM}\nLicense: Unlicense\n" + "=" * 72
            + "\n\nLICENSE\n\n" + (source / "LICENSE").read_text(encoding="utf-8"),
            "\n" + "=" * 72 + f"\nyt-dlp/ejs {ejs_manifest['version']} (embedded YouTube challenge solver)\n"
            f"{ejs_manifest['project']}\nLicense: Unlicense, with bundled ISC/BSD notices\n" + "=" * 72
            + "\n\nLICENSE\n\n" + (ejs / "LICENSE").read_text(encoding="utf-8")
            + ("\n\nyt.solver.lib.js bundled dependency notices\n\n" + ejs_header.group(0) if ejs_header else ""),
        ]
        inventory = []
        mpl_crates = []
        for package in packages:
            if package["name"] == "yt-dlp-rs":
                continue
            if package["license"] not in REVIEWED_LICENSES:
                raise ValueError(f"Unreviewed license: {package['name']} {package['license']}")
            directory = Path(package["manifest_path"]).parent
            files = sorted(f for f in directory.rglob("*") if f.is_file()
                           and f.name.lower().startswith(NOTICE_PREFIXES)
                           and "target" not in f.relative_to(directory).parts)
            files = [f for f in files if f.suffix.lower() not in {".rs", ".py", ".sh"}]
            item = {key: package[key] for key in ["name", "version", "license", "repository", "source"]}
            item["features"] = nodes[package["id"]]["features"]
            item["notice_files"] = []
            header = ("\n" + "=" * 72 + "\n" + package["name"] + " " + package["version"] + "\n"
                      + (package["repository"] or f"https://crates.io/crates/{package['name']}") + "\n"
                      + "License: " + package["license"] + "\n" + "=" * 72 + "\n")
            notices.append(header)
            if not files:
                files = sorted((PROVENANCE / "supplemental-notices").glob(f"{package['name']}-LICENSE*.txt"))
            if not files:
                # A few crates ship no license file. Use a license option whose
                # full text carries no crate-specific copyright line, and point
                # at the copy reproduced in this file.
                chosen = next((name for name in ("Apache-2.0", "MPL-2.0") if name in package["license"]), None)
                if chosen is None:
                    raise ValueError(f"Missing upstream license notice: {package['name']}")
                item["notice_files"].append(f"(none in crate; {chosen} option, full text reproduced in this file)")
                notices.append(f"\nThe {package['name']} crate ships no license file. It is used under its "
                               f"{chosen} option; the full {chosen} text is reproduced elsewhere in this file.\n"
                               f"Source: https://crates.io/crates/{package['name']}/{package['version']}\n")
            for file in files:
                relative = file.relative_to(directory) if file.is_relative_to(directory) else file.name
                item["notice_files"].append(str(relative))
                notices.append("\n" + str(relative) + "\n\n" + file.read_text(encoding="utf-8", errors="replace"))
            if "MPL" in package["license"]:
                mpl_crates.append(crate_archive(package, lock_checksums))
            inventory.append(item)
        notices.append("\n" + "=" * 72 + f"\n{rust_version} standard library notices\n" + "=" * 72 + "\n" + rust_text)

    LICENSE_OUTPUT.write_text("\n".join(notices), encoding="utf-8")
    PROVENANCE.mkdir(parents=True, exist_ok=True)
    (PROVENANCE / "dependencies.json").write_text(json.dumps(inventory, indent=2) + "\n", encoding="utf-8")
    if mpl_crates:
        write_deterministic_archive(REPOSITORY / SOURCE_ARCHIVE, mpl_crates)
        record_source_archive(REPOSITORY / SOURCE_ARCHIVE, tag)
    print(f"Retained notices for {len(inventory)} packages; {len(mpl_crates)} MPL-2.0 crate sources archived.")


if __name__ == "__main__":
    arguments = argparse.ArgumentParser()
    arguments.add_argument("tag")
    arguments.add_argument("--binary", type=Path,
                           default=REPOSITORY / "Aagedal Media Converter/Binaries/yt-dlp-rs",
                           help="bundled binary used to confirm the Rust toolchain")
    options = arguments.parse_args()
    generate(options.tag, options.binary if options.binary.exists() else None)
