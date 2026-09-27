# Aagedal Media Converter

[English](../../README.md) · [Norsk bokmål](README.nb.md) · [Español](README.es.md) · [简体中文](README.zh-CN.md) · [Français](README.fr.md) · [Italiano](README.it.md) · [Deutsch](README.de.md) · [日本語](README.ja.md) · [Português (Brasil)](README.pt-BR.md) · [한국어](README.ko.md)

<img alt="Aagedal Media Converter" src="https://github.com/user-attachments/assets/213e64a6-f382-4562-b4cf-797ad1e0f368" />

En lett og minimalistisk macOS-app som er enkel på overflaten, men har mange kraftige funksjoner. Bygger på FFmpeg, MPV, SwiftMediaMetadata, yt-dlp, rclone og whisper.cpp, og er skrevet helt i Swift / SwiftUI.

Helt gratis og med åpen kildekode. Privat og lokal. En valgfri oppdateringssjekk er aktivert som standard, men kan slås av.

Et lidenskapsprosjekt: Jeg laget appen for meg selv for å jobbe mer effektivt, og ville dele den med andre. Merk at det meste av appen er «vibe-kodet» med KI-assistanse.

---

## Installasjon

### Homebrew
```bash
brew tap aagedal/tap && brew install --cask aagedal-media-converter
```

### Manuell nedlasting
[Last ned gjeldende versjon](https://github.com/aagedal/Aagedal-Media-Converter/releases/latest)

---

## Hovedfunksjoner

- **Rask å starte og enkel å bruke**
- **Konverter i grupper** nesten alle video- og lydfiler (alternativ til Shutter Encoder eller Handbrake)
- **Spill av** i fullskjerm med tidskode og JKL-kontroller (alternativ til IINA eller VLC)
- **Vis og sammenlign metadata**, inkludert sjekk for C2PA (alternativ til MediaInfo)
- **Last ned** videoer fra nettsteder, med planlegging og nedlasting av direktesendinger
- **Ta opp skjermen** med systemlyd og valgfritt separat mikrofonspor (alternativ til OBS)
- **Transkriber** video og lyd til SRT-undertekster
- **Last opp** til en server etter konvertering

- **Sett sammen** klipp i en tidslinje med sekvensforhåndsvisning og ripple-trimming
- **Automatiser konverteringer med lokal MCP** og valgfri agenttilgang

### Generelt

- Forhåndsvis og kod nesten alle videofiler
- Importer og eksporter **bildesekvenser** (PNG, TIFF, EXR, DPX, JPEG 2000 m.m.) med tilknyttet lyd og kontroll over bildefrekvens
- Eksporter **DCP (Digital Cinema Package)** med JPEG 2000 XYZ-bilde og PCM-lyd
- Eksporter eksperimentelle **IMF App 2e- og RDD 45**-pakker for validering i leveringsverktøyet
- Gruppekonvertering, overvåket mappe og fremdriftslinje
- Trim, beskjær, omruter eller fjern lydspor, og slå sammen klipp i samme format
- Vis og sammenlign metadata
- Mange [tastatursnarveier](../../KeyboardShortcuts.md): de fleste funksjoner kan brukes uten mus
- Mange innstillinger for tilpasning
- Automatisk oppdateringssjekk med diskret varsel, som kan slås av
- Last ned fra YouTube, TikTok osv. (yt-dlp)
- Transkriber til SRT (whisper.cpp)
- Last opp til FTP (rclone)
- Sjekk C2PA-signatur (SwiftMediaMetadata)
- Skjermopptak i HDR med systemlyd og valgfri mikrofon på et eget lydspor

### Gruppekonvertering

- Kod automatisk alle filer i køen
- Endre koderekkefølgen ved å dra og slippe filer
- Fjern filer fra køen mens kodingen pågår

### Overvåket mappe

- Importer automatisk filer fra en angitt mappe
- Kan brukes samtidig med manuell dra-og-slipp-import; alle jobber samles i ett vindu
- Valgfri automatisk sletting og ignorering av filer i mappen
- Aktiver med øyeikonet i verktøylinjen i hovedvinduet

### Forhåndsvisning

- Vanlige redigeringssnarveier som JKL og piltaster
- En enkel lydmåler (⌘A)
- Bruker den innebygde macOS-spilleren for kompatible filer, med jevn avspilling også baklengs
- Bytter automatisk til MPVKit for filer macOS ikke støtter direkte, men baklengs avspilling er mindre pålitelig

### Raske justeringer

- Trim med håndtak eller tastene I/O
- Kopier tidskode fra kilden, angi den manuelt eller fjern den
- Beskjær med kontroller på skjermen; trykk C eller beskjæringsikonet i trimvisningen
    - Fungerer ikke med Stream Copy-forvalget
- Slett eller endre rekkefølgen på lydspor
    - Fungerer ikke med Stream Copy-forvalget

### Slå sammen filer i køen

- Slå sammen filer med samme kodek, oppløsning, bildefrekvens, bitdybde og lydspor
- Første klipp i køen bestemmer tidskode og beskjæring
- Rediger grupper i tidslinjen med filmstriper, sekvensavspilling, ripple-trimming, omorganisering, splitting, områdesletting og angre.
- Trim og slå sammen med Stream Copy uten omkoding. Kuttene avhenger av kildens nøkkelbilder og kan avvike fra valgte grenser; noe metadata kan gå tapt.
- Eksporter Resolve EDL-klippmarkører og innebygde kapitler, med valg om å beholde eller erstatte eksisterende kapitler.

### Import fra kamerakort

- Se gjennom klipp etter kortmappe og opptaksdato før import.
- Merk fortsettelser av opptak eksplisitt, og del eventuelt grupper etter opphold på over to timer. Kompatibilitetssjekker hjelper deg å finne klipp som kan settes sammen.

### Lokal agenttilgang

Aktiver **Settings → Agent Access**, godkjenn kildemapper og kopier oppsettet for MCP-klienten din. Den medfølgende hjelperen lar agenter bla gjennom og undersøke godkjente medier, planlegge konverteringer, sende inn jobber, følge fremdrift og avbryte arbeid i appens kø. Alle 17 innebygde forvalg er tilgjengelige; egendefinerte FFmpeg-forvalg er unntatt. IMF-eksport er eksperimentelt.

Godkjente jobber fortsetter etter at klienten kobler fra. Planer er gyldige i 15 minutter, og resultater fra avsluttede jobber er tilgjengelige i 30 dager. Agenteksport deaktiverer utgående tidskode. Se [oppsetts- og arbeidsflytveiledningen](../../Documentation/LOCAL_AGENT_ACCESS.md) for mappegodkjenning, klientoppsett og gjenoppretting av jobber.

### Animerte lydbølgeformer

- Lag animerte bølgeformer fra filer som bare inneholder lyd
- Fem forvalg med farge- og normaliseringsalternativer

### Skjermbilder med kildens oppløsning og bitdybde

Kameraknappen i trimspilleren tar stillbilder med kildens oppløsning. Standardformatet er JPEG XL. Format kan velges separat for hver bitdybde i innstillingene, som også har alternativer for video med alfakanal.

### Eksport og filnavn

- Som standard fjernes mellomrom og spesialtegn. æ, ø og å erstattes med ae, o og aa.
- Forhåndsvisning av det behandlede filnavnet
- Varsel hvis filen allerede finnes
- Etter koding kan et ikon vise den konverterte filen i eksportmappen
- Et annet ikon lar deg dra den ferdige filen til en annen app eller mappe
- Velg standardforvalg i innstillingene
- Velg standard eksportmappe

### Metadata

- Kommentarfelt per fil for valgfri metadata, for eksempel kreditering
- Valgfri datotagg (Generated [YYYYMMDD]), prefiks og suffiks i kommentarfeltet før kommentaren
- Vis og sammenlign metadata

### 15-sekundersvarsel for automatisk avspilling med VideoLoop

Nettlesere nekter ofte å spille av lange sløyfevideoer med lyd automatisk. Appen viser et gult ⚠️-ikon når VideoLoop-forvalg brukes på klipp over 15 sekunder, slik at du kan trimme eller velge et annet forvalg.

### App Intents

1. Legg til i kodekøen.
2. Konverter video umiddelbart med standardforvalget.

---

## Eksportforvalg

Alle forvalg kan brukes som standard ved oppstart. Alle unntatt standardforvalget kan skjules i forvalgsvelgeren.

#### Video Loop

For sømløse, lydløse sløyfer. Koder med x264 ved CRF 23 (omtrent 3–9 Mbps variabel bitrate), fjerner lyd og begrenser korteste side til 1080 piksler for avspilling på nett. Et varsel vises når klippet er over 15 sekunder.

#### Video Loop w/ Audio

Samme x264-innstillinger som den lydløse sløyfen, men beholder alle lydspor som AAC ved 128 kbps. Korteste side begrenses fortsatt til 1080 piksler.

#### H.264 / AVC

Bredt kompatibel H.264/AVC-koding. Velg rask maskinvarekoding med VideoToolbox eller kvalitetsorientert programvarekoding med libx264 og CRF-kontroll. Støtter MP4, MOV og MKV.

#### H.265 / HEVC

Moderne 10-bit H.265/HEVC-koding. VideoToolbox gir rask maskinvarekoding, mens libx265 kan velges for høy komprimeringseffektivitet.

#### AV1

SVT-AV1-koding med støtte for 10 bit og høy komprimeringseffektivitet. Kun programvarekoding, uten maskinvareakselerasjon på macOS.

#### AV2 (eksperimentelt)

Eksperimentell AV2-koding med den medfølgende AOM AVM-referansekoderen (`avmenc`), introdusert i en forhåndsversjon. Støtter 8/10 bit, konstant kvalitet eller variabel bitrate, samt justerbar hastighet og oppløsning. Parallell koding i segmenter bruker flere CPU-kjerner i modusen for konstant kvalitet.

Velg IVF (`.ivf`) med bare video eller Matroska (`.mkv`) med AAC- eller Opus-lyd. Referansekoding er svært treg, og bitstrømmen er under utvikling og krever en AV2-kompatibel dekoder. Appen kan dekode AV2 for konvertering og miniatyrbilder, men støtter ennå ikke interaktiv avspilling. Bruk AV2 til eksperimentering fremfor levering.

#### TV (HEVC 10-bit 4:2:2)

Leveringsformat for kringkasting med maskinvarekodet HEVC 10-bit 4:2:2, justerbar oppløsning og bildefrekvens, automatisk tilpasning av bitrate og alle lydkanaler bevart som 24-bit PCM.

#### TV (AVC-Intra)

Kringkastingsformat i MXF. AVC-Intra 10-bit 4:2:2 med valgbare klasser (50/100/200 Mbps), oppløsning og bildefrekvens, samt 4/8/16 monokanaler med 24-bit PCM.

#### Stream copy

Kopierer eksisterende lyd- og videostrømmer til en ny fil og bevarer opprinnelige kodeker, metadata og filendelse. Passer godt til trimming og sammenslåing.

#### ProRes

Apple ProRes (yuv422p10) for redigeringsvennlige masterfiler. Tar med første video- og lydstrøm, beholder 24-bit PCM-lyd og bruker standard ProRes-bitrater. Standardprofil velges i forvalgsinnstillingene.

#### Proxy

Lette proxyfiler i HEVC, ProRes Proxy eller DNxHR med justerbar oppløsningsgrense. Beholder alle lydkanaler som ukomprimert PCM. Egnet for offline-redigering og en egen Proxy-undermappe ved siden av kildematerialet.

#### DCP (Digital Cinema Package)

SMPTE-kompatibel DCP-eksport. Koder video som JPEG 2000 i 12-bit XYZ-fargerom med konvertering fra BT.709, pakker i MXF med asdcp-wrap og genererer alle nødvendige SMPTE XML-filer (CPL, PKL, ASSETMAP, VOLINDEX). Støtter 2K og 4K i Flat, Scope og Full ved 24/25/30/48 fps, med justerbar bitrate (100–250 Mbps). Lyd eksporteres som 24-bit PCM i et separat MXF-spor. Metadata per element omfatter tittel, innholdstype, merknad, aldersgrense og lydspråk. Skalering: tilpass med svarte felt eller fyll med beskjæring.

#### IMF App 2e / RDD 45 (eksperimentelt)

Eksperimentell IMF-pakkeeksport med ett bildespor og ett PCM-lydspor. Undertekster i pakken og flere lydspor støttes ikke. Valider hver pakke i det aktuelle mastering- eller leveringsverktøyet før levering.

#### Image Sequence

Importer og eksporter bildesekvenser i PNG, JPEG, TIFF, EXR, DPX, BMP, TGA, SGI, JPEG XL og JPEG 2000. Import oppdager bildenummerering automatisk og støtter hull. Lydfiler kan knyttes til sekvenser for avspilling og eksport. Bildefrekvens kan velges per sekvens eller beregnes fra lydens varighet. Eksport kan inkludere separate metadatafiler (Markdown eller JSON) med fargerom, kodek og kamerainformasjon.

#### Animated Stills

Animerte bildesekvenser som GIF, AVIF eller animert PNG (APNG), valgt i forvalgsinnstillingene.

#### Audio Only AAC

AAC med stereonedmiks som bevarer stereobildet og reduserer filstørrelsen kraftig.

#### Audio Only WAV

Ukomprimert WAV som bevarer alle lydkanaler når det er mulig.

#### 10 egendefinerte FFmpeg-forvalg

Ti forvalg (C1–C10) med egne utdataargumenter, suffikser og filendelser. Inndataparametere håndteres automatisk. Kommandoer med `-copy` kan ikke kombineres med beskjæring eller lydomruting i forvalgsinnstillingene.

#### [Oppgaver / kjente problemer](../../TODO.md)

---

## Skjermbilder

#### Gruppevisning med tidslinje

Forhåndsvis en sekvens ved siden av klipplisten, med miniatyrbilder, lydbølgeformer, trimhåndtak og utgående tidskode. Tidslinjen har også kontroller for splitting, markører, områdevalg og zoom.

![Gruppevisning med tidslinje](../screenshots/group-timeline.jpeg)

#### Trimvisning

![Trimvisning](https://github.com/user-attachments/assets/0a48088d-e770-402a-a989-dc93d9fcb2c8)

#### Beskjæring

![Beskjæring](https://github.com/user-attachments/assets/97745a95-7bda-43bf-873a-bd865e886690)

#### Lydomruting

![Lydomruting](https://github.com/user-attachments/assets/b7f0ab61-a6f1-4f90-8ec6-2f90b05c6022)

#### Nedlastingsvisning

![Nedlastingsvisning](https://github.com/user-attachments/assets/b2704580-464a-473d-9cac-9f1991ba4bb5)

#### Metadatavisning

![Metadatavisning](https://github.com/user-attachments/assets/77f2c209-bc92-4cca-8e6c-36414bb0ecf3)

#### Overstyring av tidskode

![Overstyring av tidskode](https://github.com/user-attachments/assets/7c3d951d-9bbb-402c-9984-2fe46fa7d713)

#### Innstillinger

![Innstillinger](https://github.com/user-attachments/assets/26b71bfa-e947-42c8-bc0c-4e3e66e81099)

#### Fullskjermspiller

![Fullskjermspiller](https://github.com/user-attachments/assets/c9af806f-279e-4a1c-a2ee-a4cae8572911)

---

## Systemkrav

| | Minimum |
|---|---|
| macOS | 15.0 (Sequoia) eller nyere |
| Maskinvare | Apple Silicon (M1 eller nyere) |

---

## Bruk

1. Start appen.
2. Dra videofiler inn i vinduet, eller klikk på plussknappen for å importere.
3. Velg et **eksportforvalg** i verktøylinjen.
4. Klikk på den grønne *Convert*-knappen eller trykk ⌘⏎.

Dette er et fritidsprosjekt som jeg ikke får betalt for.

---

## Lisens

Prosjektet distribueres under **GNU General Public License, versjon 3.0**. Se [LICENSE](../../LICENSE) for hele teksten.

Den medfølgende FFmpeg-binærfilen er kompilert med `--enable-gpl` og er lisensiert under **GPL v2 eller nyere**. Prosjektet bruker GPL v3 for all kode og oppfyller dermed dette kravet. Se [den opprinnelige FFmpeg-lisensen](../../Licenses/ffmpeg-LICENSE.txt).

Den medfølgende asdcp-wrap-binærfilen kommer fra [asdcplib](https://github.com/cinecert/asdcplib) av John Hurst, lisensiert under **BSD 3-Clause License**. Se [asdcplib-lisensen](../../Licenses/asdcplib-LICENSE.txt).

---

## Takk til

Fargebehandlingen for DCP-eksport er basert på den gode dokumentasjonen fra [DCP-o-matic](https://dcpomatic.com/) om konvertering til DCI XYZ. DCP-o-matic er et gratis verktøy med åpen kildekode for å lage DCP: [GitHub-prosjekt](https://github.com/cth103/dcpomatic).

Metadataanalyse og C2PA-funksjoner for innholdsautentisitet bruker [SwiftMediaMetadata](https://github.com/aagedal/SwiftMediaMetadata).

---

PS! Appen het tidligere Aagedal VideoLoop Converter. Aagedal Media Converter er den samme appen, med et navn som bedre beskriver hva den har blitt.
