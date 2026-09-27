# Aagedal Media Converter

[English](../../README.md) · [Norsk bokmål](README.nb.md) · [Español](README.es.md) · [简体中文](README.zh-CN.md) · [Français](README.fr.md) · [Italiano](README.it.md)

<img alt="Aagedal Media Converter" src="https://github.com/user-attachments/assets/213e64a6-f382-4562-b4cf-797ad1e0f368" />

Un'applicazione macOS leggera e minimalista, semplice in superficie ma con funzionalità potenti. Utilizza FFmpeg, FFprobe, MPV, SwiftMediaMetadata, yt-dlp, rclone e whisper.cpp, ed è scritta interamente in Swift / SwiftUI.

Completamente gratuita e open source. Privata e locale. Il controllo facoltativo degli aggiornamenti è attivo per impostazione predefinita, ma può essere disattivato.

Un progetto nato dalla passione: l'ho creata per lavorare in modo più efficiente e ho voluto condividerla. Gran parte dell'app è stata sviluppata con il «vibe coding», con l'assistenza dell'IA.

---

## Installazione

### Homebrew
```bash
brew tap aagedal/tap && brew install --cask aagedal-media-converter
```

### Download manuale
[Scarica la versione attuale](https://github.com/aagedal/Aagedal-Media-Converter/releases/latest)

---

## Funzionalità principali

- **Avvio rapido e utilizzo semplice**
- **Conversione in batch** di quasi tutti i file video e audio (alternativa a Shutter Encoder o Handbrake)
- **Riproduzione** a schermo intero con timecode e comandi JKL (alternativa a IINA o VLC)
- **Visualizzazione e confronto dei metadati**, incluso il rilevamento di C2PA (alternativa a MediaInfo)
- **Download** di video dai siti web, con pianificazione e download di dirette
- **Registrazione dello schermo** con audio di sistema e traccia microfono separata facoltativa (alternativa a OBS)
- **Trascrizione** di video e audio in sottotitoli SRT
- **Caricamento** su un server dopo la conversione

### Generale

- Anteprima e codifica di quasi tutti i file video
- Importazione ed esportazione di **sequenze di immagini** (PNG, TIFF, EXR, DPX, JPEG 2000 e altri) con audio associato e controllo del frame rate
- Esportazione **DCP (Digital Cinema Package)** per il cinema, con codifica JPEG 2000 nello spazio colore XYZ conforme a SMPTE
- Conversione in batch, cartella monitorata e barra di avanzamento
- Taglio della durata, ritaglio dell'immagine, riassegnazione o rimozione delle tracce audio e unione di clip dello stesso formato
- Visualizzazione e confronto dei metadati
- Molte [scorciatoie da tastiera](../../KeyboardShortcuts.md): la maggior parte delle funzioni è accessibile senza mouse
- Numerose impostazioni di personalizzazione
- Controllo automatico degli aggiornamenti con notifica discreta, disattivabile
- Download da YouTube, TikTok ecc. (yt-dlp)
- Trascrizione in SRT (whisper.cpp)
- Caricamento tramite FTP (rclone)
- Verifica della firma C2PA (SwiftMediaMetadata)
- Registrazione dello schermo in HDR con audio di sistema e microfono facoltativo su una traccia separata

### Conversione in batch

- Codifica automatica di tutti i file in coda
- Riordino della coda di codifica tramite trascinamento
- Rimozione di file dalla coda durante la codifica

### Cartella monitorata

- Importazione automatica dei file da una cartella specifica
- Funziona insieme all'importazione manuale tramite trascinamento, raccogliendo le conversioni in un'unica finestra
- Opzioni di eliminazione automatica e di esclusione dei file nella cartella
- Attivazione dall'icona a forma di occhio nella barra degli strumenti della finestra principale

### Anteprima

- Scorciatoie comuni di montaggio, come JKL e i tasti freccia
- Semplice misuratore del livello audio (⌘A)
- Lettore nativo di macOS per i file compatibili, con riproduzione fluida anche all'indietro
- Passaggio automatico a MPVKit per i file non supportati da macOS, con riproduzione all'indietro meno affidabile

### Regolazioni rapide

- Taglio della durata con le maniglie o i tasti I/O
- Copia del timecode dalla sorgente, impostazione manuale o rimozione
- Ritaglio dell'immagine con i controlli a schermo; premi C o l'icona di ritaglio nella vista di taglio
    - Non funziona con il preset Stream Copy
- Eliminazione o riordino delle tracce audio
    - Non funziona con il preset Stream Copy

### Unire i file in coda

- Unione di file con gli stessi codec, risoluzione, frame rate, profondità di bit e tracce audio
- La prima clip determina il timecode e il ritaglio dell'immagine
- Taglio della durata e Stream Copy possono essere combinati per tagliare e unire senza perdita di qualità. Alcuni metadati potrebbero andare persi.

### Animazioni delle forme d'onda audio

- Generazione di animazioni delle forme d'onda per file solo audio
- Cinque preset con opzioni di colore e normalizzazione

### Catture alla risoluzione e profondità di bit della sorgente

Il pulsante della fotocamera nel lettore di taglio cattura immagini alla risoluzione originale. Il formato predefinito è JPEG XL. Nelle impostazioni puoi scegliere il formato per ciascuna profondità di bit e il trattamento del canale alfa.

### Esportazione e nomi dei file

- Per impostazione predefinita vengono rimossi spazi e caratteri speciali. æ, ø e å sono sostituiti con ae, o e aa.
- Anteprima del nome del file elaborato
- Avviso se il file esiste già
- Dopo la codifica, un'icona mostra il file convertito nella cartella di esportazione
- Un'altra icona permette di trascinare il risultato in un'altra app o cartella
- Scelta del preset predefinito nelle impostazioni
- Scelta della destinazione di esportazione predefinita

### Metadati

- Campo commento per ogni file per metadati facoltativi, ad esempio i crediti
- Etichetta data facoltativa (Generated [YYYYMMDD]), prefisso e suffisso inseriti nel campo prima del commento
- Visualizzazione e confronto dei metadati

### Avviso di riproduzione automatica oltre 15 secondi per VideoLoop

I browser spesso impediscono la riproduzione automatica di lunghi video in loop con audio. L'app mostra un'icona gialla ⚠️ quando i preset VideoLoop vengono applicati a clip di oltre 15 secondi, invitando a tagliarle o a scegliere un altro preset.

### App Intents

1. Aggiungi alla coda di codifica.
2. Converti immediatamente il video con il preset predefinito.

---

## Preset di esportazione

Tutti i preset possono essere impostati come predefiniti all'avvio. Tutti, tranne quello predefinito, possono essere nascosti dal selettore.

#### Video Loop

Ottimizzato per loop continui e senza audio. Codifica con x264 a CRF 23 (circa 3–9 Mbps a bitrate variabile), rimuove l'audio e limita il lato più corto a 1080 pixel per il web. Mostra un avviso quando la clip supera i 15 secondi.

#### Video Loop w/ Audio

Stesse impostazioni x264, ma conserva tutte le tracce audio in AAC a 128 kbps. Mantiene il limite di 1080 pixel per il lato più corto.

#### H.264 / AVC

Codifica H.264/AVC ampiamente compatibile. Scegli VideoToolbox hardware per la velocità o libx264 software con controllo CRF per la qualità. Contenitori MP4, MOV e MKV.

#### H.265 / HEVC

Codifica H.265/HEVC moderna a 10 bit. VideoToolbox velocizza l'esportazione tramite hardware; libx265 software offre un'elevata efficienza di compressione.

#### AV1

Codifica SVT-AV1 con supporto a 10 bit ed elevata efficienza di compressione. Solo software, senza accelerazione hardware su macOS.

#### AV2 (sperimentale)

Codifica AV2 sperimentale con l'encoder di riferimento AOM AVM incluso (`avmenc`), introdotta in una versione di anteprima. Supporta output a 8/10 bit, qualità costante o bitrate variabile, velocità e risoluzione configurabili. La codifica parallela per segmenti utilizza più core della CPU in modalità qualità costante.

Scegli IVF (`.ivf`) solo video o Matroska (`.mkv`) con audio AAC o Opus. La codifica di riferimento è molto lenta e il bitstream, ancora in evoluzione, richiede un decoder compatibile con AV2. L'app può decodificare AV2 per conversioni e miniature, ma non supporta ancora la riproduzione interattiva. Usa AV2 per sperimentare, non come formato di consegna.

#### TV (HEVC 10-bit 4:2:2)

Formato di consegna per la trasmissione con HEVC hardware a 10 bit 4:2:2, risoluzione e frame rate configurabili, adattamento automatico del bitrate e conservazione di tutti i canali audio in PCM a 24 bit.

#### TV (AVC-Intra)

Formato broadcast in contenitore MXF. AVC-Intra a 10 bit 4:2:2 con classi selezionabili (50/100/200 Mbps), risoluzione e frame rate, e 4/8/16 canali mono in PCM a 24 bit.

#### Stream copy

Copia i flussi audio e video esistenti in un nuovo file, mantenendo codec, metadati ed estensione originali. Adatto al taglio e all'unione.

#### ProRes

Apple ProRes (yuv422p10) per master facili da montare. Include i primi flussi video e audio, conserva l'audio PCM a 24 bit e usa i bitrate standard ProRes. Il profilo predefinito si sceglie nelle impostazioni dei preset.

#### Proxy

Creazione di proxy leggeri in HEVC, ProRes Proxy o DNxHR con limiti di risoluzione configurabili. Conserva tutti i canali audio in PCM non compresso, ideale per il montaggio offline e una sottocartella Proxy dedicata accanto al materiale sorgente.

#### DCP (Digital Cinema Package)

Esportazione DCP conforme a SMPTE. Codifica il video come JPEG 2000 nello spazio XYZ a 12 bit con conversione da BT.709, lo incapsula in MXF tramite asdcp-wrap e genera tutti gli XML SMPTE necessari (CPL, PKL, ASSETMAP, VOLINDEX). Supporta 2K e 4K nei formati Flat, Scope e Full a 24/25/30/48 fps, con bitrate configurabile di 100–250 Mbps. L'audio viene esportato come PCM a 24 bit in una traccia MXF separata. I metadati per elemento includono titolo, tipo di contenuto, annotazione, classificazione e lingua audio. Ridimensionamento: adatta con bande nere o riempi ritagliando.

#### Image Sequence

Importazione ed esportazione di sequenze in PNG, JPEG, TIFF, EXR, DPX, BMP, TGA, SGI, JPEG XL e JPEG 2000. Rilevamento automatico della numerazione e supporto dei numeri mancanti. È possibile associare file audio per riproduzione ed esportazione. Il frame rate si configura per sequenza o si calcola dalla durata dell'audio associato. L'esportazione può includere file di metadati separati (Markdown o JSON) con spazio colore, codec e informazioni sulla fotocamera.

#### Animated Stills

Sequenze animate in GIF, AVIF o PNG animato (APNG), selezionabili nelle impostazioni dei preset.

#### Audio Only AAC

Downmix stereo AAC che conserva l'immagine stereo riducendo notevolmente le dimensioni del file.

#### Audio Only WAV

Esportazione WAV non compressa che conserva tutti i canali audio ove possibile.

#### 10 preset FFmpeg personalizzati

Dieci preset (C1–C10) consentono di definire argomenti di output, suffissi ed estensioni. I parametri di input sono gestiti automaticamente. I percorsi con `-copy` non possono essere combinati con le opzioni di ritaglio o riassegnazione audio nelle impostazioni dei preset.

#### [Attività da fare / problemi noti](../../TODO.md)

---

## Schermate

#### Vista della timeline del gruppo

Visualizza una sequenza accanto alla lista delle clip, con miniature, forme d’onda audio, maniglie di taglio e timecode di output. La timeline offre anche comandi per divisione, marcatori, selezione di intervalli e zoom.

![Vista della timeline del gruppo](../screenshots/group-timeline.jpeg)

#### Vista di taglio

![Vista di taglio](https://github.com/user-attachments/assets/0a48088d-e770-402a-a989-dc93d9fcb2c8)

#### Vista di ritaglio

![Vista di ritaglio](https://github.com/user-attachments/assets/97745a95-7bda-43bf-873a-bd865e886690)

#### Riassegnazione audio

![Riassegnazione audio](https://github.com/user-attachments/assets/b7f0ab61-a6f1-4f90-8ec6-2f90b05c6022)

#### Vista dei download

![Vista dei download](https://github.com/user-attachments/assets/b2704580-464a-473d-9cac-9f1991ba4bb5)

#### Vista dei metadati

![Vista dei metadati](https://github.com/user-attachments/assets/77f2c209-bc92-4cca-8e6c-36414bb0ecf3)

#### Modifica del timecode

![Modifica del timecode](https://github.com/user-attachments/assets/7c3d951d-9bbb-402c-9984-2fe46fa7d713)

#### Impostazioni

![Impostazioni](https://github.com/user-attachments/assets/26b71bfa-e947-42c8-bc0c-4e3e66e81099)

#### Lettore a schermo intero

![Lettore a schermo intero](https://github.com/user-attachments/assets/c9af806f-279e-4a1c-a2ee-a4cae8572911)

---

## Requisiti

| | Minimo |
|---|---|
| macOS | 15.0 (Sequoia) o successivo |
| Hardware | Apple Silicon (M1 o successivo) |

---

## Utilizzo

1. Avvia l'app.
2. Trascina i file video nella finestra o fai clic sul pulsante più per importarli.
3. Seleziona un **preset di esportazione** dalla barra degli strumenti.
4. Premi il pulsante verde *Convert* o ⌘⏎.

È un progetto personale realizzato nel tempo libero, per il quale non ricevo compensi.

---

## Licenza

Il progetto è distribuito con la **GNU General Public License, versione 3.0**. Il testo completo è in [LICENSE](../../LICENSE).

Il binario FFmpeg incluso è compilato con `--enable-gpl` e ha licenza **GPL v2 o successiva**. Il progetto usa GPL v3 per tutto il codice, soddisfacendo questo requisito. Consulta la [licenza originale di FFmpeg](../../Licenses/ffmpeg-LICENSE.txt).

Il binario asdcp-wrap incluso proviene da [asdcplib](https://github.com/cinecert/asdcplib), di John Hurst, con licenza **BSD 3-Clause License**. Consulta la [licenza di asdcplib](../../Licenses/asdcplib-LICENSE.txt).

---

## Ringraziamenti

Il trattamento del colore nell'esportazione DCP si basa sull'ottima documentazione di [DCP-o-matic](https://dcpomatic.com/) sulla conversione nello spazio DCI XYZ. DCP-o-matic è un creatore di DCP gratuito e open source: [progetto GitHub](https://github.com/cth103/dcpomatic).

L'ispezione dei metadati e le funzioni di autenticità C2PA utilizzano [SwiftMediaMetadata](https://github.com/aagedal/SwiftMediaMetadata).

---

PS! Questa app si chiamava Aagedal VideoLoop Converter. Aagedal Media Converter è la stessa app, con un nome che riflette meglio ciò che è diventata.
