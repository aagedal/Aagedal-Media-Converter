#!/usr/bin/env python3
"""Stage/rebuild all of MPV, using qualified FFmpeg/auxiliary outputs read-only.

This never replaces archive members, publishes artifacts, or changes an app pin.
The recipe and dependency cache are inputs; every writable build path is owned by
the new output directory. Both macOS architectures use the normal MPVKit recipe.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE_COMMIT = "41f6a645068483470267271e1d09966ca3b9f413"
SOURCE_TAG = "v0.41.0"
STANDARD_PATCHES = (
    "0001-player-add-moltenvk-context.patch",
    "0002-revert-build-static.patch",
    "0003-enable-avfoundation-ao-tvos.patch",
    "0004-coreaudio-init-failure.patch",
    "0005-coreaudio-clear-failed-unit.patch",
)
STANDARD_SOURCE_HASHES = {
    "filters/f_lavfi.c": "064f23b34cdf424a583d35d2d12d9a3760aff901f5ae15c82e30faa0cffcc80b",
    "audio/decode/ad_lavc.c": "d2662c390407d9a89b08faf1413ef9695db55496d4e755ae95cab21a9edabf25",
    "audio/out/ao_coreaudio.c": "b952bfb9e46b34c5307633a37079790664c51f561cb3f9a53e0eba57e03e6383",
}
EXTRA_INPUTS = (
    "mpv-0.41.0-meter-history.patch",
    "amc_meter_history.h",
    "mpv-0.41.0-aac-discard-priming.patch",
)
# Logical installed output roots only. Versioned source trees and hidden caches
# are unnecessary to compile MPV and must never become writable staging paths.
DEPENDENCIES = (
    "FFmpeg", "gmp", "nettle", "gnutls", "openssl", "libunibreak",
    "libfreetype", "libfribidi", "libharfbuzz", "libass", "libsmbclient",
    "libplacebo", "libdav1d", "lcms2", "libdovi", "vulkan", "libshaderc",
    "libuchardet", "libbluray", "libluajit", "libuavs3d",
)
TOOL_COMMANDS = {
    "git": ["--version"], "tar": ["--version"], "swift": ["--version"],
    "clang": ["--version"], "meson": ["--version"], "ninja": ["--version"],
    "pkg-config": ["--version"], "brew": ["--version"], "wget": ["--version"],
    "xcodebuild": ["-version"], "xcrun": ["--version"], "lipo": ["-h"],
    "otool": ["--version"], "zip": ["-v"],
}


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def checked(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def git(source, *arguments):
    return subprocess.check_output(["git", "-C", str(source), *arguments], text=True).strip()


def preflight_tools():
    tools = {}
    for name, arguments in TOOL_COMMANDS.items():
        executable = shutil.which(name)
        if executable is None:
            raise ValueError(f"Required build tool is missing: {name}; install it before running this builder")
        result = subprocess.run([executable, *arguments], capture_output=True, text=True)
        text = (result.stdout or result.stderr).strip()
        # Apple's lipo has no version query; it returns its usage with status 1.
        if result.returncode and not (name == "lipo" and result.returncode == 1 and "usage: lipo" in text):
            raise ValueError(f"Build tool preflight failed: {name}: {text}")
        path = Path(executable).resolve()
        tools[name] = {"path": str(path), "sha256": digest(path),
                       "version": text.splitlines()[0] if text else ""}
    return tools


def hash_tree(root):
    return {str(path.relative_to(root)): digest(path)
            for path in sorted(root.rglob("*")) if path.is_file()}


def ensure_owned_tree(root, owner):
    for path in root.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(owner):
            raise ValueError(f"Writable source/recipe symlink escapes output: {path}")


def export_source(cache, destination, archive):
    destination.mkdir()
    with archive.open("wb") as output:
        checked(["git", "-C", str(cache), "archive", SOURCE_COMMIT], stdout=output)
    # The exact known Git tree is authoritative, including when the cache has
    # modified/deleted/untracked working files. Validate archive links as well.
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            path = destination / member.name
            if not path.resolve().is_relative_to(destination):
                raise ValueError("Source archive path escapes output")
            if member.issym() and not (path.parent / member.linkname).resolve().is_relative_to(destination):
                raise ValueError("Source archive symlink escapes output")
            if not (member.isfile() or member.isdir() or member.issym()):
                raise ValueError("Unexpected source archive member type")
        source.extractall(destination, filter="data")


def rewrite_recipe(output, jobs):
    entrypoint = output / "Sources/BuildScripts/XCFrameworkBuild/main.swift"
    invocation = "    try BuildFFMPEG().buildALL()"
    text = entrypoint.read_text()
    if text.count(invocation + "\n") != 1 or text.count("    try BuildMPV().buildALL()") != 1:
        raise ValueError("Recipe must contain exactly one FFmpeg and one MPV build invocation")
    entrypoint.write_text(text.replace(invocation + "\n", "", 1))
    base = output / "Sources/BuildScripts/XCFrameworkBuild/base.swift"
    text = base.read_text()
    invocation = '["compile", "--verbose"]'
    if text.count(invocation) != 1:
        raise ValueError("Unexpected Meson compile recipe; cannot safely set jobs")
    text = text.replace(invocation, f'["compile", "--verbose", "--jobs", "{jobs}"]', 1)
    if 'for key in ["TMPDIR", "CLANG_MODULE_CACHE_PATH"]' not in text:
        marker = "        task.environment = environment"
        if text.count(marker) != 1:
            raise ValueError("Unexpected tool environment recipe")
        text = text.replace(marker, '''        for key in ["TMPDIR", "CLANG_MODULE_CACHE_PATH"] {
            if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
        }
''' + marker, 1)
    base.write_text(text)


def stage(recipe_root, source_cache, output, jobs=4, build=False):
    if not isinstance(jobs, int) or isinstance(jobs, bool) or not 1 <= jobs <= 32:
        raise ValueError("Jobs must be an integer from 1 to 32")
    original_output = Path(output).absolute()
    recipe_root, source_cache, output = (Path(p).resolve() for p in (recipe_root, source_cache, output))
    if original_output.exists() or original_output.is_symlink() or output.exists():
        raise ValueError("Output must be a new directory")
    if any(output == root or output.is_relative_to(root) for root in (recipe_root, source_cache, ROOT)):
        raise ValueError("Output must be outside recipe, source cache, and repository")
    if git(source_cache, "rev-parse", "HEAD") != SOURCE_COMMIT or git(source_cache, "rev-parse", SOURCE_TAG + "^{commit}") != SOURCE_COMMIT:
        raise ValueError("MPV cache HEAD and tag must match the exact pinned source commit")
    recipe_patches = recipe_root / "Sources/BuildScripts/patch/libmpv"
    if sorted(p.name for p in recipe_patches.glob("*.patch")) != sorted(STANDARD_PATCHES):
        raise ValueError("Unexpected standard MPV patch set")
    for name in EXTRA_INPUTS:
        if not (ROOT / "docs/dependency-patches" / name).is_file():
            raise ValueError(f"Missing repository patch input: {name}")
    if not (recipe_root / "dist/FFmpeg/macos/thin/arm64/lib").is_dir() or not (recipe_root / "dist/FFmpeg/macos/thin/x86_64/lib").is_dir():
        raise ValueError("Both qualified FFmpeg thin output directories are required")
    tools = preflight_tools()
    output.mkdir(parents=True, exist_ok=False)
    report = {
        "status": "staging", "source_commit": SOURCE_COMMIT,
        "source_cache_read_only": str(source_cache), "recipe_root_read_only": str(recipe_root),
        "output": str(output), "meson_compile_jobs": jobs, "production_pin_changed": False,
        "tool_versions": tools,
    }
    record = output / "staging.json"
    try:
        for name in ("Sources", "scripts", "docs"):
            # Dereference inputs while copying. Staged recipe files may be edited;
            # retaining their original symlinks would allow writes into the cache.
            shutil.copytree(recipe_root / name, output / name, symlinks=False)
            ensure_owned_tree(output / name, output)
        report["input_recipe_sha256"] = {name: hash_tree(output / name) for name in ("Sources", "scripts", "docs")}
        dist = output / "dist"
        dist.mkdir()
        (dist / "libmpv").mkdir()
        (dist / "release").mkdir()
        dependency_roots = {}
        dependency_hashes = {}
        for name in DEPENDENCIES:
            source = recipe_root / "dist" / name
            if not source.is_dir():
                continue
            source = source.resolve()
            (dist / name).symlink_to(source, target_is_directory=True)
            dependency_roots[name] = str(source)
            for arch in ("arm64", "x86_64"):
                thin = source / "macos/thin" / arch
                for directory in ("include", "lib"):
                    base = thin / directory
                    if base.is_dir():
                        for relative, checksum in hash_tree(base).items():
                            dependency_hashes[f"{name}/macos/thin/{arch}/{directory}/{relative}"] = checksum
        report["read_only_dependency_roots"] = dependency_roots
        report["dependency_input_sha256"] = dependency_hashes
        report["dependency_pkgconfig_sha256"] = {key: value for key, value in dependency_hashes.items() if key.endswith(".pc")}
        source = dist / "libmpv-v0.41.0"
        archive = output / "upstream-mpv-source.tar"
        export_source(source_cache, source, archive)
        ensure_owned_tree(source, output)
        report["upstream_archive_sha256"] = digest(archive)
        report["standard_patch_sha256"] = {}
        for name in STANDARD_PATCHES:
            patch = output / "Sources/BuildScripts/patch/libmpv" / name
            report["standard_patch_sha256"][name] = digest(patch)
            checked(["git", "apply", "--check", str(patch)], cwd=source)
            checked(["git", "apply", str(patch)], cwd=source)
        actual = {name: digest(source / name) for name in STANDARD_SOURCE_HASHES}
        if actual != STANDARD_SOURCE_HASHES:
            raise ValueError("Standard-patched MPV source hashes differ from qualified inputs")
        report["standard_patched_source_sha256"] = actual
        extra = output / "meter-patches"
        extra.mkdir()
        report["extra_patch_sha256"] = {}
        for name in EXTRA_INPUTS:
            patch = extra / name
            shutil.copyfile(ROOT / "docs/dependency-patches" / name, patch)
            report["extra_patch_sha256"][name] = digest(patch)
            if name.endswith(".patch"):
                checked(["git", "apply", "--check", str(patch)], cwd=source)
                checked(["git", "apply", str(patch)], cwd=source)
            else:
                shutil.copyfile(patch, source / "filters" / name)
        ensure_owned_tree(source, output)
        report["patched_source_sha256"] = hash_tree(source)
        rewrite_recipe(output, jobs)
        report["entrypoint_sha256"] = digest(output / "Sources/BuildScripts/XCFrameworkBuild/main.swift")
        report["base_recipe_sha256"] = digest(output / "Sources/BuildScripts/XCFrameworkBuild/base.swift")
        environment = {"TMPDIR": str(output / "tmp"), "CLANG_MODULE_CACHE_PATH": str(output / "module-cache")}
        for path in environment.values():
            Path(path).mkdir()
        report["environment"] = environment
        command = ["swift", "run", "--disable-sandbox", "--build-path", ".build",
                   "--package-path", "Sources/BuildScripts", "build", "platform=macos", "enable-gpl"]
        report["command"] = command
        report["status"] = "staged-not-built"
        record.write_text(json.dumps(report, indent=2) + "\n")
        if build:
            report["status"] = "building"
            record.write_text(json.dumps(report, indent=2) + "\n")
            with (output / "build.log").open("w") as log:
                result = subprocess.run(command, cwd=output, env={**os.environ, **environment},
                                        stdout=log, stderr=subprocess.STDOUT)
            report["build_exit_code"] = result.returncode
            report["status"] = "built" if result.returncode == 0 else "build-failed"
        record.write_text(json.dumps(report, indent=2) + "\n")
        return report
    except Exception as error:
        report["status"] = "failed"
        report["error"] = str(error)
        record.write_text(json.dumps(report, indent=2) + "\n")
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recipe-root", type=Path, required=True)
    parser.add_argument("--source-cache", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--build", action="store_true")
    args = parser.parse_args()
    try:
        report = stage(args.recipe_root, args.source_cache, args.output, args.jobs, args.build)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"{error}\n")
    print(json.dumps({key: report[key] for key in ("status", "output", "source_commit")}, indent=2))
    if args.build:
        raise SystemExit(report["build_exit_code"])


if __name__ == "__main__":
    main()
