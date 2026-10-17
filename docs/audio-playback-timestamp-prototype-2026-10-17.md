# Playback meter timestamp transport prototype — 2026-10-17

The isolated dependency prototype preserves timestamped decoder measurements through
MPV's existing metadata property. It is not installed in the app. Source remains
the default meter; Playback retains its existing timing caveat. Neither player-clock
alignment nor physical presentation is qualified by this experiment.

This implements the first dependency instrumentation milestone from the
[previous investigation](audio-playback-timing-2026-10-16.md), plus a diagnostic
capture of the second milestone. No package pin, packaged binary, license notice,
Swift code or user interface changed.

## Instrumentation

[The patch](dependency-patches/mpv-0.41.0-meter-history.patch) and its
[portable queue](dependency-patches/amc_meter_history.h) target the exact fork's
`filters/f_lavfi.c`, SHA-256
`064f23b34cdf424a583d35d2d12d9a3760aff901f5ae15c82e30faa0cffcc80b`.
The corresponding source is recorded with the
[pinned MPVKit update](mpvkit-1.1.0-update-2026-10-15.md).

An explicit `amc-meter-history=yes` option on the audio `lavfi` bridge allocates
the history. Without it the existing bridge behavior is unchanged. The capture
runs after `mp_frame_from_av` and `fix-pts` remapping, before the frame is handed
to the next filter. It takes the start and end from `mp_aframe_get_pts` and
`mp_aframe_end_pts`, including the frame's effective sample rate/speed semantics.
Missing MPV timestamp sentinels and nonfinite/invalid intervals are explicit
invalid-time records. Captured frame metadata is cleared before each dictionary
copy: MPV's existing copy operation merges tags and otherwise could retain values
absent from the current frame. Metadata values remain strings, including `-inf`.

The ring retains at most 128 records, each with at most 16,384 JSON payload bytes
plus its terminating NUL. At the probe's 100 ms cadence this is about 12.8 seconds;
other graphs can have different cadence. Retained payload memory is bounded at
2 MiB plus record/allocation overhead. Serialization and polling add temporary
allocations and copies; this is a diagnostic implementation with no performance
qualification. Raw metadata count/size is checked before constructing nodes;
escaping can still cause serialized-size rejection.

`af-metadata/amc_timing` retains ordinary latest-frame tags and adds the string
`amc-meter-history-v1`. Parse that string as JSON. Its experimental schema has:

- `schema-version: 1`, process-local filter `instance`, graph/continuity `epoch`,
  `last-sequence`, `capacity`, cumulative `evicted` and `rejected` counters.
- `reset-reason`, a diagnostic graph/reset/rejection reason. Rejection can update
  this reason without changing epoch; counters and sequences define coverage.
- `frames` in chronological order, each with a `sequence` and `frame` JSON string.
  Parse the latter to obtain `valid-time`, valid `start`/`end`, `effective-rate`,
  `speed`, `sample-rate`, `samples`, decoded `layout` and copied `metadata`.

Reads are nondestructive because MPV can query metadata during property type and
nested-key resolution. Consumers must deduplicate by their player generation and
`instance/epoch/sequence`; instance IDs are unique only within one process.
`last-sequence` includes rejected records. Eviction means ring removal, not
necessarily a reader loss: a reader may already have copied that frame. Compare
sequences to establish received coverage. Rejection is always missing coverage.
Graph reset, format/EOF recovery and timing/layout discontinuities clear the ring
and advance epoch; recreation allocates a new instance. Sequence/loss counters
survive graph resets within that instance. Timestamp continuity allows half an
effective sample; serialized timestamps have MPV JSON's six decimal places.

This transport does not reset or certify the loudness accumulator after an
internally detected discontinuity. A future consumer must gate loudness history
and arrange filter restart where needed. It must also handle lifecycle changes
that occur entirely between polls, and filter destruction before a final read.
No snapshot proves whole-program completeness.

## Repeat the isolated build and capture

The [builder](../scripts/prototype-mpv-meter-history.py) requires the matching
local MPVKit static framework products, thin macOS `compile_commands.json`, and
exact corresponding mpv source. It rejects a changed source hash. It copies only
the instrumented translation unit, compiles against the existing generated
configuration, replaces the exact object member in a copied thin archive, and
links the [probe](../scripts/probe-mpv-meter-history.c). Framework aliases must
resolve to that replacement inside the copied framework. Original source, build
objects, products and the app's dependency remain untouched. Build evidence
records source/patch/header/compiler-command/library/probe hashes and commands.
This is not a clean dependency rebuild or distributable universal package.

```sh
python3 scripts/prototype-mpv-meter-history.py \
  --source /path/to/pinned/mpv-source \
  --compile-commands /path/to/matching/macos/scratch/arm64/compile_commands.json \
  --products /path/to/matching/static-framework-products \
  --output /private/tmp/amc-meter-history-candidate
```

Generate the repeatable lossless signal and two-track AAC fixture:

```sh
"Aagedal Media Converter/Binaries/ffmpeg" -v error -f lavfi \
  -i 'aevalsrc=if(lt(mod(t\,4)\,2)\,0.05\,0.2)*sin(2*PI*1000*t)|if(lt(mod(t\,4)\,2)\,0.05\,0.2)*sin(2*PI*1000*t):s=48000:d=24' \
  -c:a flac /private/tmp/amc-meter-history-fixture.flac
"Aagedal Media Converter/Binaries/ffmpeg" -v error \
  -i /private/tmp/amc-meter-history-fixture.flac -map 0:a -map 0:a -c:a aac \
  -metadata:s:a:0 title=First -metadata:s:a:1 title=Second \
  /private/tmp/amc-meter-history-aac.m4a
/private/tmp/amc-meter-history-candidate/probe \
  /private/tmp/amc-meter-history-aac.m4a null 2 \
  > /private/tmp/amc-meter-history-capture.jsonl
python3 scripts/analyze-mpv-meter-history.py \
  --input /private/tmp/amc-meter-history-capture.jsonl \
  --output /private/tmp/amc-meter-history-analysis.json
```

Repeat with `coreaudio` and `avfoundation`, holding the media constant. The probe
sets volume to zero, disables video and config-file loading, requests exactly the
named driver and fails if MPV reports a different driver or cannot initialize it.
Login-session audio access may be required. Omit the final audio ID for a single
track. The 12-second capture pauses at 2 seconds, resumes at 2.5, seeks to media
second 8 at 4, sets speed 1.5 at 6, removes/reinserts the meter at 8, and optionally
selects the second audio track at 10. These are stimuli, not assertions that the
commands achieved media/device synchronization. Rows include monotonic elapsed
receipt time, separately queried `time-pos` and `audio-pts`, actual speed, pause,
seeking and audio ID, requested-output confirmation, action phase and the history.
These property reads are sequential rather than an atomic player-state snapshot.

## Verification and retained evidence

Both arm64 and x86_64 candidate objects and probes build. The arm64 probe runs
with null, CoreAudio and AVFoundation; the x86_64 null probe runs through Rosetta.
Initial sandboxed hardware-driver attempts failed audio initialization; the same
muted probes succeed with permitted login-session audio-service access. Forced
driver substitution is rejected. The matching-input AAC runs are audio-only,
not the prior AAC/video app benchmark.

[Raw compressed captures and the hashed report](provenance/audio-meter-timestamps-2026-10-17/report.json)
retain all five final captures:

| Capture | Unique received frames | Observed epochs |
| --- | ---: | ---: |
| arm64 FLAC / null | 151 | 3 |
| x86_64 FLAC / null | 150 | 3 |
| arm64 AAC / null | 157 | 4 |
| arm64 AAC / CoreAudio | 150 | 4 |
| arm64 AAC / AVFoundation | 267 | 4 |

All have zero malformed/changed identities, received sequence gaps, timestamp
continuity breaks or rejection counters. Ring eviction is zero in these short
captures; sanitizer tests exercise repeated wraparound and explicit eviction.
Both pause values and playback speeds 1/1.5 appear. AAC runs record audio IDs
1 and 2. Post-seek epochs and post-reinsertion instances appear. Frame speeds
remain 1: these describe the measurement boundary, separately from the later
playback-speed setting. They do not prove speed-adjusted output alignment.

Every run has an initial snapshot without initialized history/output confirmation.
The analyzer deliberately returns `observed_history_complete: false`, and
`alignment_qualified: false` is unconditional. Its checks cover received snapshots
and observed epochs, excluding unseen reset boundaries and trailing frames. The
CLI reports malformed/gapped/discontinuous received history as failure while still
writing its report. Raw captures can be decompressed and reanalyzed with the same
commands above.

An independent known-signal check compares FLAC frame timestamps with alternating
amplitudes 0.05/0.2 every two seconds, whose expected peaks are about −26.0206 and
−13.9794 dBFS. Excluding frames that straddle transitions, all 148 arm64 and 147
x86_64 frames match within 0.02 dB (maximum error about 0.000013 dB). The report
retains counts, tolerance and fixture/FFmpeg hashes. This checks signal identity at
the recorded media timestamp, not when a device presented it. AAC is not compared
to ideal sine peaks because codec reconstruction changes them.

Portable queue tests compile with C11 warnings as errors, AddressSanitizer and
UndefinedBehaviorSanitizer. They verify copied ownership, repeat reads, bounds,
multiple ring wraps, eviction, exact size limits, rejected-sequence gaps and reset
counter retention. Analyzer tests cover valid lifecycle history, missing/invalid
records, changed duplicates, malformed timing, sequence gaps, backward counters/
epochs/instances, and receipt ordering. Existing audio benchmark parser regressions
also pass. No Swift/app UI behavior changed, so the prior app suite was not rerun.

## Remaining acceptance work

The dependency instrumentation milestone is complete as an experiment. Before
production use, expand matched app benchmarks with video on/off, delayed audio,
short impulses, pause/seek/track/source changes, multiple speeds and deliberate
polling stalls; verify overflow and discontinuity recovery against independent
signal transitions. Select and validate a presentation clock, retain future frames
until that clock reaches their interval, and derive loudness readiness from
continuous measured history. Reset the filter/accumulator when required. Full
packaging/provenance, longer Release CPU/thermal runs and physical loopback/device
synchronization remain separate work. Playback must keep its current qualification
and Source default until that evidence exists.
