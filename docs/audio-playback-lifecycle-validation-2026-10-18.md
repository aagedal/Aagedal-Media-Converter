# Playback meter lifecycle observations — 2026-10-18

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
