#!/usr/bin/env python3
"""Restore the pinned Apple Silicon Metal runtime from its verified release archive.

Run this only when intentionally replacing/restoring bundled binaries. The
source files stay untouched during ordinary Xcode builds; signed copies go into
DerivedData and the app. Model weights are downloaded separately at runtime.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def prepare(archive: Path, provenance: dict) -> None:
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    if digest != provenance["archiveSHA256"]:
        raise ValueError("NeMo runtime archive checksum does not match the pinned release")
    with tempfile.TemporaryDirectory(prefix="nemo-runtime-") as temporary:
        extraction = Path(temporary)
        subprocess.run(["tar", "-xzf", str(archive.resolve()), "-C", str(extraction)], check=True)
        source = extraction / "nemo-speech-0.2.0-macos-aarch64-metal"
        destination = ROOT / "Aagedal Media Converter/Binaries/NeMoSpeech"
        if destination.exists():
            shutil.rmtree(destination)
        for name in ["bin", "lib", "share/nemo-speech", "share/licenses/nemo-speech"]:
            shutil.copytree(source / name, destination / name, symlinks=True)
        shutil.rmtree(destination / "lib/cmake")
        licenses = source / "share/licenses/nemo-speech"
        parts = [
            "NeMo-Speech.cpp 0.2.0 — official macOS arm64 Metal distribution\n"
            "https://github.com/NVIDIA/NeMo-Speech.cpp/releases/tag/v0.2.0\n\n"
            "The following notices and license texts are reproduced from the official archive.\n"
        ]
        for path in sorted(licenses.rglob("*")):
            if path.is_file():
                parts.append("\n" + "=" * 72 + "\n" + str(path.relative_to(licenses))
                             + "\n" + "=" * 72 + "\n" + path.read_text())
        (ROOT / "Licenses/nemo-speech-LICENSE.txt").write_text("\n".join(parts))
        (ROOT / "scripts/nemo-runtime-inputs.xcfilelist").write_text(
            "\n".join("$(SRCROOT)/" + path.relative_to(ROOT).as_posix()
                      for path in sorted(destination.rglob("*"))) + "\n"
        )
        write_output_file_list(destination)


def write_output_file_list(destination: Path) -> None:
    # A directory that does not exist when Xcode creates its sandbox profile is
    # treated as a literal output. Declare every nested path for clean builds.
    outputs = []
    for prefix in ["$(DERIVED_FILE_DIR)/SignedMediaHelpers/NeMoSpeech",
                   "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/NeMoSpeech"]:
        outputs.append(prefix)
        for path in sorted(destination.rglob("*")):
            output = prefix + "/" + path.relative_to(destination).as_posix()
            outputs.append(output)
            if path.is_file() and not path.is_symlink() and (path.suffix == ".dylib" or path.name == "nemo-speech"):
                outputs.append(output + ".cstemp")
    (ROOT / "scripts/nemo-runtime-outputs.xcfilelist").write_text("\n".join(outputs) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="Use a previously downloaded official archive")
    args = parser.parse_args()
    provenance = json.loads((ROOT / "docs/provenance/nemo-speech-0.2.0.json").read_text())
    with tempfile.TemporaryDirectory(prefix="nemo-download-") as temporary:
        archive = args.archive or Path(temporary) / "runtime.tar.gz"
        if args.archive is None:
            subprocess.run(["curl", "--fail", "--location", "--proto", "=https",
                            "--proto-redir", "=https", provenance["archiveURL"],
                            "--output", str(archive)], check=True)
        prepare(archive, provenance)
    print("Restored NeMo Speech 0.2.0. Regenerate BundledDependencies.json before committing.")


if __name__ == "__main__":
    main()
