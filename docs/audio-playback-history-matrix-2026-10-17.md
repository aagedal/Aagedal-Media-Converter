# Playback timestamp-history matrix — 2026-10-17

The [AAC startup continuation](audio-playback-aac-startup-validation-2026-10-17.md)
adds a nonperiodic peak/RMS oracle and investigates the startup failure below.
The results in this record retain their original periodic stimulus.

This continues the [isolated dependency prototype](audio-playback-timestamp-prototype-2026-10-17.md).
It tests received decoder-frame history against independently decoded source
samples. The application, package pin, bundled dependencies and notices are unchanged.
Source remains the default meter. No presentation clock has been selected or
qualified, and this experiment does not establish audible synchronization.

## Repeatable capture

The expanded [probe](../scripts/probe-mpv-meter-history.c) retains the original
12-second lifecycle scenario. Optional `--steady` captures 18 seconds without
lifecycle commands. `--video` selects video with `vo=null`: MPV decodes and
synchronizes that stream without creating a display window. This exercises a
video playback path, not the application's renderer. Video-off cases explicitly
require no selected video track. All output remains muted.

In steady mode, `--short-stall` withholds metadata reads from elapsed seconds
2–6; `--stall` withholds them from seconds 2–16. Events continue draining.
These are consumer polling stalls, not player suspension. The two durations
exercise retention within and beyond the 128-record ring at the observed
100 ms media cadence. Property read start/end times bound the sequential reads;
the existing receipt field precedes those reads. Neither is a device timestamp.

The [matrix runner](../scripts/benchmark-mpv-meter-history.py) generates 30-second
stereo audio in a 31-second MPEG-4 video MOV. The left channel alternates sine
amplitudes 0.05/0.2 every two seconds; the right has 1 ms, amplitude-0.5 impulses
at odd media seconds relative to the audio start. It generates lossless PCM,
the same PCM delayed 750 ms, and AAC versions. Each file is held constant when
comparing video on/off. Audio delay is assigned with `asetpts` and the decoded
reference start is asserted before capture. Separate four/fourteen-second stall
runs use lossless PCM. `--cases delayed` can rerun only the offset cases.

The bundled FFmpeg decodes an independent float PCM reference. An explicitly
supplied ffprobe records the first decoded sample timestamp. The oracle compares
every unique received frame's per-channel peak with samples at its recorded
media interval, with a 0.05 dB tolerance and exact negative-infinity silence.
This reference model is limited to the generated continuous, fixed-rate stereo
fixtures; it does not model internal source timestamp gaps or layout changes.
AAC uses its reconstructed reference, not ideal sine amplitudes.

The signal repeats every four seconds. Peak agreement therefore cannot exclude
a timestamp error by a whole signal period. This is a bounded signal-consistency
check, not proof that every possible timestamp error would be detected.

Rebuild the probe with the original prototype builder and matching dependency
inputs, then run:

```sh
python3 scripts/benchmark-mpv-meter-history.py \
  --probe /path/to/isolated/probe \
  --ffprobe /path/to/ffprobe \
  --output /private/tmp/amc-history-matrix \
  --drivers null coreaudio avfoundation
```

The output directory must be new. The runner records commands, tool/source and
fixture hashes, compressed captures, signal comparisons, coverage checks and
clock diagnostics. Each case passes only with a successful probe, at least
150 checked frames, at least 16 seconds of measured media coverage, an initial
frame at the reference start and a receipt after 17.5 seconds. Normal and short
stall cases must include every expected impulse in that received span. Steady
runs must retain one instance/epoch, no rejected or invalid frames, and no
continuity breaks between adjacent sequences. Long stalls require missing
sequences localized between the pre-stall receipt and the first post-stall
receipt, plus subsequent continuous history. Loss is explicitly expected; a
passing overflow test does not mean complete measurement coverage.

Use the same arguments with `--reanalyze` to reevaluate an existing output
directory without replay. Reanalysis requires the generated MOV files and
verifies the recorded tool, fixture and capture hashes before decoding, and
records the current analyzer/runner hashes. Both legacy gzip and current xz
captures are readable.

## Results and verification

All 24 muted arm64 captures finish successfully: eight cases each for null,
CoreAudio and AVFoundation. All received frames match the independent per-channel
sample-peak oracle within 0.05 dB. There are no rejected records, malformed frames,
unexpected steady resets or adjacent-sequence timestamp discontinuities.

Eighteen lossless cases pass every final acceptance check. The six AAC cases
fail initial coverage: the first received interval starts at 0.021333 seconds,
whereas the independent decoded reference starts at zero. This is approximately
1,024 samples at 48 kHz. The remaining frames match their timestamped reference
windows; this does not recover or certify the unmeasured prefix. The cause of
the startup discrepancy remains unresolved. The final runner and reanalysis
exit nonzero for these evidence sets, deliberately retaining the failed
acceptance results. Initial runs used a looser startup tolerance; only the final
retained reports apply the exact initial-sample coverage requirement.

All three four-second stalls recover every sequence and expected impulse.
Fourteen-second stalls lose twelve records with null, thirteen with CoreAudio,
and twelve with AVFoundation. Those gaps are localized to the withheld-read
period, with continuous adjacent frames afterward. Ring eviction also occurs
during ordinary polling without received gaps: eviction alone is not reader loss.

For matched lossless video files, median newest-frame start minus `time-pos`
is approximately 0.16–0.23 seconds with CoreAudio and 3.50–3.75 seconds with
AVFoundation; null is about 0.30–0.37 seconds. Video-on uses `vo=null`.
The similarly large AVFoundation offset also appears against `audio-pts`.
These findings isolate output choice more closely than the earlier mixed
AAC/video-versus-FLAC comparison, but do not identify a physical presentation
clock or justify subtracting a fixed delay.

[Null evidence](provenance/audio-meter-history-matrix-2026-10-17/report-null.json),
[hardware-output evidence](provenance/audio-meter-history-matrix-2026-10-17/report-hardware.json)
and [build/capture details](provenance/audio-meter-history-matrix-2026-10-17/README.md)
retain the final source hashes and original JSONL streams compressed with xz.
The independent lifecycle regression succeeds with video selected, retaining its
existing caveats about unobserved boundaries and heuristic reset attribution.

All 151 Python script tests pass with permitted local endpoint access, including
21 focused queue/analyzer/oracle/fixture tests and the ASan/UBSan queue checks. The initial
sandboxed full run failed four existing MCP endpoint tests; the permitted rerun
passes. The muted hardware probes likewise initially failed sandboxed audio
initialization and succeeded with login-session audio access. The expanded C probe
builds with `-Wall -Wextra -Werror`. The final focused suite and whitespace check
pass. A final fixture hash audit caught an initial `-itsoffset` stimulus whose
offset was discarded during muxing. All six offset cases were rerun with
`asetpts`, and a real bundled-FFmpeg regression now checks that the delayed MOV
starts at 750 ms and differs from the baseline. Only those corrected offset
captures are retained. No Swift/app behavior changed, so the app build/UI suite was not rerun.

## Interpretation and remaining work

`frame.start - time-pos` and `frame.start - audio-pts` are diagnostic offsets
of the newest received frame. The report records minimum, median and maximum,
plus sequential property-read spans. These are not latency or physical
presentation measurements. Startup snapshots can lack history/output state.
The existing lifecycle completeness field is not used as steady-run acceptance:
it expects actions and resets that this scenario deliberately does not perform.

The analyzer now rejects malformed clock/read intervals, reports nonzero-epoch
boundary coverage as unknown, and distinguishes missing sequences from timestamp
discontinuities among adjacent received frames. Its lifecycle action-to-reset
attribution remains heuristic; unobserved reset boundaries and final frames
remain uncertified.

App integration, source replacement, stronger lifecycle acknowledgments,
AAC startup-history coverage, nonperiodic signal fixtures, presentation-clock selection, future-frame buffering,
continuous loudness readiness/reset, longer Release CPU/thermal tests and
physical loopback/device synchronization remain open. Neither these tools nor
a passing matrix justify changing Playback's current timing caveat or default.
