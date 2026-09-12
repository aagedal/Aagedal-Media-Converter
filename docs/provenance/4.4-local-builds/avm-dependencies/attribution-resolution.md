# AVM attribution resolution — 2026-09-12

`Licenses/avm-LICENSE.txt` now packages the retained AVM license and patent grant,
all 17 dependency groups' retained licenses/authors/patents, the recovered libyuv
material, nested TensorFlow notices, and 277 distinct file-level notice blocks.
Scope deliberately includes every compiler-input group; proving removal by the
linker is unnecessary when conservatively retaining attribution.

## libyuv recovery

The official upstream repository is
https://chromium.googlesource.com/libyuv/libyuv . Its revision
`7cd7f5a80fa7d63cdd0ca3b7e11447b8e6a1e7ec` declares version 1456.
`libyuv/LICENSE`, `PATENTS`, and `AUTHORS` are byte-for-byte snapshots from that
revision. `libyuv/upstream-match.json` fingerprints all 61 common files (41 exact
matches). For the 27 compiler-referenced files, the only changes are ten initial
copyright/license comments replaced by AOM and one `libvpx` → `libavm` comment.
`libyuv/retained-source.patch` captures every change in those 27 files. Both the
original LibYuv copyright comments and AOM's retained comments are included.
The uncompiled `mjpeg_validate.cc` also differs; no claim is made that the entire
retained tree is unchanged upstream revision 1456.

Recovery can be repeated using `git clone` of the official URL, checking out that
revision, and copying its three root notice files. This resolves the missing
material without substituting a current license for a historical source subset.

## File-level review

Every compiler-referenced source file was scanned for whole comment blocks
containing copyright, redistribution, permission, public-domain and embedded
Cephes/SSE attribution. Original comment wording is retained in
`file-level-NOTICES.txt` and the packaged notice. This captures the BSD grant for
Fabian Giesen's half conversion, Intel's BSD notice, Cephes' permission from
Stephen Moshier, and Eigen's MPL/Apache notices. Parent directories of the actual
resolved compiler inputs were checked for nested legal files. Three were found:
TensorFlow's FFT2D, XLA and TSL licenses, now retained under `tensorflow/nested`.
These supplement, rather than replace, all top-level licenses.

## Source accompaniment and reconstruction

Eigen's MPL Source Code Form is supplied in the release source companion as
`avm-eigen-source.tar.gz`. Its manifest is `eigen-source-archive.json`. It contains
all retained `Eigen/`, `unsupported/`, and root `COPYING.*` files (748 files),
including the exact referenced headers and notices. The archive uses stable tar
metadata and gzip timestamps. It lives under ignored `build/attribution/` and
must be distributed alongside the application; merely checking in this notice
is not sufficient source delivery.

Reconstruct from the retained sibling tree using:

```sh
python3 scripts/assemble-avm-notices.py --source-root /Users/truls.aagedal/Developer/avm
python3 scripts/verify-avm-evidence.py --source-root /Users/truls.aagedal/Developer/avm
```

The assembler first checks all 1,744 source-input hashes and fails on drift.
The current retained local Eigen tree is the source of truth. Its source-selection
module does not establish an authentic upstream revision, so this record does
not invent one or claim exact build reproducibility. Delivering these retained
sources and notices resolves the concrete attribution/source-availability issue;
reconstructing historical build-time timestamps is a separate provenance limit.
