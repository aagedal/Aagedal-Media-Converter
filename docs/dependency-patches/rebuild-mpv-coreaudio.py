#!/usr/bin/env python3
"""Stage and build patched libmpv without modifying an existing MPVKit checkout.

Requires the MPVKit revision recorded below and its built macOS dependencies.
Outputs are candidates for release verification, never installed into the app.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

RECIPE_REVISION = "230c3174f1515898f24599147ad61c2a277d0dc2"
MPV_REVISION = "41f6a645068483470267271e1d09966ca3b9f413"


def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def revision(path):
    return run(["git", "-C", str(path), "rev-parse", "HEAD"], capture_output=True).stdout.strip()


def tree_manifest(root):
    entries = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            entries.append({"path": str(path.relative_to(root)), "symlink": os.readlink(path)})
        elif path.is_file():
            entries.append({"path": str(path.relative_to(root)), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mpvkit", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True, help="New, empty staging directory")
    parser.add_argument("--build", action="store_true", help="Run the staged macOS GPL build")
    args = parser.parse_args()
    root, output = args.mpvkit.resolve(), args.output.resolve()
    source = root / "dist/libmpv-v0.41.0"
    patch = Path(__file__).with_name("mpv-0.41.0-coreaudio-init-failure.patch").resolve()
    if revision(root) != RECIPE_REVISION or revision(source) != MPV_REVISION:
        parser.error("Unexpected MPVKit/mpv source revision; review the recipe before updating pins")
    if run(["git", "-C", str(root), "status", "--porcelain"], capture_output=True).stdout:
        parser.error("MPVKit recipe checkout must be clean")
    app_root = Path(__file__).resolve().parents[2]
    if output.exists() or any(output == repo or repo in output.parents for repo in (root, app_root)):
        parser.error("Output must be a new directory outside MPVKit and the app repository")
    for tool in ("swift", "brew", "pkg-config", "wget", "meson", "ninja"):
        if not shutil.which(tool):
            parser.error(f"Missing prerequisite: {tool}")
    run(["git", "-C", str(source), "apply", "--check", str(patch)])
    output.mkdir(parents=True)
    shutil.copytree(root / "Sources/BuildScripts", output / "Sources/BuildScripts")
    shutil.copytree(root / "docs", output / "docs")
    staged_source = output / "dist/libmpv-v0.41.0"
    shutil.copytree(source, staged_source, symlinks=True, ignore=shutil.ignore_patterns(".git"))
    manifest_path = output / "source-input-manifest.json"
    manifest_path.write_text(json.dumps(tree_manifest(staged_source), indent=2) + "\n")
    # Prior packaging removed tracked macOS bundle assets from the source tree;
    # Meson requires them even for a libmpv build. Restore only deleted assets
    # from the pinned commit, preserving all existing source modifications.
    deleted = run(["git", "-C", str(source), "ls-files", "--deleted", "-z"], capture_output=True).stdout
    restored = []
    for name in filter(None, deleted.split("\0")):
        if not name.startswith("TOOLS/osxbundle/mpv.app/"):
            raise RuntimeError(f"Unexpected deleted source file: {name}")
        target = staged_source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(subprocess.check_output(["git", "-C", str(source), "show", f"HEAD:{name}"]))
        restored.append(name)
    # Dependency outputs are read-only inputs to the MPV-only recipe. Never link
    # libmpv or release: buildALL removes/recreates those paths.
    for child in (root / "dist").iterdir():
        if child.is_dir() and child.name not in ("libmpv", "libmpv-v0.41.0", "release"):
            (output / "dist" / child.name).symlink_to(child, target_is_directory=True)
    run(["git", "apply", str(patch)], cwd=staged_source)
    recipe_patch = output / "Sources/BuildScripts/patch/libmpv/0004-coreaudio-init-failure.patch"
    shutil.copy2(patch, recipe_patch)
    entrypoint = output / "Sources/BuildScripts/XCFrameworkBuild/main.swift"
    text = entrypoint.read_text()
    start, end = text.index("    // SSL\n"), text.index("    try BuildMPV().buildALL()")
    entrypoint.write_text(text[:start] + text[end:])
    # The upstream launcher replaces the environment, losing the sandbox's
    # writable temporary directory and compiler module cache location.
    base = output / "Sources/BuildScripts/XCFrameworkBuild/base.swift"
    base_text = base.read_text()
    marker = "        task.environment = environment"
    if base_text.count(marker) != 1:
        raise RuntimeError("Unexpected upstream process launcher")
    base.write_text(base_text.replace(marker,
        '        for key in ["TMPDIR", "CLANG_MODULE_CACHE_PATH"] {\n'
        '            if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }\n'
        '        }\n' + marker))
    source_diff = run(["git", "-C", str(source), "diff", "--binary", "HEAD"], capture_output=True).stdout
    (output / "source-before-coreaudio.patch").write_text(source_diff)
    evidence = {
        "mpvkit_revision": RECIPE_REVISION,
        "mpv_revision": MPV_REVISION,
        "patch_sha256": hashlib.sha256(patch.read_bytes()).hexdigest(),
        "source_before_coreaudio_diff_sha256": hashlib.sha256(source_diff.encode()).hexdigest(),
        "source_input_manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        "source_status": run(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=all"], capture_output=True).stdout,
        "dependency_input_directory": str(root / "dist"),
        "restored_bundle_assets": restored,
        "sdk": run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], capture_output=True).stdout.strip(),
        "status": "staged",
        "release_ready": False,
    }
    evidence_path = output / "rebuild-evidence.json"
    evidence_path.write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"Staged isolated recipe at {output}", flush=True)
    if args.build:
        environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(output / "clang-module-cache"))
        with (output / "build.log").open("w") as log:
            result = subprocess.run(["swift", "run", "--disable-sandbox", "--build-path", str(output / ".build"),
                "--package-path", str(output / "Sources/BuildScripts"), "build", "platform=macos", "enable-gpl"],
                cwd=output, env=environment, stdout=log, stderr=subprocess.STDOUT)
        evidence["status"] = "build_succeeded" if result.returncode == 0 else "build_failed"
        evidence["exit_code"] = result.returncode
        evidence["patched_coreaudio_sha256"] = hashlib.sha256(
            (staged_source / "audio/out/ao_coreaudio.c").read_bytes()).hexdigest()
        evidence["candidate_archives"] = [
            {"path": str(path.relative_to(output)), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            for path in sorted((output / "dist/release").glob("*.zip"))
        ]
        evidence["candidate_binaries"] = [
            {"path": str(path.relative_to(output)), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            for path in sorted((output / "dist/libmpv").rglob("*"))
            if path.is_file() and not path.is_symlink() and (path.name == "libmpv.a" or path.name == "Libmpv")
        ]
        evidence_path.write_text(json.dumps(evidence, indent=2) + "\n")
        print(f"Build exit {result.returncode}; log: {output / 'build.log'}", flush=True)
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
