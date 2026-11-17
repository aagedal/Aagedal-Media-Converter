# Whisper corrections (both full builds)

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

`prepare_whisper_source.py` applies the patch chain below with zero fuzz in an
isolated directory, checks the hash after each patch, and refuses an existing
output file. It admits only the original hash or a hash from earlier in the
chain, so a Photo Agent tree that already carries the canonical patch receives
only the remaining one. Both full builds (`full` for Media Converter and
`photo-agent`) apply the chain, each in its own source tree.

## Word details: `initial_prompt`, `p` and `language`

`af_whisper-word-details.patch` (local, LGPL 2.1 or later like the filter)
applies after the canonical patch for Media Converter's word pipeline
(`format=json:max_len=1`):

- `initial_prompt=<text>` (default empty = unchanged): sets whisper.cpp's
  `initial_prompt` with `carry_initial_prompt`. Each queue chunk is its own
  `whisper_full()` call without context, so the prompt starts every chunk, and
  carrying it keeps it in front of every 30 s decode window inside a chunk.
- Each JSON line gains `"p"` and `"language"` after `start`, `end`, `text`:
  `{"start":ms,"end":ms,"text":"…","p":0.8481,"language":"no"}`
  - `p` is the mean `whisper_full_get_token_p` over the segment's text tokens
    (ids below EOT; timestamp and special tokens skipped), clamped to 0–1 and
    printed with four decimals. It is `null` if the segment has no text token
    (whisper's empty `""` segments) or a probability is not finite.
  - `language` is `whisper_lang_str(whisper_full_lang_id())` for the chunk, so
    `language=auto` reports the detected code. It is `null` unless the code is
    lowercase ASCII.

Text and SRT output are unchanged. DTW token timestamps are not exposed: whisper.cpp
sets them per context with an alignment-heads preset that must match the model's
base architecture (large-v1 and large-v2 look identical to the filter, and fine-tuned
models such as NB-Whisper only inherit a preset), and 1.9.5 disables DTW whenever
flash attention is on (the default).

- Patched source SHA-256: `d27e7b5c3c110f599b5d43c16752aec832ad858bc601096fe4db5e7de0362615`

## Tests

```bash
python3 scripts/ci/test_ffmpeg_whisper_patch.py
```

The harness compiles the actual patched escaping, transcription, and activation
functions with minimal dependency stubs and ASan/UBSan. It checks 63 JSON text
roundtrips, 15 `p`/`language` cases (special-only, empty, NaN/infinite, clamped,
odd language codes), 4 prompt cases, unchanged text/SRT output, 14 fault/runtime
scenarios, 11 timing cases, and 12 allocation points, plus the source-hash chain
and overwrite refusal. It does not establish actual model
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

## libopenjpeg frame-size caps

`libopenjpegenc-max-size.patch` (local, LGPL 2.1 or later like the encoder) adds
two encoder options so DCP/IMF exports can honour bitrates other than the fixed
`-cinema_mode` limits (`-b:v` is ignored by this encoder):

- `-max_cs_size <int>`: maximum codestream bytes per frame (default 0 = unchanged)
- `-max_comp_size <int>`: maximum bytes per component (default 0; when only
  `max_cs_size` is set it becomes `max_cs_size / 1.25`, the libdcp ratio)

They are applied after the `cinema_mode` switch and `cinema_parameters()`, and
only take effect with `-profile cinema2k|cinema4k` or a `-cinema_mode`; OpenJPEG
clamps them to the 24 fps limits. Because OpenJPEG's rate allocation can
overshoot its target by a few bytes, a set `max_cs_size` makes the encoder
re-encode with a tighter target until the codestream fits. With both options
unset the encode path and output bytes are unchanged.

- Original encoder SHA-256: `6b6bf1241f3606f83929920d08d576e33f88ddb76fa682d98c3cb0ae3d41bef7`
- Patched encoder SHA-256: `9c5e75a7941888a2cf4972c21a9481a0f5d7c3791dcb210e1512d8e014a19c39`

The full and Photo Agent builds apply it with zero fuzz; minimal and photo do not
enable libopenjpeg. Both completion markers include the patch hash.

## libopenjpeg IMF profiles

`libopenjpegenc-imf.patch` (local, LGPL 2.1 or later) applies on top of
`libopenjpegenc-max-size.patch` and lets the encoder write ISO/IEC 15444-1 Amd 8
IMF profile codestreams for ST 2067-21 (IMF App 2e):

- `-profile imf_2k|imf_4k|imf_8k` (lossy, 9/7) and `imf_2k_r|imf_4k_r|imf_8k_r`
  (reversible, 5/3) set Rsiz to `OPJ_PROFILE_IMF_*` (0x0400–0x0900)
- `-imf_mainlevel <-1..11>` (default -1): derived from the component sample rate
  (luma plus subsampled chroma × frame rate) against OpenJPEG's
  `OPJ_IMF_MAINLEVEL_*_MSAMPLESEC`, then raised if the sub level needs it
  (ISO/IEC 15444-1 Table A.53)
- `-imf_sublevel <-1..9>` (default -1): derived from `max_cs_size` × 8 × frame
  rate against `OPJ_IMF_SUBLEVEL_*_MBITSSEC`, or 0 without `max_cs_size`. An
  explicit sub level without `max_cs_size` sets `max_cs_size` to the sub level's
  bitrate ÷ frame rate, like `opj_compress -IMF …,sublevel=Y,framerate=FPS`

OpenJPEG 2.5.4 (`opj_j2k_set_imf_parameters`) then sets 32×32 code blocks,
CPRL, one tile part per component with TLM, 256×256 precincts (128×128 for NLLL),
caps the decomposition levels and forces the 9/7 wavelet for lossy profiles, so
`-irreversible 1` is not needed. `opj_j2k_is_imf_compliant` checks the result. If
it rejects the parameters (for example a 2K profile at 3840×2160, `imf_2k_r` with
`-irreversible 1`, an alpha channel or a non-CPRL `-prog_order`), OpenJPEG would
silently write Rsiz 0. The encoder fails the frame instead. Inconsistent levels,
bitrates or `cinema_mode` fail at init.

`max_cs_size`/`max_comp_size` now also apply to IMF profiles, with the same
re-encode-until-it-fits guarantee as for the cinema profiles. They are not clamped
to the DCI 24 fps limits. `-b:v` stays ignored: the app already passes it, so
honouring it would change existing output.

- Patched encoder SHA-256 (after both patches): `740027d284ec225b67220fa7bd970f1cf6be953953d558a223e2c7c96fdcbb12`

With no IMF profile and no IMF level option, encoding is byte-identical to the
max-size-only build, and the cinema profiles are unchanged. Both completion
markers include this patch's hash.

## MOV `fiel` for H.264

`movenc-h264-fiel.patch` (local, LGPL 2.1 or later like the muxer) changes one
condition in `mov_write_video_tag()` in `libavformat/movenc.c`. Stock FFmpeg
writes the QuickTime `fiel` atom for most video codecs but skips H.264, so a
stream copy of interlaced H.264 to `.mov` has no field information in the
`avc1` sample entry. That includes Panasonic P2 AVC-Intra 50/100 1080i, which
Media Converter rewraps from MXF. QuickTime, Final Cut Pro and Resolve may
then treat the file as progressive, although `ffmpeg -i` reports "top first".

With the patch, H.264 in MOV mode (`track->mode == MODE_MOV`) gets `fiel` like
the other codecs, from the stream's field order:

| Field order | `fiel` |
|---|---|
| progressive | `0x0100` |
| top first (`tt`) | `0x0201` |
| bottom first (`bb`) | `0x0206` |
| `tb` / `bt` | `0x0209` / `0x020e` |
| unknown | not written |

MP4, 3GP, ISMV and other ISO BMFF modes are unchanged, because `fiel` is not
part of ISO BMFF. MPEG-4 Part 2 and DNxHD are unchanged too.

- Original muxer SHA-256: `f4303c1c2313c590919ddcdcfac41ab1fc3d78c9a8a032462d6d83f6e767bea7`
- Patched muxer SHA-256: `960097131ea278459a9ee75dfa3d5b2428960388370f66724f9375e648fcf99e`

Both full builds apply it with zero fuzz, like the YADIF correction, and both
completion markers include its hash. Minimal and photo are unchanged. After
compiling, `12-ffmpeg.sh` runs the regression check against the new binary:

```bash
python3 scripts/ci/test_movenc_fiel.py --ffmpeg dist/9.0.2/full/ffmpeg
```

It encodes top-first, bottom-first and progressive H.264 with libx264 as raw
Annex B, so the field order comes from the bitstream, and stream copies each to
`.mov` and `.mp4`. It also encodes top-first AVC-Intra 100 into MXF, as on a P2
card, and stream copies it to `.mov` (`ai15` sample entry). It walks the atoms
down to the sample entry and requires `fiel` 0x0201/0x0206/0x0100 in MOV, no
`fiel` in MP4, and an ffprobe field order of `tt`/`bb`/`progressive`. A stock
9.0.2 binary fails every MOV case. On the AVC-Intra MOV it has no `fiel`, and
its own ffprobe reports `progressive`.

The patch writes the stream's field order as is. When ffmpeg itself encodes
interlaced video, its CLI labels the result `tb`/`bt` (top/bottom first,
interleaved). An H.264 encode or a container that keeps that label, such as
MKV, therefore gets `0x0209`/`0x020e` in MOV, as ProRes already does. That is
QuickTime's interleaved "spatial first line early/late" detail. Stream copies
from MXF or raw H.264 take the order from the bitstream (`tt`/`bb`).
