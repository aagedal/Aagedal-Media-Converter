# Aagedal Media Converter Improvement Plan

Last reviewed: 2026-11-12 (after 4.7.0)

This is the current backlog: what is still open, grouped by theme, with links to
the evidence. Keep it short. Record implementation and validation details in a
dated file under `docs/` and link it from here, rather than appending logs to
this file. The detailed work log up to 2026-10-18 is in
[docs/improvement-history-2026.md](docs/improvement-history-2026.md); section
numbers below (1.1, 2.2, …) refer to it.

An open item is not automatically a release blocker. A confirmed defect that can
lose data, silently produce incorrect supported output, corrupt settings, or leave
work writing after cancellation must be fixed, or the affected path disabled,
before a release. Record a disposition for unresolved risks; do not quietly
reclassify them as polish.

## Architecture and change risk

- **One conversion engine.** `ConversionManager` (queue UI) and `ApplicationJobService`
  (agent/MCP jobs, in `Logic/AgentAccess/ApplicationJobContract.swift`) both run
  conversions. Converge on one shared job service, following the phases in
  `docs/engine-unification-plan.md`. Phase 0 (#107) is done; next is a shared
  request builder with a parity test (3.1).
- **Large files.** `ApplicationJobContract`, `ContentView` and `FFMPEGCommandBuilder` are
  each 3,000–4,300 lines. Split along existing seams before adding features to them.
- **Typed conversion plans.** Audio routing, crop, trim and several codec settings are
  typed; remaining video filters, codecs, metadata and output ownership are still
  assembled as argument strings (3.2).
- **Settings access.** Remaining feature settings still read `UserDefaults` directly,
  and older schema changes lack migration tests (3.3).
- **View coordinators.** ContentView and list-view coordination plus upload follow-up
  execution are still inside the views (3.1).

## Reliability

- **Blocking and callback audit.** Remaining unbounded framework callbacks, metadata
  consumers and screen-capture stream start/stop need deadlines and ownership (2.2).
- **Helper draining.** Converter-owned framework/MCA probes, native waveform tasks and
  superseded helpers are not yet fully drained on cancellation (2.1).
- **Errors.** Per-operation diagnostics and the filesystem/bookmark error audit are
  incomplete (2.3).
- **Release-mode MCP tests.** The `AMC_UI_TEST_AGENT_PORT_ID` override is `#if DEBUG`,
  so four `ApplicationJobContractTests` cases fail in a Release test build
  ([details](docs/AUDIO-METERING-PLAN.md#optimized-build-qualification--2026-10-18)).
- **Memory.** The Matroska muxer keeps all collected AV2 frames in memory (1.1).

## Output correctness

- AV2 output for generated waveform/synthesized video is unsupported (1.1).
- Matroska layout labels can fall back to channel-count inference instead of reading
  AAC/Opus layout descriptors (1.1).
- Generated IMF CPL `SourceEncoding` references need full MXF descriptor coverage and
  conformance validation (1.1).
- Keep extending the command-generation matrix for new presets and format
  combinations (1.1).

## Accessibility and localization

- Manual VoiceOver and keyboard-only pass over custom controls and secondary flows (4.1).
- Localization: scrolled-off content, Shortcuts app integration, analysis detail
  strings (comparison metadata, warnings, some track labels), and review of the eight
  non-English/Norwegian languages flagged for review (4.2). The user is handling
  translation work directly.
- Language pass over the string catalog. Known error: Korean "Browse…" is "먹다…"
  ("eat"); look for similar machine-translation mistakes in all eight languages.

## Features and polish

- **Encode history follow-ups:** record a merge or stitch as one entry with several
  inputs; restore DCP, IMF and image-sequence metadata; keep yt-dlp source URLs
  ([plan](docs/encode-history-plan.md)).
- **Playback metering:** optional running playback-session LUFS, clearly separate from
  whole-program analysis; evaluate newer MPVKit/FFmpeg for ProRes RAW VideoToolbox
  decoding and animated WebP ([plan](docs/AUDIO-METERING-PLAN.md#deferred-improvements)).
- **Transcription pipeline:** host the converted wav2vec2 aligners (before 4.8.0
  ships; the changelog promises downloads) and add more languages; move Nemotron and Parakeet onto the word-level cue builder; live
  transcript with in-run corrections; optional Foundation Models clean-up on macOS 27
  ([plan](docs/transcription-pipeline-plan.md)).
- **First-run diagnostics:** model availability and feature-level codec/architecture
  compatibility preflight (4.4).

## Manual validation backlog

These need a person, real hardware or a live service:

- Screen recording: live static/animated captures at each rate, long A/V sync,
  Auto/display behaviour, permission flows, midnight rollover in editors (4.3).
- Playback meter: physical speaker/video synchronization on Bluetooth and external
  interfaces (`docs/audio-playback-meter-sync-check.md`) before considering Playback as
  the default. Checked by eye and ear on a non-Bluetooth output on 2026-11-12.
- Encode history sync: a full two-Mac check (sync on, encodes on both, statistics per
  Mac, turning sync off). A first look on 2026-11-12 was fine.
- Clean-machine install and update for direct download and Homebrew (5).

## Release and dependency hygiene

- Bump the Homebrew cask for 4.7.0.
- Resolve the remaining unattributed tool/dylib licenses in
  `BundledDependencies.json` (5).
- Measure download size and launch/import memory before any binary cleanup; optimize
  only with measured evidence (5).
