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
4. **Speakers.** NeMo Speech's Sortformer v3 diarizer (`nemotron-3-diarization`,
   107 MB, downloaded on first use, up to eight speakers) runs only when speaker
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
  finder, but it needs a 107 MB download, so the bundled Silero model took over
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
(flexible length up to 40 s, fp16 computation) and writes two aligners,
`<id>.zip` with 8-bit weights and `<id>-float16.zip`, each with `aligner.json`
holding the vocabulary, blank and delimiter tokens. The app downloads the zip, checks its SHA-256 and
compiles it. `Install from File…` installs a zip directly.

| Aligner | Source | License | 8-bit | float16 |
|---|---|---|---|---|
| `nb-bokmaal-300m` | NbAiLab/nb-wav2vec2-300m-bokmaal-v2 | Apache-2.0 | 272 MB | 584 MB |
| `nn-nynorsk-300m` | NbAiLab/nb-wav2vec2-300m-nynorsk | Apache-2.0 | 271 MB | 584 MB |
| `sv-voxrex-large` | KBLab/wav2vec2-large-voxrex-swedish | CC0-1.0 | 271 MB | 584 MB |
| `en-base-960h` | facebook/wav2vec2-base-960h | Apache-2.0 | 81 MB | 175 MB |
| `de-xlsr53-large` | jonatasgrosman/wav2vec2-large-xlsr-53-german | Apache-2.0 | 274 MB | 583 MB |
| `es-xlsr53-large` | jonatasgrosman/wav2vec2-large-xlsr-53-spanish | Apache-2.0 | 274 MB | 583 MB |
| `fr-xlsr53-large` | jonatasgrosman/wav2vec2-large-xlsr-53-french | Apache-2.0 | 274 MB | 583 MB |
| `it-xlsr53-large` | jonatasgrosman/wav2vec2-large-xlsr-53-italian | Apache-2.0 | 274 MB | 583 MB |
| `pt-xlsr53-large` | jonatasgrosman/wav2vec2-large-xlsr-53-portuguese | Apache-2.0 | 274 MB | 583 MB |

All nine are hosted at
[huggingface.co/taagedal/wav2vec2-word-aligners-coreml](https://huggingface.co/taagedal/wav2vec2-word-aligners-coreml)
(2026-11-14; 8-bit and de, es, fr, it, pt added 2026-11-16), with a model card listing sources, revisions and licences. The app
downloads from a pinned commit (`AppConstants.wordAlignerDownloadBaseURL`), so a
later upload can't change what a released version gets; publishing a new
aligner means uploading it, then moving the pin and adding its SHA-256 and size
to `WordAlignerModel.allModels`. Every conversion matched PyTorch's best token on
every frame at 3 s and 17 s.

The default archives (`<id>.zip`) store weights as 8-bit integers (symmetric,
per output channel), about half the size; the float16 originals stay
available as `<id>-float16.zip`. Settings › Transcription › Aligner precision
picks which one is downloaded (default 8-bit), and the installed precision is
recorded in a `precision` file next to the model. Compared with the float16
conversions by forced
alignment over five minutes of `say` speech, character starts stayed within
one 20 ms frame (nb, nn, sv: all; en: 99.97%, at most 40 ms). On about a
minute of `say` speech per language (two voices), de, es and pt kept every
character within 20 ms, fr 99.92% (at most 40 ms) and it 99.91%, with one
character 420 ms away. 6-bit
palettization (226 MB) and 4-bit (151–169 MB) moved some characters by
0.4–0.5 s, so they are not used.

The German model has no ß (its training text wrote "ss"), so the aligner
spells out letters a vocabulary lacks: ß → ss, æ → ae, œ → oe.

Meta's MMS forced aligner covers 1,100 languages in one model but is
CC-BY-NC-4.0, so it is not used.

## Japanese, Chinese and Korean — 2026-11-16

Tested with `say` (Kyoko, Tingting, Yuna), the bundled filter and Whisper base and
large-v3, with and without speech-only VAD.

- **The filter returns phrases, not words, for Japanese and Chinese.** With
  `max_len` set, the filter also sets whisper.cpp's `split_on_word`, which splits
  only before tokens that start with a space. Japanese came back as 2–7 s phrases
  (`今日は東京で新しい映画祭が始まりました`), Chinese as whole sentences (base: one
  19 s line), with no timing inside. Korean has spaces and arrives word by word.
  `TranscriptWordSplitter` (`TranscriptScript.swift`) now splits these phrases
  with `NLTokenizer` and joins the pieces into units a line may break between:
  Japanese particles and endings stay on their word (`映画祭が`, `始まりました`),
  kanji and katakana compounds stay together, Chinese particles and measure words
  stay on theirs (`开始了`, `一个`). Each unit gets its share of the phrase's
  time by character count, before speech-only times are mapped back (a phrase
  across a removed pause would otherwise be clamped). The aligner then refines
  those times. Without an aligner, Japanese and Chinese timing is approximate
  within each phrase.
- Splitting in FFmpeg instead (a UTF-8-aware `split_on_word` in `af_whisper`)
  would give whisper.cpp's token times, which are rough without DTW, and needs a
  rebuild of the bundled FFmpeg; not done.
- **Whisper drops punctuation.** large-v3 left out most `。` in Japanese and
  wrote ASCII commas in Chinese. The end of each split phrase is marked
  (`TranscriptWord.endsPhrase`) and counts as a clause end, and ASCII `,.?!:;`
  after Han or kana become full-width (`、` in Japanese, `，` in Chinese).
  Sentence and clause ends include `。！？．` and `、，；：`.
- **Layout.** Words join without a space next to Han or kana (`TranscriptText`),
  Korean keeps its spaces. Line length scales from the Latin setting by the
  ratios in subtitle guidelines such as Netflix's: 13 characters for Japanese
  and 16 for Chinese and Korean at the default 42. Reading speed is 4, 9 and 12
  characters a second.
- **Script detection.** `TranscriptLanguage.resolve` already handles these
  languages: `NLLanguageRecognizer` returns `ja`, `zh-Hans`/`zh-Hant` (normalized
  to `zh`) and `ko`. The script comes from the language, or from the text when
  the language is unknown or not one of these.
- **Traditional Chinese.** Whisper base wrote Traditional characters for
  Mandarin speech; large-v3 wrote Simplified. `NLTokenizer` set to Simplified
  splits Traditional text into single characters, so the splitter picks the
  variant from the text.

### Aligners for ja, zh and ko (checked; only Korean is cleared)

| Model | Licence | Vocabulary | Training data |
|---|---|---|---|
| jonatasgrosman/wav2vec2-large-xlsr-53-japanese | Apache-2.0 | 2,155 kanji, kana, digits | Common Voice 6.1, CSS10, JSUT |
| jonatasgrosman/wav2vec2-large-xlsr-53-chinese-zh-cn | Apache-2.0 | 3,441 Simplified hanzi, A–Z, pinyin | Common Voice 6.1, CSS10, ST-CMDS |
| kresnik/wav2vec2-large-xlsr-korean | Apache-2.0 | 1,202 Hangul syllables | Zeroth-Korean |

- The model licences allow redistribution, but two training sets do not allow
  commercial use: ST-CMDS is CC BY-NC-ND 4.0, and JSUT's audio is free for
  non-commercial use only, with commercial users asked to contact its authors.
  Whether such terms reach a trained model is unsettled (Creative Commons reads
  NC as covering a shared model), and the app is used commercially, so the
  Japanese and Chinese models are **not used** (decided 2026-11-16). Korean's
  Zeroth-Korean is CC BY 4.0 and its model card must credit it. Without an
  aligner, Japanese and Chinese keep the splitter's timing.
- Korean is syllables, not jamo, so Hangul is looked up as is; syllables
  outside the 1,202 are skipped like other unknown characters.
- Coverage on the app's ja, zh-Hans and ko UI translations (55k, 31k and 42k
  characters): 0.09%, 1.0% and 0.5% of characters are missing from the
  vocabularies (rare kanji such as 梱, hanzi such as 帧, syllables such as 팁).
- The Chinese vocabulary has no Traditional characters, so `CTCForcedAligner`
  falls back to the `Hant-Hans` transform per character.
- Folding: Foundation's diacritic folding leaves precomposed kana alone (が stays
  が). Half-width katakana write voicing as a separate character (ｶﾞ), so a word
  containing them is widened as a whole first; per-character folding would have
  produced カ.
- Japanese and Chinese models were trained on text without spaces and never
  emit the `|` delimiter between words, so `CTCForcedAligner` puts it only where
  the text has a space (WhisperX aligns these languages per character for the
  same reason). Per-word alignment of the split units stays meaningful: each
  unit is a run of characters, and its range is the span of its characters.

## Next steps

- **More aligners:** Korean (kresnik, cleared above); Japanese and Chinese models
  trained only on data cleared for commercial use (Common Voice is CC0; check
  AISHELL-1 and each model's own training data); then Danish and Finnish from the
  WhisperX table, after checking licences.
- **Thai** also writes without spaces between words; the splitter could handle it
  with `NLTokenizer` once tested.
- **Simplified or Traditional Chinese** as a choice: Whisper picks either for
  Mandarin; a prompt or a `Hans-Hant` transform could make the output consistent.
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
