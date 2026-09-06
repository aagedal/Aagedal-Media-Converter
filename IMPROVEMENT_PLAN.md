# Aagedal Media Converter Improvement Plan

Last reviewed: 2026-09-06

This is the prioritized improvement roadmap. `TODO.md` remains a small historical
feature checklist; new improvement work should be tracked here with an owner or
issue link when it starts.

## Audit snapshot

- The project builds successfully with Xcode 17 and Swift 6 strict concurrency.
- The unit-test baseline is green: 433 tests pass. The
  anamorphic-crop regression was fixed and now has generated-media coverage for
  pixels, square-pixel SAR, and output dimensions; custom-command tokenization now
  has focused coverage for empty quoted arguments and whitespace handling; every
  built-in preset now has default container/codec coverage; audio selection,
  ordering, duplication, downmixing, channel operations, subtitle-container policy,
  and AVC-Intra MCA label generation now have focused command tests. Metadata
  policy, manual/preserved/drop-frame timecode, image-sequence inputs and JPEG
  output, DCP/IMF conformance arguments, and AV2 chunk planning now have direct
  coverage as well.
- The app contains about 93,800 lines of Swift. Several core files are very large:
  `FFMPEGConverter.swift` (4,591 lines), `ConversionManager.swift` (3,371),
  `ContentView.swift` (3,017), `VideoFileListView.swift` (2,280), and
  `ExportPreset.swift` (2,241).
- There are 433 unit tests. The UI test target now has deterministic smoke
  assertions for empty-queue launch, Settings navigation, generated-fixture import,
  preset selection, conversion success, conversion failure details, and start/cancel
  state transitions.
- GitHub Actions now builds Debug and runs unit tests on pushes and pull requests;
  tagged and scheduled runs also build Release. `main` now requires the GitHub
  Actions Debug build-and-test check, including for administrators, with strict
  up-to-date branch enforcement.
- External tools now construct `Process` only inside the shared runner in production.
  The DEBUG-only UI-test fixture generator now uses the same runner as well.
  All production launch paths share the same cancellation, timeout, pipe-draining,
  and error-reporting layer.
- Image-sequence import now probes associated-audio duration asynchronously end to
  end behind a non-joining five-second deadline. The former semaphore compatibility
  bridge has been removed, and cancellation is checked before a derived frame rate is
  published.
- The empty queue, imported queue rows, primary conversion toolbar, and Settings
  navigation now have a tested accessibility-identifier contract. Most icon-heavy
  and custom AppKit/SwiftUI controls still need explicit labels, state values, and
  flow coverage.
- The string catalog has 1,481 entries. All 59 previously missing App Intent
  strings and the ordinary interface omissions are now translated into Norwegian.
  The only 15 missing entries are intentionally untranslated format/command tokens;
  CI rejects unclassified omissions and broken interpolation placeholders.
- Bundled binaries, frameworks, and resources total roughly 280 MB before the app
  bundle is packaged. Their contents and licenses should be verified as part of a
  release rather than only reviewed manually.

## Priority 0 — Restore a trustworthy baseline

Target: first; approximately 2–4 focused days.

### 0.1 Resolve the failing anamorphic-crop regression test

Status: completed 2026-08-31.

- Create a tiny generated 1440×1080, SAR 4:3 fixture with an unmistakable crop
  target.
- Verify the produced pixels, display aspect ratio, and output dimensions with
  FFmpeg/SwiftExif. Do not decide correctness from the command string alone.
- Fix the filter construction if the output is wrong; otherwise rewrite the stale
  assertion to describe the new “replace desqueeze with crop + setsar” behavior.
- Add square-pixel, anamorphic, inactive-crop, stream-copy, and odd-dimension cases.

Acceptance: all unit tests pass from a clean Derived Data directory, and the test
name/comments match the intended filter behavior.

Completed with explicit post-crop square-pixel normalization, a generated
1440x1080 SAR 4:3 color-band fixture, pixel/SAR/dimension validation, and focused
square-pixel, anamorphic, inactive-crop, stream-copy, missing-PAR, and odd-dimension
tests.

### 0.2 Add build-and-test CI

Status: completed 2026-09-05; hosted validation and required-check enforcement configured (Codex).

- On every pull request and push, build the Debug app and run unit tests on macOS.
- Add a Release build on tags or a scheduled run so packaging-only problems are
  caught before release day.
- Upload the `.xcresult` when tests fail.
- Keep the appcast publishing job separate from validation.

Acceptance: a change cannot be merged unnoticed with a compile error or failing
unit test.

Implemented in a validation workflow that runs a Debug build and the unit-test
target on every pull request and push. Tagged and weekly scheduled runs also build
Release; manually dispatched runs can validate both configurations on demand.
Failed jobs retain their `.xcresult` bundles for diagnosis. The appcast publisher
remains an independent workflow. The first hosted Debug build and unit-test run
passed on commit `a57ed1d`. The `main` branch now requires `Debug build and unit tests`,
bound to the GitHub Actions app identity, with strict up-to-date checks and administrator
enforcement. The GitHub API confirmed the configured protection on 2026-09-05.

A permanent shared `Aagedal Media Converter Unit Tests` scheme now builds only the app
and unit target. CI uses it for unit validation, avoiding the unrelated UI-runner
relink permission failure without removing UI tests from the ordinary app scheme
(Codex, 2026-09-06).

### 0.3 Turn the existing TODO into current work

Status: completed 2026-08-31.

- Closed the ambiguous screen-recording item as an implemented CFR baseline:
  growing presets use a fixed frame pump with Auto, integer 50 fps (PAL), or integer
  60 fps (NTSC). Non-growing presets intentionally retain source-timestamp VFR,
  with the selected rate acting as a requested delivery cap. The distinct
  broadcast-grade expansion—25, 29.97, 50, and 59.94, rational timing, drop-frame
  timecode, and explicit CFR/VFR labeling—remains tracked in 4.3.
- Marked the Downloads Homebrew-install-guide item complete: yt-dlp settings show
  a copyable `brew install yt-dlp` command; package-manager installation remains a
  manual Terminal step.
- Kept completed implementation history in the changelog and removed stale open
  wording from the historical checklist.

Acceptance: no open item is ambiguous or already implemented.

## Priority 1 — Protect conversion correctness

Target: next; approximately 1–2 weeks, delivered incrementally.

### 1.1 Build a command-generation test matrix

Status: in progress; default preset matrix added 2026-08-31.

Cover the pure logic before refactoring it:

- every built-in preset and its container/codec pairing;
- trim + crop + anamorphic normalization;
- audio mapping, removal, channel routing, and MCA labels;
- subtitle mapping/OCR/transcription hand-off;
- stream copy incompatibilities;
- metadata, timecode, image-sequence, DCP, IMF, and AV2 special paths;
- custom-argument tokenization, including empty quoted arguments.

Prefer structured expected values and focused assertions over full command-string
snapshots, which are brittle when argument order is irrelevant.

Acceptance: each built-in preset has at least one command test, and every fixed
conversion regression gains a test.

Custom-command tokenization now has direct tests for explicitly empty quoted
arguments, single- and double-quoted whitespace, and escaped whitespace. A
structured default matrix now covers the output extension, video codec, audio
codec, and media shape for every FFmpeg-backed built-in preset. AV2 has a separate
assertion that preserves its dedicated `avmenc` route. Stream Copy now has a
regression test that verifies audio/video copying while excluding subtitles. The
H.264, H.265, and AV1 paths now verify MP4/MOV fallback from incompatible Opus to
AAC and native Opus retention in Matroska. Audio-routing coverage now exercises
selection order, duplicate tracks, removal/fallback behavior, mixed downmix and
pass-through filters, and merge/split/swap/extract channel operations. Subtitle
mapping is tested for MKV, MP4/MOV, disabled preservation, and unsupported output
containers; AVC-Intra MCA tests cover manual overrides, input dual-mono labels,
silent padding, and unknown layouts. Those tests fixed duplicate video mapping
when an audio map appeared first and prevented subtitle arguments from being added
to PNG, AVIF, MXF, IVF, and audio-only outputs.

Metadata/timecode coverage now verifies source-map versus deterministic stripping,
manual replacement without requiring a successful source probe, item-level disable
without silently reloading the global default, trim offsets, 29.97/59.94 drop-frame
minute rules, ten-minute boundaries, and very-low-rate safety. This fixed invalid
drop-frame labels, a possible divide-by-zero, missing timecode on waveform and
synthesized-video command branches, and redundant re-probing when request metadata
is already available. A generated QuickTime fixture now verifies that Stream Copy
preserves source timecode, replaces both the container and video-stream tags for a
manual value, and clears both tags when timecode is disabled so FFmpeg cannot recreate
a stale `tmcd` track. Image-sequence input/range/audio and JPEG quality are tested;
DCP and IMF tests cover geometry, profiles, rational rates, HDR color tags, and
codec choices; AV2 chunk-count policy is covered for CQ, VBR, and short inputs.

Generated fixed-rate media now verifies that AV2 start-only trims plan only the
remaining duration and frame count, preventing parallel chunks from seeking beyond
the source. A generated color-band fixture now verifies that image-sequence exports
retain their selected visual encoder and apply crop filters to the actual output
pixels, rather than losing both behind the embedded-video-track capability. IMF App
2e now retains its exact produced JP2 frame count before optional cleanup and reuses
it for audio padding and CPL duration; App 5 retains a tested duration fallback. The
image-sequence import path now resolves normalized crop geometry from its concrete
first frame rather than attempting to probe the containing directory; a generated
PNG sequence verifies the assembled command and cropped output pixels. The next
slice now uses dummy video/audio essences to exercise DCP and IMF assembly end to
end: essence moves, PKL hashes and sizes, ASSETMAP paths and lengths, CPL timing and
metadata, optional-audio omission, and IMF parser round-trip are covered without
external tools. This exposed
and fixed DCP CPL/PKL generation that ignored the requested content title,
annotation, and audio language.

DCP and IMF audio post-processing now follows the same virtual source as the picture
encode: concat groups extract across the full demuxer list, while image sequences
open their associated audio file directly. Generated PCM fixtures verify the full
concat duration and companion-WAV duration. The audio-only fallback also handles
WAV/AIFF-style inputs whose stream topology is not available through SwiftExif,
instead of silently treating them as mute.

AV2 now follows custom concat and image-sequence sources instead of silently
reopening the representative URL. Concat commands use the full demuxer list and
the queue's known duration/frame rate; image sequences use their first concrete
frame for geometry and preserve their image2 input arguments. Virtual sources stay
on the validated single-process encoder path until independent segment seeking has
generated-media coverage. Matroska audio now follows the same virtual source,
including full concat audio and image-sequence companion files, and item-level mute
suppresses the audio track. Audio-only generated-video requests fail with a clear
unsupported message instead of entering an incompatible AV2 path.

AV2-in-Matroska now writes the same composed comment/date value and resolved
manual or preserved timecode as the generic export path, including global and
primary-video tags. Raw IVF remains metadata-free by design. Arbitrary additional
FFmpeg output arguments now fail with a clear unsupported error instead of being
silently discarded; there are currently no production AV2 callers that supply
them.

AV2-in-Matroska now also consumes the shared audio-routing policy. A routed
audio-only Matroska stage preserves selected order, duplicate tracks, removals,
per-track downmixing, and channel operations before AAC or Opus packets are handed
to the in-app muxer. The muxer writes ordered audio track numbers and block IDs,
marks only the first audio stream as default, and exposes routing only when the AV2
container is Matroska. Generated two-track fixtures cover AAC and Opus staging,
downmixing, duplication, split/extract channel operations, and output channel order;
selected-audio extraction failures now stop the conversion instead of silently
producing video-only output.

DCP and IMF package audio extraction now treats an empty customized audio route as
an intentional silent package. This prevents the post-processing path from indexing
an empty stream selection when the user removes every audio track; generated WAV
coverage verifies that the package stays silent without launching FFmpeg.

The audit identified these remaining high-risk follow-ups:

- generated waveform/synthesized-video AV2 output remains unsupported;
- routed AV2 audio tracks are currently reconstructed from time zero, so differing
  source-track start offsets are not preserved; uncommon AAC program-config-element
  layouts also remain unsupported by the elementary-stream parser;
- generated IMF CPL `SourceEncoding` references need full MXF descriptor and
  subdescriptor coverage plus conformance validation.

### 1.2 Add small media-fixture integration tests

Status: completed 2026-09-01.

- Generate short fixtures in the test setup instead of committing large media.
- Exercise one representative file per major family: video+audio, anamorphic,
  multichannel audio, subtitle, still/image sequence, and malformed input.
- Validate output with in-process metadata where possible and FFmpeg only where the
  app itself depends on FFmpeg behavior.
- Include cancellation, failed-process, missing-binary, existing-output, and
  source-overwrite prevention cases.

Acceptance: the core “import → command → convert → validate output” path runs in CI
in a few minutes and leaves no temporary artifacts behind.

A generated one-second video+audio Matroska fixture now drives
`FFMPEGConverter.convert` through real output naming, process launch, progress
handling, completion, and post-run validation. The test verifies the H.264 result
contains one video and one audio stream with the expected dimensions and duration,
and cleans its temporary directory. Generated follow-up cases now verify that an
existing output is preserved under a unique destination, a same-path request cannot
overwrite its source, malformed input returns an actionable failure, and cancelling a
running FFmpeg process completes promptly. Failed and cancelled ordinary-file exports
now remove partial output and revoke their app-created-file registration, preventing a
stale path from authorizing deletion of a file created there later. Explicit selection
of a missing custom FFmpeg binary also fails before registering or creating an output.
A single completion gate now covers every ordinary-file exit path, including early AV2
rejection and native-waveform failures, so racing auxiliary/FFmpeg exits cannot complete
twice or bypass failed-output cleanup. An AV2 generated-video rejection test verifies the
reserved destination is unregistered even though no encoder process starts.
A generated 5.1 fixture now exercises the core converter's real audio-routing path and
verifies a selected surround track is downmixed to one stereo output stream. A generated
Matroska text-subtitle fixture verifies H.264/MP4 conversion produces a `mov_text` stream
whose subtitle payload can be extracted intact. Together with the existing generated
anamorphic and image-sequence cases, the fixture families and failure/safety cases in
this milestone are now covered without committed media or leftover temporary files.

### 1.3 Replace the placeholder UI test with smoke coverage

Status: completed 2026-09-01.

Start with stable, high-value flows:

1. Launch into an empty queue.
2. Open Settings and move between panes.
3. Import a fixture and select a preset.
4. Start and cancel a conversion.
5. Verify the result/error state is exposed to the UI.

Use accessibility identifiers as the test API rather than coordinates or visible
English text.

Acceptance: the UI suite contains real assertions and is deterministic across two
consecutive clean runs.

The stale UI-test host target name has been corrected. Stable accessibility
identifiers now cover the empty queue, imported queue rows and their state, Import,
Preset, Start/Cancel, Settings, and each Settings sidebar pane. The generated
placeholder test has been replaced with empty-queue/toolbar assertions and a Settings
test that opens the window and moves from General to Presets to Metadata while
checking the exposed pane state. A DEBUG-only launch hook now generates a tiny media
fixture in an app-owned temporary directory and imports it through the production
URL path, allowing the UI suite to verify queue import and preset selection without
automating the sandboxed system file picker. The generated-fixture import and preset
selection test passed twice consecutively. The same fixture now exercises a successful
H.264 conversion through the production manager, while deleting the imported fixture
before Start produces a deterministic missing-input failure whose technical detail is
exposed through a dedicated accessibility element. Cancellation uses a DEBUG-only,
real-time-paced 15-second fixture so automation observes the real FFmpeg process without
depending on encoder speed. This exposed a batch-lifecycle race: cancellation could
arrive before the completion waiter was installed, and Cancel All did not resume that
waiter. The waiter is now installed before conversion starts and is released on every
batch cancellation. Per-batch and per-process identities also prevent late callbacks
from an older cancelled conversion from clearing or completing newer work, including
cancellation during FFmpeg preflight before the process launches. Start/cancel,
success, and failure UI tests passed together in two consecutive runs; the full
unit target remains green.

## Priority 2 — Make long-running work reliable

Target: after the correctness net; approximately 1–2 weeks.

### 2.1 Introduce one subprocess runner

Status: completed 2026-09-05; shared runner plus yt-dlp, rclone, OCR, Whisper, Parakeet,
analytics, package-version probes, merge preparation, screenshot capture, and the
ordinary FFmpeg conversion, Deno archive extraction, and yt-dlp warm-up paths
migrated 2026-09-01–04. Image-sequence WAV sidecar extraction and AV2 one-shot
helper launches migrated 2026-09-04.
Native-waveform streaming encoding migrated 2026-09-04.
Chunked AV2 worker pipelines migrated 2026-09-04.
AV2 source decoder pipelines migrated 2026-09-04.

Provide an injectable runner that owns:

- cancellation and process-tree termination;
- optional deadlines and a clear timeout error;
- concurrent stdout/stderr draining without deadlocks;
- incremental progress parsing;
- structured exit status and bounded diagnostic output;
- environment construction and redaction of credentials, cookies, and URLs;
- test fakes for success, failure, timeout, and cancellation.

Migrate the highest-risk paths first: FFmpeg conversion, yt-dlp, rclone upload,
Whisper/Parakeet, OCR, and package wrappers. Do not attempt all 50 call sites in one
change.

Acceptance: cancelling a queue item reliably stops its child process, and no tool
invocation can wait forever without an explicit policy.

The first incremental slice introduces an injectable runner with structured exit
results, concurrent stdout/stderr draining, independently bounded capture tails,
stdin delivery, task cancellation, explicit deadlines, TERM-to-KILL escalation,
descendant termination, incremental output events, elapsed timing, and log-safe URL
and sensitive-argument redaction. Focused process tests cover successful and nonzero
exits, stdin, output beyond pipe capacity, capture bounds, timeout, descendant cleanup,
cancellation, TERM-ignoring-child escalation, and redaction. The duplicated yt-dlp
metadata and playlist probes now use the runner with a five-minute deadline, a 16 MB
JSON safety limit, bounded diagnostic stderr, redacted cookie/URL arguments, and
sanitized length-bounded error text. The main yt-dlp download path now uses the same
runner while retaining its activity-based five-minute stall policy for indefinite live
recordings. Incremental output is reassembled across arbitrary byte chunks; the final
output-path line, progress, title, overwrite detection, and concise first error continue
to be parsed without logging URLs or cookie values. Per-item cancellation handles preserve
user-cancel, live-stop, and stall outcomes, cancel the full subprocess tree, and prevent
one concurrent or late download from cancelling or clearing another. Fake-runner tests
cover split output, successful result validation, redacted failures, explicit and parent-task
cancellation, and live-stop behavior; the runner also verifies that every captured byte reaches its
incremental handler, including final-drain bytes.

The rclone upload, connection-test, and password-obscuring paths now use the shared
runner with six-hour, one-minute, and five-second deadlines respectively, bounded
stdout/stderr capture, stdin-only password delivery, and redacted paths, destinations,
key files, and credentials. Inherited rclone configuration variables are scrubbed before
the request-specific in-memory remote is installed. Arbitrary output chunks are
reassembled into complete progress/error lines, including final unterminated output.
Upload cancellation now follows each item's Swift task instead of a single mutable
`Process`, so cancelling one concurrent
upload cannot terminate another; execution identities also prevent late progress,
completion, or cleanup from an older attempt from overwriting a retry. Fake-runner tests
cover split/final progress, request construction, diagnostic redaction, connection error
classification, password timeout/stdin behavior, and isolated concurrent cancellation.

Per-frame Tesseract OCR now uses the shared runner instead of a detached task around
`Process.waitUntilExit`. Its existing ten-second limit is enforced by the runner with
process-tree termination, stdout/stderr are drained concurrently into bounded captures,
input paths are redacted from diagnostics, and parent-task cancellation propagates through
the shared cancellation path. Focused fake-runner tests cover request construction and
environment, timeout mapping, redacted failures, truncated-output rejection, and
cancellation.

The OCR pipeline's FFmpeg subtitle-stream extraction now uses the shared runner as well.
Its thirty-minute deadline terminates the process tree, stderr capture is bounded, source
and scratch paths are redacted from concise failure details, and user or parent-task
cancellation reaches the runner through run-keyed extraction tasks. Concurrent OCR runs
retain independent task slots, while per-attempt operation IDs ensure a row-level cancel
stops only that item's current extraction or recognition tasks; a cancellation dispatched
before actor registration is retained for that attempt, and an explicit cancel-all path
remains available for batch shutdown. Incremental FFmpeg progress is reassembled across
arbitrary output chunks without treating partial records as real progress. Fake-runner
tests cover request construction, deadline/capture policy, split progress, timeout mapping,
bounded redacted failures, early/direct task cancellation, and isolated overlapping service
cancellation.
The FFmpeg Whisper-filter transcription path now uses the shared runner with a generous
twelve-hour deadline, bounded stderr capture, process-tree cancellation, and redacted
input, model, output, and filter paths. Its progress parser reassembles arbitrary stderr
chunks and final unterminated records before interpreting duration and timestamp updates.
The actor no longer blocks in `waitUntilExit`, and per-attempt operation IDs keep overlapping
transcription cancellation isolated without poisoning a later retry. A cancellation dispatched
before actor registration is remembered for that attempt; parent-task cancellation follows the
same path and is rechecked before publication. Each run writes a short UUID-only staged SRT and
replaces its reserved destination only after success, so cancellation and failed reruns preserve
an existing valid subtitle. Concurrent same-basename runs reserve distinct final names instead
of overwriting one another. Queue progress, completion, and embedding publication are fenced by
the same attempt ID, preventing a cancelled or superseded run from mutating the current row;
grouped queue children use the same targeted cancellation route. The guarded embedding commit
uses atomic replacement so a publication failure preserves the original video. The raw filter
string, including private model and output paths, is no longer logged, and its values now use
both required FFmpeg escaping layers. Focused fake-runner
tests cover request construction, stream selection, deadline and capture policy, split progress,
timeout mapping, bounded redacted diagnostics, early/direct/late task cancellation, isolated
overlapping cancellation, long filenames, concurrent destination reservation, and staged
publication. A bundled-FFmpeg parser test also round-trips paths containing colons, commas,
semicolons, brackets, backslashes, and apostrophes without loading a real model.

The Parakeet pipeline now uses the shared runner for both selected-track FFmpeg extraction
and parakeet-mlx transcription. Both stages have process-tree cancellation, bounded output,
redacted private paths, and explicit two- and twelve-hour deadlines. Progress parsing keeps
stdout and stderr records separate while reassembling arbitrary chunks and final unterminated
records. Per-attempt operation IDs isolate overlapping and grouped queue cancellation, including
cancel-before-registration and parent-task cancellation, and fence stale progress, completion,
and subtitle embedding. Each run transcribes through a short UUID staging directory and atomically
publishes to a reserved destination only after its final cancellation check, preserving an existing
subtitle on failure and preventing concurrent same-basename runs from colliding. Focused fake-runner
tests cover request construction, environment and selected-stream mapping, deadlines and capture
policy, split/final progress, timeout and redacted failure mapping, isolated overlapping and early
cancellation, late parent cancellation, staging cleanup, failed-rerun preservation, and concurrent
publication.

The ordinary single-process FFmpeg conversion path now uses the shared runner with a
seven-day safety deadline, bounded stderr capture, redacted command/error paths,
process-tree cancellation, and CR/LF progress-record reassembly across arbitrary output
chunks. Per-conversion task and progress gates prevent late output from a cancelled or
superseded encode from mutating the next attempt. Per-attempt output reservations also
keep delayed cleanup away from a same-destination retry, and conversion-ID ownership keeps
stale handlers from clearing a newer AV2 process handle. Timeout, cancellation, nonzero
exit, launch failure, output validation, and failed-output cleanup continue through the
same single completion gate. Fake-runner tests cover request policy, split progress,
diagnostic redaction, timeout mapping, task cancellation, and same-destination
superseded-retry isolation; the generated-media conversion, file-safety, malformed-input,
and real cancellation fixtures remain green. AV2 source decoding still uses its explicit
avmdec-to-FFmpeg pipe until the runner supports streaming stdin.

The one-shot FFmpeg decoders used by native waveform export analysis and preview waveform
images now use the shared runner with twelve-hour deadlines, bounded stderr capture,
private-path redaction, process-tree cancellation, and injectable test fakes. Native
waveform analysis is tracked as part of the active conversion, so queue cancellation can
stop it before the streaming video encoder starts. Conversion-identity checks fence every
async hand-off into that encoder, its progress and termination callbacks cannot mutate a
newer attempt, its frame writer is cancelled with the conversion, and FFT work checks
cancellation periodically. Focused tests cover mono and per-channel PCM/image output,
request policy, redacted bounded failures (including custom executable paths), timeout
mapping, direct cancellation, and converter-level cancellation. Those tests also exposed
and fixed a short-audio FFT range crash by zero-padding requested frames beyond the
available PCM samples.

Rclone package resolution now uses the shared runner for both custom-binary identity
validation and the active-version query. The duplicated direct `Process` launches and
hand-rolled watchdog were replaced by one injectable five-second probe with bounded stdout
and stderr, process-tree cancellation, structured exit checking, and executable-path
redaction. Focused fake-runner tests cover request policy, accepted and rejected output,
nonzero exit, cancellation, and the update service's injected active-version path.

Video-quality analytics now uses the shared runner for VMAF, PSNR, XPSNR, per-frame
FFmpeg extraction, and SSIMULACRA2 comparison. The actor no longer blocks in
`waitUntilExit`; each tool has an explicit deadline, bounded output capture,
process-tree cancellation, and private-path redaction. FFmpeg progress is reassembled
across arbitrary CR/LF chunks, VMAF scratch logs are removed on every exit, and an
attempt identity prevents a superseded analysis from clearing or cancelling its
replacement. Injectable media metadata and subprocess seams provide focused coverage
for request policy, split progress, result parsing, scratch cleanup, SSIMULACRA2's
three-stage tool flow, timeout/nonzero diagnostics, direct cancellation, and overlapping
attempt isolation.

BMX package rewrapping and MXF metadata/MCA-label probes now use the shared runner.
`bmxtranswrap` has a twelve-hour deadline, process-tree cancellation, bounded and
redacted diagnostics, split-record-safe progress parsing, serialized execution, and
nonempty-output validation. Conversion-scoped cancellation is retained when it wins
the race before subprocess registration, without affecting another conversion. The
`mxf2raw` probes have five-minute deadlines and bounded output, reject truncated or
nonzero results instead of parsing partial metadata, and keep their existing MCA
cache and security-scope lifetime. Operation-aware queue cancellation removes a
waiting rewrap immediately, and post-processing ownership prevents a cancelled or
superseded conversion from reporting late success. Fake-runner tests cover request
policy, progress, redaction, timeout, direct, queued, and pre-registration cancellation,
serialization, missing and partial outputs, OP1a detection, MCA parsing, and
truncated-probe rejection.

Preview thumbnail and legacy waveform subprocesses now use the shared runner instead
of the centralized wait-before-drain `Process` helper. Each file-producing invocation
has a thirty-minute deadline, bounded stderr, no stdout retention, private-path
redaction, process-tree cancellation, nonempty-output validation, and partial-file
cleanup. Per-URL cancellation and app termination cancel tracked runner tasks; fallback
loops no longer turn cancellation into retries or apparent success. Attempt ownership
also prevents cleanup from an older cancelled generation removing a replacement.
Focused fake-runner tests cover request policy, bounded redacted failures, timeout
mapping, targeted cancellation, and cancellation of every tracked process.

The yt-dlp updater's active yt-dlp and Deno version probes now use the shared runner
instead of a polling loop with manual TERM/KILL handling. Both probes have a
three-second deadline, bounded stdout and stderr, executable-path redaction,
process-tree cancellation, structured exit checking, and truncated-output rejection.
Focused fake-runner tests cover request construction, tool-specific parsing, nonzero
exit, launch failure, timeout, truncation, and parent-task cancellation.

Merge trim and conformance preparation now uses the shared runner instead of an
untracked continuation around `Process`. Each one-shot FFmpeg run has a twelve-hour
safety deadline, concurrent pipe draining with bounded stderr, private-path redaction,
process-tree cancellation, and nonempty-output validation. Batch cancellation stops
the active preparation task, while cancelling any constituent row invalidates the stale
merge snapshot and lets the remaining rows continue individually; operation and batch
identities prevent an older completion from clearing or publishing over a replacement.
Failed, timed-out, and cancelled runs remove partial prepared clips. Fake-runner tests
cover request policy, redaction, missing and empty output validation, failure and timeout
cleanup, and parent-task cancellation.

The shared FFmpeg/Parakeet and Tesseract version helpers now use the shared runner
instead of waiting synchronously and draining one pipe only after exit. Both variants
have a five-second deadline, concurrent bounded capture, executable-path redaction,
structured exit checking, selected-stream truncation rejection, and parent-task
cancellation. Focused fake-runner tests cover stdout/stderr parsing, request policy,
nonzero, truncated, and empty results, timeout mapping, and cancellation.
Tesseract's selected version stream now matches the current CLI's stdout behavior.

Interactive screenshot capture now uses the shared runner instead of a detached
task that waited indefinitely before draining FFmpeg's error pipe. Captures have a
thirty-minute deadline, discard stdout, retain bounded stderr, redact executable and
media paths, propagate cancellation, reject missing or empty output, and remove
partial files after every failed exit. Each attempt writes a UUID-owned staging file
and uses an exclusive atomic rename to publish a collision-free destination without
replacing an earlier screenshot. The controller owns and identifies the active
capture so preview teardown stops it and rejects a late success. The two player UIs
no longer publish the same success state and overlay twice or log expected teardown
cancellation as an error. Focused fake-runner tests cover request policy, redacted
nonzero diagnostics, timeout and parent cancellation, late success, atomic
publication, and missing or empty output cleanup.

Deno archive extraction now uses the shared runner instead of blocking the updater
actor in `waitUntilExit`. The `ditto` invocation has a five-minute deadline, bounded
stderr, discarded stdout, temporary-path redaction, structured exit checking, and
task cancellation. The updater explicitly owns both the complete update and its active
extraction, so the existing Settings cancel action reaches release lookup, download,
checksum verification, `ditto`, and the final publication boundary. The replacement
binary is prepared in the destination directory and atomically renamed over the old
runtime only after permissions and cancellation checks succeed, so a failed or
cancelled update preserves the working installation. Archive hashing uses cancellable
one-megabyte reads off the updater actor, and parent cancellation is bridged to the
underlying URLSession download task. Extraction scratch is removed after every failed
or cancelled attempt, and successful scratch ownership is returned explicitly so the
installer removes it after moving the binary. The downloaded archive is also removed
when extraction or installation fails instead of leaking in the temporary directory.
Focused fake-runner tests cover request policy, direct and nested archive layouts,
nonzero, missing-binary, timeout, service-routed cancellation, and scratch cleanup.
Installer tests cover successful atomic replacement and deterministic cancellation
immediately before publication.

The app-downloaded yt-dlp warm-up now uses the shared runner with a 30-second
deadline and no retained stdout or stderr. The updater owns the active warm-up,
so repeated requests cancel superseded work; `warmUp()` also returns its parent task
for callers that need explicit cancellation. The longer deadline preserves the
purpose of warming the documented slow first launch instead of prematurely killing
it at the three-second version-probe deadline. Focused fake-runner tests cover request
policy, supersession, and parent cancellation.

ConversionManager subtitle embedding now uses the shared runner for both generated
and manually attached subtitle files. Muxing has a twelve-hour safety deadline,
bounded stderr, private-path redaction, process-tree cancellation, and nonempty
staged-output validation. Per-item attempt ownership lets row, item, and batch
cancellation stop embedding after transcription hands off to FFmpeg, while attempt
identities prevent a cancelled or superseded mux from publishing late. Both paths
now atomically replace the original only after a successful final ownership check,
removing the manual attach path's remove-then-move data-loss window. Focused
fake-runner tests cover request policy, redacted nonzero cleanup, atomic publication,
targeted cancellation, and late superseded success.

Whisper capability and FFmpeg-version discovery now uses a single asynchronous,
actor-cached probe instead of two lazily initialized synchronous `Process` waits on
the UI path. The parallel filter/version requests have five-second deadlines,
bounded output, executable-path redaction, structured exit and truncation checks,
and injectable fakes. Concurrent settings and queue consumers share one probe pair;
their loading and ready states update asynchronously, while cancelling one waiter
does not cancel work still needed by another. Focused tests cover request policy,
parsing, cache reuse, concurrent callers, nonzero and truncated output, timeouts,
missing binaries, and waiter cancellation. Changing the selected FFmpeg source or
custom path now invalidates the cache; custom-path edits use a short debounce so the
active capability follows the resolved binary without probing on every keystroke.

DCP/IMF PCM package-audio extraction now uses the shared runner instead of waiting
for a direct `Process` before draining stderr. The extraction has a twelve-hour safety
deadline, concurrent bounded diagnostics, private-path redaction, nonempty-output
validation, and partial-file cleanup across nonzero, timeout, launch-failure, and
cancellation exits. The converter owns the active extraction task during package
post-processing, so queue cancellation reaches the FFmpeg process tree and rejects a
late result. Focused fake-runner tests cover request policy, redacted diagnostics,
timeout and parent cancellation, output validation, and cleanup; generated concat and
image-sequence companion-audio fixtures remain covered.

DCP and IMF package wrapping now uses the shared runner for DCP picture/audio
`asdcp-wrap`, IMF App 2e `raw2bmx`, IMF audio `asdcp-wrap`, and IMF WAV padding.
Every stage has a twelve-hour safety deadline, concurrent bounded diagnostics,
private-path redaction, nonempty-output validation, and partial-output cleanup.
Conversion-scoped task ownership lets cancellation or a superseding conversion stop
the active wrapper and reject late publication, while the App 2e output-size progress
poller remains active only for the lifetime of its runner task. Focused fake-runner
tests cover request policy, combined stdout/stderr diagnostics, nonzero exits,
timeouts, cancellation propagation, redaction, missing and empty output, and cleanup.

AVC-Intra audio-only preprocessing now uses the shared runner instead of blocking
the converter actor in `waitUntilExit` while leaving its stdout and stderr pipes
undrained. The pre-pass has a twelve-hour safety deadline, bounded diagnostics,
private-path redaction, process-tree cancellation, nonempty-output validation, and
partial-output cleanup. Conversion- and task-level ownership stops a cancelled or
superseded pre-pass and rejects late output; cancellation is distinct from an ordinary
preprocessing failure so it cannot fall back into a new main conversion. Focused
fake-runner tests cover request policy, success, redacted nonzero failure, timeout,
missing and empty output, cancellation propagation, and cleanup.

Image-sequence WAV sidecar extraction now uses the shared runner instead of the last
production `waitUntilExit`. It has a twelve-hour safety deadline, bounded and redacted
stderr diagnostics, process-tree cancellation, output validation, and a
conversion-owned task so row, batch, and superseding-conversion cancellation reaches
post-processing. Each run writes a UUID-owned staging WAV and atomically publishes it
across an actor-isolated final ownership check, keeping an older valid sidecar intact
across failure or cancellation. Focused fake-runner tests cover request and trim policy,
nonzero and redacted diagnostics, timeout, missing and empty output, cooperative and
late non-cooperative cancellation, no-audio skipping, staging cleanup, and preservation
of an existing destination; a generated video-and-audio fixture verifies the trimmed WAV
and its duration through the real bundled FFmpeg.

The one-shot helpers used by AV2 Matroska muxing now use the shared runner for
codec-private probes, routed-audio staging, and per-track packet extraction. Probe
invocations have five-minute deadlines; full-media audio work has twelve-hour deadlines.
All paths discard stdout, retain bounded stderr, redact executable and private media
paths, and terminate subprocess trees on cancellation. A conversion-owned,
identity-checked task prevents a cancelled or superseded mux from continuing into
another helper stage or clearing a replacement operation, including cancellation while
an audio-stream probe is suspended. Concat-list members are added to the redaction set so
an indirect source path echoed by FFmpeg cannot enter a queue error. Focused fake-runner
tests cover request and capture policy, nonzero exits, launch failures, timeouts,
direct and probe-time cancellation, concat-path redaction, and isolated replacement
cancellation; the generated AAC/Opus routing fixture remains green through the real
bundled FFmpeg.

The shared runner now accepts a backpressured standard-input producer, closes parent pipe ends
correctly, suppresses SIGPIPE per descriptor, cancels the producer with its process, and never
joins an uncooperative producer after child exit. Native-waveform frames stream through that API
instead of a directly managed `Process`; the encode has a seven-day safety deadline, bounded and
redacted diagnostics, process-tree cancellation, nonempty-output validation, and failed temporary
MXF cleanup. Focused tests cover live streaming, backpressure timeout and cancellation,
non-joining producer cleanup, request policy, output bytes, encoder-stage cancellation, timeout
mapping, and partial-output cleanup.

The shared runner now supports a coordinated producer-to-consumer pipeline on top of its
backpressured standard-input API. It starts and drains both tools through the same bounded,
redacted request policy; preserves structured producer launch, timeout, cancellation, and
connection failures; and cancels upstream production when the consumer stops. The single-file
AV2 encode now uses this pipeline for ffmpeg-to-avmenc streaming instead of two directly managed
`Process` instances. Conversion-owned task tracking stops both tools on cancellation or
supersession, partial IVF output is removed on every failed terminal path, and split-chunk `POC:`
and ffmpeg progress records remain supported. Focused tests cover full-duplex draining, EOF after
producer failure, launch failure, downstream-timeout cancellation, bounded/redacted AV2 policy,
broken-pipe producer shutdown, split progress, upstream diagnostic precedence, partial-output
cleanup, both-stage conversion cancellation, and late ownership cancellation.

Chunked AV2 encoding now runs every concurrent ffmpeg-to-avmenc worker through the coordinated
runner. Each stage has the same seven-day safety deadline, bounded redacted diagnostics, process-tree
cancellation, and split-record-safe `POC:` parsing as the single-file path. The first failed worker's
actionable error is retained while sibling pipelines are cancelled, and partial segment files and
their scratch directory are removed before returning. Focused fake-runner tests cover concurrent
request policy, redaction, aggregated split progress, upstream-error precedence, scratch cleanup,
and cancellation of every producer and consumer stage.

AV2 source decoding now runs avmdec-to-FFmpeg through the coordinated runner instead of
two directly managed `Process` instances. Both stages have seven-day safety deadlines,
bounded diagnostics, private-path redaction, process-tree cancellation, and split-record-safe
FFmpeg progress parsing. Decoder launch, timeout, and nonzero failures remain distinct from
downstream FFmpeg failures; decoder failures take precedence when the downstream tool only
fails because its Y4M input ended early. Partial outputs are removed through the shared
conversion completion gate, and cancellation stops both pipeline stages. Focused fake-runner
tests cover request policy, streamed input, redaction, split progress, failure precedence,
cleanup, and two-stage cancellation.

The Homebrew/Python resolver now returns immutable executable, argument, and environment
configurations directly to yt-dlp, its updater, and Parakeet. The five configuration-only
`Process` shims have been removed, leaving the shared runner as the sole production owner of
subprocess launch.

The runner now launches each tool atomically into a dedicated POSIX process group instead
of discovering descendants from a point-in-time PID-tree snapshot. Cancellation and timeout
send TERM and then KILL to the whole group, including descendants created during shutdown or
reparented after a wrapper exits. The direct `posix_spawn` path preserves explicit/inherited
environments, working directories, stdin/stdout/stderr behavior, an empty signal mask, and
structured exit status. Focused tests cover group identity, environment and working-directory
semantics, descendant cleanup, TERM-ignoring escalation, pipelines, streaming input, bounded
capture, and cancellation. A child that deliberately escapes with `setsid`/`setpgid` remains
outside the runner's control, matching ordinary process-group semantics.

### 2.2 Remove sync-over-async waits

Status: in progress; image-sequence duration probing migrated async end-to-end,
preview/analytics media preflight bounded, Apple Vision per-frame OCR bounded, and
Whisper and Parakeet model downloads made cancellation-safe 2026-09-04.
Native preview rendering and player observer work bounded 2026-09-05 (Codex).

- Make image-sequence duration probing async end-to-end, or give the compatibility
  bridge a bounded timeout while callers are migrated.
- Audit `waitUntilExit`, `DispatchGroup.wait`, and semaphore waits for cancellation
  and actor/thread assumptions.
- Add cancellation checks around metadata probing, thumbnails, downloads, uploads,
  and conversion post-processing.

Acceptance: Thread Sanitizer smoke runs show no new races, and stalled media probes
cannot indefinitely block an import.

Image-sequence folder and single-file detection now await the shared asynchronous
duration probe end to end. File-picker and DEBUG fixture imports await detection while
retaining their security-scoped access, and the semaphore-based synchronous duration
bridge has been removed. Each audio probe has a non-joining five-second deadline and
retains the exact selected-folder or resolved-parent sandbox scope until even a late,
non-cooperative load returns. Single-frame imports only discover sibling audio when that
parent scope is available; a frame-only Powerbox grant is never treated as permission for
siblings. File-picker imports are owned by the view, cancel on teardown, and re-check
sequence identity after each suspension so overlapping selections cannot append duplicates. Cancellation checks
fence directory enumeration, each sequence, and the result of an associated-audio probe
so a cancelled import cannot publish a stale derived frame rate. Focused tests cover
asynchronous associated-audio frame-rate derivation and prompt fallback when a probe does
not cooperate with cancellation. The wider wait/cancellation audit remains open; the
non-joining deadline tests described below pass under Thread Sanitizer.

Virtual-display configuration now has a real ten-second deadline around the blocking
WindowServer `applySettings` call. The former task-group race still implicitly joined
the non-cooperative blocking child after its timeout won, so a stalled WindowServer
could keep creation suspended indefinitely. An exactly-once, lock-protected
continuation now returns on operation completion, timeout, or parent cancellation
without waiting for the losing blocking call; the background closure retains its
private display objects until any late completion. Deterministic tests cover immediate
success, prompt timeout, and a late result being ignored without double-resuming the
caller.

The AVC-Intra audio-only pre-pass and image-sequence WAV sidecar extraction no longer
block the converter actor with `waitUntilExit`; their subprocess migrations, deadlines,
concurrent pipe draining, and tracked cancellation are described in 2.1. There are no
remaining production `waitUntilExit` calls. The remaining synchronous compatibility
wait is the two-second app-termination wait for preview cleanup.

Video import and player metadata loading now use a non-joining asynchronous deadline
instead of task-group timeout races that implicitly waited for a cancelled child. A
stalled synchronous SwiftMediaMetadata read can finish safely in the background, but
each probe returns after its fifteen-second deadline or immediately on parent cancellation.
The essential-info fallback has its own bound, and an exhausted fallback no longer re-enters
the same stalled single-flight read through separate duration and stream probes.
Deterministic tests cover immediate success, timeout with late completion, prompt parent
cancellation, a bounded fallback, and the player metadata entry point.

Queue-row thumbnail loading now has its own non-joining fifteen-second deadline alongside
the metadata probe. A stalled SwiftMediaMetadata or AVFoundation thumbnail read can finish
safely behind the generator's retained security scope, but it can no longer hold the
parallel `loadDetails` tuple and pin an import after metadata has already resolved. Focused
tests cover prompt timeout and parent cancellation while a non-cooperative thumbnail probe
finishes late.

Lazy C2PA and camera-metadata reads in the comparison window now have independent
non-joining fifteen-second deadlines. A stalled SwiftMediaMetadata callback can finish late,
but each task-group child still resolves, clears its loading state, and responds promptly to
parent cancellation. Focused tests cover a non-cooperative timeout and direct cancellation.

Camera-card merge compatibility, camera-card automatic format splitting, and conversion merge
preflight now use a shared throwing metadata probe with a non-joining fifteen-second deadline.
Timeout remains distinct from parent cancellation: card work exits when cancelled, while merge
preflight returns its explicit cancelled result rather than treating cancellation as unavailable
metadata. Independent card-file probes run concurrently, so even a large card has one fifteen-second
probe window instead of accumulating a separate deadline for every clip. Deterministic tests cover a
successful shared probe, timeout with late completion, concurrent batch deadlines, and prompt
merge-check cancellation. Dismissing, importing, auto-splitting, or superseding a check from the card
dialog also cancels its owned task, rejects late publication, and releases folder access. An
unavailable probe is reported distinctly from a confirmed video-less file and no longer presents a
terminal failure as ongoing metadata gathering.

Preview asset generation now reuses one shared bounded metadata result for cached per-stream waveform
discovery and new waveform rendering. A stalled parse can no longer pin the preview workflow at either
read, and cancelling preview generation propagates instead of being erased by `try?`. That audit also
identified direct, unbounded consumers in player audio discovery and conversion command builders;
the subsequent slices below migrated those paths.

Preview media preflight now resolves duration, video topology, rich metadata, and HDR classification
through one bounded result shared by full asset and row-thumbnail generation. Unsupported and
audio-only inputs use a separately bounded essential-info fallback, while a timed-out rich read is not
immediately re-entered through the same parser. Parent cancellation remains distinct from unavailable
duration, and audio thumbnails reuse the resolved duration instead of starting another probe. Focused
tests cover rich-result reuse, the essential fallback, prompt non-joining timeout, and prompt parent
cancellation.

SSIMULACRA2 media preflight now applies a non-joining fifteen-second deadline to both duration and
resolution discovery before launching frame tools. A stalled default or injected provider returns an
actionable metric failure without being joined, while cancellation remains a distinct prompt outcome.
Focused tests stall each provider independently and verify that no subprocess is launched afterward.

Player audio ordering, AVPlayer track-option refresh, and on-demand channel-waveform discovery now
use the same bounded probe. Refresh attempts are explicitly owned and superseded work cannot publish
track options for a newer player item; teardown cancels the active refresh. A focused test verifies
that audio discovery returns on deadline without joining a stalled parser.

The seven direct `VideoMetadataService` consumers in conversion command builders, AV2 planning and
muxing, and conversion audio routing now use the shared non-joining fifteen-second deadline. Command
planning reuses request metadata for deinterlace and AVC-Intra duration decisions when it is already
available, and a failed AV2 metadata read no longer immediately starts a second geometry probe. A
focused non-cooperative test verifies that deinterlace planning returns on deadline and applies its
existing progressive-source fallback.

The lower-level `FFMPEGProbeService` facade now gives audio-stream discovery, duration fallback,
chapter loading, and post-export stream verification the same non-joining fifteen-second deadline.
Video-container audio reads reuse the shared metadata cache and single-flight probe instead of
starting a second raw parse. Raw duration, chapter, output-verification, and audio-only reads retain their
security-scoped access until a late non-cooperative parser actually finishes, even after the caller
has returned. A deterministic test stalls all four facade operations concurrently and verifies that
none is joined after its deadline.

AV2 conversion now resolves visual metadata once per operation and passes that result through
parallel-segment selection, single-pipeline fallback, Matroska bit-depth configuration, and—when
the visual and source URLs are the same—preserved-timecode setup. A failed or timed-out probe is
not immediately retried by the next planning stage. Focused coverage builds all three planning
products from one known metadata value with further probing disabled.

Normal application termination now uses AppKit's asynchronous terminate-later handshake
instead of blocking the main thread on a semaphore to reach the preview actor. Repeated quit
requests share one cleanup attempt, preview subprocess cancellation remains bounded by a
non-joining two-second deadline, and AppKit receives exactly one completion reply even if
cleanup stalls. Focused tests cover coalescing and the stalled-cleanup deadline. There are
now no production semaphore, `DispatchGroup.wait`, or `waitUntilExit` calls; the wider audit
of unbounded framework callbacks and metadata consumers remains open.

Apple Vision bitmap-subtitle recognition now gives every blocking framework request the
same ten-second per-frame safety limit as Tesseract. The PNG is loaded into owned memory
before the non-joining deadline starts, so a late non-cooperative Vision request remains
safe after the OCR run removes its scratch directory. Timeout and parent cancellation return
promptly without waiting for `VNImageRequestHandler.perform`, and late completion cannot
replace the finished outcome or publish text into the completed request. Injectable-performer
tests cover input and language configuration, prompt timeout, late completion, and prompt
parent cancellation.

Screen-recording file finalization now gives `AVAssetWriter.finishWriting` a non-joining
60-second deadline. A missing framework callback can no longer leave the capture UI permanently
busy or hold output-folder access indefinitely; timeout is surfaced as a specific actionable
error and parent-task cancellation returns promptly. A retained finalization box keeps the
writer alive until any late callback actually arrives, so returning early cannot release live
AVFoundation state. Deterministic tests cover immediate completion, timeout, late completion,
and parent cancellation.

Whisper model downloads now run through an injectable, exactly-once URLSession operation with
an explicit twelve-hour resource deadline. Parent-task and Settings cancellation terminate the
underlying transfer promptly, while per-model attempt identities fence late progress and prevent
a cancelled download from publishing over or clearing its retry. Downloaded files remain staged
outside the models directory until the final ownership check, and cancellation is no longer
reported as a user-visible download failure. Focused tests cover deadline configuration, staged
publication and progress, prompt parent cancellation, and a non-cooperative late result racing a
successful retry.

Parakeet model metadata and file downloads now use injectable, exactly-once URLSession
operations with explicit five-minute metadata and twelve-hour file resource deadlines.
Parent-task and Settings cancellation reach the active request, while model-keyed attempt IDs
keep simultaneous downloads isolated and prevent late progress or files from a cancelled run
overwriting its retry. Each attempt builds a UUID-owned HuggingFace cache tree and publishes it
only after the complete snapshot passes a final ownership check; failure and cancellation remove
staging files without exposing `refs/main`. Remote filenames, commit IDs, and blob identifiers are
validated before filesystem use, HTTP failures are rejected, and blob metadata is explicitly
requested so every known file size is checked before publication and LFS files can also be
verified against their published SHA-256 before installation.
Active state and progress live in the manager, so a recreated Settings view can rediscover and
cancel an in-flight transfer or report its terminal failure, while duplicate callers receive an
explicit in-progress error. Focused tests cover deadline policy, cache layout and progress,
metadata and parent cancellation, concurrent-model isolation, duplicate callers, atomic
replacement of incomplete caches, late retry results and failures, truncated non-LFS files,
checksum failure, unsafe remote paths, and staging cleanup. All 308 unit tests pass;
the wider audit of remaining unbounded framework callbacks continues.

The shared SwiftExif duration entry point now bounds the complete parser and
AVFoundation fallback chain, covering partial-download inspection as well as callers
with their own outer deadline. Late results cannot replace the returned outcome;
cancellation is checked before fallback reads. The innermost worker retains its own
sandbox access until parsing actually finishes, and image-sequence imports keep their
existing folder-owning deadline around an explicitly unbounded resolver. Focused tests
cover immediate success, a stalled parser deadline, parent cancellation, and late
security-scope release. The subsequent native-preview slice below addresses
AVFoundation thumbnail/filmstrip generation and player observer metadata loads,
including safeguards against late output-file writes.

Native AVFoundation row-thumbnail and filmstrip rendering now has a fifteen-second
non-joining deadline, including track/format loading, image generation, and PNG encoding.
Each worker retains its own security access and produces only in-memory bytes; cache
files are written atomically only after the caller accepts the result. Late output cannot
overwrite a fallback thumbnail, and cancellation suppresses fallback work. Injectable tests
cover accepted publication, timeout with late frames, and prompt cancellation.

Player readiness now owns and bounds track validation and its initial seek. Replacing or
tearing down a player cancels this work, and operation/observer identities reject stale
metadata, time, loop, and seek callbacks. Audible-selection group loads are bounded and
retain their own source access until any late completion. A failed player immediately
falls back with its existing error instead of launching speculative diagnostic metadata
reads. Tests cover stalled metadata/seek and late results after player replacement.
The wider callback audit remains open; these concrete preview candidates are implemented.
Normal queue cancellation now also stops DCP/IMF codestream preparation. Blocking
frame I/O runs in an actor-owned detached task, with cooperative checks before each
frame, before output writes, and after the final progress callback. Cancellation and
supersession cancel that task; cleanup waits for it to stop before deleting scratch
frames, and a cancelled preparation cannot launch a wrapper. Two focused tests pass:
full IMF queue cancellation after frame one prevents frame two and wrapper launch,
and cancellation during the final frame cannot report success (Codex, 2026-09-05).
The wider audit of unbounded framework callbacks remains open.

Screen/window discovery for recording and universal audio metering now shares a
15-second non-joining deadline. Cancellation returns promptly and late framework
snapshots cannot replace the completed outcome. Three deterministic tests cover
success, a stalled discovery callback, and cancellation. The timeout has English and
Norwegian recovery text. Remaining capture audit candidates include stream start,
stop, configuration updates, and microphone permission lifecycle; these require
operation ownership and stale-result handling as well as deadlines (Codex, 2026-09-06).

A stalled bilingual UI audit exposed a synchronous Keychain secret read in Upload
Settings' saved-password presence check. Normal and S3 presence checks now request
only match status, explicitly disable secret data return, and forbid authentication
interaction. Actual upload password retrieval keeps its existing explicit path. Four
injected-query tests cover query policy, errors/authentication requirements, and
invalid identifiers without accessing real credentials. UI audits now use a volatile
blank upload profile instead of personal destinations or Keychain entries
(Codex, 2026-09-06).

Microphone authorization now has a non-joining 60-second deadline. Parent cancellation,
explicit stop/teardown, and superseding requests reject late authorization callbacks;
an unanswered prompt aborts setup with localized recovery guidance instead of being
reported as a denial. Output-folder access begins only after permission resolves.
Five deterministic tests cover grant/denial, timeout, late callbacks, cancellation,
supersession, and explicit stop. Stream start/stop/configuration, session ownership
across other suspension points, and live permission validation remain open
(Codex, 2026-09-06).

Universal audio metering now owns the complete discovery/start attempt and bounds
startup and stop with fifteen-second non-joining deadlines. Stop and parent cancellation
invalidate pending work; late successful starts are stopped, and stale level/frequency
callbacks cannot overwrite silence or a newer session. Frequency-analyzer replacement
is serialized on the sample queue. Four deterministic regressions cover late startup
and retry, stalled stop callbacks, stop during discovery, and parent cancellation.
Recording stream start/stop/configuration and broader recording-session ownership remain
open (Codex, 2026-09-06).

Recording stream shutdown now has a fifteen-second non-joining deadline, with the
retired stream/output retained until a late framework callback finishes. A synchronized
delivery fence stops writer appends and queued preview/meter updates before finalization.
Recording starts reserve ownership across discovery, permission, preview teardown, and
stream startup; stop invalidates those attempts and cleans up late tiles instead of
installing them. Shared folder access and timers remain owned until all pending starts
and concurrent finalizers finish. Nine deterministic tests cover deadline/late callback,
retired delivery, cancellation-independent cleanup, duplicate starts, stop generations,
and shared-session ownership. Stream startup itself still needs a deadline with late-success
cleanup; a permanently stalled start retains its reservation and access. Preview selection
supersession, configuration changes, and live capture validation remain (Codex, 2026-09-06).

### 2.3 Standardize user-visible errors

Status: in progress; queue failure details and redacted diagnostic copying added 2026-09-05 (Codex).

- Keep `try?` for best-effort cleanup only. Log or surface failures for directory
  creation, bookmark access, file moves, settings import, and result validation.
- Give every queue failure a concise message plus expandable technical details.
- Add a “Copy diagnostics” action with app/tool versions and redacted commands.

Acceptance: each failed long-running operation ends in success, cancellation, or a
specific actionable error—never a silent return or permanently busy state.

DCP and IMF final package-folder creation no longer discards filesystem errors and
continues into a misleading manifest-assembly failure. The conversion now logs the
underlying filesystem diagnostic, reports a concise package-specific queue error,
skips manifest publication, and still cleans temporary essences. Both new messages
are included in the Norwegian catalog.

DCP and IMF App 2e now share checked JPEG 2000 codestream preparation. Scratch-directory
creation, frame reads, missing codestream markers, and atomic output writes must all
succeed before the video wrapper starts. A failed frame can no longer be silently dropped
or counted toward the expected essence bytes; the queue reports the underlying preparation
error and cleans scratch frames. DCP skips audio work after picture failure, preserving
the original error, and scoped cleanup removes unused temporary picture/audio essences.
Tests cover exact output bytes/progress, missing and malformed frames, directory
conflicts, and output-write failures.

Settings sync no longer treats an unreadable, malformed, or newer-format snapshot as
if no remote file existed. Automatic reconciliation preserves the existing file instead
of overwriting it with local settings, publishes an actionable Settings error, and logs
the failure; manual import uses the same validated decoder. Focused tests cover valid,
malformed, and unsupported-schema snapshots.

Settings sync now also reports folder creation/open failures while starting its directory
monitor and preserves the monitoring error across otherwise successful reads and writes.
Each cancelled monitor closes its own descriptor, preventing an old cancellation handler
from closing a replacement monitor after the location changes. iCloud placeholder download
failures are logged and shown, and backup-folder creation/Finder failures use the existing
Settings alert even when sync is disabled. Two filesystem tests cover monitor-directory
creation and failure without overwriting an existing file. All 310 unit tests pass; the final
alert wiring also passed a focused rebuild/test. Real iCloud/Finder failure scenarios,
and remaining bookmark/filesystem paths remain; the subsequent queue-details slice is described below.

Queue rows now expose an explicit keyboard-accessible Error details button with a
selectable, scrollable popover. It collects conversion, download, subtitle, upload,
and analysis failures, including failures without a technical message; upload and
analysis errors no longer produce an empty status message. Copy diagnostics includes
app/build, macOS, preset, and bounded captured errors, using the shared redactor for
known input/output paths, filenames, home directory, and URLs. Reused cells or changed
failures dismiss stale popovers. Three unit tests cover aggregation, missing details,
and redaction. Capturing the exact historical tool versions and redacted commands
per operation remains open; this initial report does not reconstruct them from current
settings. The wider filesystem/bookmark error audit also remains open.
The combined unit suite passes all 325 tests (zero failures or skips); a focused
three-test package-preparation run also passes after the final cleanup adjustment.
The DEBUG fixture generator now creates and removes fixtures inside the app's own
temporary directory, avoiding the UI runner's inaccessible sandbox. Fixture-test
teardown relaunches the app for synchronous cleanup because XCTest termination can
bypass normal termination notifications. Missing-input
failure is requested through a launch flag and performed by the app after import.
Output preferences are installed in the volatile argument domain before views are
constructed, so the test folder is not saved into the user's output settings.
The failure UI smoke test reaches Error details, checks the full failure and Copy
diagnostics button, and captures a window screenshot. All six functional UI smoke
tests pass in two consecutive runs, with the
saved output-folder preference verified unchanged. All six also passed after explicit
teardown cleanup was added; the final fixture directory was confirmed absent.
The window-only Error details
screenshot was visually checked for readable text and an accessible Copy button.
Full locale/VoiceOver validation remains tracked under Priority 4.

AV2 segment planning no longer creates scratch directories as a side effect.
Execution exclusively creates its proposed directory before starting any workers,
reports filesystem failures with localized recovery advice, and installs cleanup
only after acquiring ownership. Five regressions cover abandoned plans, conflicting
files/directories, missing parents, zero worker launches on preparation failure, and
cleanup after worker failure. Test settings use the process's volatile argument
domain so this new coverage does not persist changes to user preferences (Codex,
2026-09-05).

## Priority 3 — Reduce change risk in architecture

Target: continuous work after Priority 1 tests exist.

### 3.1 Split orchestration from state and views

Status: in progress; queue decisions and bulk state transitions extracted 2026-09-05 (Codex).

- Move import, queue commands, window/overlay presentation, and App Intent hand-off
  out of `ContentView` into small coordinators or observable models.
- Split `ConversionManager` into queue scheduling, conversion execution, upload
  follow-up, and item state transitions.
- Split `VideoFileListView`/`VideoFileCellView` by behavior rather than adding more
  extensions to already-large views.

Acceptance: view bodies describe presentation, state transitions can be unit
tested without launching the app, and each extraction is behavior-preserving.

`ConversionQueueState` now owns ordered batch selection, duration-weighted progress,
and bulk cancellation transitions. `ConversionManager` delegates these decisions
without changing scheduling or subprocess ownership. Focused tests cover selected
batch limits, trim-aware weighting, failed/cancelled exclusion, progress bounds,
cancellation scope, preservation of unrelated item fields, and idempotence.
Conversion execution, upload follow-up, and the ContentView/list-view coordinator
extractions remain open.

`ConversionUploadFollowUp` now owns success/opt-in decisions for individual outputs
and chooses one representative in merge order for a shared output. Five focused tests
cover failures, selection boundaries, empty merges, and stale indices. Actual upload
execution remains in UploadManager; conversion execution, broader state transitions,
and view coordinators remain open (Codex, 2026-09-06).

### 3.2 Make conversion plans typed

- Replace repeated mutation of raw `[String]` arguments with a typed conversion
  plan: inputs, video filters, audio routes, maps, codecs, metadata, and outputs.
- Render the plan to arguments at the process boundary.
- Detect incompatible options during preflight instead of silently ignoring them.

Acceptance: filter ordering and map ownership are explicit, and invalid
combinations produce a preflight explanation before encoding starts.

### 3.3 Centralize settings access

Status: in progress; settings snapshots and upload-profile migration safety added 2026-09-06 (Codex).

- Wrap `UserDefaults` keys in feature-scoped settings types with defaults and
  migrations.
- Inject settings into logic under test rather than reading global defaults inside
  command builders and services.
- Keep machine-specific paths, bookmarks, and credentials outside synced settings.

Acceptance: tests do not mutate the user's defaults, and a settings schema change
has an explicit migration test.

Post-conversion Whisper, Parakeet, OCR, and analytics now use injected feature-scoped
settings providers. Model, language, OCR engine, subtitle embedding, and metric
preferences are captured before the operation suspends; changing Settings during a
job affects the next operation. OCR now carries its selected engine through extraction
instead of reading it again later. Five isolated-suite tests cover default/fallback
values, language precedence, metric filtering, store isolation, and snapshot stability.
Standalone Whisper, Parakeet, OCR, and analytics actions now use the same injected
providers. Analytics captures auto-export enablement, format, and SSIMULACRA2 frame
limits at operation start; the service and exporter no longer read global preferences.
Eight isolated settings tests cover defaults, invalid-value fallback, snapshot stability,
and real JSON export from captured settings. The existing analytics sampling test now
verifies that a per-operation one-frame limit governs ten-second media.

The existing filename boolean-to-mode compatibility migration now lives in an
injectable `FileNameSettings` adapter. Four isolated migration tests preserve legacy
true/false behavior, give explicit newer modes precedence, verify invalid/missing
fallbacks, and confirm repeated reads do not rewrite saved preferences. Broader
feature settings migration and coverage of the remaining schema changes remain open
(Codex, 2026-09-06).

AV2 encoding preferences now use an immutable, injectable `AV2Settings` snapshot.
One snapshot spans metadata discovery, single/chunked command construction, and final
Matroska bit-depth setup, so changing Settings during an encode cannot make its mux
metadata disagree with the encoded picture. Four new regressions cover defaults,
explicit zero values, invalid enum fallbacks, and actual commands/plans built from a
captured snapshot after preferences change. The scratch-planning regression now uses
an isolated defaults suite. Broader feature settings, including AV2 container/audio
preferences, and schema migration coverage remain open (Codex, 2026-09-06).

AV2 container, audio codec, and bitrate now join the same injectable snapshot before
the converter's first suspension. Output extensions, source-collision naming, mux
selection, and staged audio arguments all use that snapshot. Single and merged queue
completion paths retain its output extension for file size, reveal, and upload handling. Three focused tests cover
snapshot stability, invalid-value fallbacks, and audio preferences changed while source
probing suspends. Broader non-AV2 settings remain open (Codex, 2026-09-06).

Capture-display and legacy audio-preset startup migrations now live in an injectable
`StartupSettingsMigration` adapter. Six isolated tests cover automatic and explicit
display choices, preservation of cleared selections, all three legacy audio formats,
all legacy visibility combinations, modern-value precedence, and idempotence. The audio
migration now preserves an already configured modern format or visibility value instead
of overwriting it when the migration marker is absent. Upload-profile and other schema
migration coverage remain open (Codex, 2026-09-06).

Upload-profile storage and migration now accept an isolated defaults store. Six
regressions cover all four legacy backends, stable UUIDs for credential associations,
backend-specific fields and selection, modern-list precedence (including an explicitly
empty list), malformed data recovery, and idempotence. Migration no longer overwrites
newer destinations or deletes legacy data after a decoding failure; malformed source
lists remain untouched for repair and retry. Other feature settings and schema
migration coverage remain open (Codex, 2026-09-06).

## Priority 4 — Accessibility, localization, and product polish

Target: parallelizable once stable identifiers are introduced.

### 4.1 Audit the primary flows with VoiceOver and keyboard-only input

Status: in progress; preview/fullscreen control semantics added 2026-09-05 (Codex).

- Queue import/reorder/remove, preset selection, conversion controls, progress and
  errors, trim/crop, metadata, downloads/uploads, screen capture, and Settings.
- Label icon-only controls, expose state/value changes, define logical focus order,
  and provide identifiers for automated tests.
- Verify custom timeline, crop, audio meter, and AppKit bridge controls provide a
  useful accessibility representation.

Acceptance: all primary flows are completable without a pointer and have no
unlabeled interactive controls in Accessibility Inspector.

Preview crop geometry inputs now have descriptive labels, pixel values, identifiers,
and Return-key instructions. Preview/fullscreen timecode displays expose edit and
cycle actions, and fullscreen transport buttons expose labels and toggle states. The
custom fullscreen timeline has a native adjustable-slider accessibility representation.
All new interface strings have Norwegian translations. Debug builds pass; manual
VoiceOver and keyboard checks, trim-range/crop-overlay accessibility, and the wider
primary-flow audit remain.

Settings folder actions in General, Screenshots, and Watch Folder, metadata timecode
adjustments, and update-command copying now expose explicit localized accessibility
labels and stable identifiers. Screenshot format and alpha pickers now carry distinct
spoken names despite their hidden visual labels. The Settings navigation UI test
verifies the General/Screenshots button labels and all four screenshot picker names;
the focused test passes. Manual VoiceOver and keyboard focus validation remains open.

Sidebar pane names and the show/hide action now have explicit accessibility labels;
the toggle also has a stable identifier. A new bilingual audit checks native sidebar
row selection and translated names while capturing the main window and all 18 panes.
The audit now completes an uninterrupted desktop run in both languages, capturing
the main window and all 18 Settings panes. Screenshot review exposed runtime String
values bypassing the catalog in several panes, a fixed-height tip truncation, and a
selected-sidebar label truncation. Those concrete findings are corrected below; the full bilingual desktop rerun now passes (2026-09-06).
Scrolled-off content and interaction-level VoiceOver validation remain distinct follow-ups
(Codex, 2026-09-05).

The custom trim timeline now exposes native accessibility sliders for playback and
both trim boundaries, plus chapter-seek actions. Playback timecode editing and mode
selection are real keyboard-focusable buttons. Crop reset/centering, track selection,
image-sequence frame rate, and preview toggles have explicit names, values, or stable
identifiers. New strings are translated into Norwegian. The combined Debug build
passes; manual VoiceOver and keyboard interaction validation remains (Codex, 2026-09-05).

### 4.2 Close the localization gap

Status: corrected-build bilingual Settings audit completed 2026-09-06; scrolled-content and Shortcuts validation remain.

- Classify the 87 Norwegian-missing entries as user-facing text, intentional
  format tokens, or App Intent phrases.
- Translate user-facing text and validate interpolation/plural variants.
- Add a catalog check to CI and capture screenshots in English and Norwegian for
  the main window and every Settings pane.

Acceptance: CI reports no unclassified user-facing strings missing Norwegian, and
both locales fit without clipped controls.

The 87-entry Norwegian gap has been classified as 15 intentional format/command
tokens, 59 App Intent phrases, and 13 ordinary interface strings. All 13 interface
strings are now translated, and a checked-in audit plus CI script rejects new
unclassified omissions, stale classifications, incorrectly translatable format
tokens, and interpolation mismatches. The audit also fixed a malformed `%@`
placeholder in the Norwegian timecode help text. All 59 App Intent titles, descriptions,
and parameter summaries are now translated,
with `${videos}` placeholders preserved and enforced by CI. Three new settings-sync
errors are translated as well. The catalog check passes with 1,230 entries and only
15 intentional omissions; negative checks verify missing translations and broken
placeholders are rejected. English/Norwegian screenshots and clipping checks in the
app, Settings, and Shortcuts remain.

The full bilingual screenshot audit now passes for the main window and all 18 Settings
panes. Inspection exposed additional catalog omissions and dynamic strings rendered
without localization in General, File Names, Screenshots, Waveform, Downloads, Upload,
Whisper, Analytics, Updates, and Shortcuts. Those paths now explicitly localize their
values; Shortcuts search also matches translated action descriptions. The empty-queue
tip wraps at its natural height, and selected sidebar labels can shrink slightly to
fit. An additional 185 Settings and Shortcuts catalog entries now have Norwegian translations, alongside
the 27 diagnostics/accessibility entries added in this pass. The catalog audit passes
with 1,472 entries and the same 15 intentional omissions. The corrected-build audit
now passes for the main window and all 18 panes in both
languages, with all 38 screenshots visually reviewed. The Upload hang was traced to
a Keychain secret read and fixed; audits use a volatile blank upload profile. A blank
main-window preset picker exposed missing hidden-selection tags and inherited
icon-only toolbar styling. The menu now always represents its selected preset and
explicitly displays its title, with a bilingual regression test and verified final
screenshots. Five remaining
descriptive preset names now localize without changing persisted raw values or custom
names. Scrolled-off content, Shortcuts app integration, and VoiceOver remain.
The established “Watch Folder” terminology is retained (Codex, 2026-09-06).

### 4.3 Finish broadcast-grade screen-recording rates

Status: implementation and generated-writer validation completed 2026-09-05 (Codex); live capture/editor validation remains.

- Offer explicit 25, 29.97, 50, and 59.94 choices if professional PAL/NTSC delivery
  is the goal; keep display-native Auto separate.
- Use rational frame durations rather than representing every rate as an integer.
- Add drop-frame timecode for 29.97/59.94 and verify midnight rollover behavior.
- State clearly which presets are CFR and which intentionally remain VFR.

Acceptance: `avg_frame_rate`, `r_frame_rate`, duration, frame count, and timecode
match the selected rate in generated validation recordings.

Capture now offers 25, exact 30000/1001, 50, exact 60000/1001, and integer
60 fps while preserving existing saved choices and display-native Auto. Stream
configuration, growing-file CFR presentation times, encoder hints, movie/media
clocks, and timecode share one rational rate. The two NTSC choices use drop-frame
labels and all timecodes wrap at midnight. Settings and the recording overlay
explicitly explain CFR versus the non-growing presets' VFR delivery cap.

Six focused tests cover saved choices, long timestamp arithmetic, drop-frame
minute/ten-minute boundaries, midnight rollover, CoreMedia timecode descriptions,
and generated AVC growing recordings at all five fixed rates. The generated movies
verify actual frame spacing, final frame duration, total video duration against frame
count, and persisted timecode duration/quanta/flags. This caught and fixed total
track-duration rounding caused by AVAssetWriter's default 600 Hz movie clock.
The test distinguishes actual video samples from AVAssetReader's zero-sample
boundary markers rather than weakening frame-cadence assertions.

The bilingual Settings UI test verifies all six menu options and captures English
and Norwegian screenshots. Visual inspection exposed twelve older preset/detail/
dynamic-range strings bypassing the catalog; these now use localization, alongside
the eight new rate/explanation entries. The catalog audit passes with 1,250 entries
and the same 15 intentional omissions.

Remaining: live static/animated screen recordings across rates, long A/V sync,
Auto/display behavior, sandbox/permission flows, and midnight/editor interoperability.
The final combined validation passes all 333 unit tests and seven functional UI
smoke tests, with no failures. English/Norwegian capture-settings screenshots were
visually checked for clipping.
The timecode-input and stop-time reliability follow-up is now implemented. Video
and timecode wait for both writer inputs to be ready; timecode construction and
append errors fail the recording instead of silently dropping labels. Stop freezes
the endpoint and drains final CFR frames in bounded passes with a five-second
deadline and cancellation checks. Video samples carry explicit rational durations,
and the session ends at the exact emitted frame boundary, fixing doubled duration
on immediate-stop single-frame recordings.
Generated recordings verify persisted video/timecode sample counts and timestamps,
including frozen-clock single-frame recordings at every fixed rate; deterministic
tests cover backpressure, append failures,
large-backlog yielding, and deadline checks within a pass. The new errors are
translated into Norwegian. Live capture, A/V sync, permission flows, and editor
interoperability remain validation gaps (Codex, 2026-09-05).

### 4.4 Improve first-run and dependency diagnostics

Status: in progress; diagnostics and early package/AV2 dependency preflight added 2026-09-06 (Codex).

- Provide one Tools/Diagnostics view for bundled, Homebrew, and custom binaries,
  including version, architecture, executable status, and a test action.
- Keep copyable Homebrew commands and explain when the bundled tool is sufficient.
- Warn before a conversion when a selected feature depends on a missing or
  incompatible optional tool.

Acceptance: users can diagnose a missing tool without reading logs or opening
Terminal unless installation itself requires it.

The new Tool Diagnostics Settings pane checks active FFmpeg, yt-dlp, Deno, rclone,
Tesseract, and SSIMULACRA2 selections with their existing resolvers. It shows resolved
paths, Mach-O architecture or script status, executable availability, and bounded
version probes. Launch failures and timeouts have distinct recovery messages; leaving
the pane cancels its process and prevents stale publication. Six focused tests cover
headers, missing/nonexecutable inputs, output bounds, nonzero/truncated results,
cancellation, and failure classification. The pane explains when bundled FFmpeg is
sufficient and points to existing installation settings. Norwegian translations and a
bilingual UI smoke test cover the pane.

Diagnostics now also checks BMX transwrap, mxf2raw, raw2bmx, AS-DCP wrap, the AV2
encoder/decoder, and Parakeet. Verified BMX/AS-DCP version flags use the same bounded
runner; AV2 and Parakeet receive availability/architecture checks with an explicit
localized explanation that their versions were not checked. Two additional tests
verify that availability-only checks never launch a process and protect the verified
helper flags. Model availability and feature-level compatibility preflight remain open
(Codex, 2026-09-06).

Tool Diagnostics now also displays the selected Whisper and Parakeet model paths
and local availability. Checks reject missing/empty files and stale Parakeet refs
without readable configuration and model weights, follow cache blob symlinks, and
retain custom Whisper security-scoped access during inspection. These are local
availability checks; model compatibility and integrity are not claimed. Four
filesystem regressions cover missing/empty resources, dangling symlinks, and malformed
or oversized cache refs, and nonblocking rejection of named pipes. The tool check also rejects a directory masquerading as an
executable. Norwegian translations and model-row assertions extend the bilingual
Diagnostics test. Feature-level compatibility preflight remains open (Codex, 2026-09-06).

Conversion preflight now checks executable regular-file availability of the required
DCP/IMF picture wrappers and AV2 encoder before creating outputs or encoding. Recognized
AV2 sources also check the decoder at that boundary and retain the resolved path for
launch. IMF audio checks AS-DCP when existing direct-source metadata confirms audio;
customized empty routing remains silent. Six focused regressions cover helper mapping,
ordinary-export independence, invalid executable selections, early converter rejection,
AV2 source decoding, and conditional IMF audio. Decoder pipeline fixtures now use
executable tool paths, and their readiness waits fail explicitly after five seconds
instead of hanging indefinitely. The failure points to Tool Diagnostics
and is translated into Norwegian. Unknown/custom-source IMF audio dependencies and
feature-level codec/architecture compatibility remain open (Codex, 2026-09-06).

IMF audio preflight now resolves unknown and virtual inputs with the same source policy
as package extraction: concat representative clips, image-sequence companion audio,
audio-only fallback, and intentionally silent routes. It probes only when AS-DCP is
unavailable, has a bounded cancellable task before output creation, and rejects stale
results. Five additional regressions cover source selection, early rejection, timeout,
and cancellation. Unavailable topology retains the existing extraction fallback; codec
and architecture compatibility remain open (Codex, 2026-09-06).

## Priority 5 — Release and dependency hygiene

Target: before the next public release, then automate.

Status: in progress; dependency inventory and pre-upload artifact validation added 2026-09-05.

- Inventory bundled executables and dylibs; remove anything unreachable from the
  shipping app after dependency verification.
- Generate a version/checksum/license manifest for bundled tools.
- In the release script, verify architectures, dynamic-library resolution,
  executable permissions, code signatures, notarization, Sparkle signature, and
  appcast contents.
- Run a clean-machine smoke test for direct-download and Homebrew installations,
  including update behavior.
- Measure compressed download size and launch/import memory before and after binary
  cleanup; optimize only with measured evidence.

Acceptance: a release fails early when a binary, license, signature, architecture,
or update artifact is inconsistent.

`BundledDependencies.json` now records every executable and dylib shipped from the
app's Binaries and Frameworks directories, including byte size, SHA-256, file mode,
architecture, linked libraries, dylib install names, and available tool versions.
The generator runs in CI and at the start of a release, so a changed, added, or
removed binary cannot ship with a stale inventory. Known executable licenses are
identified without guessing; the manifest deliberately lists missing local license
files and unclassified dylib licenses as release follow-up. Full per-library license
attribution and reachability analysis remain open.

The release script now checks the exported bundle's strict/deep code signature and
extracts the final distribution ZIP to verify its signature, notarization staple, and
Gatekeeper assessment before uploading. A CryptoKit Ed25519 check verifies the ZIP
against the public key embedded in the exported app, detecting a mismatched signing
key as well as archive tampering. Appcast preparation happens in a separate candidate
file before upload and validates XML, build/version/minimum-OS agreement with the
exported app, increasing build numbers, archive length, HTTPS, and signature/key
encoding. Command-line version/build overrides now reach the archive build itself.
Nine release-script regression tests cover valid and rejected appcasts plus real
Ed25519 signatures, tampering, wrong keys, and malformed signatures; CI runs them.
The unsigned Release build, catalog audit, and bundled manifest check also pass.
The signed/notarized publishing pipeline still needs a credentialed release run;
complete licenses, clean-machine
installation/update checks, and measured size/memory baselines remain open.

Exported release bundles and the extracted final ZIP now pass a static Mach-O audit
before publication. Release CI runs the same audit on its unsigned build. It requires
arm64 and owner-executable permissions, resolves direct and transitive dylibs with
per-helper executable paths and inherited rpaths, and rejects missing dependencies,
external non-system library paths, and symlinks escaping the bundle. Fourteen generated
Mach-O fixture tests cover success and rejection cases; all 23 release-script tests
pass, and the existing unsigned Release bundle passes for all 44 Mach-O images.
Architecture/dependency resolution enforcement is implemented (Codex, 2026-09-05).
Full license attribution, reachability/removal decisions, measured size/memory baselines,
clean-machine install/update tests, and a credentialed release run remain.

The dependency manifest now also records hashes and sizes for all six local license
notices. Regression tests reject empty or escaping notice paths and unresolved
attribution. Release publishing requires complete notice references before building,
signing, notarizing, or uploading; ordinary CI still checks inventory freshness.
The strict gate currently fails as intended on 99 unresolved entries: three tools
(avmenc, avmdec, rclone) and all 96 source-tree dylibs. No license assignments were
invented and no binaries were removed. See `docs/bundled-dependency-licenses.md` for
the evidence and packaging follow-up. All 31 release-script tests pass, including
eight new inventory/license tests (Codex, 2026-09-05).

All six existing local license notices are now copied into app resources and are
readable offline from About > Licenses. Exported-bundle and final-ZIP checks compare
every notice byte count and SHA-256 with the manifest; Release CI runs the same check.
Six regression tests reject missing, changed, escaping, duplicate-name, and empty
notice inventories. This closes packaging/discovery of existing notices only; the
99 unresolved tool/dylib attributions and broader provenance work remain unchanged
(Codex, 2026-09-06).

## Suggested delivery sequence

Latest validation (2026-09-06, Codex): all 433 unit tests pass with zero failures or
skips using the permanent shared unit-only scheme. The unsigned Release build passes; its bundle audit verifies all 44 Mach-O images
and all six packaged license notices. All 37 release-script tests, bundled-manifest freshness, and localization checks pass
(1,481 entries, 15 intentional omissions). The six packaged notices also match the
manifest in the Debug app. GUI inspection could not be completed: the computer-use
service returned stale menu elements and no screenshot. Live capture/permissions,
VoiceOver, and the new About viewer's visual/bilingual inspection remain unverified.
The initial Debug distribution audit correctly rejected test-injected XCTest support;
distribution validation uses the Release app. No publishing or credentialed checks
were performed.


Latest validation (2026-09-06, Codex): Debug compilation and all 414 unit tests pass
with parallel workers enabled, including sixteen new upload-migration, audio-meter
lifecycle, and conversion-preflight regressions. All 31 release-script tests, bundled
manifest freshness, and localization checks pass (1,476 entries, 15 intentional
omissions). The ordinary scheme still hits the existing UI-runner relink permission
error; validation used a temporary unit-only scheme, removed afterward. An intermediate
run built during the decoder fixture update was interrupted; the final completed sources
were rebuilt and all tests passed with zero skips. No UI interaction or live capture tests
were run for this batch. The manual and wider roadmap gaps remain open.

Previous validation (2026-09-06, Codex): Debug compilation and all 398 unit tests pass
with parallel workers enabled, including ten new AV2 audio settings, startup migration,
and readiness-gated subprocess regressions. All 31 release-script tests, bundled-manifest
freshness, and localization checks pass (1,475 entries, 15 intentional omissions).
The existing UI-runner relink permission error prevented the ordinary scheme's test
build, so the final run used a temporary unit-only scheme, removed afterward. No UI
or live capture tests were run for this batch. Manual validation and the wider roadmap
items below remain open.


The TERM-ignoring descendant timeout regression now emits its child PID only after
installing its signal trap and allows a two-second startup window for loaded workers.
A separate cancellation regression waits for explicit child readiness before cancelling,
then verifies that escalation removes the descendant. A standalone harness using the
production runner passed eight concurrent timeout and eight cancellation checks
(Codex, 2026-09-06).


Previous validation (2026-09-06, Codex): Debug compilation and all 388 unit tests
pass, including thirteen new AV2 settings, microphone permission, and model-resource
regressions. All 31 release-script tests, bundled-manifest freshness, and the catalog
audit pass (1,475 entries, 15 intentional omissions). The combined run's unsigned
UI runner was killed before connecting; the bilingual Diagnostics test then passed
with a fresh locally signed build, and both results screenshots were visually checked.
The final rebuilt unit bundle ran with `test-without-building` to bypass the recurring
UI-runner relink permission error. A parallel run missed the child PID in the existing
200 ms TERM-ignoring-descendant test; all 388 tests pass with parallel workers disabled.
That subprocess startup sensitivity was addressed in the subsequent test-hardening slice below.
Live capture/permission, VoiceOver, broader Settings
and Shortcuts, and credentialed release checks remain outstanding.


Previous validation (2026-09-06, Codex): Debug builds and all 375 unit tests pass,
including sixteen new settings/migration, capture-discovery, helper-diagnostics, and
Keychain-presence regressions. All 31 release-script tests, manifest freshness, and
localization checks pass (1,472 entries, 15 intentional omissions). The corrected-build
bilingual audit passes and all 38 main/Settings screenshots were reviewed. Functional
UI checks pass across runs, including the isolated preset-menu retry; the combined
desktop suite was not uninterrupted green because of intermittent menu focus and
a lost macOS accessibility connection. Live capture,
VoiceOver, scrolled Settings content, Shortcuts app integration, and credentialed
release validation remain unperformed.

1. Green the failing crop test with fixture-backed expected behavior.
2. Add CI and the first command/file-safety test matrix.
3. Introduce accessibility identifiers while replacing the placeholder UI test.
4. Add the subprocess runner and migrate one tool path at a time.
5. Extract architectural seams under the new tests.
6. Complete accessibility/localization and rational screen-recording rates.
7. Automate the release/dependency audit.

Every milestone should update this document, record tests run, and move shipped
user-visible changes into `CHANGELOG.md`.
