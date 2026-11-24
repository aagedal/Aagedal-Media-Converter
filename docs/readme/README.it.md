# Aagedal Media Converter

[English](../../README.md) · [Norsk bokmål](README.nb.md) · [Español](README.es.md) · [简体中文](README.zh-CN.md) · [Français](README.fr.md) · [Italiano](README.it.md) · [Deutsch](README.de.md) · [日本語](README.ja.md) · [Português (Brasil)](README.pt-BR.md) · [한국어](README.ko.md)

<img alt="Aagedal Media Converter" src="https://github.com/user-attachments/assets/213e64a6-f382-4562-b4cf-797ad1e0f368" />

Un'applicazione macOS leggera e minimalista, semplice in superficie ma con funzionalità potenti. Utilizza FFmpeg, MPV, SwiftMediaMetadata, yt-dlp, rclone e whisper.cpp, ed è scritta interamente in Swift / SwiftUI.

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
- **Analisi** di loudness, silenzi, picchi, fase stereo e qualità del video codificato
- **Download** di video dai siti web, con pianificazione e download di dirette
- **Registrazione dello schermo** con audio di sistema e traccia microfono separata facoltativa (alternativa a OBS)
- **Trascrizione** di video e audio in sottotitoli SRT
- **Caricamento** su un server dopo la conversione
- **Unire** clip in una timeline con anteprima della sequenza e taglio con ripple
- **Automatizzare le conversioni tramite MCP locale** con accesso facoltativo per gli agenti

### Generale

- Anteprima e codifica di quasi tutti i file video
- Importazione ed esportazione di **sequenze di immagini** (PNG, TIFF, EXR, DPX, JPEG 2000 e altri) con audio associato e controllo del frame rate
- Esportazione **DCP (Digital Cinema Package)** con immagine JPEG 2000 XYZ e audio PCM
- Esportazione sperimentale di pacchetti **IMF App 2e e RDD 45** da validare nello strumento di consegna
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

### Regolazioni

Fai clic con il tasto destro su un file in coda e scegli **Regolazioni…** per impostare, per singolo file:
- **Rotazione** di 90°/180° e **capovolgimento** orizzontale o verticale (applicati dopo il ritaglio e prima del ridimensionamento del preset)
- **Velocità** da 0,25× a 4× mantenendo l'intonazione dell'audio
- **Dissolvenza** del video da/verso il nero, e dissolvenza in entrata e in uscita dell'audio
- **Scostamento audio** per correggere clip fuori sincrono (valori positivi ritardano l'audio)
- **Sostituzione o aggiunta dell'audio** da un altro file, allineato al taglio e adattato alla durata del video
- **Sottotitoli impressi nel video** da una traccia sottotitoli di testo o da un file SRT, ASS o VTT, con dimensione del carattere, contorno o riquadro e posizione. I sottotitoli grafici (PGS, DVD) richiedono prima l'OCR dei sottotitoli in SRT.
- Esclusione o modifica per singolo file della normalizzazione loudness

Le regolazioni richiedono un preset con ricodifica; non sono disponibili per Stream Copy, DCP, IMF, AV2, unioni o video generati con forme d'onda.

### Normalizzazione loudness

Attiva **Normalize Loudness** in Impostazioni → Preset per normalizzare ogni traccia audio ricodificata secondo EBU R128 (−23 LUFS, −1 dBTP), ATSC A/85, streaming (−14 LUFS), web/podcast (−16 LUFS) o un target personalizzato. Ogni traccia viene misurata in un primo passaggio e poi normalizzata con il filtro `loudnorm` di FFmpeg usando un guadagno lineare dove il programma lo consente. Nei preset broadcast con tracce mono come AVC-Intra la misurazione avviene per traccia sorgente prima della separazione, mantenendo così il bilanciamento stereo.

### Unire i file in coda

- Unione di file con gli stessi codec, risoluzione, frame rate, profondità di bit e tracce audio
- La prima clip determina il timecode e il ritaglio dell'immagine
- Modifica i gruppi nella timeline con strisce di miniature, riproduzione della sequenza, taglio con ripple, riordino, divisione, eliminazione di intervalli e annullamento.
- Taglia e unisci con Stream Copy senza ricodifica. I tagli dipendono dai fotogrammi chiave della sorgente e possono differire dai limiti selezionati; alcuni metadati potrebbero andare persi.
- Esporta marcatori di clip in EDL per Resolve e capitoli incorporati, scegliendo se mantenere o sostituire quelli esistenti.

### Importazione da schede della fotocamera

- Esamina le clip per cartella della scheda e data di registrazione prima di importarle.
- Segna esplicitamente le continuazioni di registrazione e, se desiderato, dividi i gruppi dopo pause superiori a due ore. I controlli di compatibilità aiutano a individuare clip che possono essere unite.

### Accesso locale per gli agenti

Attiva **Settings → Agent Access**, autorizza le cartelle sorgenti e copia la configurazione per il client MCP. L’helper incluso consente agli agenti di esplorare e ispezionare i media autorizzati, pianificare conversioni, inviare lavori, seguirne l’avanzamento e annullarli nella coda dell’app. Sono disponibili 21 preset integrati (tutti i preset integrati tranne Lossless FFV1); gli slot FFmpeg personalizzati sono esclusi. Le esportazioni IMF sono sperimentali.

I lavori accettati continuano dopo la disconnessione del client. I piani sono validi per 15 minuti e i risultati dei lavori terminati restano disponibili per 30 giorni. Le esportazioni tramite agenti disattivano il timecode di output. Consulta la [guida di configurazione e flusso di lavoro](../../Documentation/LOCAL_AGENT_ACCESS.md) per autorizzazioni delle cartelle, configurazione dei client e recupero dei lavori.

### Animazioni delle forme d'onda audio

- Generazione di animazioni delle forme d'onda per file solo audio
- 7 stili nativi in Swift (tra cui Halo, Orb, Ridgeline e LED Meter) più 5 stili classici di FFmpeg, con palette sfumate e opzioni per colore, opacità, sfondo trasparente e normalizzazione

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

### Analisi dei media

![Campioni SSIMULACRA2 verificati accanto alla riproduzione della sorgente](../images/ssimulacra2-frame-inspection-en.png)
Apri il pulsante del grafico su un file in coda per esaminarne i report Audio e Video.

- Misura la loudness dell'intero programma e il true peak per singole tracce, coppie mono personalizzate o gruppi mono 5.1; esporta report completi in JSON o PDF.
- Individua intervalli di silenzio e picchi, confronta il bilanciamento dei canali oppure verifica la correlazione stereo e il fold-down mono. Salta alle sezioni misurate nell'anteprima in pausa ed esporta le misurazioni complete in JSON.
- Individua intervalli neri (`blackdetect` di FFmpeg, con durata minima, rapporto immagine e soglia pixel regolabili) e cambi scena (`scdet` di FFmpeg, con soglia regolabile e una miniatura per taglio) nel video sorgente. Fai clic su un evento per ispezionarlo nell'anteprima in pausa, poi esporta in JSON o come marcatori EDL per Resolve. Consulta i formati dei report di [intervalli neri](../../docs/video-black-report-format.md) e [cambi scena](../../docs/video-scene-cut-report-format.md).
- Dopo la codifica, confronta il video con VMAF, PSNR, XPSNR o campioni SSIMULACRA2. Esamina la qualità nel tempo, alterna la riproduzione tra sorgente e output e salta alle sezioni con i punteggi più bassi.
- SSIMULACRA2 confronta fotogrammi decodificati verificati fino al limite selezionato, anche su clip brevi. I video vengono prima indicizzati; un numero maggiore di campioni richiede più tempo.
- Esporta la qualità video come JSON a piena risoluzione o come PDF A4 impaginato con timeline, punteggi per componente e avvisi di confronto. Consulta [l'interpretazione dei punteggi e i dettagli del report](../../docs/video-quality-report-format.md).

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

L'encoder e il decoder inclusi utilizzano AVM `1.0.0-445-g14342caad` (14 ottobre 2026). Gli strumenti restano sperimentali; consulta la [validazione di compilazione e compatibilità](../../docs/av2-integrated-encoder-2026-10-14.md) per il sorgente fissato, le istruzioni di ricompilazione e le verifiche.

Scegli IVF (`.ivf`) solo video o Matroska (`.mkv`) con audio AAC o Opus. La codifica di riferimento è molto lenta e la riproduzione richiede un decoder compatibile con AV2. L'app può decodificare AV2 per conversioni e miniature, ma non supporta ancora la riproduzione interattiva. Usa AV2 per sperimentare, non come formato di consegna.

#### VP9 / WebM

VP9 royalty-free per il web, codificato con libvpx a qualità costante (CRF con target di bitrate a zero) e multithreading per righe. Scegli il CRF, una velocità da Best a Realtime, 8 bit (profilo 0) o 10 bit (profilo 2) e un limite di risoluzione. L'audio è codificato in Opus a un bitrate selezionabile. Genera file WebM o Matroska (`.mkv`). Opus non può codificare alcune disposizioni di canali, come `5.1(side)`; effettua il downmix di queste tracce tramite la riassegnazione audio.

#### TV (HEVC 10-bit 4:2:2)

Formato di consegna per la trasmissione con HEVC hardware a 10 bit 4:2:2, risoluzione e frame rate configurabili, adattamento automatico del bitrate e conservazione di tutti i canali audio in PCM a 24 bit.

#### TV (AVC-Intra)

Formato broadcast in contenitore MXF. AVC-Intra a 10 bit 4:2:2 con classi selezionabili (50/100/200 Mbps), risoluzione e frame rate, e 4/8/16 canali mono in PCM a 24 bit.

#### XDCAM HD422 (MXF)

Consegna broadcast Sony XDCAM HD422: MPEG-2 4:2:2 Profile @ High Level, 50 Mbps CBR long GOP (GOP chiusi di 12 fotogrammi a 25/50 Hz e 15 a 29,97/59,94 Hz, due B-frame) in un file MXF OP1a. Scegli 1080i50, 1080p25, 1080i59.94, 1080p29.97, 720p50 o 720p59.94. Le sorgenti vengono ridimensionate con pillarbox o letterbox a pieno raster 16:9 e l'audio viene consegnato come 4 o 8 tracce mono PCM a 24 bit e 48 kHz.

#### Stream copy

Copia i flussi audio e video esistenti in un nuovo file, mantenendo codec, metadati ed estensione originali. Adatto al taglio e all'unione.

#### ProRes

Apple ProRes (yuv422p10) per master facili da montare. Include i primi flussi video e audio, conserva l'audio PCM a 24 bit e usa i bitrate standard ProRes. Il profilo predefinito si sceglie nelle impostazioni dei preset.

#### DNxHR

Avid DNxHR alla risoluzione sorgente per montaggio e mastering: LB, SQ o HQ (8 bit 4:2:2), HQX (10 bit 4:2:2) o 444 (10 bit 4:4:4). Scegli un contenitore MOV o MXF. Ogni traccia audio è conservata in PCM a 24 bit (ricampionata a 48 kHz in MXF).

#### CineForm

GoPro CineForm alla risoluzione sorgente in contenitore MOV, per montaggio e finitura: YUV a 10 bit 4:2:2, RGB a 12 bit 4:4:4 o RGB a 12 bit 4:4:4 con alfa. Scegli una qualità da Low a Film Scan 3+ (Film Scan 1 per impostazione predefinita). Il codec memorizza al massimo 12 bit per canale, quindi le sorgenti a 16 bit vengono ridotte a 12 bit. L'encoder di FFmpeg richiede una larghezza multipla di 16, perciò le altre larghezze vengono riempite di nero ai lati. Ogni traccia audio è conservata in PCM a 24 bit.

#### Proxy

Creazione di proxy leggeri in HEVC, ProRes Proxy o DNxHR con limiti di risoluzione configurabili. Conserva tutti i canali audio in PCM non compresso, ideale per il montaggio offline e una sottocartella Proxy dedicata accanto al materiale sorgente.

#### DCP (Digital Cinema Package)

Esportazione Digital Cinema Package. Codifica il video come JPEG 2000 nello spazio XYZ a 12 bit con conversione da BT.709, lo incapsula in MXF tramite asdcp-wrap e genera gli XML del pacchetto (CPL, PKL, ASSETMAP, VOLINDEX). Supporta 2K e 4K nei formati Flat, Scope e Full a 24/25/30/48 fps, con bitrate configurabile di 100–250 Mbps. L'audio viene esportato come PCM a 24 bit in una traccia MXF separata. I metadati per elemento includono titolo, tipo di contenuto, annotazione, classificazione e lingua audio. Ridimensionamento: adatta con bande nere o riempi ritagliando.

#### IMF App 2e / RDD 45 (sperimentale)

Esportazione sperimentale di pacchetti IMF con una traccia immagine e una traccia audio PCM. Non sono supportati sottotitoli nel pacchetto né tracce audio multiple. Valida ogni pacchetto nello strumento di mastering o consegna previsto prima della consegna.

#### Image Sequence

Importazione ed esportazione di sequenze in PNG, JPEG, TIFF, EXR, DPX, BMP, TGA, SGI, JPEG XL e JPEG 2000. Rilevamento automatico della numerazione e supporto dei numeri mancanti. È possibile associare file audio per riproduzione ed esportazione. Il frame rate si configura per sequenza o si calcola dalla durata dell'audio associato. L'esportazione può includere file di metadati separati (Markdown o JSON) con spazio colore, codec e informazioni sulla fotocamera.

#### Animated Stills

Sequenze animate in GIF, AVIF, PNG animato (APNG), WebP animato o JPEG XL animato, selezionabili nelle impostazioni dei preset.

#### Lossless (FFV1)

Codifica di archiviazione FFV1 matematicamente senza perdita in Matroska (`.mkv`) con audio PCM non compresso.

#### Audio Only

Estrai o transcodifica l'audio in WAV (PCM non compresso che conserva tutti i canali), FLAC, ALAC o AAC/MP4, configurabile nelle impostazioni dei preset.

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

L'interfaccia dell'app supporta inglese, norvegese bokmål, tedesco, spagnolo, francese, italiano, giapponese, coreano, portoghese brasiliano e cinese semplificato. Segue la lingua preferita dell'app impostata nelle Impostazioni di Sistema di macOS. Le otto traduzioni aggiunte di recente sono una prima bozza; le stringhe in attesa di revisione linguistica sono contrassegnate come **Needs Review** in `Aagedal Media Converter/Resources/Localizable.xcstrings`.

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
