# Photo Agent Whisper correction

Vendored from Aagedal Photo Agent's `scripts/ffmpeg/` and
`scripts/ci/test_ffmpeg_whisper_patch.py` at the user's request on 2026-10-13.
The patch modifies only FFmpeg's `libavfilter/af_whisper.c`.

The unmodified fixture is Copyright (c) 2025 Vittorio Palmisano, FFmpeg,
LGPL 2.1 or later. Its retained header and `COPYING.LGPLv2.1` cover the filter
and correction. The Photo Agent source package records the local correction
as LGPL 2.1-or-later. The fixture was originally extracted from its attributed
FFmpeg 9.0.1 archive; FFmpeg 9.0.2 has the same filter bytes.

- Original source SHA-256: `322a8d54baa69b74f91552ad809a43ad0e3934632b256adf2123e4325a3b85d6`
- Corrected source SHA-256: `eba0b4645581f5fd14f841f25b83550522d67d064aaa9fd752c828fa9ba38b71`

`prepare_whisper_source.py` admits only the original hash, applies the patch
with zero fuzz in an isolated directory, and refuses an existing output file.
The full stock build checks the original hash; the Photo Agent build accepts
only this original source or the already-corrected hash in its separate tree.

```bash
python3 scripts/ci/test_ffmpeg_whisper_patch.py
```

The harness compiles the actual patched escaping, transcription, and activation
functions with minimal dependency stubs and ASan/UBSan. It checks 63 JSON text
roundtrips, 14 fault/runtime scenarios, 11 timing cases, and 12 allocation points,
plus source-hash and overwrite refusal. It does not establish actual model
accuracy or the full FFmpeg/Whisper ABI. `tools/test_whisper_runtime.py` performs
real process checks separately, including GPU backend evidence and real AVIO
write failures. Timestamp discontinuities and arbitrary malformed backend data
remain outside the tested scope.

## Common VideoToolbox correction

Both full builds also apply Vincent Herbst's proposed upstream fix for the
reproduced `yadif_videotoolbox` teardown crash:
[FFmpeg PR 23850](https://code.ffmpeg.org/FFmpeg/FFmpeg/pulls/23850),
commit `732e3afeb3f4a35389edeccc4329256265519a56` (2026-07-19). The verbatim
upstream patch retains its authorship. The modified FFmpeg filter is LGPL 2.1
or later. This is a proposed upstream fix, not a claim of inclusion in 9.0.2.
It wraps the kernel invocation in an autorelease pool and removes two releases
of borrowed Metal objects; the deinterlacing algorithm stays the same.

- Original filter SHA-256: `dad7ff78662f5e6eda23e36a8f9fb4c155e6606d2dd8178df81063a657fb8d3c`
- Corrected filter SHA-256: `950f9acd1346a45171710c163d5f78c0673b0dcd59d57ee767b66919a07c7e37`

Both completion markers include this patch's hash. The recipe admits only these
source hashes and checks the corrected result after zero-fuzz application.
`tools/test_yadif_videotoolbox.sh` tests NV12/P010 hardware frames in frame/field
modes, checks frame counts, and requires successful process exit after teardown.
