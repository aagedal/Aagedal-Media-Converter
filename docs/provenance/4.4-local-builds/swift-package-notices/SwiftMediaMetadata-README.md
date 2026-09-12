# SwiftMediaMetadata

A native Swift library for reading and writing image and video metadata — Exif, IPTC (IIM), XMP, C2PA, MakerNotes, and ICC profiles — with no external dependencies.

## Supported Formats

| Format | Read | Write | Metadata Types |
|--------|------|-------|----------------|
| JPEG | Yes | Yes | Exif, IPTC, XMP, C2PA, ICC |
| TIFF | Yes | Yes | Exif, IPTC, XMP, C2PA, ICC |
| DNG / GPR / CR3 | Yes | Yes | Exif, IPTC, XMP, MakerNotes, ICC |
| Proprietary RAW (CR2, NEF, NRW, ARW, RAF, RW2, ORF, PEF, SRW, .raw, IIQ, 3FR, FFF, X3F, MRW) | Yes | XMP sidecar | Exif, IPTC, XMP, MakerNotes, ICC; embedded writes are refused by default because a full TIFF rewrite can damage maker-private data |
| JPEG XL (container) | Yes | Yes | Exif, XMP, C2PA, ICC |
| PNG | Yes | Yes | Exif, XMP, C2PA, ICC |
| AVIF | Yes | Yes | Exif, XMP, C2PA, ICC |
| HEIF / HEIC | Yes | Yes | Exif, XMP, C2PA, ICC |
| WebP | Yes | Yes | Exif, XMP, C2PA, ICC |
| GIF | Yes | Yes | XMP; C2PA read-only |
| PDF | Yes | Yes | XMP, document metadata; C2PA read-only |
| PSD (Photoshop) | Yes | Yes | Exif, IPTC, XMP, ICC |
| BMP | Yes | — | Container and image dimensions; no embedded metadata writer |
| SVG | Yes | Yes | XMP |
| MP4 / MOV / M4V | Yes | Yes | XMP, GPS, C2PA, Sony NRT camera metadata, full stream info (codec, profile, fps, field order, bit depth, chroma subsampling, pixel format, color primaries/transfer/matrix/range, pixel aspect ratio, bit rate) + audio (codec, sample rate, channels, channel layout, bit depth, bit rate) + subtitle tracks (tx3g, WebVTT, TTML, CEA-608/708) with language, QuickTime `tmcd` timecode |
| Blackmagic RAW (.braw) | Yes | — | Container metadata via QuickTime layout (no `ftyp`, tail-placed `moov`): resolution, project frame rate, audio, timecode, plus the `moov.meta` slate — camera make/model, firmware, viewing gamma/gamut, color science, compression ratio, shutter type, sensor capture FPS (off-speed), production slate (clip number / scene / take / reel / camera / environment / day-night), sensor area, crop / safe-area rectangles, LUT used, post-3DLUT mode, frameguide aspect ratio, gamut compression. Per-frame interpretation attributes (white point, tint, absolute ISO) live in proprietary `bfdn`/`ctrn` boxes and remain unparsed |
| RED RAW (.R3D) | Yes | — | Clip-header metadata from RED's own length-prefixed `RED2`/`RED1` atom: resolution (from `rdi`), audio sample rate (from `rda`), original capture frame rate, plus the TLV slate — camera brain + sensor, body serial, lens model, firmware, ISO, color temperature (Kelvin), crop area (`WxH+X+Y`), record/playback timecodes, reel + take, video format ("8K 16:9"), quality preset, storage media + serial + format date/time, original camera filename, focus distance. Tag IDs match ExifTool's `Image::ExifTool::Red` table |
| Nikon RAW Video (N-RAW) | Yes | — | Detected by `ftyp niko` brand + `NR3D` codec FourCC. Nikon Z8/Z9 ship N-RAW with a `.R3D` extension as part of the post-acquisition "RED RAW" branding, but the bitstream is wholly unrelated to RED's REDCODE — promoted to `format = .nikonRaw` so callers can disambiguate. All standard MP4 metadata (resolution, timecode, audio, color) reads through the QuickTime path |
| MXF (SMPTE 377) | Yes | — | C2PA, Sony NonRealTimeMeta (RDD-18), picture/sound essence descriptors (resolution, frame rate, scan type, chroma, color) |
| Sony X-OCN (.mxf) | Yes | — | MXF wrapper detected via picture-essence UL (`060e2b34.0401.0106.0e06.0401.0206.06xx`) or NRT `videoCodec` label. Promotes `format = .xocn` with codec long-names `Sony X-OCN LT/ST/XT`. Deepens NRT AcquisitionRecord harvest: every `CameraUnitMetadataSet`, `SonyF65CameraMetadataSet`, `CameraPostureMetadataSet`, `LensUnitMetadataSet` `<Item>` is captured into a flat `acquisitionGroups` dictionary, with curated typed fields on `CameraMetadata` for ISO, exposure index, shutter angle/time, ND filter, white balance, capture/look gamma + color, raw black/gray/white code values, monitoring LUT, sensor effective size, camera tilt/roll. ASC CDL Slope/Offset/Power/Saturation from `<ExtendedContents>` parsed into `ascCDL` (identity transforms suppressed). Verified against Sony F55 8.6K 3:2 X-OCN LT clips |
| ARRIRAW (.mxf) | Yes | — | MXF-wrapped ARRIRAW detection, stream metadata, and ARRI camera JSON/slate metadata |
| Canon Cinema RAW Light (.CRM / .CRL) | Yes | — | ISOBMFF with `ftyp crx ` and the same Canon-metadata UUID (`85c0b687-820f-11e0-8111-f4ce462b6a48`) used by CR3 still images. Distinguished from CR3 by CNCV `"CanonCRM..."`. Reads the in-`moov` `CMT1`/`CMT2`/`CMT3`/`CMT4` TIFF IFDs (Make/Model/Lens/exposure/GPS via the shared `CanonUUIDExtractor`) plus the dedicated `CTMD` track for per-frame timed metadata: type 0x0001 timestamp (with hundredths-of-a-second), 0x0004 focal length (mm), 0x0005 exposure (F-number / shutter / ISO), 0x0007/8/9 embedded TIFF blocks (CanonColorData → R/G1/G2/B white-balance multipliers). The full per-frame stream lands in `videoMetadata.cameraTimeline`; first-frame values populate single-valued `CameraMetadata` fields. THMB and PRVW JPEGs are surfaced as `embeddedThumbnailJPEG` / `embeddedPreviewJPEG`. `.CRL` proxies share the layout and tag as `format = .crl` ("Canon Cinema RAW Light Proxy"). Verified against EOS C70 master clips |
| Matroska (.mkv) | Yes | — | Stream info (codec, profile, fps, dimensions, bit depth, chroma, chroma location, color, pixel format) decoded from both `Tracks` and `CodecPrivate` (hvcC/av1C/avcC), Segment-level `COMMENT`/`DESCRIPTION` tags, audio tracks, subtitle tracks (SRT, ASS/SSA, WebVTT, PGS, VobSub) with language + default/forced/SDH flags |
| WebM (.webm) | Yes | — | Stream info (VP8/VP9/AV1) + audio (Vorbis/Opus) + subtitle tracks |
| AVI (RIFF) | Yes | — | Stream info (codec, fps, dimensions, bit depth) + audio (codec, sample rate, channels), INFO tags |
| MPEG-PS / MPEG-TS / M2TS | Yes | — | Sequence-header stream facts (resolution, fps, aspect, bit rate), PMT elementary-stream inventory (DVB subtitles / teletext / PGS with language), M2TS (Blu-ray BDAV, 192-byte packets) auto-detected |
| IVF | Yes | — | VP8, VP9, AV1, or AV2 elementary-stream codec, dimensions, frame rate, duration, and frame count |
| MP3 (ID3v1 / ID3v2) | Yes | Yes | Tags + codec, sample rate, channels, bit rate, duration; ID3v2 frame detail (TXXX/WXXX/PRIV/GEOB/CHAP/CTOC) |
| FLAC | Yes | Yes | Tags + sample rate, channels, bit depth, duration; SeekTable + CueSheet |
| M4A | Yes | Yes | Tags + codec, sample rate, channels, bit depth, channel layout, bit rate, duration |
| Ogg Opus (.opus) | Yes | — | Vorbis comments + channels, sample rate, channel layout, duration |
| Ogg Vorbis (.ogg / .oga) | Yes | — | Vorbis comments + channels, sample rate, bit rate, duration |
| WAV / BWF (RIFF) | Yes | Yes | LIST/INFO tags, Broadcast WAVE `bext` (v0/v1/v2), iXML, C2PA, sample rate, channels, bit depth |
| AIFF / AIFC | Yes | Yes | NAME/AUTH/(c)/ANNO/COMT chunks, COMM 80-bit sample rate, channels, bit depth |
| XMP sidecar (.xmp) | Yes | Yes | XMP |
| C2PA sidecar (.c2pa) | Yes | — | External JUMBF manifest store next to the asset |
| AAE sidecar (Apple Photos) | Yes | — | iPhone/iPad edit-decision sidecar |
| Sony NRT sidecar (.XML) | Yes | — | Camera metadata auto-probed next to MP4/MXF |

Compressed SVGZ payloads are not currently decoded; use an uncompressed SVG
when reading or writing XMP.

## Requirements

- Swift 6.0+
- macOS 13+ / iOS 16+

## Installation

### CLI

Install the macOS arm64 CLI with Homebrew:

```sh
brew install aagedal/tap/swift-exif
swift-exif --version
```

Or download the archive and checksum directly from the
[2.0.0 release](https://github.com/aagedal/SwiftMediaMetadata/releases/tag/2.0.0):

```sh
curl -LO https://github.com/aagedal/SwiftMediaMetadata/releases/download/2.0.0/swift-exif-macos-arm64.tar.gz
curl -LO https://github.com/aagedal/SwiftMediaMetadata/releases/download/2.0.0/swift-exif-macos-arm64.tar.gz.sha256
shasum -a 256 -c swift-exif-macos-arm64.tar.gz.sha256
tar -xzf swift-exif-macos-arm64.tar.gz
./swift-exif-macos-arm64/swift-exif --version
```

Keep the manually extracted executable and resource bundle together.

### Swift Package

Add the package to your `Package.swift` with:

```swift
dependencies: [
    .package(url: "https://github.com/aagedal/SwiftMediaMetadata.git", from: "2.0.0"),
]
```

Then add it as a dependency to your target:

```swift
.target(name: "YourApp", dependencies: ["SwiftMediaMetadata"]),
```

### Migrating from 1.x

Version 2.0 renames the package, library product, and importable module from
`SwiftExif` to `SwiftMediaMetadata`. Update the package URL and target dependency
above, then replace `import SwiftExif` with `import SwiftMediaMetadata`. The
installed CLI command remains `swift-exif`.

For the unreleased APIs currently on `main`, including exhaustive-enum changes,
synchronization policies, typed projections, transactional sidecars, semantic
preservation, and GPS conversion, see the [migration guide](MIGRATION.md).

## Building from source

### macOS (arm64)

The supported release target. Builds with the system Swift toolchain
(Xcode 16+ / Swift 6.0+):

```sh
./Scripts/build-release.sh
```

Output lands at `dist/swift-exif-macos-arm64.tar.gz`. The archive contains the
stripped CLI, its adjacent SwiftPM resource bundle, which supplies the offline
geolocation database, and the project license. Keep the executable and bundle
together when installing manually.
For a plain development build, `swift build -c release` places the executable
and resource bundle together under `.build/release`.

### Linux (static musl, unsupported)

Linux binaries are no longer part of the release pipeline. The recipe
below is preserved for downstream contributors who need a static-musl
build. It cross-compiles from macOS using the official swift.org
toolchain (the macOS-bundled Swift inside Xcode is not compatible with
the Static Linux SDK).

1. Install the swift.org toolchain via [swiftly](https://swiftlang.github.io/swiftly/):

   ```sh
   swiftly install 6.3.1
   source "$HOME/.swiftly/env.sh"
   ```

2. Install the Static Linux SDK:

   ```sh
   swift sdk install \
     https://download.swift.org/swift-6.3.1-release/static-sdk/swift-6.3.1-RELEASE/swift-6.3.1-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz \
     --checksum fac05271c1f7d060bd203240ce5251d5ca902d30ac899f553765dbb3a88b97ad
   ```

3. Cross-compile (replace `x86_64` with `aarch64` for ARM64 Linux):

   ```sh
   SDK_ROOT="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.1-RELEASE_static-linux-0.1.0.artifactbundle/swift-6.3.1-RELEASE_static-linux-0.1.0/swift-linux-musl/musl-1.2.5.sdk"

   swift build -c release \
     --swift-sdk x86_64-swift-linux-musl \
     --static-swift-stdlib \
     --product swift-exif \
     -Xswiftc -Onone \
     -Xlinker "$SDK_ROOT/x86_64/usr/lib/libz.a" \
     --disable-sandbox
   ```

   Keep the generated `SwiftMediaMetadata_SwiftMediaMetadata.bundle` directory
   next to the executable when copying it out of `.build`; it contains the
   offline geolocation database.

   `-Onone` is mandatory: `-O` with whole-module-optimization stalls the
   swift-6.3.1 musl optimizer indefinitely (frontend pinned at ~100% CPU
   with no progress). `-Onone` compiles in a few minutes; the binary is
   larger and slower than the macOS build but functional.

4. Optional shrink — strip debug info and compress with UPX:

   ```sh
   llvm-strip .build/x86_64-swift-linux-musl/release/swift-exif
   upx --best --no-progress .build/x86_64-swift-linux-musl/release/swift-exif
   ```

   UPX reduces the binary from ~70 MB to ~25 MB at the cost of a few
   hundred milliseconds of one-time decompression at startup.

## Usage

### Reading Metadata

```swift
import SwiftMediaMetadata

// From a file URL
let metadata = try readMetadata(from: imageURL)

// From data in memory
let metadata = try readMetadata(from: imageData)
```

### Accessing IPTC Fields

```swift
let headline = metadata.iptc.value(for: .headline)
let keywords = metadata.iptc.values(for: .keywords)
let caption = metadata.iptc.value(for: .captionAbstract)
```

### Accessing Exif Fields

```swift
if let exif = metadata.exif {
    let camera = exif.value(for: .make)
    let model = exif.value(for: .model)
}
```

### Writing Metadata

The same API writes every format marked “Yes” in the table above. Proprietary
RAW files default to XMP sidecars because embedded TIFF rewrites are unsafe:

```swift
var metadata = try readMetadata(from: imageURL)

metadata.iptc.setValue("Breaking news photo", for: .headline)
metadata.iptc.setValue("Jane Doe", for: .byline)
metadata.iptc.setValues(["news", "politics"], for: .keywords)

try metadata.write(to: outputURL)
```

Use the result API when a caller needs a uniform outcome across media types or
must surface non-fatal warnings. Serialization is a separate, filesystem-free
step:

```swift
let serialized = try metadata.serialized()
let bytes: Data = serialized.output

let written = try metadata.writeResult(to: outputURL)
print("Wrote \(written.output.path)")
for warning in written.warnings {
    print("Warning: \(warning)")
}
```

`ImageMetadata`, `VideoMetadata`, and `AudioMetadata` expose `serialized()` and
`writeResult(to:options:)`; `XMPSidecar` exposes the equivalent static methods.
The earlier `writeToData()` and `write(to:)` methods remain supported.

Filesystem modification dates update by default, while creation dates are
preserved by default. Either timestamp can be assigned independently:

```swift
// In-place edit
let preserve = ImageMetadata.WriteOptions(
    fileModificationDate: .preserveExisting
)
try metadata.write(to: imageURL, options: preserve)

// Source → new destination
let values = try sourceURL.resourceValues(forKeys: [.contentModificationDateKey])
if let sourceDate = values.contentModificationDate {
    let copyDate = ImageMetadata.WriteOptions(
        fileModificationDate: .set(sourceDate),
        fileCreationDate: .set(sourceDate)
    )
    try metadata.write(to: outputURL, options: copyDate)
}
```

The CLI equivalent for in-place writes is `-P` or
`--preserve-file-modification-date`.

### XMP Sidecar Files

Read and write `.xmp` sidecar files alongside image files:

```swift
// Write XMP sidecar for a RAW file
var metadata = try readMetadata(from: rawFileURL)
metadata.syncIPTCToXMP()
try metadata.writeSidecar(for: rawFileURL) // creates IMG_001.xmp

// Read XMP sidecar
var xmp = try readXMPSidecar(for: rawFileURL)
print(xmp.headline)
```

For concurrent editors, read a content revision and use a transactional
mutation. The closure receives the latest parsed packet and preserves fields it
does not change. It can run more than once when a competing writer commits, so
keep it free of one-shot side effects:

```swift
let sidecarURL = XMPSidecar.sidecarURL(for: rawFileURL)
let snapshot = try XMPSidecar.readSnapshot(from: sidecarURL)

let result = try XMPSidecar.update(
    at: sidecarURL,
    expectedRevision: snapshot.revision,
    maximumRetries: 2,
    options: ImageMetadata.WriteOptions(
        fileModificationDate: .preserveExisting
    )
) { xmp in
    xmp.rating = 5
}

print(result.revision)
```

A base revision that was already stale throws
`XMPSidecarUpdateError.staleRevision` without overwriting the newer packet.
Use `.missing` as the expected revision when a transaction should create a
sidecar only if none exists.

Localized `rdf:Alt` values retain their original order, language tags,
duplicates, and empty entries:

```swift
let titles = xmp.languageAlternativeValue(
    namespace: XMPNamespace.dc,
    property: "title"
)

xmp.setValue(
    .languageAlternative([
        XMPLanguageAlternative(language: "x-default", value: "Default title"),
        XMPLanguageAlternative(language: "nb-NO", value: "Norsk tittel"),
    ]),
    namespace: XMPNamespace.dc,
    property: "title"
)
```

### IPTC / XMP Sync

```swift
// Compatibility behavior: copy the legacy mappings directly
metadata.syncIPTCToXMP()

// Or the other way around
metadata.syncXMPToIPTC()

// Standards-aware merge: preserve localized dc:title and full-precision dates,
// carry explicit clear intent, and inspect pre-existing carrier disagreements.
let report = metadata.synchronizeIPTCToXMP(options: .init(
    explicitlyClearedTags: [.headline]
))
print(report.conflicts)
```

Use `IPTCXMPSynchronizationOptions.replace` when missing source values should
remove mapped destination values. The standards-aware API preserves `dc:title`
instead of treating it as IIM Object Name unless `titlePolicy` is explicitly
set to `.mirrorObjectName`.

For a carrier-independent view, `photoMetadata` prefers XMP, falls back to
IPTC-IIM and Exif, and retains all candidates so conflicts remain visible:

```swift
let photo = metadata.photoMetadata
print(photo.string(.headline) ?? "")
print(photo[.headline]?.source as Any)
print(photo.conflicts.keys)

let mutation = PhotoMetadataMutation(
    values: [.keywords: .strings(["news", "portrait"])],
    clearedFields: [.credit]
)
let mutationReport = try metadata.applyPhotoMetadataMutation(mutation)
print(mutationReport.unappliedFields)
```

Each image format exposes an explicit read, write, and preservation contract
for Exif, IPTC-IIM, XMP, Camera Raw (`crs:`), ICC, and C2PA. This distinguishes
direct writes from RAW-sidecar workflows and opaque preservation:

```swift
let capabilities = metadata.metadataCapabilities
print(capabilities[.xmp].write)          // directlyWritable or sidecarOnly
print(capabilities[.c2pa].preservation) // preservedOpaquely
```

Use semantic comparison after a write/read cycle or container conversion. It
compares expanded XMP namespace names, normalized TIFF values, dates and GPS
spellings, and canonical C2PA claims rather than raw container layout. The
report provides facts; the application decides which differences are allowed:

```swift
let written = try metadata.writeToData()
let readBack = try ImageMetadata.read(from: written)
let preservation = metadata.preservationReport(comparedTo: readBack)

print(preservation.added)
print(preservation.removed)
print(preservation.changed)
print(preservation.unrepresentable)
print(preservation.opaquePreserved)
```

Typed XMP GPS access retains each packet's original spelling while providing
validated decimal values. Coordinate writers emit XMP's
degrees/decimal-minutes form with six fractional minute digits by default;
altitude and direction use reduced rationals with three fractional digits:

```swift
var xmp = metadata.xmp ?? XMPData()
try xmp.setGPSLatitude(59.913868)
try xmp.setGPSLongitude(-10.752245)
try xmp.setGPSAltitude(23.5)
try xmp.setGPSImageDirection(271.25, reference: .trueNorth)

let gps = try xmp.parsedGPS()
print(gps.latitude?.decimalDegrees as Any)
print(gps.latitude?.originalLexicalValue as Any)
```

The parser also accepts decimal, directional decimal, degrees/minutes/seconds,
and degrees/decimal-minutes input. Invalid ranges and contradictory signs or
hemispheres throw `XMPGPSParsingError`. `PhotoMetadata` projects the typed XMP
and Exif GPS candidates together, so carrier disagreements remain visible.

Structured XMP setters retain unknown sibling fields. For app-specific
structures, use `patchStructure` or `patchStructuredArrayItem` with an
`XMPStructurePatch` to replace and remove only named members.

### Video Metadata

Read rich stream-level metadata from the video and cinema-camera containers in
the supported-format table above — enough to replace `ffprobe` in editorial
and media-pipeline tooling. Container essence (mdat / MXF KLV body / Matroska
clusters) is never fully materialised; parsers only touch the header metadata.

```swift
let video = try VideoMetadata.read(from: videoURL)
```

Everything below is populated from the container header — no decoding,
no AVFoundation, no external dependencies.

#### Container-level facts

| Property | Type | Description |
|----------|------|-------------|
| `format` | `VideoFormat` | `.mp4`, `.mov`, `.m4v`, `.mxf`, `.xocn`, `.mkv`, `.webm`, `.avi`, `.mpg`, `.braw`, `.arriraw`, `.r3d`, `.nikonRaw`, `.crm`, `.crl`, `.ivf` |
| `formatLongName` | `String?` | Human-readable container name (`"QuickTime / MOV"`, `"MP4 (MPEG-4 Part 14)"`, `"Matroska"`, `"WebM"`, …) — matches ffprobe `format_long_name` |
| `fileSize` | `Int64?` | File size in bytes |
| `duration` | `TimeInterval?` | Total playback duration in seconds |
| `creationDate` | `Date?` | Capture / mux time (ISOBMFF `mvhd`, Matroska `DateUTC`, etc.) |
| `modificationDate` | `Date?` | Embedded container modification time (for example QuickTime `mvhd`), not the filesystem modification date |
| `bitRate` | `Int?` | Overall container bitrate in bits/second |
| `timecode` | `String?` | Clip start timecode `HH:MM:SS:FF` (or `HH:MM:SS;FF` for drop-frame) — the first source the container yields |
| `timecodes` | `[Timecode]` | Every timecode source the container carries, tagged with provenance — QuickTime `tmcd` track, `moov>udta ©TIM`, XMP `xmpDM:startTimeCode`/`altTimeCode`, MXF MaterialPackage vs FilePackage, Sony NRT LtcChangeTable. Mismatches trigger a `timecode mismatch:` entry in `warnings` |
| `chapters` | `[VideoChapter]` | Chapter markers ordered by start time — QuickTime `tref > chap` text tracks and Nero `udta > chpl` in MP4/MOV, `Chapters` master in Matroska / WebM |
| `title` / `artist` / `comment` | `String?` | QuickTime `©nam` / `©ART` / `©cmt`, Matroska Info/Title + Segment-level `COMMENT`/`DESCRIPTION`, RIFF INFO |
| `gpsLatitude` / `gpsLongitude` / `gpsAltitude` | `Double?` | QuickTime `©xyz` / ISO 6709 |
| `c2pa` | `C2PAData?` | Parsed C2PA manifest store (MP4/MOV uuid or top-level `jumb`, MXF SMPTE UL or Dark KLV) |
| `camera` | `CameraMetadata?` | Sony NonRealTimeMeta (RDD-18) from MXF header or sidecar XML |
| `xmp` | `XMPData?` | XMP packet embedded in uuid box or `xml ` meta |

#### Per-stream: video

`VideoMetadata.videoStreams: [VideoStream]` exposes one entry per video track,
plus convenience accessors that mirror the first video stream at the top level
(`videoWidth`, `videoHeight`, `videoCodec`, `frameRate`, `fieldOrder`,
`colorInfo`, `bitDepth`, `chromaSubsampling`, `pixelAspectRatio`,
`displayWidth`, `displayHeight`).

| `VideoStream` property | Description |
|------------------------|-------------|
| `index` | Track index within the container |
| `codec` | 4CC / ID — `"hvc1"`, `"av01"`, `"avc1"`, `"apch"`, `"V_VP9"`, `"V_MPEGH/ISO/HEVC"`, … |
| `codecName` | Human-readable — `"H.265 / HEVC"`, `"Apple ProRes"`, `"AV1"`, `"VP9"`, `"MPEG-2 Video"` |
| `profile` | Codec profile — `"Main"`, `"Main 10"`, `"High"`, `"Main 4:4:4 12"`, `"Professional"` — from `hvcC` / `av1C` / `avcC` or Matroska `CodecPrivate` |
| `width` / `height` | Coded luma dimensions |
| `displayWidth` / `displayHeight` | Final rendered display dimensions, after PAR *and* rotation (matches ffprobe `display_aspect_ratio`). For an iPhone-recorded 3840×2160 portrait clip this is 2160×3840 with `rotation = -90` — do not re-apply rotation when sizing UI |
| `pixelAspectRatio` | `(Int, Int)` — e.g. `(40, 33)` for anamorphic 1440×1080 |
| `bitDepth` | 8 / 10 / 12 from `hvcC` / `av1C` / CDCI / Matroska `BitsPerChannel` or `CodecPrivate` |
| `chromaSubsampling` | `"4:2:0"`, `"4:2:2"`, `"4:4:4"`, `"4:0:0"`, `"4:1:1"` |
| `chromaLocation` | `"left"`, `"center"`, `"topleft"`, `"top"`, `"bottomleft"`, `"bottom"` — matches ffprobe `chroma_location` |
| `pixelFormat` | ffprobe-style `pix_fmt` string — `"yuv420p"`, `"yuv420p10le"`, `"yuvj420p"`, `"yuv444p12le"`, `"gray10le"`, derived from codec + chroma + depth + range |
| `frameRate` | fps — from `stsz`/`stts` for ISOBMFF, Matroska `DefaultDuration`, MXF `SampleRate`, AVI `dwRate`/`dwScale`, MPEG-2 sequence header |
| `avgFrameRate` / `rFrameRate` | ffprobe-compatible pair — `avg_frame_rate` (average) and `r_frame_rate` (raw cadence) |
| `duration` | Per-track duration in seconds |
| `frameCount` | Container-advertised frame count (ISOBMFF `stsz`, AVI `dwLength`, Matroska `NUMBER_OF_FRAMES` tag) |
| `fieldOrder` | `.progressive`, `.topFieldFirst`, `.bottomFieldFirst`, `.mixed`, `.unknown` |
| `colorInfo` | `VideoColorInfo?` — primaries / transfer / matrix / range (H.273 codes) with readable `label` |
| `hdr` | `HDRMetadata?` — SMPTE ST 2086 mastering display (R/G/B/W xy + max/min luminance), CTA-861.3 MaxCLL / MaxFALL, Dolby Vision config. Read from ISOBMFF `mdcv` / `clli` / `dvcC` / `dvvC` boxes, H.264 / H.265 SEI (payload types 137 and 144), and the Matroska `MasteringMetadata` (0x55D0) / `MaxCLL` (0x55BC) / `MaxFALL` (0x55BD) elements |
| `bitRate` | Per-stream bits/second (ISOBMFF `btrt`) |
| `timecode` | Per-stream timecode (when the track carries one) |
| `isAttachedPic` | `true` when the track is a cover-art / attached-picture track |

`VideoColorInfo.label` returns canonical names: `"bt709"`, `"bt601"`,
`"bt2020"`, `"bt2020-pq"` (HDR10 / SMPTE ST 2084), `"bt2020-hlg"` (Hybrid
Log-Gamma), … — the same vocabulary `ffprobe -show_streams` uses.

#### Timecodes (every source)

Broadcast workflows frequently carry the same timecode value in several
independent places — a QuickTime `tmcd` track plus an XMP `startTimeCode`
plus an MXF Material/File TimecodeComponent — and the three can disagree
after a partial round-trip. `VideoMetadata.timecodes` keeps each one with
its provenance rather than merging them silently:

```swift
for tc in video.timecodes {
    print(tc.source, tc.value, tc.frameRate ?? -1)
    // tc.source is .tmcdTrack, .quicktimeUdta, .xmpDM, .xmpDMAlt,
    // .mxfMaterialPackage, .mxfFilePackage, or .sonyNRT
}
if video.warnings.contains(where: { $0.hasPrefix("timecode mismatch:") }) {
    // two or more sources disagree — worth surfacing to the operator
}
```

The scalar `timecode` field stays in sync with the first recorded entry
for backward compatibility. `--streams` JSON output emits the full list at
`format.Timecodes` (array of `{ value, source, frameRate }`) plus per-stream
`Timecode` fields when the source is track-local.

#### Per-stream: audio

`VideoMetadata.audioStreams: [AudioStream]` plus top-level `audioCodec`,
`audioSampleRate`, `audioChannels`.

| `AudioStream` property | Description |
|------------------------|-------------|
| `codec` / `codecName` | `"mp4a"` / `"AAC"`, `"ac-3"` / `"Dolby Digital (AC-3)"`, `"A_OPUS"` / `"Opus"`, `"lpcm"` / `"Linear PCM"`, `"alac"` / `"ALAC"`, … |
| `profile` | Codec profile (`"LC"`, `"HE-AAC"`, `"HE-AACv2"`, …) where the container carries one |
| `sampleRate` | Hz |
| `channels` | Channel count |
| `channelLayout` | `"mono"`, `"stereo"`, `"stereo-headphones"`, `"5.1"`, `"7.1"`, … (from QuickTime `chan` box or synthesised from the channel count) |
| `bitDepth` | Bits per sample |
| `bitRate` | Bits/second (ISOBMFF `btrt` or MPEG-4 ES descriptor) |
| `duration` | Per-track duration |
| `language` | ISO 639-2/T code (`"eng"`, `"nor"`, `"swe"`, …) |
| `isDefault` | Default-track flag if the container signals one |

QuickTime Sound Description **V2** is handled correctly, so 24-bit LPCM and
Float64-sample-rate ProRes/APV audio tracks report accurate channels and
rate.

#### Per-stream: subtitles & closed captions

`VideoMetadata.subtitleStreams: [SubtitleStream]`:

```swift
for sub in video.subtitleStreams {
    print(sub.codecName)         // "SubRip (SRT)", "PGS (Blu-ray)", "3GPP Timed Text", "WebVTT"
    print(sub.language)          // "eng", "nor", "swe" — ISO 639-2/T
    print(sub.title)             // Matroska track name, when set
    print(sub.isDefault)         // Matroska FlagDefault
    print(sub.isForced)          // FlagForced — foreign-audio burn-in
    print(sub.isHearingImpaired) // SDH flag
}
```

Codec coverage:

- **MP4/MOV/M4V**: `tx3g` (3GPP Timed Text), `wvtt` (WebVTT), `stpp` (TTML),
  `c608` / `c708` (CEA-608/708 closed captions), `text` (QuickTime Text);
  handler types `subt`, `text`, `sbtl`, `clcp`.
- **Matroska / WebM**: `S_TEXT/UTF8` (SRT), `S_TEXT/ASS`, `S_TEXT/SSA`,
  `S_TEXT/WEBVTT`, `S_HDMV/PGS` (Blu-ray), `S_VOBSUB`, `S_HDMV/TEXTST`.
- **MPEG-TS**: DVB subtitles (stream type `0x06` + descriptor `0x59`),
  DVB teletext (descriptor `0x56`), Blu-ray PGS (stream type `0x82`).

#### Chapter markers

`VideoMetadata.chapters: [VideoChapter]` — start/end times in seconds from
presentation start, with optional title and language. Ordered by start time,
and re-indexed contiguously after hidden-atom suppression so `chapter.index`
always matches array position.

```swift
for ch in video.chapters {
    print(ch.index, ch.startTime, ch.endTime ?? -1,
          ch.title ?? "", ch.language ?? "")
    // duration is a computed property: endTime - startTime (or nil)
    if let d = ch.duration { print("lasts \(d)s") }
}
```

| `VideoChapter` property | Description |
|-------------------------|-------------|
| `index` | Position in the chapter list (0-based, contiguous) |
| `id` | Stable identifier where the container provides one (Matroska `ChapterUID`); nil for MP4 chap / chpl |
| `startTime` | Seconds from presentation start |
| `endTime` | Seconds from presentation start; nil when the source doesn't record one (Nero `chpl`, open-ended Matroska atoms) |
| `duration` | Computed `endTime − startTime`; nil when `endTime` is nil |
| `title` | Chapter title; UTF-8 |
| `language` | BCP-47 or ISO 639-2/T, when the container records one (Matroska `ChapLanguage` / `ChapLanguageBCP47`) |

Source coverage:

- **MP4 / MOV / M4V**: QuickTime text-track chapters — any trak's
  `tref > chap` points at a text/subt trak whose stts-timed UTF-8 samples
  carry the titles (DaVinci Resolve, Apple Compressor, iTunes, ffmpeg
  `-map_chapters`). Falls back to Nero `udta > chpl` (x264, ffmpeg,
  MP4Box) when no chap reference exists. The chap-referenced text track
  is filtered out of `subtitleStreams` to match ffprobe, which reclassifies
  those tracks as `codec_type=data` under `-select_streams s`.
- **Matroska / WebM**: top-level `Chapters` master — walks every
  `EditionEntry` + `ChapterAtom`, honouring `EditionFlagHidden` and
  `ChapterFlagHidden`; supports `ChapterDisplay > ChapString`, both
  `ChapLanguage` and the newer `ChapLanguageBCP47`.

#### Format-specific highlights

- **MP4 / MOV / M4V**: per-track `mdhd` timescale + language, visual sample
  entry walk (`fiel`, `pasp`, `colr` for `nclx`/`nclc`, `hvcC`, `av1C`,
  `avcC`, `btrt`) including codec profile extraction, QuickTime `chan`
  channel layouts, V0/V1/V2 Sound Description. QuickTime `tmcd` timecode
  tracks: frame counter read from `mdat` via `stco`/`co64`, formatted
  `HH:MM:SS:FF` with SMPTE 12M drop-frame arithmetic. Also: embedded XMP
  (uuid `BE7ACFCB-…`), GPS (`©xyz`), C2PA manifests, and Sony NRT sidecar
  auto-discovery.
- **Blackmagic RAW (`.braw`)**: ISOBMFF derivative with the legacy QuickTime
  layout — `wide` + `mdat` at the head, `moov` tail-placed, no `ftyp`.
  Standard boxes (`mvhd`, `tkhd`, `stsd`, `stts`, `mdhd`) yield duration,
  project frame rate (e.g. 24p), resolution, audio, and timecode. The
  Blackmagic slate is parsed out of `moov.meta` using QuickTime's
  non-FullBox `mdta` layout — a sniff at the box header disambiguates the
  ISOBMFF/iTunes FullBox shape from the QuickTime shape so existing MP4 /
  iTunes parsing stays untouched. The `mdta` decoder handles BRAW's typed
  payloads, including the BMD-specific type 71 (float32 BE pair) used for
  rectangle fields like `sensor_area_captured` and the BMD type 77
  (uint32) used for `braw_codec_bitrate`. Surfaces to `CameraMetadata`:
  - **Camera + lens** — make / model, firmware, lens model, color science
    generation, viewing gamma / gamut, shutter type, compression ratio,
    `analog_gain` and `_is_constant`, off-speed flag.
  - **Production slate** — clip number, scene, take, reel, camera number,
    operator, director, production name, environment, day/night, location,
    filters, frameguide aspect, anamorphic flag.
  - **Sensor / framing** — `sensor_area_captured`, `crop_origin` /
    `crop_size` / `safe_area`, `sensor_line_time` (rolling-shutter μs),
    `sensor_photosite_pitch_in_micrometres`, `rotation`, `time_lapse_interval`.
  - **Lens corrections + OIS** — `lens_shading_enable`,
    `lens_distortion_correction_enable`,
    `lens_chromatic_aberration_correction_enable`, `ois_enable`.
  - **Tone curve** — contrast, saturation, midpoint, highlights, shadows,
    black/white level, `video_black_level`, `highlight_recovery`,
    `gamut_compression_enable`.
  - **Embedded 3D LUT** — `post_3dlut_mode`, `_embedded_name`, `_embedded_title`,
    `_embedded_bmd_gamma`, `_embedded_size` (cube edge), and a
    `_embedded_data` size marker (the ~432 KB blob is not inlined).
  - **BRAW codec config** — `braw_codec_bfdn`, `braw_codec_ctrn`,
    `braw_codec_bver`, and `braw_codec_bitrate` are pulled from the BRAW
    sample entry's child boxes; works across the BRAW quality presets
    (`brhq` High Quality, `brst` Standard, `brlt` Light, …).
  - **Per-frame motion tracks** — `mebx` tracks declaring the
    `com.blackmagicdesign.motiondata.gyroscope` /
    `…accelerometer` namespaces are flagged with
    `has_gyroscope_motion_data` / `has_accelerometer_motion_data`. The
    per-frame vec3 samples themselves are not decoded.
  - **First-frame interpretation** — frame 0's `bmdf` header in mdat
    yields `shutter_angle` (`shtv` atom, UTF-8 padded — e.g. "180°"),
    `aperture` (`aptr` — e.g. "f2.7"), `focal_length` (`fcln` —
    e.g. "135mm"), `focus_distance` (`dsnc` — e.g. "2430mm"),
    `iso` (`isoe`), `white_balance_kelvin` (`wkel`), and
    `white_balance_tint` (`wtin`, signed int16). The per-frame header
    carries identical values across every frame in the clips we've
    tested, so frame 0 is sufficient for the clip-level default; we
    don't iterate over the rest. The four lens strings are skipped
    when empty (which the camera emits on bodies without electronic
    lens contacts). Other atoms in the same header (`srte`, `agpf`,
    `expo`, `shdp`, `dcp[ugrb]`, …) carry per-frame state we haven't
    yet mapped.

  Off-speed shoots populate `captureFps` distinct from `frameRate` — a 24p
  clip captured at 112 fps reports `frameRate=24` and `captureFps≈112`.

  **Per-frame export** — `swift-exif braw-frames <file.braw>` walks every
  frame's `bmdf` header (or every `mebx` IMU sample) and emits CSV for
  graphing. Three streams: `attributes` (default; one row per video
  frame with shutter / aperture / focal length / focus distance / ISO /
  WB Kelvin / tint), `gyroscope` (rad/s vec3 at ~1 kHz), and
  `accelerometer` (m/s² vec3, gravity observable on the up-axis).
  Numeric columns; opens directly in Excel / pandas / matplotlib /
  gnuplot. Public Swift API: `BRAWFrameReader.readAttributes(from:)`
  and `BRAWFrameReader.readMotionSamples(from:stream:)`.
- **RED RAW (`.R3D`)**: not ISOBMFF — RED uses its own length-prefixed
  container with a fixed 1202-byte `RED2` (or `RED1`, on older firmware)
  clip-header atom carrying every metadata field. The header packs three
  fixed-layout sub-atoms (`rdi` for image dimensions, `rda` for audio
  sample rate, two `rdx` markers) followed by a stream of TLV records.
  Each TLV is `[1-byte length][2-byte tag = class<<8 | id][value]`
  where the tag IDs match ExifTool's `Image::ExifTool::Red` table —
  `0x1006` SerialNumber, `0x101a` ReelNumber, `0x101b` Take, `0x1023`
  DateCreated, `0x1024` TimeCreated, `0x1025` FirmwareVersion,
  `0x1029` ReelTimecode, `0x102a` StorageType, `0x1056`
  OriginalFileName, `0x1070` LensModel, `0x1086` VideoFormat
  ("8K 16:9"), `0x10a0` Brain, `0x10a1` Sensor, `0x10be` Quality,
  `0x200d` ColorTemperature (float32 BE Kelvin), `0x2066`
  OriginalFrameRate (float32), `0x4037` CropArea (4× uint16
  origin/dims), `0x403b` ISO (uint16), `0x606c` FocusDistance
  (uint16 mm). Two non-ExifTool timecode strings (`0x10ad`,
  `0x10ae`) surface as additional `Timecode` entries tagged
  `.redR3D`. Records exceeding 64 bytes are skipped as a sanity
  cap (largest real TLV is the 28-byte original-filename string).
  `camera.deviceManufacturer` is set unconditionally to `"RED"`
  since the format doesn't include it as a TLV. Tested on KOMODO-X
  (RD4.15 firmware) and V-RAPTOR [X] (RD4.15) clips.
- **MXF (SMPTE 377-1)**: picture and sound essence descriptors parsed from
  header metadata — `StoredWidth`/`StoredHeight`, `DisplayWidth`/`DisplayHeight`,
  `FrameLayout` (scan type), `ComponentDepth`,
  `HorizontalSubsampling`/`VerticalSubsampling`, `SampleRate` (frame rate),
  `ContainerDuration`, colour ULs → H.273 codes. KLV essence is skipped by
  seek, so gigabyte files parse cheaply.
- **Matroska / WebM**: EBML/VINT walker over Segment `Info` + `Tracks` +
  `Tags`. Colour master element (primaries / transfer / matrix / range) +
  `ChromaSubsamplingHorz`/`Vert` + `ChromaSitingHorz`/`Vert` →
  `chroma_location`, `BitsPerChannel`, `DefaultDuration` → fps,
  `FlagInterlaced` + `FieldOrder`, subtitle `FlagDefault` / `FlagForced` /
  `FlagHearingImpaired`. `CodecPrivate` is decoded for HEVC / AV1 / AVC
  tracks (same layout as `hvcC` / `av1C` / `avcC`) to surface profile +
  bit depth even when the `Video` master doesn't. Segment-level
  `COMMENT` / `DESCRIPTION` / `TITLE` and per-track `BPS` /
  `NUMBER_OF_FRAMES` SimpleTags are surfaced as container / stream facts.
- **AVI**: RIFF/LIST walker, `avih` (width/height/microSecPerFrame) +
  `strl/strh/strf` (BITMAPINFOHEADER + WAVEFORMATEX), OpenDML `dmlh` for
  >4 GB frame counts, `INFO` tags (`INAM`/`IART`/`ICMT`).
- **MPEG-PS / MPEG-TS / M2TS**: MPEG-1/2 sequence header decode
  (resolution, fps, aspect ratio, bit rate), PAT → PMT walk for
  elementary-stream inventory, ES descriptor loop for language + subtitle
  type. M2TS (Blu-ray BDAV, 192-byte packets with `TP_extra_header`)
  auto-detected via magic-byte sniff.

#### Export

```swift
// Flat dictionary for CSV/table output
let dict = VideoMetadataExporter.buildDictionary(video)

// JSON string matching ffprobe's general shape
let json = VideoMetadataExporter.toJSONString(video)
```

The CLI surfaces all of the above:

```shell
$ swift-exif read --format json path/to/clip.mov
```

#### Example output

A 4K HEVC HLG clip straight out of an iPhone:

```json
{
  "FileFormat": "MOV",
  "FormatLongName": "QuickTime / MOV",
  "FileSize": 16309447,
  "VideoCodec": "hvc1",
  "VideoProfile": "Main 10",
  "VideoWidth": 3840,
  "VideoHeight": 2160,
  "FrameRate": 59.9568655643422,
  "AvgFrameRate": 59.9568655643422,
  "RFrameRate": 59.9568655643422,
  "BitDepth": 10,
  "ChromaSubsampling": "4:2:0",
  "PixelFormat": "yuv420p10le",
  "ColorSpace": "bt2020-hlg",
  "ColorPrimaries": 9,
  "TransferCharacteristics": 18,
  "MatrixCoefficients": 9,
  "Duration": 2.316666666666667,
  "AudioCodec": "mp4a",
  "AudioSampleRate": 48000,
  "AudioChannels": 2,
  "AudioChannelLayout": "stereo",
  "CreationDate": "2025-12-09T14:56:44Z"
}
```

A Blu-ray MKV remux with 31 PGS subtitle tracks and 14 audio streams
returns each track individually under `videoStreams` / `audioStreams` /
`subtitleStreams`, with language tags, flags, and codec IDs preserved.

### Audio Metadata

Standalone MP3, FLAC, M4A, Ogg Opus (.opus), Ogg Vorbis (.ogg/.oga),
RIFF WAV / Broadcast WAVE (.wav), and AIFF / AIFC (.aif / .aiff) files
expose codec, sample rate, channel count, channel layout, bit depth,
and bit rate alongside container-specific tags:

```swift
let audio = try AudioMetadata.read(from: mp3URL)
print(audio.codec, audio.codecName)  // "mp3", "MP3"
print(audio.sampleRate, audio.channels, audio.bitrate, audio.bitDepth)
print(audio.title, audio.artist, audio.album)
```

Format-specific detail:

- **MP3 (ID3v1 / ID3v2)**: full ID3v2 frame decode including `TXXX`
  user-defined text, `WXXX` user URL, `PRIV` private frames, `GEOB`
  general encapsulated objects, and `CHAP` / `CTOC` chapter/table-of-
  contents frames.
- **FLAC**: Vorbis comments plus `SEEKTABLE` (sample → byte offsets)
  and `CUESHEET` (track index points for CD-DA mastering).
- **WAV / BWF (RIFF)**: `LIST INFO` tags (`INAM`/`IART`/`ICMT`/`ICRD`/…),
  Broadcast WAVE `bext` v0 / v1 (UMID) / v2 (loudness fields), and
  iXML — read **and** write, with the `bext` chunk rewritten in place
  preserving the surrounding `data` / `LIST` chunks.
- **AIFF / AIFC**: `NAME` / `AUTH` / `(c) ` / `ANNO` / `COMT` chunks
  decoded from IFF, COMM 80-bit IEEE 754 sample-rate field handled
  natively — read and write.

#### Async video API

Convenience top-level functions parse on a detached task so callers can
`await` without blocking the main actor. Missing metadata returns `nil`
rather than throwing — reserve errors for I/O and hard parse failures.

```swift
import SwiftMediaMetadata

// C2PA manifests embedded in MP4/MOV (same JUMBF path as AVIF/HEIF).
if let c2pa = try await readVideoC2PAMetadata(from: videoURL) {
    let claim = c2pa.activeManifest?.claim
    print(claim?.claimGenerator)             // "Adobe Premiere Pro 24.0"
    print(claim?.claimGeneratorInfo?.name)   // "Adobe Premiere Pro"
    for assertion in c2pa.activeManifest?.assertions ?? [] {
        print(assertion.label)               // "c2pa.actions", "c2pa.hash.data", …
    }
}

// Camera metadata — Sony NonRealTimeMeta (RDD-18) embedded or sidecar .XML,
// or Blackmagic RAW slate from `moov.meta`.
if let cam = try await readVideoCameraMetadata(from: videoURL) {
    print(cam.deviceManufacturer)    // "Sony" / "Blackmagic Design"
    print(cam.deviceModelName)       // "PXW-FX9" / "Pyxis 12K"
    print(cam.lensModelName)         // "Sony FE 24-70mm F2.8 GM"
    print(cam.captureFps)            // 23.98 (off-speed FPS for BRAW)
    print(cam.captureGammaEquation)  // "SLog3" / "Blackmagic Film Gen 5"
}

// Both in one pass (cheaper than calling the two above separately).
let video = try await readVideoMetadata(from: videoURL)
```

#### Sidecar auto-discovery

When reading `CLIP.MP4` or `CLIP.MXF`, SwiftMediaMetadata automatically probes for
a Sony NonRealTimeMeta sidecar (`CLIP.XML`, `CLIP.xml`, `CLIP.M01`) next
to the clip. If found, its parsed contents populate `camera`.

```swift
// Given: /path/CLIP.MXF next to /path/CLIP.XML
let video = try VideoMetadata.read(from: mxfURL)
video.camera?.deviceManufacturer   // pulled from the sidecar
```

### C2PA Content Provenance

Access embedded C2PA manifests for content authenticity. Coverage:
JPEG (APP11), TIFF (Exif sub-IFD or DNG private tag), PNG (caBX),
JPEG XL, AVIF, HEIF, WebP (C2PA RIFF chunk), GIF (Application
Extension), PDF (catalog `/Metadata`), MP4 / MOV (uuid or top-level
`jumb`), MXF (SMPTE UL or Dark KLV), Broadcast WAVE (`C2PA` LIST
chunk), and external `.c2pa` sidecars. Hash bindings and ECDSA
signatures are verified against the embedded certificate chain:

```swift
if let c2pa = metadata.c2pa {
    for manifest in c2pa.manifests {
        print(manifest.claim.claimGenerator)           // "SONY_CAMERA"
        print(manifest.claim.claimGeneratorInfo?.name) // "SONY_CAMERA"
        print(manifest.claim.title)                    // "20251212_TRA_MOV_0224.MP4"
        print(manifest.signature.algorithm)            // ES256
        print(manifest.signature.certificateChain.count)

        for assertion in manifest.assertions {
            print(assertion.label)   // "c2pa.actions.v2", "c2pa.hash.bmff.v3", …
            if case .actions(let actions) = assertion.content {
                for action in actions.actions {
                    print(action.action)              // "c2pa.created"
                    print(action.digitalSourceType)   // IPTC URL
                }
            }
        }
    }
}
```

The JSON exporter surfaces the same fields under `HasContentCredentials`,
`HasSignature`, `ClaimGenerator`, `ClaimGeneratorInfoName`, `ClaimTitle`,
`ManifestLabel`, `SignatureAlgorithm`, `SignatureCertificateCount`,
`Assertions`, `ActionsAction`, `ActionsDigitalSourceType`,
`ActionsSoftwareAgent` — matching the field set consumed by downstream
apps that previously shelled out to ExifTool.

Each assertion is decoded into a typed payload (`c2pa.actions(.v2)`,
`c2pa.hash.data` / `c2pa.hash.bmff(.v3)`, `c2pa.training-mining`,
`c2pa.thumbnail.*`, `stds.exif`, `stds.iptc`, `stds.schema-org.*`)
rather than left as opaque CBOR. Hash assertions are verified against
the asset bytes; signature assertions are verified with ECDSA over the
embedded certificate chain — failures are surfaced via
`c2pa.verification` rather than thrown.

### MakerNotes

Camera-specific manufacturer metadata for Canon, Nikon, Sony, Fujifilm,
Olympus, Panasonic, Apple (iPhone / iPad), DJI, Samsung, Pentax, Leica,
and Sigma. Canon and Sony parsers extract array-tag depth (Canon
CameraSettings / ShotInfo / AFInfo2 / FileInfo / SensorInfo, Sony
0x01xx / 0x2xxx / 0xB0xx blocks) — including a curated FE-mount lens
ID table for Sony — alongside basic identifiers (serial, firmware,
lens model). Apple iPhone surfaces Live Photo `ContentIdentifier`,
HDR image type, burst UUID, and acceleration vector.

```swift
if let makerNote = metadata.exif?.makerNote {
    print(makerNote.manufacturer)  // .canon, .nikon, .sony, .apple, .dji, …
    for (name, value) in makerNote.tags {
        print("\(name): \(value)")
    }
}
```

### ICC Color Profiles

```swift
// Read
if let icc = metadata.iccProfile {
    print(icc.colorSpace)               // "RGB ", "CMYK", etc.
    print(icc.profileDescription)       // "sRGB IEC61966-2.1"
}

// Copy ICC profile to another image
var dest = try readMetadata(from: destURL)
dest.iccProfile = metadata.iccProfile
try dest.write(to: destURL)
```

### Composite Tags

Derived values calculated from raw Exif data:

```swift
let composites = CompositeTagCalculator.calculate(from: metadata.exif!)

composites["Megapixels"]     // 24.2
composites["LightValue"]     // 10.5
composites["FieldOfView"]    // 63.7
composites["LensID"]         // "EF 24-70mm f/2.8L II USM"
composites["GPSPosition"]    // "59.9139 N, 10.7522 E"
```

### GPX Geotagging

Apply GPS coordinates from a GPX track to images based on capture time:

```swift
let track = try GPXParser.parse(from: gpxFileURL)

var metadata = try readMetadata(from: imageURL)
let matched = metadata.applyGPX(track, maxOffset: 60)
if matched {
    try metadata.write(to: imageURL)
}
```

### Reverse Geocoding

Convert GPS coordinates to city, region, and country names **offline** —
no network access, no API key. Uses an embedded GeoNames database
(~33,500 cities with population ≥ 15,000) behind a k-d tree for
O(log n) nearest-neighbor lookup.

```swift
// Standalone lookup
let geocoder = ReverseGeocoder.shared
if let location = geocoder.lookup(latitude: 59.9139, longitude: 10.7522) {
    print(location.city)        // "Oslo"
    print(location.region)      // "Oslo"
    print(location.country)     // "Norway"
    print(location.countryCode) // "NOR" (ISO 3166-1 alpha-3)
    print(location.timezone)    // "Europe/Oslo"
    print(location.population)  // 580000
    print(location.distance)    // 0.3 (km from query point)
}

// Nearest N cities — useful for disambiguating near borders
let nearby = geocoder.nearest(latitude: 59.9139, longitude: 10.7522, count: 5)
```

Populate IPTC/XMP location fields directly from an image's embedded GPS:

```swift
var metadata = try readMetadata(from: imageURL)

// Fills IPTC City / Province-State / Country-Name / Country-PrimaryLocationCode
// and the matching XMP fields. Skips fields that are already set unless
// overwrite: true is passed.
if let location = metadata.fillLocationFromGPS() {
    print("Matched \(location)")
    try metadata.write(to: imageURL)
}
```

Both APIs accept a `maxDistance:` parameter (km) to reject matches that
are too far away — defaults are 50 km for `lookup`, 100 km for `nearest`.

### Copy Metadata Between Files

```swift
var dest = try readMetadata(from: destURL)
let source = try readMetadata(from: sourceURL)

// Copy all metadata
dest.copyMetadata(from: source)

// Or selective groups
dest.copyMetadata(from: source, groups: [.exif, .iptc])

try dest.write(to: destURL)
```

### Metadata Diff

```swift
let a = try readMetadata(from: fileA)
let b = try readMetadata(from: fileB)

let diff = a.diff(against: b)
for change in diff.changes {
    print("\(change.type): \(change.key) — \(change.oldValue ?? "nil") → \(change.newValue ?? "nil")")
}
```

### Thumbnail Extraction

```swift
if let jpegData = metadata.extractThumbnail() {
    try jpegData.write(to: thumbnailURL)
}
```

### Metadata Stripping

```swift
var metadata = try readMetadata(from: imageURL)

metadata.stripAllMetadata()   // Remove everything
metadata.stripGPS()           // Remove GPS only
metadata.stripExif()          // Remove Exif only
metadata.stripIPTC()          // Remove IPTC only
metadata.stripXMP()           // Remove XMP only
metadata.stripC2PA()          // Remove C2PA only
metadata.stripICCProfile()    // Remove ICC profile only

try metadata.write(to: outputURL)
```

### Date Shifting

```swift
var metadata = try readMetadata(from: imageURL)
metadata.shiftDates(by: 3600)  // Shift all dates forward by 1 hour
try metadata.write(to: imageURL)
```

### Conditional Batch Processing

Process files that match specific conditions:

```swift
let condition: MetadataCondition = .and([
    .equals(field: "IPTC:City", value: "Oslo"),
    .greaterThan(field: "Exif:FocalLength", value: 50)
])

let result = try BatchProcessor.processDirectory(
    at: directoryURL,
    where: condition,
    recursive: true
) { metadata in
    metadata.iptc.setValue("© 2026 Agency", for: .copyrightNotice)
}
```

### File Renaming

Rename files using metadata-driven templates:

```swift
let renamer = MetadataRenamer(
    template: "%{DateTimeOriginal:yyyyMMdd}_%{IPTC:City}_%c",
    counterDigits: 3
)

// Preview before renaming
let preview = renamer.dryRun(files: imageURLs)
for (from, to) in preview {
    print("\(from.lastPathComponent) → \(to.lastPathComponent)")
}

// Perform rename
let result = renamer.rename(files: imageURLs)
print("\(result.renamed.count) files renamed")
```

### Export

```swift
// JSON
let json = MetadataExporter.toJSONString(metadata)

// Human-readable JSON with print conversions
let readable = MetadataExporter.toReadableJSON(metadata)

// XML
let xml = MetadataExporter.toXML(metadata)

// CSV (multiple files)
let csv = CSVExporter.toCSV(metadataArray, fields: ["IPTC:Headline", "Exif:Make"])
```

### Print Conversion

Convert raw numeric values to human-readable strings:

```swift
let readable = PrintConverter.buildReadableDictionary(metadata)
// "Orientation" → "Rotate 90 CW" (instead of 6)
// "ExposureTime" → "1/250" (instead of rational)
// "Flash" → "Fired, Return detected" (instead of 15)
```

### Batch Processing

```swift
let result = try BatchProcessor.processDirectory(at: directoryURL, recursive: true) { metadata in
    metadata.iptc.setValue("© 2026 Agency", for: .copyrightNotice)
}

print("\(result.succeeded) files updated, \(result.failed.count) errors")
```

## Architecture

```
Sources/SwiftMediaMetadata/
├── API/            # Public API: ImageMetadata, BatchProcessor, FormatDetector,
│                   #   MetadataExporter, CSVExporter, PrintConverter,
│                   #   MetadataRenamer, CompositeTagCalculator
├── Binary/         # Low-level binary readers/writers, CRC32, ISO BMFF
├── Exif/           # Exif IFD parsing and writing
├── IPTC/           # IPTC IIM reader/writer (Records 1/2/3/6/7/8 + PLUS), Photoshop IRB
├── XMP/            # XMP reader/writer with namespace mapping
├── C2PA/           # C2PA manifest/claim/signature parsing + ECDSA verification
├── CBOR/           # CBOR decoder for C2PA payloads
├── MakerNote/      # Camera-specific MakerNote parsers (12 manufacturers)
├── GPX/            # GPX track parser and geotagging
├── Geolocation/    # Offline reverse geocoder (GeoNames + k-d tree)
├── ICC/            # ICC color profile reader (TRC, primaries, A2B/B2A LUTs, chad)
├── JPEG/           # JPEG segment parser and writer (incl. CIPA DC-007 MPF)
├── TIFF/           # TIFF/RAW file parser and writer
├── RAW/            # Camera RAW format support (DNG, CR2/CR3, NEF, ARW, RAF,
│                   #   RW2, ORF, PEF, IIQ, 3FR, FFF, X3F, MRW, …)
├── CR3/            # Canon CR3 (ISOBMFF) parser and writer
├── PNG/            # PNG chunk parser and writer
├── JPEGXL/         # JPEG XL box parser and writer
├── AVIF/           # AVIF (ISOBMFF) parser and writer
├── HEIF/           # HEIF/HEIC parser and writer with auxiliary image walk
├── WebP/           # WebP (RIFF container) parser and writer
├── GIF/            # GIF parser/writer (XMP + C2PA Application Extension)
├── BMP/            # BMP header reader
├── SVG/            # SVG XMP metadata reader/writer
├── PDF/            # PDF document metadata + catalog `/Metadata` XMP reader/writer
├── PSD/            # Photoshop document parser and writer
├── Apple/          # AAE sidecar parser (Apple Photos edit decisions)
├── Audio/          # MP3/FLAC/M4A/Ogg/WAV/AIFF tag and codec readers + writers
└── Video/          # MP4/MOV/M4V/MXF/MKV/WebM/AVI/MPEG-TS metadata parsers,
                    #   Sony NonRealTimeMeta (NRT / RDD-18) XML parser, GoPro GPMF
```

## Benchmark

Measured with `Sources/Benchmark/main.swift` (release build) against a 382 KB JPEG sample, writing 8 IPTC fields + 8 XMP fields, and reading all of IPTC/XMP/EXIF. C2PA and MP4 parse benchmarks use synthetic JUMBF manifest stores.

**Write / Read (100 files)**

| Operation | exiftool batch | exiftool sequential | SwiftMediaMetadata sequential | SwiftMediaMetadata batch |
|-----------|---------------:|--------------------:|---------------------:|----------------:|
| Write     | 18.0 ms/file   | 267.7 ms/file       | 8.2 ms/file          | **2.8 ms/file** |
| Read      | 22.6 ms/file   | —                   | 4.5 ms/file          | **2.8 ms/file** |

SwiftMediaMetadata batch write is ~6× faster than exiftool batch and ~95× faster than exiftool sequential. Read is ~8× faster than exiftool batch.

**C2PA JUMBF parse (1 000 iterations)**

| Payload | Size    | Per parse |
|---------|--------:|----------:|
| Small (1 manifest, 2 assertions)   | 1.2 KB  | 29.0 µs  |
| Medium (3 manifests, 5 assertions) | 5.3 KB  | 120.0 µs |
| Large (10 manifests, 10 assertions)| 27.4 KB | 590.3 µs |

**MP4 container + C2PA parse (1 000 iterations)** — full `MP4Parser.parse` pass over a synthetic `ftyp` / `moov` / `uuid` container with embedded JUMBF.

| Payload | Container | Per parse |
|---------|----------:|----------:|
| Small   | 1.3 KB    | 31.9 µs   |
| Medium  | 5.4 KB    | 122.7 µs  |
| Large   | 27.5 KB   | 604.0 µs  |

<sup>Tested 2026-04-19 on macOS 26.4.1 (Apple M1 Max, 10 cores). SwiftMediaMetadata @ `c84bfee` (main). ExifTool 13.55 via Homebrew.</sup>

## Acknowledgements

- **GeoNames** (https://www.geonames.org/) — The reverse geocoding database is built from GeoNames geographical data, licensed under [Creative Commons Attribution 4.0](https://creativecommons.org/licenses/by/4.0/). The embedded city database contains ~33,500 cities with population >= 15,000.
- **ExifTool** by Phil Harvey (https://exiftool.org/) — The reference implementation for image metadata processing. SwiftMediaMetadata aims to provide equivalent functionality as a native Swift library.

## License

GPL-3.0 — see [LICENSE](LICENSE) for details.
