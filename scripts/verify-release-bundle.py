#!/usr/bin/env python3
"""Statically validate the arm64 distribution without executing bundled code.

Only Apple system-library paths may resolve outside the bundle (these often live
in dyld's shared cache). All other dependencies must resolve through the actual
loader/executable paths and inherited LC_RPATHs, without DYLD_* overrides.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from dataclasses import dataclass
from pathlib import Path
import plistlib
import re
import subprocess
import sys


MACHO_MAGICS = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca", "cafebabf", "bfbafeca"
)}
LOAD_COMMANDS = {"LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LOAD_UPWARD_DYLIB", "LC_LAZY_LOAD_DYLIB"}


def verify_notices(bundle: Path, manifest: Path) -> int:
    """Verify that every inventoried notice is distributed byte-for-byte.

    Xcode copies these text resources to the Resources root. Attribution
    completeness remains a separate manifest gate; this checks packaging only.
    """
    bundle = bundle.resolve(strict=True)
    entries = json.loads(manifest.read_text())["licenseFiles"]
    if not entries:
        raise ValueError("The dependency manifest contains no license notices")
    names = set()
    for entry in entries:
        name = Path(entry["path"]).name
        if name in names:
            raise ValueError(f"Duplicate packaged license notice name: {name}")
        names.add(name)
        notice = bundle / "Contents/Resources" / name
        if not notice.resolve().is_relative_to(bundle):
            raise ValueError(f"{notice}: license notice escapes the app bundle")
        if not notice.is_file():
            raise ValueError(f"{notice}: missing packaged license notice")
        contents = notice.read_bytes()
        if not contents.strip() or len(contents) != entry["bytes"] or hashlib.sha256(contents).hexdigest() != entry["sha256"]:
            raise ValueError(f"{notice}: packaged license notice differs from the dependency manifest")
    return len(entries)


@dataclass
class Image:
    executable: bool
    dependencies: list[str]
    rpaths: list[str]


def output(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=30).stdout


def is_system(path: str) -> bool:
    # Normalize first so /usr/lib/../../opt/... cannot masquerade as a system library.
    normalized = os.path.normpath(path) if path.startswith("/") else path
    return normalized.startswith(("/usr/lib/", "/System/Library/"))


def read_image(path: Path, architecture: str) -> Image:
    arches = output("/usr/bin/lipo", "-archs", str(path)).split()
    if architecture not in arches:
        raise ValueError(f"{path}: missing required {architecture} architecture ({', '.join(arches)})")
    header = output("/usr/bin/otool", "-arch", architecture, "-hv", str(path))
    executable = bool(re.search(r"\bEXECUTE\b", header))
    if executable and not path.stat().st_mode & 0o100:
        raise ValueError(f"{path}: executable has no execute permission")
    commands = output("/usr/bin/otool", "-arch", architecture, "-l", str(path))
    dependencies, rpaths = [], []
    for block in re.split(r"Load command \d+\n", commands)[1:]:
        command = re.search(r"^\s*cmd (\S+)$", block, re.MULTILINE)
        if not command:
            continue
        kind = command.group(1)
        if kind in LOAD_COMMANDS or kind == "LC_RPATH":
            field = "path" if kind == "LC_RPATH" else "name"
            value = re.search(rf"^\s*{field} (.+) \(offset \d+\)$", block, re.MULTILINE)
            if not value:
                raise ValueError(f"{path}: malformed {kind}")
            (rpaths if kind == "LC_RPATH" else dependencies).append(value.group(1))
    return Image(executable, dependencies, rpaths)


def verify(bundle: Path, architecture: str = "arm64") -> int:
    bundle = bundle.resolve(strict=True)
    info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    main = (bundle / "Contents/MacOS" / info["CFBundleExecutable"]).resolve()
    images: dict[Path, Image] = {}
    for path in sorted(bundle.rglob("*")):
        if path.is_symlink() and not path.resolve().is_relative_to(bundle):
            raise ValueError(f"{path}: symlink escapes the app bundle")
        if not path.is_file():
            continue
        with path.open("rb") as handle:
            magic = handle.read(4)
        if magic in MACHO_MAGICS:
            real = path.resolve()
            if real not in images:
                images[real] = read_image(real, architecture)
    if main not in images or not images[main].executable:
        raise ValueError(f"{main}: app executable is missing or is not a Mach-O executable")

    def expand(value: str, loader: Path, executable: Path) -> Path | None:
        for token, base in (("@loader_path", loader.parent), ("@executable_path", executable.parent)):
            if value == token or value.startswith(token + "/"):
                return (base / value[len(token):].lstrip("/")).resolve()
        return Path(value).resolve() if value.startswith("/") else None

    visited = set()
    reached = set()

    def walk(path: Path, executable: Path, inherited: tuple[Path, ...], chain: tuple[Path, ...] = ()):
        if path in chain:
            return
        image = images[path]
        local = tuple(expand(value, path, executable) for value in image.rpaths)
        if None in local:
            raise ValueError(f"{path}: unsupported relative or recursive LC_RPATH")
        rpaths = tuple(dict.fromkeys((*local, *inherited)))
        context = (path, executable, rpaths)
        if context in visited:
            return
        visited.add(context)
        reached.add(path)
        for dependency in image.dependencies:
            if is_system(dependency):
                continue
            if dependency.startswith("/"):
                raise ValueError(f"{path}: dependency {dependency} uses an absolute path outside the bundle relocation model")
            if dependency.startswith("@rpath/"):
                candidates = [(base / dependency[len("@rpath/"):]).resolve() for base in rpaths]
            else:
                candidate = expand(dependency, path, executable)
                candidates = [candidate] if candidate else []
            target = None
            for candidate in candidates:
                if is_system(str(candidate)):
                    target = candidate
                    break
                if not candidate.is_relative_to(bundle):
                    raise ValueError(f"{path}: dependency {dependency} resolves outside the bundle: {candidate}")
                if candidate.is_file():
                    target = candidate
                    break
            if target is None:
                raise ValueError(f"{path}: unresolved dependency {dependency}")
            if is_system(str(target)):
                continue
            if target not in images:
                raise ValueError(f"{path}: dependency {dependency} is not a Mach-O image: {target}")
            walk(target, executable, rpaths, (*chain, path))

    for path, image in images.items():
        if image.executable:
            walk(path, path, ())
    # Also cover plug-ins/dlopen libraries not referenced by LC_LOAD_DYLIB.
    main_rpaths = tuple(expand(value, main, main) for value in images[main].rpaths)
    for path in images.keys() - reached:
        walk(path, main, main_rpaths)
    return len(images)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--architecture", default="arm64")
    parser.add_argument("--manifest", type=Path, help="Also verify packaged license notices against this dependency manifest")
    args = parser.parse_args()
    try:
        count = verify(args.bundle, args.architecture)
        notice_count = verify_notices(args.bundle, args.manifest) if args.manifest else None
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        print(f"ERROR: release bundle validation failed: {error}", file=sys.stderr)
        return 1
    print(f"Verified {count} Mach-O images: {args.architecture}, executable permissions, and bundled library resolution.")
    if notice_count is not None:
        print(f"Verified {notice_count} packaged license notices against the dependency manifest.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
