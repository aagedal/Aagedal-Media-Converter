# Aagedal Media Converter

[English](../../README.md) · [Norsk bokmål](README.nb.md) · [Español](README.es.md) · [简体中文](README.zh-CN.md) · [Français](README.fr.md) · [Italiano](README.it.md) · [Deutsch](README.de.md) · [日本語](README.ja.md) · [Português (Brasil)](README.pt-BR.md) · [한국어](README.ko.md)

<img alt="Aagedal Media Converter" src="https://github.com/user-attachments/assets/213e64a6-f382-4562-b4cf-797ad1e0f368" />

Eine schlanke, minimalistische macOS-App, die auf den ersten Blick einfach wirkt, aber viele leistungsfähige Funktionen bietet. Sie nutzt FFmpeg, MPV, SwiftMediaMetadata, yt-dlp, rclone und whisper.cpp und ist vollständig in Swift / SwiftUI geschrieben.

Völlig kostenlos und quelloffen. Privat und lokal. Die optionale Suche nach Updates ist standardmäßig aktiviert, lässt sich aber abschalten.

Ein Herzensprojekt: Ich habe die App entwickelt, um bei meiner Arbeit effizienter zu sein, und wollte sie mit anderen teilen. Ein Großteil der App wurde per „Vibe Coding“ mit KI-Unterstützung entwickelt.

---

## Installation

### Homebrew
```bash
brew tap aagedal/tap && brew install --cask aagedal-media-converter
```

### Manueller Download
[Aktuelle Version herunterladen](https://github.com/aagedal/Aagedal-Media-Converter/releases/latest)

---

## Hauptfunktionen

- **Schneller Start und einfache Bedienung**
- **Stapelkonvertierung** fast aller Video- und Audiodateien (Alternative zu Shutter Encoder oder Handbrake)
- **Wiedergabe** im Vollbild mit Timecode und JKL-Steuerung (Alternative zu IINA oder VLC)
- **Metadaten anzeigen und vergleichen**, einschließlich Prüfung auf C2PA (Alternative zu MediaInfo)
- **Videos herunterladen**, mit Zeitplanung und Download von Livestreams
- **Bildschirmaufnahme** mit Systemton und optionaler separater Mikrofonspur (Alternative zu OBS)
- **Video und Audio transkribieren** und SRT-Untertitel erstellen
- Nach der Konvertierung auf einen Server **hochladen**

- Clips in einer Timeline mit Sequenzvorschau und Ripple-Trimming **zusammenfügen**
- Konvertierungen über **lokales MCP automatisieren**, mit optionalem Agentenzugriff

### Allgemein

- Fast alle Videodateien in der Vorschau anzeigen und kodieren
- **Bildsequenzen** (PNG, TIFF, EXR, DPX, JPEG 2000 und weitere) mit zugeordnetem Audio und einstellbarer Bildrate importieren und exportieren
- **DCP (Digital Cinema Package)** mit JPEG-2000-Bild im XYZ-Farbraum und PCM-Audio exportieren
- Experimentelle **IMF-App-2e- und RDD-45**-Pakete zur Prüfung im Auslieferungswerkzeug exportieren
- Stapelkonvertierung, überwachter Ordner und Fortschrittsanzeige
- Laufzeit kürzen, Bild beschneiden, Audiospuren neu zuordnen oder entfernen und Clips gleichen Formats zusammenfügen
- Metadaten anzeigen und vergleichen
- Viele [Tastenkürzel](../../KeyboardShortcuts.md): Die meisten Funktionen sind ohne Maus erreichbar
- Zahlreiche Einstellungen zur Anpassung
- Automatische Update-Suche mit dezenter Benachrichtigung, abschaltbar
- Downloads von YouTube, TikTok usw. (yt-dlp)
- Transkription nach SRT (whisper.cpp)
- FTP-Upload (rclone)
- C2PA-Signaturen prüfen (SwiftMediaMetadata)
- HDR-Bildschirmaufnahme mit Systemton und optionalem Mikrofon auf einer eigenen Audiospur

### Stapelkonvertierung

- Alle Dateien in der Warteschlange automatisch kodieren
- Die Kodierreihenfolge per Drag-and-drop ändern
- Dateien während der Kodierung aus der Warteschlange entfernen

### Überwachter Ordner

- Dateien aus einem ausgewählten Ordner automatisch importieren
- Parallel zum manuellen Import per Drag-and-drop nutzbar; alle Konvertierungen erscheinen in einem Fenster
- Optionen zum automatischen Löschen und Ignorieren von Dateien im Ordner
- Aktivierung über das Augensymbol in der Symbolleiste des Hauptfensters

### Vorschau

- Übliche Schnitt-Tastenkürzel wie JKL und die Pfeiltasten
- Einfache Audiopegelanzeige (⌘A)
- Nativer macOS-Player für kompatible Dateien, mit flüssiger Wiedergabe auch rückwärts
- Automatischer Wechsel zu MPVKit für nativ nicht unterstützte Dateien; die Rückwärtswiedergabe ist dabei weniger zuverlässig

### Schnelle Anpassungen

- Laufzeit mit Griffen oder den Tasten I/O kürzen
- Timecode aus der Quelle übernehmen, manuell festlegen oder entfernen
- Bild mit Bedienelementen auf dem Bildschirm beschneiden; in der Trimmansicht C drücken oder das Zuschneidesymbol anklicken
    - Nicht mit dem Preset Stream Copy verfügbar
- Audiospuren löschen oder neu anordnen
    - Nicht mit dem Preset Stream Copy verfügbar

### Dateien in der Warteschlange zusammenfügen

- Dateien mit gleichem Codec, gleicher Auflösung, Bildrate, Bittiefe und gleichen Audiospuren zusammenfügen
- Der erste Clip bestimmt Timecode und Bildbeschnitt
- Gruppen in der Timeline mit Filmstreifen, Sequenzwiedergabe, Ripple-Trimming, Umordnen, Teilen, Bereichslöschung und Rückgängig bearbeiten
- Mit Stream Copy ohne Neukodierung kürzen und zusammenfügen. Schnitte hängen von den Quell-Keyframes ab und können von den gewählten Grenzen abweichen; einige Metadaten können verloren gehen.
- Resolve-EDL-Clipmarker und eingebettete Kapitel exportieren; vorhandene Kapitel können beibehalten oder ersetzt werden.

### Import von Kamerakarten

- Clips vor dem Import nach Kartenordner und Aufnahmedatum prüfen.
- Fortsetzungen einer Aufnahme ausdrücklich markieren und Gruppen optional nach Pausen über zwei Stunden aufteilen. Kompatibilitätsprüfungen helfen, zusammenfügbare Clips zu erkennen.

### Lokaler Agentenzugriff

**Settings → Agent Access** aktivieren, Quellordner freigeben und die Einrichtung für den MCP-Client kopieren. Der mitgelieferte Helfer erlaubt Agenten, freigegebene Medien zu durchsuchen und zu prüfen, Konvertierungen zu planen, Aufträge einzureichen, ihren Fortschritt zu verfolgen und sie in der App-Warteschlange abzubrechen. Alle 17 integrierten Presets sind verfügbar; eigene FFmpeg-Presets sind ausgeschlossen. IMF-Exporte sind experimentell.

Angenommene Aufträge laufen nach dem Trennen des Clients weiter. Pläne gelten 15 Minuten, Ergebnisse abgeschlossener Aufträge bleiben 30 Tage verfügbar. Agentenexporte deaktivieren den Ausgabe-Timecode. Informationen zu Ordnerfreigaben, Client-Einrichtung und Auftragswiederherstellung findest du im [Einrichtungs- und Workflow-Leitfaden](../../Documentation/LOCAL_AGENT_ACCESS.md).

### Animierte Audiowellenformen

- Wellenformanimationen für reine Audiodateien erstellen
- Fünf Presets mit Farb- und Normalisierungsoptionen

### Standbilder in Quellauflösung und Quellbittiefe

Die Kameraschaltfläche im Trimmplayer erstellt Standbilder in der Auflösung der Quelle. Standardformat ist JPEG XL. In den Einstellungen lassen sich Formate je Bittiefe und der Umgang mit Videos mit Alphakanal festlegen.

### Export und Dateinamen

- Standardmäßig werden Leerzeichen und Sonderzeichen entfernt. æ, ø und å werden durch ae, o und aa ersetzt.
- Vorschau des verarbeiteten Dateinamens
- Warnung, wenn die Datei bereits existiert
- Nach der Kodierung zeigt ein Symbol die konvertierte Datei im Exportordner
- Ein weiteres Symbol erlaubt es, das Ergebnis in eine andere App oder einen anderen Ordner zu ziehen
- Standardpreset in den Einstellungen festlegen
- Standard-Exportziel festlegen

### Metadaten

- Kommentarfeld je Datei für optionale Metadaten, etwa zur Nennung von Urhebern
- Optionales Datumsfeld (Generated [YYYYMMDD]), Präfix und Suffix im Kommentarfeld vor dem Kommentar
- Metadaten anzeigen und vergleichen

### 15-Sekunden-Autoplay-Warnung für VideoLoop

Browser verhindern oft die automatische Wiedergabe langer Videoschleifen mit Ton. Die App zeigt ein gelbes ⚠️-Symbol, wenn VideoLoop-Presets auf Clips über 15 Sekunden angewendet werden, damit du den Clip kürzen oder ein anderes Preset wählen kannst.

### App Intents

1. Zur Kodierwarteschlange hinzufügen.
2. Video sofort mit dem Standardpreset konvertieren.

---

## Exportpresets

Alle Presets können beim Start als Standard verwendet werden. Alle außer dem Standardpreset lassen sich aus der Auswahl ausblenden.

#### Video Loop

Für nahtlose, lautlose Schleifen optimiert. Kodiert mit x264 bei CRF 23 (etwa 3–9 Mbps variable Bitrate), entfernt Audio und begrenzt die kürzere Bildkante für die Webwiedergabe auf 1080 Pixel. Bei Clips über 15 Sekunden erscheint eine Warnung.

#### Video Loop w/ Audio

Gleiche x264-Einstellungen, behält aber alle Audiospuren als AAC mit 128 kbps. Die kürzere Bildkante bleibt auf 1080 Pixel begrenzt.

#### H.264 / AVC

Weitgehend kompatible H.264/AVC-Kodierung. Wähle schnelle VideoToolbox-Hardwarekodierung oder qualitätsorientierte libx264-Softwarekodierung mit CRF-Steuerung. Unterstützt MP4, MOV und MKV.

#### H.265 / HEVC

Moderne H.265/HEVC-Kodierung mit 10 Bit. VideoToolbox beschleunigt den Export per Hardware; libx265 steht für hohe Kompressionseffizienz zur Verfügung.

#### AV1

SVT-AV1-Kodierung mit 10-Bit-Unterstützung und hoher Kompressionseffizienz. Nur Softwarekodierung, ohne Hardwarebeschleunigung unter macOS.

#### AV2 (experimentell)

Experimentelle AV2-Kodierung mit dem mitgelieferten AOM-AVM-Referenzencoder (`avmenc`), eingeführt in einer Vorabversion. Unterstützt 8/10 Bit, konstante Qualität oder variable Bitrate sowie einstellbare Geschwindigkeit und Auflösung. Die parallele Kodierung in Segmenten nutzt im Modus für konstante Qualität mehrere CPU-Kerne.

Wähle IVF (`.ivf`) nur für Video oder Matroska (`.mkv`) mit AAC- oder Opus-Audio. Der Referenzencoder ist sehr langsam, und der sich weiterentwickelnde Bitstream benötigt einen AV2-kompatiblen Decoder. Die App kann AV2 für Konvertierungen und Vorschaubilder dekodieren, unterstützt aber noch keine interaktive Wiedergabe. AV2 eignet sich zum Experimentieren statt als Auslieferungsformat.

#### TV (HEVC 10-bit 4:2:2)

Broadcast-Auslieferungsformat mit hardwarekodiertem HEVC 10 Bit 4:2:2, einstellbarer Auflösung und Bildrate, automatischer Bitratenanpassung und allen Audiokanälen als 24-Bit-PCM.

#### TV (AVC-Intra)

Broadcast-Format im MXF-Container. AVC-Intra 10 Bit 4:2:2 mit wählbaren Klassen (50/100/200 Mbps), Auflösung und Bildrate sowie 4/8/16 Mono-Audiokanälen als 24-Bit-PCM.

#### Stream copy

Kopiert vorhandene Audio- und Videostreams in eine neue Datei und erhält ursprüngliche Codecs, Metadaten und Dateiendung. Gut zum Kürzen und Zusammenfügen geeignet.

#### ProRes

Apple ProRes (yuv422p10) für schnittfreundliche Masterdateien. Enthält den ersten Video- und Audiostream, behält 24-Bit-PCM-Audio und verwendet übliche ProRes-Bitraten. Das Standardprofil lässt sich in den Preset-Einstellungen auswählen.

#### Proxy

Kleine Proxydateien in HEVC, ProRes Proxy oder DNxHR mit einstellbarer Auflösungsgrenze. Alle Audiokanäle bleiben als unkomprimiertes PCM erhalten. Ideal für Offline-Schnitt und einen eigenen Proxy-Unterordner neben dem Quellmaterial.

#### DCP (Digital Cinema Package)

SMPTE-konformer DCP-Export. Kodiert Video als JPEG 2000 im 12-Bit-XYZ-Farbraum mit Konvertierung aus BT.709, verpackt es mit asdcp-wrap in MXF und erstellt die erforderlichen SMPTE-XML-Dateien (CPL, PKL, ASSETMAP, VOLINDEX). Unterstützt 2K und 4K in Flat, Scope und Full bei 24/25/30/48 fps mit einstellbarer Bitrate von 100–250 Mbps. Audio wird als 24-Bit-PCM in einer separaten MXF-Spur exportiert. Metadaten je Element umfassen Titel, Inhaltstyp, Anmerkung, Altersfreigabe und Audiosprache. Skalierung: Einpassen mit schwarzen Balken oder Ausfüllen durch Beschneiden.

#### IMF App 2e / RDD 45 (experimentell)

Experimenteller IMF-Paketexport mit einer Bildspur und einer PCM-Audiospur. Untertitel im Paket und mehrere Audiospuren werden nicht unterstützt. Jedes Paket vor der Auslieferung im vorgesehenen Mastering- oder Auslieferungswerkzeug validieren.

#### Image Sequence

Bildsequenzen in PNG, JPEG, TIFF, EXR, DPX, BMP, TGA, SGI, JPEG XL und JPEG 2000 importieren und exportieren. Automatische Erkennung der Bildnummerierung mit Unterstützung für Lücken. Audiodateien können für Wiedergabe und Export zugeordnet werden. Die Bildrate ist je Sequenz einstellbar oder aus der Dauer des zugeordneten Audios berechenbar. Optional können zusätzliche Metadatendateien (Markdown oder JSON) mit Farbraum, Codec und Kamerainformationen exportiert werden.

#### Animated Stills

Animierte Bildsequenzen als GIF, AVIF oder animiertes PNG (APNG), auswählbar in den Preset-Einstellungen.

#### Audio Only AAC

AAC-Stereo-Downmix, der das Stereobild erhält und die Dateigröße deutlich reduziert.

#### Audio Only WAV

Unkomprimierter WAV-Export, der möglichst alle Audiokanäle erhält.

#### 10 eigene FFmpeg-Presets

Zehn Presets (C1–C10) erlauben eigene Ausgabeargumente, Suffixe und Dateiendungen. Eingabeparameter werden automatisch verwaltet. Pfade mit `-copy` lassen sich nicht mit Bildbeschnitt oder Audiozuordnung aus den Preset-Einstellungen kombinieren.

#### [Aufgaben / bekannte Probleme](../../TODO.md)

---

## Screenshots

#### Gruppenansicht mit Timeline

Zeigt eine Sequenz neben der Clipliste mit Vorschaubildern, Audiowellenformen, Trimmgriffen und Ausgabe-Timecode. Die Timeline bietet außerdem Funktionen zum Teilen, Setzen von Markern, Auswählen von Bereichen und Zoomen.

![Gruppenansicht mit Timeline](../screenshots/group-timeline.jpeg)

#### Trimmansicht

![Trimmansicht](https://github.com/user-attachments/assets/0a48088d-e770-402a-a989-dc93d9fcb2c8)

#### Bildbeschnitt

![Bildbeschnitt](https://github.com/user-attachments/assets/97745a95-7bda-43bf-873a-bd865e886690)

#### Audiozuordnung

![Audiozuordnung](https://github.com/user-attachments/assets/b7f0ab61-a6f1-4f90-8ec6-2f90b05c6022)

#### Downloadansicht

![Downloadansicht](https://github.com/user-attachments/assets/b2704580-464a-473d-9cac-9f1991ba4bb5)

#### Metadatenansicht

![Metadatenansicht](https://github.com/user-attachments/assets/77f2c209-bc92-4cca-8e6c-36414bb0ecf3)

#### Timecode überschreiben

![Timecode überschreiben](https://github.com/user-attachments/assets/7c3d951d-9bbb-402c-9984-2fe46fa7d713)

#### Einstellungen

![Einstellungen](https://github.com/user-attachments/assets/26b71bfa-e947-42c8-bc0c-4e3e66e81099)

#### Vollbildplayer

![Vollbildplayer](https://github.com/user-attachments/assets/c9af806f-279e-4a1c-a2ee-a4cae8572911)

---

## Systemanforderungen

| | Minimum |
|---|---|
| macOS | 15.0 (Sequoia) oder neuer |
| Hardware | Apple Silicon (M1 oder neuer) |

---

## Verwendung

1. App starten.
2. Videodateien in das Fenster ziehen oder zum Importieren auf die Plus-Schaltfläche klicken.
3. Ein **Exportpreset** in der Symbolleiste auswählen.
4. Auf die grüne Schaltfläche *Convert* klicken oder ⌘⏎ drücken.

Dies ist ein Freizeitprojekt, für das ich nicht bezahlt werde.

---

## Lizenz

Dieses Projekt wird unter der **GNU General Public License, Version 3.0** veröffentlicht. Den vollständigen Text findest du in [LICENSE](../../LICENSE).

Die mitgelieferte FFmpeg-Binärdatei wurde mit `--enable-gpl` kompiliert und steht unter **GPL v2 oder neuer**. Dieses Projekt verwendet GPL v3 für seinen gesamten Code und erfüllt damit diese Anforderung. Siehe die [ursprüngliche FFmpeg-Lizenz](../../Licenses/ffmpeg-LICENSE.txt).

Die mitgelieferte asdcp-wrap-Binärdatei stammt aus [asdcplib](https://github.com/cinecert/asdcplib) von John Hurst und steht unter der **BSD 3-Clause License**. Siehe die [asdcplib-Lizenz](../../Licenses/asdcplib-LICENSE.txt).

---

## Danksagungen

Die Farbverarbeitung des DCP-Exports basiert auf der hervorragenden Dokumentation von [DCP-o-matic](https://dcpomatic.com/) zur Konvertierung in den DCI-XYZ-Farbraum. DCP-o-matic ist ein kostenloses, quelloffenes Werkzeug zur DCP-Erstellung: [GitHub-Projekt](https://github.com/cth103/dcpomatic).

Die Metadatenprüfung und C2PA-Funktionen zur Inhaltsauthentizität nutzen [SwiftMediaMetadata](https://github.com/aagedal/SwiftMediaMetadata).

---

PS: Die App hieß früher Aagedal VideoLoop Converter. Aagedal Media Converter ist dieselbe App mit einem Namen, der besser beschreibt, was aus ihr geworden ist.
