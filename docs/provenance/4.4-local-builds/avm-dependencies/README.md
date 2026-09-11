# AVM dependency notice recovery

Collected 2026-09-11 from the retained local AVM build identified in the parent
provenance review. These are evidence snapshots for review, not a complete or
packaged notice set. No binary attribution has been marked complete.

`inventory.json` records 17 dependency directories referenced by 858 retained
`build_arm64/**/*.o.d` compiler dependency files. The scan covers all retained
build targets; a reference establishes compilation involvement, not whether the
linker included that code in either shipped executable. It also finds header-only
inputs which the executable link commands cannot expose.

The 39 snapshots preserve available top-level license, copyright, author and
patent files, FFT readmes containing its copyright/permissions, libyuv's original
metadata, and applicable retained TensorFlow CMake source-selection modules.
Snapshots are byte-for-byte copies, including original line endings. Each has
its source-relative path, size and SHA-256 in the inventory. Nested notices and
individual source-file exceptions still need review before assembling a notice.

Key findings:

- Eigen (368 referenced files), FP16 (4), FXdiv (1), fastfeat (4), and vector (2)
  extend the previous linker-only component inventory. Their available notices
  are now preserved, along with the previously identified components' notices.
- libyuv's compiled sources explicitly reference root `LICENSE`, `PATENTS`, and
  `AUTHORS` files. None is present in the retained libyuv directory. The
  `README.libavm` version claim (1456) and BSD label cannot substitute for those
  missing files or establish the exact origin of the source subset.
- TensorFlow has no own Git metadata and no files tracked by the parent AVM
  repository. The same is true of all 13 selected `build_arm64` dependency
  directories. The clean AVM revision therefore does not pin these sources.
- Retained source-selection modules frequently comment out upstream revision
  and URL settings and select pre-existing local directories. In particular,
  Eigen's module names `COPYING.MPL2` but supplies an Apache license URL. Neither
  a commented revision nor that URL should override the actual retained source
  notices or be treated as verified source provenance.

Fingerprint method: unfold backslash-newline continuations in `.o.d` files, split
on whitespace, and keep existing absolute source-file paths under the recorded
AVM root. Deduplicate and sort paths, grouping `third_party/<name>` and
`build_arm64/<name>` (excluding generated `config` and `gen_src`). For each group,
hash the UTF-8 concatenation of `relative-path`, TAB, file SHA-256, LF. The overall
compiler-record fingerprint uses that same construction for sorted `.o.d` paths.
These are fingerprints of the current retained bytes, not assurances that source
files were unchanged after compilation. `trackedFilesInAVMRepository` is the
count from `git ls-files -- <directory>`; `hasOwnGitMetadata` records the presence
of a `.git` entry in that directory, not an inferred upstream identity.

Remaining work: recover missing libyuv material, determine final executable
component reachability, inspect nested/file-level notices, and authenticate the
unversioned retained source directories against exact upstream sources and local
patches. Then assemble notices and any required source material, package them
for offline viewing, and validate the strict release gate.
