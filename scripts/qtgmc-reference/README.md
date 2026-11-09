# QTGMC reference (NumPy)

A slow, luma-only NumPy model of the Metal QTGMC pipeline in
`Aagedal Media Converter/Logic/Conversion/QTGMC/`. The stages, thresholds and
interpolators mirror `QTGMC.metal`, so changes can be evaluated before porting
them to the shaders.

- `nnedi_ref.py` — NNEDI3 prescreener + predictor following FFmpeg's `vf_nnedi.c`
  (matches `ffmpeg -vf nnedi` within one code value on 8-bit input).
- `qtgmc_ref.py` — bob/NNEDI3, search clip, hierarchical block motion search,
  MDegrain-style smoothing, resharpening, final smoothing and lossless de-combing.
- `eval.py` — builds progressive ground truth (a sub-pixel pan over a detailed
  texture, and FFmpeg's `testsrc2`), interlaces it, and reports PSNR, a
  temporal-flicker measure and each stage's result against FFmpeg's bwdif/yadif.
- `variants.py` — compares parameter variants.

Run from this directory (needs `numpy` and `ffmpeg` on `PATH`):

```sh
python3 eval.py 360 288 20      # width height progressive-frames
python3 variants.py
```

Results at 360×288, 16 fields (PSNR dB / flicker; higher / lower is better):

| clip | bwdif | QTGMC medium (lossless) | QTGMC slow-like (lossless, TR2=2) |
|------|-------|-------------------------|-----------------------------------|
| pan  | 28.12 / 14.12 | 33.02 / 8.05 | 33.37 / 7.73 |
| testsrc2 | 34.34 / 6.92 | 34.50 / 6.77 | 34.57 / 6.73 |
