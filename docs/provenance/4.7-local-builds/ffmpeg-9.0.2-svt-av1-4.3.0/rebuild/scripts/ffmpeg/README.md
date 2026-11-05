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
