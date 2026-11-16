# String catalog language pass — 2026-11-16

A review of every non-English translation in
`Aagedal Media Converter/Resources/Localizable.xcstrings` for machine-translation
mistakes. It closes the backlog item "Language pass over the string catalog".

## What was checked

- All 2,741 keys on `main` at 0883e9bb, which includes the transcription strings from
  PR #118 (Whisper speech-only/Silero, word timing and aligner precision, speaker
  changes and NeMo, "Names and terms:", the "Ready (8-bit)" and "Replace (%@)" rows).
- Nine languages: de, es, fr, it, ja, ko, nb, pt-BR, zh-Hans. Plural variations were
  reviewed as well. The 17 keys marked `shouldTranslate: false` were skipped.
- Each string was read with its developer comment and, for strings of up to four words,
  the Swift line(s) that use it, so short labels were judged in context.
- Method: each language was split into two halves and reviewed by a separate agent
  (18 in all), which proposed fixes as JSON. A script applied them only when the
  current value matched, format specifiers were unchanged and the source ellipsis was
  kept. A second pass aligned terms between the two halves of each language and
  removed stray zero-width spaces. Random samples from every language were checked by
  hand before applying.
- Only wrong meanings, wrong word sense, wrong part of speech, broken grammar,
  confusing inconsistency, leftover English and broken formatting were changed.
  Stylistic preferences were left alone. Entry `state` was not changed: fixed
  machine translations stay `needs_review`, and Norwegian entries keep `translated`.

## Results

2,748 translations changed. The category columns count fixes; a few entries were
touched by both passes, so a row can add up to slightly more than its entry count.

| Language | Entries changed | Wrong sense | Meaning | Part of speech | Grammar | Terminology | Untranslated | Format |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| de | 468 | 113 | 51 | 183 | 75 | 37 | 9 | 0 |
| es | 331 | 93 | 86 | 52 | 62 | 31 | 8 | 0 |
| fr | 317 | 97 | 77 | 31 | 26 | 73 | 13 | 0 |
| it | 342 | 79 | 85 | 20 | 76 | 74 | 1 | 10 |
| ja | 216 | 94 | 48 | 25 | 12 | 29 | 4 | 6 |
| ko | 283 | 109 | 53 | 17 | 26 | 62 | 9 | 9 |
| nb | 105 | 10 | 17 | 1 | 51 | 16 | 10 | 0 |
| pt-BR | 308 | 54 | 80 | 65 | 45 | 53 | 9 | 2 |
| zh-Hans | 378 | 171 | 69 | 18 | 28 | 70 | 5 | 17 |
| Total | 2,748 | 820 | 566 | 412 | 401 | 445 | 68 | 44 |

The #118 transcription strings were already sound in every language; the only
change there is zh-Hans "Ready (8-bit)/(16-bit)" from 已就绪 to 就绪 to match "Ready".

## Error patterns

- **Wrong sense of a short English word.** The largest group, and worst in the oldest
  strings. Examples: ko Browse… "먹다…" (eat), OK "좋아요" (Like), Disabled
  "장애가 있는" (having a disability); zh Port "港口" (harbour), Run "跑步" (jogging),
  Zoom "飞涨" (prices soaring), Export "出口" (foreign trade); ja Run "走る",
  Architecture "建築" (a building); de Share (SMB) "Aktie" (stock), Bucket "Eimer";
  fr Colon "Côlon" (intestine), Back "Dos"; es Crop "cultivo" (farm crop), Dash
  "Estrellarse" (to crash); it Content Kind "Contenuto gentile"; pt-BR Jobs "vagas"
  (job openings), Endpoint "Ponto final" (full stop).
- **Clear, Run, Ready, Track, Watch, Wrap, Frame.** Clear became "bright" in fr, es,
  it and pt-BR ("Claro", "Clair…", "Chiaro"); "Ready" became a verb or a fragment
  (pt-BR "Preparar", ja "準備ができて", ko "준비가 된"); a watch folder became TV
  viewing or a wristwatch ("視聴", "ubicación del reloj", "dell'orologio"); MXF wrap
  became line wrap ("Umbruch", "换行", "줄바꿈") or looping ("bouclage"); video frames
  became picture frames or vehicle chassis ("cornici", "车架", "bilderammer").
- **Product names and technical tokens translated.** `brew install …` was translated
  into every language, AWS region IDs were localised ("ap-nordeste-1"), CLI flags
  ("--cpu-usado"), Resolve/Premiere became "Résolution/Première", IVF became in vitro
  fertilisation (pt-BR) and "Rec. 709" became "recording".
- **Wrong part of speech.** Buttons and toggles written as formal imperatives
  ("Überprüfen Sie die Tools", "Verifique…") instead of the infinitive macOS uses in
  de, es, fr and pt-BR; progress labels written as commands ("Analyser…" for
  "Analyzing…"). Italian keeps the imperative-style buttons macOS uses (Salva, Annulla).
- **Meaning reversed or lost.** ko said higher bitrates make files smaller; es/fr/pt
  counts put the number after the noun or said "or" for "of"; de "Verschlüsselt"
  (encrypted) for "encoded".
- **Inconsistent terms.** Trim and crop shared one word in several languages, Upload
  was "Téléchargement" (download) in French, Transcription was 転写 in part of the
  Japanese catalog, preset/track/bitrate/recording had several renderings each. Each
  language now uses the majority or human-reviewed term (listed per language in the
  PR).

## Left for a human

These were judged too uncertain, too stylistic, or need a code change.

- **Shared keys that need splitting in code:** "Center" is both the crop-centre button
  and the centre surround channel (all languages); nb "Collapse" is also the
  screen-capture tile's un-zoom tooltip; pt-BR "Start" is a time label and a play
  button.
- **Address form:** de mixes du (reviewed Tips, newer strings) and Sie (most strings;
  13 new strings moved to Sie); es mixes tú and usted, and Spain and Latin American
  forms (vídeo/video, Ajustes/Configuración, el/la Mac); zh uses 你 in three strings.
- **nb:** "Watch Folder" is left in English as a feature name while explanatory text
  says "overvåkingsmappe"; playhead has three terms; container is spelled three ways;
  Option key "Option" vs "Tilvalg"; Encode button "Konverter" vs "Kod"/"koding"; fps as
  "b/s"; scene cuts as "klipp".
- **Watch folder** has two or more accepted forms in es, fr and ja
  (e.g. "carpeta de vigilancia" vs "carpeta supervisada").
- **Smaller choices per language:** fr timecode vs code temporel, "assistant" for the
  MCP helper; it sonorità vs loudness, clip gender, cucire for stitching; ja 分析/解析,
  成長ファイル for growing files, 予約録画 for scheduled recording; ko comment as 댓글;
  zh 片段/剪辑 for clips, 边车文件 vs 附属文件 for sidecar, 屏幕采集 vs 屏幕捕获;
  pt-BR "Gravar" for burn-in.
- **fr typography:** about 445 values use a straight apostrophe; only the edited ones
  were changed to ’.
- **Fill/Fit** picker values are not in the catalog, so tooltips in some languages
  name them in English.
