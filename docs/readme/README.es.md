# Aagedal Media Converter

[English](../../README.md) · [Norsk bokmål](README.nb.md) · [Español](README.es.md) · [简体中文](README.zh-CN.md) · [Français](README.fr.md) · [Italiano](README.it.md) · [Deutsch](README.de.md) · [日本語](README.ja.md) · [Português (Brasil)](README.pt-BR.md)

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

Activa **Settings → Agent Access**, autoriza las carpetas de origen y copia la configuración para tu cliente MCP. El auxiliar incluido permite a los agentes explorar e inspeccionar medios autorizados, planificar conversiones, enviar trabajos, seguir su progreso y cancelarlos en la cola de la aplicación. Están disponibles los 17 preajustes integrados; los preajustes FFmpeg personalizados quedan excluidos. Las exportaciones IMF son experimentales.

Los trabajos aceptados continúan tras desconectar el cliente. Los planes duran 15 minutos y los resultados de trabajos terminados están disponibles durante 30 días. Las exportaciones mediante agentes desactivan el código de tiempo de salida. Consulta la [guía de configuración y flujo de trabajo](../../Documentation/LOCAL_AGENT_ACCESS.md) para la autorización de carpetas, la configuración de clientes y la recuperación de trabajos.

### Animaciones de formas de onda de audio

- Genera animaciones de formas de onda para archivos que solo contienen audio
- Cinco preajustes con opciones de color y normalización

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

Elige IVF (`.ivf`) solo con vídeo o Matroska (`.mkv`) con audio AAC u Opus. La codificación de referencia es muy lenta y el flujo de bits, aún en evolución, requiere un decodificador compatible con AV2. La aplicación puede decodificar AV2 para conversiones y miniaturas, pero todavía no admite reproducción interactiva. Usa AV2 para experimentar, no como formato de entrega.

#### TV (HEVC 10-bit 4:2:2)

Formato de entrega para televisión con HEVC de 10 bits 4:2:2 por hardware, resolución y frecuencia configurables, ajuste automático de bitrate y conservación de todos los canales de audio como PCM de 24 bits.

#### TV (AVC-Intra)

Formato de televisión en contenedor MXF. AVC-Intra de 10 bits 4:2:2 con clases seleccionables de 50/100/200 Mbps, resolución y frecuencia, y 4/8/16 canales mono de audio PCM de 24 bits.

#### Stream copy

Copia los flujos de audio y vídeo existentes a un nuevo archivo, conservando códecs, metadatos y extensión originales. Útil para recortar y unir.

#### ProRes

Apple ProRes (yuv422p10) para másteres fáciles de editar. Incluye los primeros flujos de vídeo y audio, conserva audio PCM de 24 bits y usa los bitrates estándar de ProRes. El perfil predeterminado se elige en los ajustes de preajustes.

#### Proxy

Proxies ligeros en HEVC, ProRes Proxy o DNxHR con límites de resolución configurables. Conserva todos los canales de audio como PCM sin comprimir, ideal para edición offline y una subcarpeta Proxy junto al material original.

#### DCP (Digital Cinema Package)

Exportación DCP conforme a SMPTE. Codifica vídeo como JPEG 2000 en espacio XYZ de 12 bits con conversión desde BT.709, lo encapsula en MXF con asdcp-wrap y genera los XML SMPTE necesarios (CPL, PKL, ASSETMAP, VOLINDEX). Admite 2K y 4K en Flat, Scope y Full a 24/25/30/48 fps, con bitrate configurable de 100–250 Mbps. El audio se exporta como PCM de 24 bits en una pista MXF separada. Los metadatos por elemento incluyen título, tipo de contenido, anotación, clasificación y idioma del audio. Escalado: ajustar con bandas o llenar recortando.

#### IMF App 2e / RDD 45 (experimental)

Exportación experimental de paquetes IMF con una pista de imagen y una pista de audio PCM. No se admiten subtítulos en el paquete ni múltiples pistas de audio. Valida cada paquete en la herramienta de masterización o entrega de destino antes de entregarlo.

#### Image Sequence

Importa y exporta secuencias en PNG, JPEG, TIFF, EXR, DPX, BMP, TGA, SGI, JPEG XL y JPEG 2000. Detecta automáticamente la numeración y admite huecos. Se pueden asociar archivos de audio para reproducción y exportación. La frecuencia se configura por secuencia o se calcula a partir de la duración del audio. La exportación puede incluir archivos auxiliares de metadatos (Markdown o JSON) con espacio de color, códec e información de cámara.

#### Animated Stills

Secuencias animadas en GIF, AVIF o PNG animado (APNG), seleccionables en los ajustes de preajustes.

#### Audio Only AAC

Mezcla reducida a estéreo en AAC que conserva la imagen estéreo y reduce considerablemente el tamaño.

#### Audio Only WAV

WAV sin comprimir que conserva todos los canales siempre que sea posible.

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
