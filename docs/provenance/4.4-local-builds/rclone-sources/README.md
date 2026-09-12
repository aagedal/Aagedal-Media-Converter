# rclone 4.4 attribution and source

## Resolved release helper (2026-09-12)

`Licenses/rclone-LICENSE.txt` now supplies 209 reviewed notice inputs, including
all applicable retained module notices, 221 unique notice comment blocks from
4,342 selected source files, runtime/math/crypto exceptions, and embedded asset
notices. The 916-package release graph contains 139 module versions. The
original 922-package / 142-module recovery below remains historical evidence.

The original helper included `gofakes3/urlencoder.go`, explicitly marked
AGPL-3.0, through the unused `serve s3` command. The new helper removes only that
command's import (`release.patch`); the S3 storage backend and the app's copy,
lsd, obscure and version operations remain available. The three now-unused
modules are absent from the release graph and gofakes3 names are absent from the
binary. `release-review.json` records the exact old/new binary hashes, active
modules, notice inputs and review decisions. `release-build-info.txt` and
`release-source-selection.json` describe the rebuilt helper.

The helper uses LGPL v3 `cloudsoda/sddl`; its README says MIT but its actual
LICENSE is LGPL v3 without an or-later grant. We follow that stricter license,
preserve both source files, supply LGPL/GPL texts, and provide complete sources
and relinking instructions. The app's custom rclone path setting accepts a
user-rebuilt helper. HashiCorp MPL source and the exact public suffix list source
are included too. The source companion contains the Go 1.26.2 source/toolchain,
main source archive, 139 complete module ZIPs, graph metadata, source patch and
an offline rebuild recipe. It is release material, not a Git-stored binary blob.

The isolated offline source-companion rebuild produced a byte-identical,
ad-hoc-signed helper with SHA-256
`1037b434d983341c999ca372462be4a4365c78b548730c75d8eebf0705309f83`.
Smoke tests cover all six backends, command availability, the app's exact copy
and lsd flags, copied-byte equality, stdin password obscuring, removal of
serve/s3, and signature verification. The arm64 helper links only Apple system
libraries. These checks do not claim a live upload to every remote protocol.

Recreate the release source companion from the original verified downloads:

```sh
python3 scripts/generate-rclone-notices.py --check
python3 scripts/package-rclone-source.py \
  --source-archive /path/to/rclone-c441cac-source.tar.gz \
  --toolchain-archive /path/to/go1.26.2.darwin-arm64.tar.gz \
  --module-cache /path/to/rclone-go/pkg/mod
```

The default output is `build/attribution/rclone-4.4-source.tar.gz`. Distribute it
with the app; the release source-artifact manifest records its hash. Extract it
and run `python3 rebuild.py` on macOS arm64 with Python 3.12+ to rebuild without
network access. Edit the extracted library source and use `--build-only` to
relink modifications. The checked-in `rebuild.py` is also copied into the archive.

Additional primary-source notices and asset provenance are retained in
`additional-notices/reviewed-sources.json`; the full upstream Unicode files are
retained, while only their applicable complete leading license sections are
packaged. The favicon matches the project's 32px logo and preserves Andreas
Chlupka's design credit. The Caddy template keeps its modification notice.

## Historical source recovery (2026-09-11)

The following records describe the original helper and the staged investigation,
not outstanding release attribution work.

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

## Source selection and embedded-file follow-up (2026-09-12)

`source-selection.json` records an offline `go list -mod=readonly -deps -json .`
using Go 1.26.2 and the embedded darwin/arm64, CGO-disabled settings. The verified
main archive already contains the minimal backend imports: crypt, ftp, local,
s3, sftp and smb. The complete entry-point and backend/command selection files
are retained in the report with their hashes. **The resulting 922-package graph
selects exactly the same 142 module versions and checksums as the executable.**
Every selected module Go/assembly source and embed input was compared byte for
byte to its module ZIP; all ZIP hashes match the original recovery inventory.
This is strong source-selection evidence, but does not recover the exact original
build invocation or prove which functions survived linker elimination.

The graph selects 66 embedded files in 15 packages. All 66 complete byte sequences
occur in the hash-verified bundled executable. They include S3 provider YAML,
command documentation, protobuf edition defaults, the generated public-suffix
data, an HTTP favicon and the HTTP directory template. The GUI input is only
`cmd/gui/dist/README.md` containing the instruction to run `make fetch-gui`;
this archive does not supply a populated GUI distribution.

`file-level-evidence.json` indexes additional offline review snapshots and records
both original-source and snapshot hashes. These materially extend the prior
filename-only notice search:

- The embedded HTTP template carries Matthew Holt / Caddy copyright, Apache 2.0
  terms and an explicit rclone modification statement. Retain that notice in the
  eventual offline attribution alongside the applicable license text.
- Prometheus `almost_equal.go` carries Björn Rabenstein's MIT notice and says its
  code was copied to avoid a dependency; its module-root license alone does not
  preserve that notice.
- Go's selected Edwards25519 scalar implementation, selected ELF definitions and
  dsnet's bzip2 prefix implementation contain additional third-party notices.
  The retained source excerpts/files make those notices available for review.
- The selected public-suffix table identifies upstream data revision
  `d6c92f1bbb7433e5db7b8405c25d4035fb8ff376`. Its generated data and the favicon
  still need their applicable asset/source notice obligations established.

Audit the current release helper with the recovered, checksum-verified Go
toolchain and populated module cache (no network is used):

```sh
python3 scripts/audit-rclone-source-selection.py \
  --source-archive /path/to/rclone-c441cac-source.tar.gz \
  --go-root /path/to/go \
  --module-cache /path/to/rclone-go/pkg/mod \
  --output /tmp/rclone-source-selection.json
```

The script verifies the main archive and bundled executable hashes, module ZIP
hashes and selected cached module contents. Use an unmodified extracted Go
1.26.2 toolchain verified as described above; its standard-library files are not
individually authenticated by this script. To reproduce the historical graph, pass `--historical --binary /path/to/original/rclone`.
Python 3.12+ is required for safe
archive extraction using the `data` filter.

## Historical review queue (completed above)

Complete the notice review across the selected source files, including runtime
and standard-library exceptions, generated asset provenance and accompanying
source requirements. The retained file-level snapshots are targeted findings,
not an exhaustive scan. Review all 197 module notice candidates for applicability
and package the complete reviewed attribution for offline viewing. Retain the
original build recipe if recovered, or produce and validate a documented rebuild.
Rerun the strict publication gate and final-bundle checks after those steps.
No executable, license assignment or publication gate changed in this follow-up.
