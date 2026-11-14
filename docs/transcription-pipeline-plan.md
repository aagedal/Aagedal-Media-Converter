# Transcription pipeline (Whisper) — 2026-11-14

Whisper transcription now runs as a word-level pipeline instead of letting the
FFmpeg filter write the SRT. The shape follows WhisperX (BSD-2), which pairs
voice activity detection, Whisper, wav2vec2 forced alignment and diarization:

1. **Speech only.** Silero VAD (MIT, `ggml-silero-v6.2.0.bin`, 885 KB, bundled
   in Resources) finds the speech. `SileroVoiceActivityDetector` is a Swift port
   of whisper.cpp's VAD that reads the same ggml file. The pipeline writes the
   speech back to back into a 16 kHz WAV, so Whisper never hears long silence
   or music, then maps Whisper's timestamps back onto the source. If Silero
   cannot run, speaker detection's segments are used when they exist.
2. **Whisper.** The FFmpeg filter writes one JSON line per word
   (`format=json:max_len=1`). With speech-only on, it also gets the Silero
   model, which makes each 20 s queue end in a pause instead of mid-word.
   Our FFmpeg build (ffmpeg-apple-silicon PR #7, `af_whisper` patches) writes
   `{"start":ms,"end":ms,"text":"…","p":0.81,"language":"no"}` with proper
   escaping, and takes `initial_prompt`, which conditions every chunk. The
   Names and terms setting feeds that prompt; the detected language picks the
   aligner when Language is Auto. `p` (mean token probability) is not used
   yet; it is meant for flagging uncertain words in a live transcript.
   DTW token timestamps were left out: they need a per-model alignment-heads
   preset and are off while flash attention is on.
3. **Word timing.** A wav2vec2 CTC model for the transcript's language, converted
   to Core ML, gives per-frame character probabilities; `CTCForcedAligner` runs
   Viterbi over them to place every word. Without an aligner for the language,
   Whisper's own timing is kept.
4. **Speakers.** NeMo Speech's Sortformer diarizer (`nemotron-3-diarization`,
   112 MB, downloaded on first use, up to four speakers) runs only when speaker
   changes are on. Each word gets the speaker whose segments overlap it
   most. The cue builder then uses dialogue dashes ("– " on each line when two
   speakers share a cue) or speaker names.

`SubtitleCueBuilder` lays out every cue: line length (the old "Max line length"
setting, which the filter ignored), two lines, reading time, sentence and clause
breaks, and dialogue. Each refinement step falls back silently, so a run always
produces subtitles.

Code: `Logic/Transcription/`. Settings: Transcription › Whisper › Speech, Timing
and Speakers. Defaults: speech only on, word timing on, dialogue dashes.

## Findings that shaped the design

All on a synthetic clip with a known layout (two `say` voices, 4 s or 6 s pauses).

- The filter's `vad_model` only chooses where each queue ends. It does not remove
  silence, so the next chunk starts with the pause and Whisper places its first
  word at the chunk start: 3.6 s for speech that begins at 7.7 s. Hence our own
  speech-only audio rather than relying on the filter's VAD.
- Diarization ran 12 minutes of audio in 10 s on an M-series GPU, and its
  speech regions were within 0.25 s of the truth. It was the first speech
  finder, but it needs a 112 MB download, so the bundled Silero model took over
  and diarization is only used for speakers.
- The Swift Silero port matches whisper.cpp 1.9.2 (built from the FFmpeg build's
  static libraries): probabilities within 0.021 (whisper.cpp rounds convolution
  input to fp16), identical segments on the test dialogue and 52 of 53 on a
  12-minute clip, where one near-threshold pause split differently. It runs
  12 minutes of audio in 0.15 s on the CPU.
- Without alignment, Whisper word starts after a pause were 0.6–1.6 s early.
  With the full pipeline, cue starts landed within 0.05–0.2 s.
- NB-Whisper large, plain, compressed a hard final sentence into an invented
  "En kjent notator omtalte det." and stretched the previous cue 2.3 s into the
  next speaker; the speech-only run kept the cue boundary and more of the text.
- Core ML fp16 conversion of `NbAiLab/nb-wav2vec2-300m-bokmaal-v2` matches
  PyTorch: max |Δ log p| 0.013, identical argmax at untraced lengths.

## Aligner models

`scripts/convert-wav2vec2-coreml.py` converts a Hugging Face `Wav2Vec2ForCTC` model
(flexible length up to 40 s, fp16) and writes `aligner.json` with the vocabulary,
blank and delimiter tokens. The app downloads the zip, checks its SHA-256 and
compiles it. `Install from File…` installs a zip directly.

| Aligner | Source | License | Archive |
|---|---|---|---|
| `nb-bokmaal-300m` | NbAiLab/nb-wav2vec2-300m-bokmaal-v2 | Apache-2.0 | 584 MB |
| `nn-nynorsk-300m` | NbAiLab/nb-wav2vec2-300m-nynorsk | Apache-2.0 | 584 MB |
| `sv-voxrex-large` | KBLab/wav2vec2-large-voxrex-swedish | CC0-1.0 | 584 MB |
| `en-base-960h` | facebook/wav2vec2-base-960h | Apache-2.0 | 175 MB |

All four are hosted at
[huggingface.co/taagedal/wav2vec2-word-aligners-coreml](https://huggingface.co/taagedal/wav2vec2-word-aligners-coreml)
(2026-11-14), with a model card listing sources, revisions and licences. The app
downloads from a pinned commit (`AppConstants.wordAlignerDownloadBaseURL`), so a
later upload can't change what a released version gets; publishing a new
aligner means uploading it, then moving the pin and adding its SHA-256 and size
to `WordAlignerModel.allModels`. Every conversion matched PyTorch's best token on
every frame at 3 s and 17 s.

Meta's MMS forced aligner covers 1,100 languages in one model but is
CC-BY-NC-4.0, so it is not used.

## Next steps

- **More aligners:** Danish, Finnish and German from the WhisperX table, after
  checking licences.
- **Nemotron and Parakeet** can feed the same cue builder: `nemo-speech transcribe
  --format json --diarize` already returns words with speakers, and parakeet-mlx
  has word timestamps in its JSON output.
- **Live transcript.** The filter appends words to its JSON file while it runs.
  Reading that file as it grows (mapped through `SpeechRegionMap`) would let the
  queue show the transcript as it forms, so a wrong language, model or audio track
  can be stopped after seconds instead of after the whole file.
- **Corrections while it runs.** With a live transcript, the user could fix names
  and terms as they appear; corrections would apply to the rest of the run as
  prompt text (the filter's `initial_prompt` already conditions each chunk, but
  is fixed for the run) and to the finished words as replacements.
- **Clean-up with Apple Foundation Models (macOS 27+).** After alignment, an
  optional on-device pass could correct names, places and punctuation using the
  user's context and corrections. It must only rewrite word text, never timing,
  so the aligned cues stay intact.
- **Export.** A word-level JSON or VTT (`<v Speaker 1>`) sidecar would make the
  transcript usable outside subtitles.
