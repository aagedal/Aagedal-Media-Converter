# Nonperiodic AAC startup matrix evidence

See the [method, diagnosis and limitations](../../audio-playback-aac-startup-validation-2026-10-17.md).
These are muted, isolated filter-boundary captures, not application-renderer or
physical-device synchronization qualification. Video-on uses `vo=null`.

`baseline-null/` retains eight arm64 cases using the unchanged timestamp-history
probe: six lossless cases pass, while both AAC cases fail exact startup coverage.
Every received frame still matches the version-2 per-channel sample peak/RMS
oracle. The first AAC interval begins at 0.021333 seconds.

`fixed/` retains the final supplemental decoder patch's 24 passing arm64 cases.
All six AAC cases begin at zero; all received frames match peak/RMS reference
samples. Short stalls recover fully; long stalls retain their expected loss. Build
records and a separate x86_64 AAC/video run are in the sibling
[AAC priming evidence](../audio-meter-aac-priming-2026-10-17/README.md).
Each report retains tool/probe/source/fixture hashes and every case's command,
acceptance checks, diagnostics and capture hash. Captures are original JSONL
streams compressed with xz. Fixture MOVs and executable products remain external.
Interrupted preliminary v1/v2 candidate captures are excluded.

To reproduce, build a new isolated candidate with the prototype builder and run:

```sh
python3 scripts/benchmark-mpv-meter-history.py \
  --probe /path/to/final/probe --ffprobe /path/to/matching/ffprobe \
  --output /private/tmp/new-nonperiodic-matrix \
  --drivers null coreaudio avfoundation
```

The builder's exact source/framework/compile inputs must match its retained build
record. Login-session audio access is required for the two hardware-output
backends; the outputs remain muted. Reanalysis needs the original hashed fixture
MOVs next to a copy of `report.json` and captures, plus the recorded tools; add
`--reanalyze` to the runner command. Reports without `signal_version` preserve
the original peak-only periodic reference model. A passing overflow case expects
missing records during the long polling stall and does not imply complete
measurement coverage.
