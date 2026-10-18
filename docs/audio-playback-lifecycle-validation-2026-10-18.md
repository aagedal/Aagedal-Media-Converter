# Playback meter lifecycle observations — 2026-10-18

## App history consumer continuation

The application now has a bounded Swift consumer for `amc-meter-history-v1` and
an isolated Debug integration path. It preserves measured frame ends, buffers
future readings until the explicitly selected clock reaches them, rejects stale
generations and changed identities, and requests filter recreation after lost or
discontinuous history. Loudness readiness counts contiguous decoded samples at
their nominal sample rate; media timestamp spans can scale with frame speed and are not the LUFS
window clock. Half-speed/double-speed frame regressions cover this distinction;
unknown continuity suppresses LUFS until a fresh filter instance. Missing history
after initialization invalidates immediately. Startup absence remains unavailable
without repeatedly restarting a graph before a delayed track emits audio.

The path is enabled only in Debug with `AMC_PLAYBACK_METER_HISTORY=1` and requires
a history-capable diagnostic library. `AMC_PLAYBACK_METER_CLOCK` selects `time-pos`
(default) or `audio-pts` for qualification. The production package pin, bundled
binaries and Source-default behavior are unchanged. These switches do not expose
an end-user preference or establish production readiness.

Consumer validation covers malformed bounds/types, immutable repeated records,
actual receive gaps versus harmless ring eviction, clock rewind, player/filter
identity changes, future-frame gating, measured loudness history, and replay of
retained AAC/lossless lifecycle captures. A native player regression additionally
uses video with audio delayed twelve seconds: no future audio is published and
video-only elapsed time does not warm up the loudness readings. All 46 integrated
consumer/player checks pass with the byte-data cache and sample-count readiness
gate in `/private/tmp/amc-history-sample-domain-integrated.xcresult`. The final normal-package
Debug build and all 1,462 unit tests pass after the readiness correction, with
zero failures and two intentional diagnostic skips
(`/private/tmp/amc-history-sample-domain-normal-unit.xcresult`). The skipped
cases require explicit performance/history opt-in. Four benchmark-report tests
and the portable C history test also pass.

The renderer workload uses the app's `MPVPlayer` and `MPVMetalLayer` with muted
output. It has no visible SwiftUI window, so it qualifies app-player software
clock behavior only. Known level changes every two seconds supply independent
signal edges. Raw readings include actual measured ends, playhead, history-path
confirmation, sampled ingest duration and the backend queried after playback
initialization. CPU includes host plus reaped child CPU, expressed as one-core
percentage. Ingest duration excludes event-queue waiting and SwiftUI rendering.
The retained workload hashes precede the final sample-count loudness gate
correction; its frame-speed-one inputs are unchanged by that correction. Final
functional validation separately covers scaled frame speeds.

A matched single-round workload observes the following `time-pos` results. CPU
is host plus child CPU over approximately 17 seconds; this is not a statistical
performance or thermal qualification.

| Fixture / actual output | Before parsed cache | Final byte-data cache | Ingest P95 | Median edge delay |
| --- | ---: | ---: | ---: | ---: |
| Stereo AAC + video / AVFoundation | 2.345 CPU s | 0.612 CPU s | 1.72 ms | 0.167 s |
| 5.1 FLAC audio / CoreAudio | 1.846 CPU s | 0.986 CPU s | 2.60 ms | 0.183 s |

The runs retain seven/eight measured edges respectively. Cached parsed records
are bounded to 128 and reused only after byte-exact identity checks. Each incoming
raw record is converted once to owned UTF-8 `Data`; direct byte equality avoids
Unicode-equivalence loopholes and repeated string-buffer conversion. An
intermediate generic/string-buffer strategy had mixed or worse CPU results and
was replaced; its raw observations remain available. Ingest timing measures only
the operation itself, not queue waiting or display latency. An exploratory
`audio-pts` AAC run queried the output too early; its backend is explicitly
unconfirmed and it cannot qualify that backend/clock combination. The final
repeat confirms AVFoundation/CoreAudio and records median edge delays of
0.208/0.188 seconds. These differ from `time-pos` by less than the 100 ms polling
granularity, so this single comparison does not establish a superior physical
clock. `time-pos` remains the diagnostic default.

Fresh diagnostic builds now record library and object hashes as well as probe
hashes. The isolated app cache is an independent copy; its universal static
library matches both fresh architecture builds and the normal cache's original
library remains unchanged. [Build, staging and benchmark evidence](provenance/audio-meter-lifecycle-2026-10-18/app-consumer/)
is retained separately from the earlier dependency-only experiment.

Remaining work includes visible renderer/output qualification, startup coverage
(the first AAC benchmark reading begins about 2.2 seconds into playback), speed/
seek/reinsertion continuity, clean universal dependency packaging, app Release
performance and physical synchronization. Diagnostic archive-member replacements
are not distributable artifacts.

## Clean universal build continuation

The clean MPV-only build in `/private/tmp/amc-mpv-history-clean-20261018`
finished successfully. It exports the exact upstream commit rather than copying
the dirty source cache, applies the five qualified MPVKit patches followed by
the history/priming patches, and compiles all 219 units for each architecture.
The static audit confirms arm64/x86_64 slices, unchanged 58-symbol public MPV
APIs, ZIP integrity and matching framework/thin archive payloads. The XCFramework
ZIP SHA-256 is `c044a49c961d7dde509deb5f72369dbefe4538f4481f9e65d9e52541f6a6bcac`.
Only the isolated test cache receives this library; no production pin changes.

`scripts/rebuild-mpv-meter-history.py` makes that staging procedure repeatable:

```sh
python3 scripts/rebuild-mpv-meter-history.py \
  --recipe-root /path/to/qualified/MPVKit-recipe \
  --source-cache /path/to/mpv-source-git-cache \
  --output /private/tmp/new-mpv-history-build --jobs 4 --build
```

The output must be new and outside all input trees. Source, recipe, build output,
temporary directories and module cache are owned copies; only installed dependency
outputs are linked as inputs. The builder removes the FFmpeg build invocation and
records all input patch, source, recipe, tool, archive, header and pkg-config hashes.
Six tests cover dirty Git exports, write isolation, rejected inputs and failed
build records. A real staging-only run also passes: all 834 staged source files
match the already built source tree, and 1,644 dependency input files are hashed.
That run did not invoke another build. Its compressed staging record and the
[static build audit](provenance/audio-meter-lifecycle-2026-10-18/app-consumer/clean-rebuild-audit.json)
retain the distinction. Runtime tests against the clean library, corresponding
source packaging, signing and release qualification remain separate requirements.

## Clean-library runtime qualification

Startup previously lost about 2.2 seconds of measurements because audio already
decoded into the output buffer had bypassed the newly inserted filter. With
history enabled, the player now installs the filter before play/seek and
re-decodes the current position exactly through the normal seek scheduler. It
keeps any newer user seek. Seeks no longer remove the history filter, and
polling waits until the in-flight seek completes. The Swift consumer accepts the
filter's first `graph-reset` snapshot (epoch > 0, no evictions/rejections) as a
baseline instead of forcing another restart. Later epoch changes, lost records,
rejections and internal gaps still require a fresh filter (two new unit tests).

Against the clean library (SHA-256 `85495b83…5565`), all 49 focused player/history
tests pass, including a new startup/resume/seek regression. A new native UI test
drives the real SwiftUI preview sheet. It uses a Debug-only, environment-gated
accessibility trace of readings that passed the panel's display gate, with a
15-second AAC/MKV fixture that has independent stereo level edges at 4, 7 and
10 seconds. Both `time-pos` and `audio-pts` pass under AVFoundation. The first
measured interval ends at 0.079 s. Steady levels match the authored signal
within 2 dB. Every edge appears 0.125–0.375 s after its authored time, never
before it. After the rewind to 3 s, no pre-seek samples remain and the
4-second edge repeats with 0.17–0.21 s delay. This delay includes the 100 ms
trace polling interval; it is not a physical synchronization measurement.

Probes relinked against the clean library pass the full lifecycle matrix: six
arm64 cases (null/CoreAudio/AVFoundation × lossless/AAC) and both x86_64 null
cases through Rosetta. Each case checks 202–304 frames against independent
decoded references with zero signal errors. All replacement histories begin at
750 ms. With the normal production package, the Debug build and all 1,462 unit
tests pass with zero failures and three intentional diagnostic skips
(`/private/tmp/amc-resume-normal-unit.xcresult`).
[Native timing report](provenance/audio-meter-lifecycle-2026-10-18/app-consumer/native-timing-report.json),
compressed traces and the `clean-lifecycle-*` reports are retained.

A further regression test changes speed nine times 150 ms apart (1×–8×, as with
repeated J/K/L shuttle presses) during muted AAC playback. The filter measures
decoded samples ahead of MPV's tempo stage, so no history restart occurs. The
meter stays available, short-term loudness keeps its history (−15.7 LUFS for
the 440 Hz, 0.25-amplitude fixture), and readings resume within 0.6 s of the
playhead. All 50 focused tests pass against the clean library; on the normal
package the three history tests skip as intended and the other 28 player tests
pass.

The production pin, Source-default meter, bundled binaries and translations are
unchanged. Remaining before playback history can ship: corresponding-source
packaging and a production pin update, Release/thermal performance and physical
loopback synchronization.

## Original isolated lifecycle experiment

This continues the [isolated AAC startup correction](audio-playback-aac-startup-validation-2026-10-17.md).
The experimental probe now records explicit API acceptance, ordered MPV events,
queried source/player state and history identity across lifecycle transitions.
The application, package pin, dependency patches and bundled binaries are unchanged.
Source remains the default meter; audible alignment remains unqualified.

## Evidence and acceptance

The [probe](../scripts/probe-mpv-meter-history.c) retains bounded cumulative
command and event records in each snapshot: at most 16 commands and 128 events.
Commands record their start/end times, action and successful API result. Errors
terminate the capture. Events record receipt time, action and, for `start-file`,
the playlist entry ID. Event queue overflow or evidence capacity exhaustion fails
the probe. The queue drains to `MPV_EVENT_NONE` before issuing each scheduled
transition. Snapshot property queries retain their separate read interval.

The scenario declares whether replacement and a second audio track were requested
from its first snapshot. A truncated capture cannot silently become a shorter
scenario. Requested source generation is explicitly distinct from observed source
confirmation: the probe queries `path` and compares it with the requested input.

The [lifecycle analyzer](../scripts/analyze-mpv-meter-lifecycle.py) checks immutable,
ordered cumulative evidence and accepts observations only after command return
and before the next command starts. Its checks require:

- Initial load: ordered start/load/restart events, confirmed source/output and
  nonempty frame history.
- Pause: observed paused state and position stable within 50 ms over at least
  200 ms. Decoder history may advance because of buffering.
- Resume: observed unpaused state and at least 100 ms of player-position progress.
- Seek: ordered seek/restart events, settled position within 500 ms of the requested
  eight-second target, changed instance or increased epoch, and a first retained
  frame within 100 ms of that target.
- Speed: observed player speed 1.5 and subsequent position progress. Filter-frame
  speed is separately reported; it remains 1 in these captures.
- Reinsertion: successful removal/addition, an unavailable metadata query between
  removal and addition, and a different instance with nonempty history afterward.
- Optional track switch: the specifically requested track ID and a fresh instance
  or epoch relative to the precommand history.
- Source replacement: ordered start/load/restart events, a new playlist entry,
  confirmed replacement path/output and fresh history. Every snapshot after
  observed replacement readiness must retain those properties. With a reference
  start supplied, the first retained frame must begin there within one sample
  plus timestamp serialization rounding.

MPV events have no command IDs. These are observations within scheduled command
windows, not verified causal acknowledgments or presentation completion. The
report explicitly leaves causal event attribution, loudness resets and audible
alignment unverified. Nested legacy history-analysis fields retain their earlier
heuristic interpretation. Missing startup snapshots, unobserved epoch boundaries
and final-frame coverage remain uncertified even when lifecycle checks pass.

## Repeatable matrix

Build with the existing [isolated builder](../scripts/prototype-mpv-meter-history.py)
and exact corresponding source/products. The new
[runner](../scripts/benchmark-mpv-meter-lifecycle.py) generates the existing
nonperiodic stereo PCM/AAC video fixtures and a PCM replacement delayed 750 ms:

```sh
python3 scripts/benchmark-mpv-meter-lifecycle.py \
  --probe /path/to/isolated/probe \
  --build-record /path/to/isolated/build.json \
  --ffprobe /path/to/ffprobe \
  --output /private/tmp/amc-lifecycle-matrix \
  --drivers null coreaudio avfoundation
```

Output must be a new directory. Both original inputs run through pause/resume,
seek, speed and filter reinsertion, then replace the source at elapsed second 12.
Captures last 16 seconds. Video uses `vo=null`, not the app renderer. Outputs are
muted. The runner independently decodes original/replacement references and checks
every received unique frame's per-channel sample peak and RMS at its recorded
interval, using the existing 0.05 dB tolerance and signal-version-2 oracle.
Both generations need measured frames; every lifecycle check and probe exit must
also pass. These fixtures have fixed rate/layout and continuous source timestamps.

Use the same paths with `--reanalyze` for replay-free evaluation. Reanalysis checks
retained fixture, capture, executable, build-record and FFmpeg/ffprobe hashes,
and requires the probe source to match its build record. It records current
analyzer, runner and signal-oracle hashes. Generated MOVs and local tools remain
necessary for independent reference decoding; only compressed captures, reports
and build records are retained in the repository.

## Results

All eight final matrix cases pass: lossless and AAC replacement under arm64 null,
CoreAudio and AVFoundation, plus both null cases under x86_64 through Rosetta.
The arm64 cases validate 203–315 unique frames each; x86_64 validates 206–208.
Every measured peak/RMS matches its independent decoded reference. All replacement
histories begin at 750 ms. There are no rejected/invalid frames, received sequence
gaps or adjacent-frame continuity breaks. Final CLI reanalysis passes all cases.
[Retained evidence and build records](provenance/audio-meter-lifecycle-2026-10-18/README.md)
identify hashes and capture commands.

A separate muted arm64 null/video run selects track 2 in a two-track MOV before
replacement. The analyzer passes every check, including the requested ID and
changed history. Independent peak/RMS checks cover 120 original-track frames,
45 second-track frames and 59 replacement frames. The second track and replacement
use the 750 ms delayed source; both preserve that sample timeline. This is one
additional track-switch case, not a cross-output/layout/codec qualification.

Both architecture probes build with `-Wall -Wextra -Werror`, using the existing
isolated filter/decoder patches and original pinned products. Initial sandboxed
hardware captures could not initialize audio and fail acceptance; login-session
audio access allows all four hardware-output cases to pass. Rosetta is not
physical Intel hardware. These builds are diagnostic archive-member replacements,
not clean dependency rebuilds or redistributable packages.

The final focused suite passes 62 MPV tests, including 15 new lifecycle/runner
tests and the existing ASan/UBSan queue/priming checks. Negative coverage includes
stale/reordered events, failed commands, truncated/changed cumulative records,
missing declared transitions, wrong track, absent output/source confirmation,
stale or disappearing replacement history, malformed history and a signal mismatch
despite passing lifecycle identities. The full script suite passes 169 tests with
the local socket access needed by existing MCP endpoint tests. The initial
sandboxed run failed those four endpoint tests. Independent review findings about
missing history after readiness, malformed input and truncated optional scenarios
were corrected before final validation. Whitespace checks pass.

Only diagnostic scripts, tests and documentation changed; app build/UI tests were
not rerun. App-renderer integration, dependency packaging, presentation-clock
selection/future-frame buffering, continuous loudness readiness/reset, longer
Release CPU/thermal tests and physical loopback/device synchronization remain open.
