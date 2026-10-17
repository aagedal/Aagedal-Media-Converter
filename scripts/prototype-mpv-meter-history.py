#!/usr/bin/env python3
"""Build an isolated diagnostic probe from the pinned mpv source and local build inputs.

Never modifies the source tree, package products, or the application's package pin.
Requires existing matching macOS MPVKit compile commands and static frameworks.
Recompiles only the staged lavfi instrumentation and audio priming translation units.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess

SOURCE_SHA256 = "064f23b34cdf424a583d35d2d12d9a3760aff901f5ae15c82e30faa0cffcc80b"
DECODER_SOURCE_SHA256 = "d2662c390407d9a89b08faf1413ef9695db55496d4e755ae95cab21a9edabf25"
ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def build(source, commands, products, output):
    source, commands, products, output = (p.resolve() for p in (source, commands, products, output))
    original = source / "filters/f_lavfi.c"
    if digest(original) != SOURCE_SHA256:
        raise ValueError("Unexpected f_lavfi.c; use the exact pinned corresponding source")
    decoder_original = source / "audio/decode/ad_lavc.c"
    if digest(decoder_original) != DECODER_SOURCE_SHA256:
        raise ValueError("Unexpected ad_lavc.c; use the exact pinned corresponding source")
    if output.exists() or any(output == p or p in output.parents for p in (source, products, ROOT)):
        raise ValueError("Output must be a new directory outside source, products, and this repository")
    entries = [e for e in json.loads(commands.read_text()) if e["file"].endswith("/f_lavfi.c")]
    if len(entries) != 1:
        raise ValueError("Expected exactly one f_lavfi.c compile command")
    entry = entries[0]
    command = entry.get("arguments") or shlex.split(entry["command"])
    if command[command.index("-arch") + 1] not in ("arm64", "x86_64"):
        raise ValueError("Expected a macOS arm64 or x86_64 compile command")
    arch = command[command.index("-arch") + 1]
    library = products / "Libmpv.framework/Versions/A/Libmpv"
    patch = ROOT / "docs/dependency-patches/mpv-0.41.0-meter-history.patch"
    header = ROOT / "docs/dependency-patches/amc_meter_history.h"
    output.mkdir(parents=True)
    staged = output / "source/filters"
    staged.mkdir(parents=True)
    shutil.copy2(original, staged / original.name)
    shutil.copy2(header, staged / header.name)
    run(["git", "apply", "--check", str(patch)], cwd=staged.parent)
    run(["git", "apply", str(patch)], cwd=staged.parent)
    # Retain original generated config/dependency include paths and working directory.
    # Compile staged translation units; never invoke the existing build's writer.
    for flag in ("-MD", "-MMD"):
        if flag in command:
            command.remove(flag)
    for flag in ("-MQ", "-MT", "-MF", "-o"):
        if flag in command:
            index = command.index(flag)
            del command[index:index + 2]
    command[command.index("-c") + 1] = str(staged / original.name)
    object_file = output / "filters_f_lavfi.c.o"
    command += ["-I" + str(source / "filters"), "-o", str(object_file)]
    run(command, cwd=entry["directory"])
    decoder_patch = ROOT / "docs/dependency-patches/mpv-0.41.0-aac-discard-priming.patch"
    decoder_staged = output / "source/audio/decode"
    decoder_staged.mkdir(parents=True)
    shutil.copy2(decoder_original, decoder_staged / decoder_original.name)
    run(["git", "apply", "--check", str(decoder_patch)], cwd=staged.parent)
    run(["git", "apply", str(decoder_patch)], cwd=staged.parent)
    decoder_entries = [e for e in json.loads(commands.read_text()) if e["file"].endswith("/ad_lavc.c")]
    if len(decoder_entries) != 1:
        raise ValueError("Expected exactly one ad_lavc.c compile command")
    decoder_entry = decoder_entries[0]
    decoder_command = list(decoder_entry.get("arguments") or shlex.split(decoder_entry["command"]))
    if decoder_command[decoder_command.index("-arch") + 1] != arch:
        raise ValueError("Decoder compile architecture differs from filter")
    for flag in ("-MD", "-MMD"):
        if flag in decoder_command:
            decoder_command.remove(flag)
    for flag in ("-MQ", "-MT", "-MF", "-o"):
        if flag in decoder_command:
            index = decoder_command.index(flag)
            del decoder_command[index:index + 2]
    decoder_command[decoder_command.index("-c") + 1] = str(decoder_staged / decoder_original.name)
    decoder_object = output / "audio_decode_ad_lavc.c.o"
    decoder_command += ["-o", str(decoder_object)]
    run(decoder_command, cwd=decoder_entry["directory"])
    candidate = output / "products"
    candidate.mkdir()
    for path in products.iterdir():
        if path.name != "Libmpv.framework":
            (candidate / path.name).symlink_to(path, target_is_directory=path.is_dir())
    framework = candidate / "Libmpv.framework"
    shutil.copytree(products / framework.name, framework, symlinks=True)
    replacement = framework / "Versions/A/Libmpv"
    if not replacement.resolve().is_relative_to(framework.resolve()):
        raise ValueError("Framework binary symlink escapes the isolated copy")
    if (framework / "Libmpv").resolve() != replacement.resolve():
        raise ValueError("Framework linker alias does not resolve to the replaced library")
    thin = output / "libmpv-thin.a"
    run(["xcrun", "lipo", str(library), "-thin", arch, "-output", str(thin)])
    # Replace the exact archive member, rather than adding a second implementation.
    members = subprocess.check_output(["ar", "-t", str(thin)], text=True).splitlines()
    if any(members.count(obj.name) != 1 for obj in (object_file, decoder_object)):
        raise ValueError("Unexpected libmpv archive member name/count")
    run(["ar", "-r", str(thin), str(object_file), str(decoder_object)])
    shutil.copyfile(thin, replacement)
    developer = subprocess.check_output(["xcode-select", "-p"], text=True).strip()
    swift = Path(developer) / "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"
    probe = ROOT / "scripts/probe-mpv-meter-history.c"
    link = ["xcrun", "clang", "-arch", arch, "-mmacosx-version-min=12.0",
            "-Wall", "-Wextra", "-Werror", str(probe),
            "-I" + str(framework / "Headers"), "-F" + str(candidate),
            "-L" + str(candidate), "-L" + str(swift), "-o", str(output / "probe")]
    for path in sorted(candidate.glob("*.framework")):
        if path.stem != "Sparkle":
            link += ["-framework", path.stem]
    for name in ("AVFoundation", "CoreAudio", "AudioToolbox", "CoreVideo", "CoreFoundation",
                 "CoreMedia", "Metal", "VideoToolbox", "AppKit"):
        link += ["-framework", name]
    link += ["-lMoltenVK", "-lbz2", "-liconv", "-lexpat", "-lresolv", "-lxml2", "-lz", "-lc++",
             "-Wl,-rpath," + str(candidate), "-Wl,-rpath,/usr/lib/swift"]
    run(link)
    evidence = {"status": "probe-built", "arch": arch, "source_sha256": digest(original),
                "patch_sha256": digest(patch), "header_sha256": digest(header),
                "decoder_source_sha256": digest(decoder_original),
                "decoder_patch_sha256": digest(decoder_patch),
                "decoder_compile": decoder_command,
                "decoder_compile_directory": decoder_entry["directory"],
                "compile_commands_sha256": digest(commands), "input_library_sha256": digest(library),
                "probe_source_sha256": digest(probe), "probe_sha256": digest(output / "probe"),
                "compile": command, "compile_directory": entry["directory"], "link": link,
                "alignment_qualified": False, "installed": False}
    (output / "build.json").write_text(json.dumps(evidence, indent=2) + "\n")
    return evidence


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="Exact pinned mpv source directory")
    parser.add_argument("--compile-commands", type=Path, required=True, help="Matching thin macOS build commands")
    parser.add_argument("--products", type=Path, required=True, help="Matching static MPVKit framework products")
    parser.add_argument("--output", type=Path, required=True, help="New external staging directory")
    args = parser.parse_args()
    try:
        evidence = build(args.source, args.compile_commands, args.products, args.output)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"{error}\n")
    print(json.dumps({k: evidence[k] for k in ("status", "arch", "alignment_qualified", "installed")}))


if __name__ == "__main__":
    main()
