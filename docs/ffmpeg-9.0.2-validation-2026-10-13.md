# Corrected FFmpeg 9.0.2 bundle update — 2026-10-13

The app now bundles the corrected full build from
`ffmpeg-apple-silicon/t3-8b3606d8/dist/9.0.2/ffmpeg-9.0.2-full-signed.zip`. It supersedes the initial
9.0.2 build, which lacked `yadif_videotoolbox`. The corrected build enables Metal
and includes the YADIF autorelease teardown correction. The full variant keeps
its Whisper filter unmodified; the separate Photo Agent variant is not bundled.

The replacement is ARM64, reports GPL v3 or later, declares macOS 11.0 as its
minimum deployment target, and references only Apple system libraries/frameworks.
The app's own minimum macOS version is unchanged. The signed helper is 60,144,480 bytes
with SHA-256 `ec3d81944809bf5d0173edb77b8dbf8eaeabf2388289812ce87b3f90fbe410c6`.
Both the source-tree helper and the unsigned Release bundle match the supplied
qualification record's checksum. File permissions are normalized to 0755.

## Capabilities and runtime validation

No advertised encoders, decoders, muxers, or demuxers were removed: counts remain
200, 531, 183, and 361 respectively. `yadif_videotoolbox` is restored, bringing
filters back to 485, matching the original 9.0.1 filter count.

Four Metal YADIF checks also pass with the signed helper through EOF and successful process teardown: NV12
and P010 in `send_frame` and `send_field` modes. Each requires the logged Metal
device and the expected four or eight output frames. These are actual hardware
frame upload/filter/download checks, not just filter-list inspection.

Nine software encode/decode checks pass: H.264, 10-bit HEVC, 10-bit SVT-AV1,
ProRes, FFV1/PCM lossless, software YADIF, audio waveform video, JPEG XL, and
JPEG 2000. Three further VideoToolbox encode/decode checks pass for H.264,
10-bit HEVC, and ProRes with software fallback allowed. Hardware checks run
with access to macOS encoding services outside the command sandbox.

Six generated-media app tests pass against the corrected bundled helper:
image-sequence crop/export, MOV timecode preservation/replacement/removal,
captured trim/crop/mute, keyframe-aligned stream copy, AAC/PCM sample alignment,
and lossless surround channel preservation. The shared unit-only scheme was used.

The unsigned Release build passes. The bundle audit verifies all 59 Mach-O
images for ARM64, executable permissions, and library resolution, plus all
14 packaged license notices against `BundledDependencies.json`. Twenty
dependency-manifest tests and six source-packaging tests pass. Manifest freshness
and `git diff --check` pass.

## Source preservation and attribution

Current corrected-build evidence is retained in
`docs/provenance/4.5-local-builds/ffmpeg-9.0.2-metal/`: qualification, capabilities,
patch authorship/source license, exact modified recipes, working-tree patch,
actual build flags, runtime smoke results, and source-file hashes. The retained
full tree's configuration exactly matches the binary's reported build flags.
Its YADIF and unmodified Whisper source hashes match the supplied qualification.

The supplied build reuses codec libraries from the first 9.0.2 workspace. Its
original dependency-source and generated-input archives therefore remain required.
A third `ffmpeg-9.0.2-metal-source.tar.gz` archive preserves the corrected full
FFmpeg tree and recipes. All three active source archives were checked against
their recorded bytes and SHA-256 hashes. They live under ignored `build/attribution/`;
preserve them with the release source companion. The correction archive's
`README-metal-source.md` explains how to overlay it onto the dependency sources
and rebuild the full variant with the Metal compiler.

The app's existing 135 collected dependency notices remain intact, with an added
note crediting Vincent Herbst's Metal YADIF correction and identifying the full
variant. Active binary, notice, and source records are updated in
`BundledDependencies.json` and `AttributionSources.json`. The release gate also
requires the new correction source component. Earlier build evidence remains
historical under `ffmpeg-9.0.2/`; its generated-input capture scope is unchanged.

This batch does not claim an independent rebuild or testing on older macOS
versions. The full source-companion gate was not rerun because older unrelated
attribution archives are absent from this worktree; their manifest records and
release requirements remain intact. No release was signed, notarized, or published.

## Signed-artifact continuation

The supplied signed archive's binary hash matches its qualification record, whose
pre-signing hash identifies the already tested corrected build. Independent macOS
verification passes strict signature validation and the online `notarized` code
requirement. The signature is Developer ID Application: Truls Aagedal
(3R5QGG9DW6), with hardened runtime and a secure timestamp. CDHash
`e57dfafe46e4a3cece0514eb1d3a903e63e9fa73` matches the accepted notarization ticket.
The command sandbox could not resolve the signing authority; verification with
access to macOS security services succeeded.

The twelve codec smoke checks and six app regressions above were run on the
same corrected build before signing. With the signed artifact, all four Metal
YADIF checks, the Release build, manifest freshness, and bundle audit pass again.
The packaged helper is byte-identical to the archive’s FFmpeg and independently
passes strict signature verification and the notarized code requirement.

Signed qualification, receipt, and archive/binary hashes are retained under
`ffmpeg-9.0.2-metal/signing/`. The final ZIP includes records added after the
notarization submission, so its ZIP hash differs from the submitted ZIP hash;
the executable CDHash is the identity validated against the accepted ticket.
Corresponding sources are unchanged, so the three source archive records and
hashes remain intact. The app's packaging script continues to re-sign copied
helpers when signing an app; this update does not alter that policy. No whole-app
signing, notarization, or release publication was performed.
