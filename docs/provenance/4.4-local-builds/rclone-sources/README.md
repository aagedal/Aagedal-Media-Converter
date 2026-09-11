# Exact rclone source and notice recovery

Recovered 2026-09-11. These files are review evidence, not a complete packaged
notice set. The rclone manifest entry remains unresolved.

The main source archive was retrieved directly from GitHub at the full embedded
revision `c441cac8089c7d5314a37673291fdb8236900884`. Its SHA-256, size and URL are
in `source-recovery.json`; the archive itself was downloaded to temporary storage.
The six retained main-source files include `go.mod`, `go.sum`, `COPYING`, and
three additional component notices. **All 142 dependency path/version/checksum
triples from the bundled executable match this source revision's `go.sum`.**

The official Go 1.26.2 darwin-arm64 toolchain was downloaded and its SHA-256
verified against the official download index. Its record and root license are
preserved here. Using that toolchain, `go mod download -json` successfully
retrieved all 142 exact dependency versions. Every returned `Sum` matches the
corresponding embedded `h1:` checksum. `modules.json` retains those sums, module
metadata and upstream origin records when supplied by Go, source ZIP hashes,
and the individual notice snapshot hashes. This establishes source-content
agreement with the binary's embedded records, not an independently reproduced
binary or the scope of code actually linked.

All modules have at least one filename-selected notice candidate. The 197
snapshots (936,761 bytes) include nested files, selected case-insensitively by
`LICENSE`, `LICENCE`, `COPYING`, `NOTICE`, `COPYRIGHT`, `PATENTS`, or `AUTHORS`,
with an optional dot, underscore or hyphen suffix. They are byte-for-byte copies
of the verified module sources. This selection does not capture every possible
notice embedded in source comments or files with other names. Do not combine
these files into a claimed complete attribution without reviewing applicability,
file-level exceptions, embedded assets and required accompanying material.

## Reproduction

Download the main source and Go toolchain using the URLs/filename recorded in
`source-recovery.json`, verify their recorded SHA-256 values, and extract them
into a temporary directory. Confirm the toolchain checksum independently using
the recorded official index URL. Do not substitute a current rclone branch.

Build the dependency arguments from `rclone-build-info.txt`: each tab-separated
`dep` record supplies `<module>@<version>`. Run the downloaded toolchain as:

```text
go mod download -json <all 142 module@version arguments>
```

The recovery used isolated temporary `GOPATH`, `GOMODCACHE` and `GOCACHE`, with
`GOTOOLCHAIN=local`, `GOWORK=off`, and `GO111MODULE=on`, from a temporary directory
outside any module. Go's default module proxy/checksum database settings applied.
Compare each returned `Sum` to the matching embedded checksum; fail on missing,
extra, mismatched or error records before copying notices. Hash each returned
`Zip` and the selected source notices to reproduce `modules.json`.

The public Go proxy rejected the main pseudo-version
`v0.0.0-20260427122042-c441cac8089c` with HTTP 404 and
`invalid version: unknown revision c441cac8089c`. Direct GitHub retrieval using
the full revision succeeded. That proxy response does not establish that the
source revision is absent upstream; use the working full-revision archive URL.

## Remaining review

Recover the original minimal-build selection/recipe and reconcile its compiled
packages against the source graph and binary. Review the recovered module notices
and file-level/embedded-asset surfaces. The main tree contains `go:embed` inputs,
including HTTP templates, GUI assets, images and documentation; their presence
alone does not establish that each shipped. The Go root license is retained, but
a full runtime/standard-library source exception review is still needed. Package
the reviewed notices for offline viewing, record any required source material,
and rerun the strict publication gate and final-bundle checks. No executable,
license assignment or gate changed in this recovery.
