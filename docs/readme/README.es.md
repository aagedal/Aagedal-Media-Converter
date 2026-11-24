# Aagedal Media Converter

[English](../../README.md) · [Norsk bokmål](README.nb.md) · [Español](README.es.md) · [简体中文](README.zh-CN.md) · [Français](README.fr.md) · [Italiano](README.it.md) · [Deutsch](README.de.md) · [日本語](README.ja.md) · [Português (Brasil)](README.pt-BR.md) · [한국어](README.ko.md)

<img alt="Aagedal Media Converter" src="https://github.com/user-attachments/assets/213e64a6-f382-4562-b4cf-797ad1e0f368" />

Una aplicación ligera y minimalista para macOS, sencilla a primera vista pero con funciones potentes. Utiliza FFmpeg, MPV, SwiftMediaMetadata, yt-dlp, rclone y whisper.cpp, y está escrita íntegramente en Swift / SwiftUI.

Totalmente gratuita y de código abierto. Privada y local. La comprobación opcional de actualizaciones está activada de forma predeterminada, pero se puede desactivar.

Un proyecto personal: la creé para trabajar con más eficiencia y quise compartirla. Ten en cuenta que gran parte de la aplicación se ha desarrollado mediante «vibe coding», con asistencia de IA.

---

## Instalación

### Homebrew
```bash
brew tap aagedal/tap && brew install --cask aagedal-media-converter
```

### Descarga manual
[Descargar la versión actual](https://github.com/aagedal/Aagedal-Media-Converter/releases/latest)

---

## Funciones principales

- **Inicio rápido y uso sencillo**
- **Conversión por lotes** de casi cualquier archivo de vídeo o audio (alternativa a Shutter Encoder o Handbrake)
- **Reproducción** a pantalla completa con código de tiempo y controles JKL (alternativa a IINA o VLC)
- **Consulta y comparación de metadatos**, incluida la detección de C2PA (alternativa a MediaInfo)
- **Análisis** de sonoridad, silencios, picos, fase estéreo y calidad del vídeo codificado
- **Descarga** de vídeos de sitios web, con programación y descarga de emisiones en directo
- **Grabación de pantalla** con audio del sistema y pista de micrófono separada opcional (alternativa a OBS)
- **Transcripción** de vídeo y audio a subtítulos SRT
- **Subida** a un servidor tras la conversión
- **Unir** clips en una línea de tiempo con previsualización de la secuencia y recorte con desplazamiento de los clips siguientes
- **Automatizar conversiones mediante MCP local** con acceso opcional para agentes

### General

- Previsualiza y codifica casi cualquier archivo de vídeo
- Importa y exporta **secuencias de imágenes** (PNG, TIFF, EXR, DPX, JPEG 2000 y más) con audio asociado y control de la frecuencia de fotogramas
- Exporta **DCP (Digital Cinema Package)** con imagen JPEG 2000 XYZ y audio PCM
- Exporta paquetes experimentales **IMF App 2e y RDD 45** para validarlos en la herramienta de entrega
- Conversión por lotes, carpeta vigilada y barra de progreso
- Recorta la duración o el encuadre, reasigna o elimina pistas de audio y une clips del mismo formato
- Consulta y compara metadatos
- Muchos [atajos de teclado](../../KeyboardShortcuts.md): la mayoría de las funciones se pueden usar sin ratón
- Numerosos ajustes de personalización
- Comprobación automática de actualizaciones con aviso discreto; se puede desactivar
- Descarga desde YouTube, TikTok, etc. (yt-dlp)
- Transcripción a SRT (whisper.cpp)
- Subida por FTP (rclone)
- Comprobación de firmas C2PA (SwiftMediaMetadata)
- Grabación de pantalla en HDR con audio del sistema y micrófono opcional en una pista separada

### Conversión por lotes

- Codifica automáticamente todos los archivos de la cola
- Cambia el orden de codificación arrastrando los archivos
- Elimina archivos de la cola durante la codificación

### Carpeta vigilada

- Importa automáticamente archivos de una carpeta específica
- Funciona junto con la importación manual por arrastrar y soltar; todas las conversiones se reúnen en una ventana
- Opciones para eliminar automáticamente e ignorar archivos de la carpeta
- Se activa con el icono del ojo en la barra de herramientas de la ventana principal

### Previsualización

- Atajos habituales de edición, como JKL y las flechas
- Medidor de audio sencillo (⌘A)
- Reproductor nativo de macOS para archivos compatibles, con reproducción fluida incluso hacia atrás
- Cambio automático a MPVKit para formatos no compatibles con macOS, aunque la reproducción hacia atrás es menos fiable

### Ajustes rápidos

- Recorta la duración con tiradores o las teclas I/O
- Copia el código de tiempo del original, introdúcelo manualmente o elimínalo
- Recorta el encuadre con controles en pantalla; pulsa C o el icono de recorte en la vista de recorte de duración
    - No funciona con el preajuste Stream Copy
- Elimina o reordena pistas de audio
    - No funciona con el preajuste Stream Copy

### Ajustes

Haz clic derecho en un archivo de la cola y elige **Ajustes…** para configurar, por archivo:
- **Rotar** 90°/180° y **voltear** horizontal o verticalmente (se aplica después del recorte de encuadre y antes del escalado del preajuste)
- **Velocidad** de 0,25× a 4× con conservación del tono del audio
- **Fundido** de vídeo desde/hacia negro, y fundido de entrada y salida de audio
- **Desfase de audio** para corregir clips desincronizados (los valores positivos retrasan el audio)
- **Reemplazar o añadir audio** desde otro archivo, alineado con el recorte de duración y ajustado a la duración del vídeo
- **Incrustar subtítulos** desde una pista de subtítulos de texto o un archivo SRT, ASS o VTT, con tamaño de fuente, contorno o recuadro y posición. Los subtítulos de imagen (PGS, DVD) requieren primero reconocimiento OCR a SRT.
- Anulación por archivo de la normalización de sonoridad

Los ajustes requieren un preajuste con recodificación; no están disponibles para Stream Copy, DCP, IMF, AV2, uniones ni vídeos generados de formas de onda.

### Normalización de sonoridad

Activa **Normalize Loudness** en Ajustes → Preajustes para normalizar cada pista de audio recodificada según EBU R128 (−23 LUFS, −1 dBTP), ATSC A/85, streaming (−14 LUFS), web/podcast (−16 LUFS) o un objetivo personalizado. Cada pista se mide en una primera pasada y después se normaliza con el filtro `loudnorm` de FFmpeg aplicando ganancia lineal cuando el programa lo permite. En preajustes de televisión con pistas mono, como AVC-Intra, la medición se realiza por pista de origen antes de la división, de modo que se conserva el balance estéreo.

### Unir archivos de la cola

- Une archivos con el mismo códec, resolución, frecuencia de fotogramas, profundidad de bits y pistas de audio
- El primer clip determina el código de tiempo y el recorte de encuadre
- Edita grupos en la línea de tiempo con tiras de miniaturas, reproducción de la secuencia, recorte con desplazamiento, reordenación, división, eliminación de rangos y deshacer.
- Recorta y une con Stream Copy sin recodificar. Los cortes dependen de los fotogramas clave del original y pueden diferir de los límites seleccionados; algunos metadatos pueden perderse.
- Exporta marcadores de clips en EDL para Resolve y capítulos incrustados, con la opción de conservar o reemplazar capítulos existentes.

### Importación de tarjetas de cámara

- Revisa los clips por carpeta de la tarjeta y fecha de grabación antes de importar.
- Marca explícitamente las continuaciones de grabación y, opcionalmente, divide grupos tras pausas de más de dos horas. Las comprobaciones de compatibilidad ayudan a identificar clips que se pueden unir.

### Acceso local para agentes

Activa **Settings → Agent Access**, autoriza las carpetas de origen y copia la configuración para tu cliente MCP. El auxiliar incluido permite a los agentes explorar e inspeccionar medios autorizados, planificar conversiones, enviar trabajos, seguir su progreso y cancelarlos en la cola de la aplicación. Están disponibles 21 preajustes integrados (todos los preajustes integrados excepto Lossless FFV1); los espacios FFmpeg personalizados quedan excluidos. Las exportaciones IMF son experimentales.

Los trabajos aceptados continúan tras desconectar el cliente. Los planes duran 15 minutos y los resultados de trabajos terminados están disponibles durante 30 días. Las exportaciones mediante agentes desactivan el código de tiempo de salida. Consulta la [guía de configuración y flujo de trabajo](../../Documentation/LOCAL_AGENT_ACCESS.md) para la autorización de carpetas, la configuración de clientes y la recuperación de trabajos.

### Animaciones de formas de onda de audio

- Genera animaciones de formas de onda para archivos que solo contienen audio
- 7 estilos nativos en Swift (entre ellos Halo, Orb, Ridgeline y LED Meter) además de 5 estilos clásicos de FFmpeg, con paletas de degradado y opciones de color, opacidad, fondo transparente y normalización

### Capturas con la resolución y profundidad de bits del original

El botón de cámara del reproductor de recorte captura imágenes con la resolución original. El formato predeterminado es JPEG XL. Puedes elegir el formato por profundidad de bits en los ajustes, así como el tratamiento del canal alfa.

### Exportación y nombres de archivo

- De forma predeterminada se eliminan espacios y caracteres especiales. æ, ø y å se sustituyen por ae, o y aa.
- Vista previa del nombre procesado
- Aviso si el archivo ya existe
- Tras la codificación, un icono muestra el archivo convertido en la carpeta de exportación
- Otro icono permite arrastrar el resultado a otra aplicación o carpeta
- Selección del preajuste predeterminado en los ajustes
- Selección de la ubicación de exportación predeterminada

### Metadatos

- Campo de comentario por archivo para añadir metadatos opcionales, por ejemplo créditos
- Etiqueta de fecha opcional (Generated [YYYYMMDD]), prefijo y sufijo en el campo, antes del comentario
- Consulta y comparación de metadatos

### Análisis multimedia

![Muestras verificadas de SSIMULACRA2 junto a la reproducción del original](../images/ssimulacra2-frame-inspection-en.png)
Pulsa el botón de gráfico en un archivo de la cola para consultar sus informes de audio y vídeo.

- Mide la sonoridad del programa completo y el pico real en pistas individuales, pares mono personalizados o grupos mono 5.1; exporta informes completos en JSON o PDF.
- Detecta intervalos de silencio y de pico, compara el balance de canales o comprueba la correlación estéreo y la mezcla a mono. Salta a las secciones medidas en la previsualización en pausa y exporta las mediciones completas en JSON.
- Detecta intervalos en negro (`blackdetect` de FFmpeg, con duración mínima, proporción de imagen y umbral de píxel ajustables) y cortes de escena (`scdet` de FFmpeg, con umbral ajustable y una miniatura por corte) en el vídeo original. Haz clic en un evento para inspeccionarlo en la previsualización en pausa y exporta los resultados en JSON o como marcadores EDL para Resolve. Consulta los formatos de informe de [negros](../../docs/video-black-report-format.md) y [cortes de escena](../../docs/video-scene-cut-report-format.md).
- Tras la codificación, compara el vídeo con VMAF, PSNR, XPSNR o muestras de SSIMULACRA2. Inspecciona la calidad a lo largo del tiempo, alterna entre la reproducción del original y del resultado y salta a los tramos con menor puntuación.
- SSIMULACRA2 compara fotogramas decodificados verificados hasta el límite seleccionado, incluso en clips cortos. Los vídeos se indexan primero; cuantas más muestras, mayor será el tiempo de análisis.
- Exporta la calidad de vídeo como JSON a resolución completa o como PDF A4 paginado con líneas de tiempo, puntuaciones por componente y avisos de comparación. Consulta [la interpretación de puntuaciones y detalles del informe](../../docs/video-quality-report-format.md).

### Aviso de reproducción automática a los 15 segundos para VideoLoop

Los navegadores suelen impedir la reproducción automática de vídeos largos en bucle con sonido. La aplicación muestra un icono amarillo ⚠️ al aplicar un preajuste VideoLoop a clips de más de 15 segundos, para que puedas recortarlos o elegir otro preajuste.

### App Intents

1. Añadir a la cola de codificación.
2. Convertir vídeo inmediatamente con el preajuste predeterminado.

---

## Preajustes de exportación

Todos los preajustes pueden establecerse como predeterminados al iniciar. Todos, salvo el predeterminado, pueden ocultarse del selector.

#### Video Loop

Bucles silenciosos y continuos. Codifica con x264 a CRF 23 (aproximadamente 3–9 Mbps de bitrate variable), elimina el audio y limita el lado más corto a 1080 píxeles para la web. Avisa cuando el clip supera los 15 segundos.

#### Video Loop w/ Audio

Los mismos ajustes x264, pero conserva todas las pistas de audio como AAC a 128 kbps. Mantiene el límite de 1080 píxeles en el lado más corto.

#### H.264 / AVC

Codificación H.264/AVC de amplia compatibilidad. Elige VideoToolbox por hardware para mayor rapidez o libx264 por software con control CRF para priorizar la calidad. Contenedores MP4, MOV y MKV.

#### H.265 / HEVC

Codificación H.265/HEVC de 10 bits. VideoToolbox acelera la exportación por hardware; libx265 por software ofrece alta eficiencia de compresión.

#### AV1

Codificación SVT-AV1 con soporte de 10 bits y alta eficiencia de compresión. Solo por software, sin aceleración por hardware en macOS.

#### AV2 (experimental)

Codificación AV2 experimental con el codificador de referencia AOM AVM incluido (`avmenc`), introducida en una versión preliminar. Admite 8/10 bits, calidad constante o bitrate variable, y velocidad y resolución configurables. La codificación paralela por segmentos utiliza varios núcleos de CPU en modo de calidad constante.

El codificador y el decodificador incluidos utilizan AVM `1.0.0-445-g14342caad` (14 de octubre de 2026). Estas herramientas siguen siendo experimentales; consulta la [validación de compilación y compatibilidad](../../docs/av2-integrated-encoder-2026-10-14.md) para ver el código fuente fijado, las instrucciones de recompilación y las comprobaciones.

Elige IVF (`.ivf`) solo con vídeo o Matroska (`.mkv`) con audio AAC u Opus. La codificación de referencia es muy lenta y la reproducción requiere un decodificador compatible con AV2. La aplicación puede decodificar AV2 para conversiones y miniaturas, pero todavía no admite reproducción interactiva. Usa AV2 para experimentar, no como formato de entrega.

#### VP9 / WebM

VP9 libre de regalías para la web, codificado con libvpx en calidad constante (CRF con objetivo de bitrate cero) y multihilo por filas. Elige el valor CRF, una velocidad de Best a Realtime, 8 bits (perfil 0) o 10 bits (perfil 2) y un límite de resolución. El audio se codifica en Opus con bitrate seleccionable. Genera archivos WebM o Matroska (`.mkv`). Opus no admite algunas distribuciones de canales, como `5.1(side)`; haz la mezcla reducida de esas pistas mediante la reasignación de audio.

#### TV (HEVC 10-bit 4:2:2)

Formato de entrega para televisión con HEVC de 10 bits 4:2:2 por hardware, resolución y frecuencia configurables, ajuste automático de bitrate y conservación de todos los canales de audio como PCM de 24 bits.

#### TV (AVC-Intra)

Formato de televisión en contenedor MXF. AVC-Intra de 10 bits 4:2:2 con clases seleccionables de 50/100/200 Mbps, resolución y frecuencia, y 4/8/16 canales mono de audio PCM de 24 bits.

#### XDCAM HD422 (MXF)

Entrega para televisión en Sony XDCAM HD422: MPEG-2 4:2:2 Profile @ High Level, CBR de 50 Mbps con GOP largo (GOP cerrados de 12 fotogramas a 25/50 Hz y 15 a 29,97/59,94 Hz, dos fotogramas B) en un archivo MXF OP1a. Elige entre 1080i50, 1080p25, 1080i59.94, 1080p29.97, 720p50 o 720p59.94. El material de origen se escala con bandas laterales o horizontales (pillarbox o letterbox) a ráster completo 16:9, y el audio se entrega en 4 u 8 pistas mono PCM de 24 bits a 48 kHz.

#### Stream copy

Copia los flujos de audio y vídeo existentes a un nuevo archivo, conservando códecs, metadatos y extensión originales. Útil para recortar y unir.

#### ProRes

Apple ProRes (yuv422p10) para másteres fáciles de editar. Incluye los primeros flujos de vídeo y audio, conserva audio PCM de 24 bits y usa los bitrates estándar de ProRes. El perfil predeterminado se elige en los ajustes de preajustes.

#### DNxHR

Avid DNxHR a la resolución original para edición y masterización: LB, SQ o HQ (8 bits 4:2:2), HQX (10 bits 4:2:2) o 444 (10 bits 4:4:4). Elige contenedor MOV o MXF. Todas las pistas de audio se conservan en PCM de 24 bits (remuestreadas a 48 kHz en MXF).

#### CineForm

GoPro CineForm a la resolución original en contenedor MOV, para edición y acabado: YUV de 10 bits 4:2:2, RGB de 12 bits 4:4:4 o RGB de 12 bits 4:4:4 con canal alfa. Elige una calidad desde Low hasta Film Scan 3+ (Film Scan 1 por defecto). El códec almacena como máximo 12 bits por canal, por lo que las fuentes de 16 bits se reducen a 12 bits. El codificador de FFmpeg requiere una anchura múltiplo de 16, así que otros anchos se rellenan con negro a los lados. Todas las pistas de audio se conservan en PCM de 24 bits.

#### Proxy

Proxies ligeros en HEVC, ProRes Proxy o DNxHR con límites de resolución configurables. Conserva todos los canales de audio como PCM sin comprimir, ideal para edición offline y una subcarpeta Proxy junto al material original.

#### DCP (Digital Cinema Package)

Exportación de Digital Cinema Package. Codifica vídeo como JPEG 2000 en espacio XYZ de 12 bits con conversión desde BT.709, lo encapsula en MXF con asdcp-wrap y genera los XML del paquete (CPL, PKL, ASSETMAP, VOLINDEX). Admite 2K y 4K en Flat, Scope y Full a 24/25/30/48 fps, con bitrate configurable de 100–250 Mbps. El audio se exporta como PCM de 24 bits en una pista MXF separada. Los metadatos por elemento incluyen título, tipo de contenido, anotación, clasificación y idioma del audio. Escalado: ajustar con bandas o llenar recortando.

#### IMF App 2e / RDD 45 (experimental)

Exportación experimental de paquetes IMF con una pista de imagen y una pista de audio PCM. No se admiten subtítulos en el paquete ni múltiples pistas de audio. Valida cada paquete en la herramienta de masterización o entrega de destino antes de entregarlo.

#### Image Sequence

Importa y exporta secuencias en PNG, JPEG, TIFF, EXR, DPX, BMP, TGA, SGI, JPEG XL y JPEG 2000. Detecta automáticamente la numeración y admite huecos. Se pueden asociar archivos de audio para reproducción y exportación. La frecuencia se configura por secuencia o se calcula a partir de la duración del audio. La exportación puede incluir archivos auxiliares de metadatos (Markdown o JSON) con espacio de color, códec e información de cámara.

#### Animated Stills

Secuencias animadas en GIF, AVIF, PNG animado (APNG), WebP animado o JPEG XL animado, seleccionables en los ajustes de preajustes.

#### Lossless (FFV1)

Codificación de archivo FFV1 matemáticamente sin pérdidas en Matroska (`.mkv`) con audio PCM sin comprimir.

#### Audio Only

Extrae o transcodifica audio como WAV (PCM sin comprimir conservando todos los canales), FLAC, ALAC o AAC/MP4, configurable en los ajustes de preajustes.

#### 10 preajustes FFmpeg personalizados

Diez preajustes (C1–C10) permiten definir argumentos de salida, sufijos y extensiones. Los parámetros de entrada se gestionan automáticamente. Las rutas con `-copy` no pueden combinarse con recorte de encuadre ni reasignación de audio en los ajustes de preajustes.

#### [Tareas pendientes / problemas conocidos](../../TODO.md)

---

## Capturas de pantalla

#### Vista de línea de tiempo del grupo

Previsualiza una secuencia junto a la lista de clips, con miniaturas, formas de onda de audio, tiradores de recorte y código de tiempo de salida. La línea de tiempo también ofrece controles de división, marcadores, selección de rangos y zoom.

![Vista de línea de tiempo del grupo](../screenshots/group-timeline.jpeg)

#### Vista de recorte de duración

![Vista de recorte de duración](https://github.com/user-attachments/assets/0a48088d-e770-402a-a989-dc93d9fcb2c8)

#### Vista de recorte de encuadre

![Vista de recorte de encuadre](https://github.com/user-attachments/assets/97745a95-7bda-43bf-873a-bd865e886690)

#### Reasignación de audio

![Reasignación de audio](https://github.com/user-attachments/assets/b7f0ab61-a6f1-4f90-8ec6-2f90b05c6022)

#### Vista de descargas

![Vista de descargas](https://github.com/user-attachments/assets/b2704580-464a-473d-9cac-9f1991ba4bb5)

#### Vista de metadatos

![Vista de metadatos](https://github.com/user-attachments/assets/77f2c209-bc92-4cca-8e6c-36414bb0ecf3)

#### Modificación del código de tiempo

![Modificación del código de tiempo](https://github.com/user-attachments/assets/7c3d951d-9bbb-402c-9984-2fe46fa7d713)

#### Ajustes

![Ajustes](https://github.com/user-attachments/assets/26b71bfa-e947-42c8-bc0c-4e3e66e81099)

#### Reproductor a pantalla completa

![Reproductor a pantalla completa](https://github.com/user-attachments/assets/c9af806f-279e-4a1c-a2ee-a4cae8572911)

---

## Requisitos

| | Mínimo |
|---|---|
| macOS | 15.0 (Sequoia) o posterior |
| Hardware | Apple Silicon (M1 o posterior) |

---

## Uso

La interfaz de la aplicación está disponible en inglés, noruego bokmål, alemán, español, francés, italiano, japonés, coreano, portugués de Brasil y chino simplificado. Sigue el idioma preferido configurado para la app en Ajustes del Sistema de macOS. Las ocho traducciones recién añadidas son una primera versión; las cadenas pendientes de revisión lingüística están marcadas como **Needs Review** en `Aagedal Media Converter/Resources/Localizable.xcstrings`.

1. Abre la aplicación.
2. Arrastra vídeos a la ventana o pulsa el botón más para importarlos.
3. Selecciona un **preajuste de exportación** en la barra de herramientas.
4. Pulsa el botón verde *Convert* o ⌘⏎.

Este es un proyecto personal de tiempo libre por el que no recibo remuneración.

---

## Licencia

Este proyecto se distribuye bajo la **GNU General Public License, versión 3.0**. Consulta [LICENSE](../../LICENSE) para ver el texto completo.

El binario FFmpeg incluido se compila con `--enable-gpl` y tiene licencia **GPL v2 o posterior**. Este proyecto utiliza GPL v3 para todo el código, cumpliendo ese requisito. Consulta la [licencia original de FFmpeg](../../Licenses/ffmpeg-LICENSE.txt).

El binario asdcp-wrap incluido procede de [asdcplib](https://github.com/cinecert/asdcplib), de John Hurst, con licencia **BSD 3-Clause License**. Consulta la [licencia de asdcplib](../../Licenses/asdcplib-LICENSE.txt).

---

## Agradecimientos

El procesamiento de color de la exportación DCP se basa en la excelente documentación de [DCP-o-matic](https://dcpomatic.com/) sobre la conversión al espacio DCI XYZ. DCP-o-matic es un creador de DCP gratuito y de código abierto: [proyecto en GitHub](https://github.com/cth103/dcpomatic).

La inspección de metadatos y las funciones de autenticidad C2PA utilizan [SwiftMediaMetadata](https://github.com/aagedal/SwiftMediaMetadata).

---

¡PD! Antes esta aplicación se llamaba Aagedal VideoLoop Converter. Aagedal Media Converter es la misma aplicación, con un nombre que refleja mejor lo que ha llegado a ser.
