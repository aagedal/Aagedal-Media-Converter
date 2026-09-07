

# Aagedal Media Converter

<img alt="SCR-20260426-ugrc" src="https://github.com/user-attachments/assets/213e64a6-f382-4562-b4cf-797ad1e0f368" />



Una aplicación minimalista y ligera para macOS que es sencilla a primera vista, pero con potentes funciones incorporadas. Funciona con FFMPEG, FFPROBE, MPV, SwiftExif, yt-dlp, rclone y whisper.cpp en segundo plano y está escrita íntegramente en Swift / SwiftUI.

Completamente gratuita y de código abierto. Privada y local. (Un verificador de actualizaciones opcional está activado por defecto, pero se puede desactivar.)

Un proyecto personal; lo hice para mí mismo porque necesitaba ser eficiente en mi trabajo. Solo quería compartirlo.

Ten en cuenta que la mayor parte de esta aplicación se desarrolló de forma ágil e intuitiva.


---

## Instalación

### Homebrew
```bash
brew tap aagedal/tap && brew install --cask aagedal-media-converter
```

### Descarga manual
[Descargar la versión actual](https://github.com/aagedal/Aagedal-Media-Converter/releases/latest)


---


## Características principales
- **Lanzamiento rápido y fácil de usar**
- **Conversión por lotes** de casi todos los archivos de video y audio (alternativa a Shutter Encoder o Handbrake)
- **Reproducir** en pantalla completa con vista de código de tiempo y controles de reproducción JKL (alternativa a IINA o VLC)
- **Ver y comparar metadatos**, incluido el verificador de presencia C2PA (alternativa a MediaInfo)
- **Descargar** videos desde sitios web, con soporte para programación y descarga de transmisiones en vivo
- **Grabación de pantalla** con sonido del sistema y pista de micrófono separada opcional (alternativa a OBS)
- **Transcribir** archivos de video y audio a subtítulos SRT
- **Subir** al servidor después de la conversión


### General
- Vista previa y codificación de casi cualquier archivo de video existente
- Importar y exportar **secuencias de imágenes** (PNG, TIFF, EXR, DPX, JPEG 2000 y más) con asociación de audio y control de tasa de fotogramas
- Exportar **DCP (Paquete Cinematográfico Digital)** para reproducción en cines, con codificación en espacio de color JPEG 2000 XYZ compatible con SMPTE
- Conversión por lotes, monitor de carpetas, barra de progreso,
- Recortar, encuadrar, redirigir o eliminar pistas de audio, fusionar clips (si están en el mismo formato)
- Vista de metadatos con comparación
- Muchos [atajos de teclado](KeyboardShortcuts.md): la mayoría de las funciones son accesibles sin usar el mouse
- Muchas opciones de configuración si deseas personalizar
- Verificación automática de actualizaciones con una notificación discreta, se puede desactivar.
- Descargar desde YouTube, TikTok, etc. (yt-dlp)
- Transcribir a SRT (whisper.cpp)
- Subir a FTP (rclone)
- Verificar firma C2PA (SwiftExif)
- Grabación de pantalla en HDR con sonido del sistema y grabación de micrófono opcional en una pista de audio separada


### Conversión por lotes
- Codificar automáticamente todos los archivos de la cola
- Reordenar archivos arrastrando y soltando para modificar la cola de codificación
- Eliminar archivos de la cola durante la codificación

### Monitor de carpetas
- Importar automáticamente archivos desde una carpeta especificada
- Funciona junto con la ventana de arrastrar y soltar manual, reuniendo todas las codificaciones en una sola ventana
- Eliminación automática opcional y opción para ignorar archivos en la carpeta monitorizada
- Activar presionando el ícono de ojo en la barra de herramientas principal

### Archivos de vista previa
- Atajos comunes de NLE como JKL y las teclas de flecha
- Un medidor de audio simple (CMD + A)
- Utiliza el reproductor nativo de macOS para archivos compatibles, para una reproducción fluida incluso en reversa
- Respaldo invisible al reproductor MPVKit para archivos no soportados nativamente por macOS (aunque la reproducción inversa es menos fiable)


### Ajustes rápidos
- Recortar usando controles de la interfaz o el atajo de teclado I/O
- El código de tiempo se puede copiar desde la fuente, establecer manualmente o eliminarse
- Encuadrar el video con controles en pantalla, accesibles en la vista de recorte presionando C o el ícono de recorte.
    - No funciona con el preset Stream Copy
- Eliminación y reordenamiento de pistas de audio
    - No funciona con el preset Stream Copy

### Fusionar archivos en cola
- Fusionar archivos en uno solo si comparten el mismo codec, resolución, fotogramas por segundo, profundidad de bits y pistas de audio.
- El primer clip de la cola actúa como maestro para el código de tiempo y el encuadre.
- Permite recortar y Copiar flujo al mismo tiempo, lo que permite recortar y fusionar archivos sin pérdida de calidad. (Algunos metadatos pueden perderse)

### Generar animación de forma de onda de audio
- Generar animaciones de forma de onda para archivos solo de audio
- 5 presets diferentes, con opciones de color y normalización

### Capturar rápidamente capturas de pantalla a la resolución y profundidad de bits originales
En el reproductor de recorte hay un botón de cámara que permite capturar imágenes estáticas. Las imágenes se capturarán automáticamente a la resolución de origen. Por defecto, la aplicación capturarán capturas de pantalla en formato JPEG XL. El formato para capturas de pantalla se puede cambiar en la configuración según la profundidad de bits. También hay una opción para especificar qué hacer con el video con canal alfa.


### Exportación y nomenclatura de archivos
- Por defecto, la aplicación eliminará espacios y caracteres especiales. æ, ø, å se reemplazan por ae, o y aa.
- La aplicación mostrará una vista previa del nombre de archivo después del procesamiento
- Advertencia si el archivo ya existe, 
- Después de la codificación, hay un ícono para mostrar el archivo convertido en el directorio de exportación
- Después de la codificación hay un ícono arrastrable, lo que permite arrastrar y abrir el archivo codificado directamente en otra aplicación para copiarlo a un nuevo directorio.

- Establecer preset predeterminado en el menú de configuración
- Establecer ubicación de exportación predeterminada


### Metadatos
- Campo de comentario por archivo, para agregar un comentario opcional a los metadatos del archivo. Útil para incrustar información de créditos
- Etiqueta de fecha opcional (Generado [YYYYMMDD]), prefijo y sufijo en el campo de comentario antes del comentario.
- Ver y comparar metadatos

### Advertencia de reproducción automática de 15 segundos para los presets de VideoLoop
Los navegadores web a menudo se niegan a reproducir automáticamente videos largos y en bucle con sonido. La aplicación muestra un ícono amarillo ⚠️ cuando los presets de VideoLoop se aplican a clips de más de 15 segundos, incentivándote a recortar el video o elegir otro preset.

### Intenciones de la aplicación (App Intents)
1. Añadir a la cola de codificación
2. Convertir video inmediatamente (usando el preset predeterminado).


---

## Presets de exportación
Todos los presets se pueden establecer como predeterminados al iniciar, y todos excepto el predeterminado se pueden ocultar del selector de presets.

#### Video Loop
Optimizado para bucles silenciosos perfectos. Codifica con x264 en CRF 23 (aproximadamente 3–9 Mbps de bitrate variable), elimina el audio y limita el lado más corto a 1080 px para reproducción web.
La advertencia automática de duración se muestra cuando un clip de Video Loop supera los 15 segundos para que puedas recortarlo antes de reproducirlo automáticamente en la web.

#### Video Loop con Audio
Mismas configuraciones x264 que el bucle silenciado, pero conserva cada pista de audio como AAC a 128 kbps, manteniendo el límite de 1080 px en el lado más corto.

#### H.264 / AVC
Codificación H.264/AVC altamente compatible con la opción entre codificación por hardware rápida con VideoToolbox o codificación por software enfocada en calidad con libx264 y control CRF, además de contenedores MP4, MOV y MKV.

#### H.265 / HEVC
Codificación moderna H.265/HEVC de 10 bits. La codificación por hardware mediante VideoToolbox mantiene las exportaciones rápidas, mientras que la codificación por software libx265 puede elegirse para una máxima eficiencia de compresión.

#### AV1
Codificación SVT-AV1 de próxima generación con soporte de 10 bits. La mejor eficiencia de compresión de la aplicación, pero es solo por software (sin aceleración por hardware en macOS).

#### TV (HEVC 10-bit 4:2:2)
Formato de entrega para transmisión con HEVC por hardware de 10 bits 4:2:2, resolución/fotogramas por segundo configurables, escalado de bitrate automático y conservación de todos los canales de audio como PCM de 24 bits.

#### TV (AVC-Intra)
Formato de entrega para transmisión en un contenedor MXF. AVC-Intra 10-bit 4:2:2 ofrece clases seleccionables (50/100/200 Mbps), resolución y fotogramas por segundo, además de canales de audio mono 4/8/16 como PCM de 24 bits.

#### Copia de flujo (Stream copy)
Copia los flujos de audio y video existentes en un nuevo archivo. Su fortaleza radica en mantener los codecs, metadatos y extensión originales, por lo que se combina bien con tareas de recorte o fusión.

#### ProRes
Apple ProRes (yuv422p10) para masters fáciles de editar. Incluye los primeros flujos de video y audio, conserva audio PCM de 24 bits y apunta a bitrates estándar de ProRes. El perfil ProRes predeterminado se puede elegir en Configuración de presets.

#### Proxy
Creación de proxies ligeros en HEVC, ProRes Proxy o DNxHR con límites de resolución configurables. Conserva cada canal de audio como PCM sin comprimir, lo cual es ideal para edición offline y para combinar con una subcarpeta Proxy dedicada junto al material de origen.

#### DCP (Paquete Cinematográfico Digital)
Exportación de Paquete Cinematográfico Digital compatible con SMPTE. Codifica el video como JPEG 2000 en espacio de color XYZ de 12 bits con conversión de entrada BT.709, envuelve a MXF usando asdcp-wrap y genera todo el XML SMPTE requerido (CPL, PKL, ASSETMAP, VOLINDEX). Soporta tamaños de contenedor 2K y 4K Flat, Scope y Full a 24/25/30/48 fps con bitrate configurable (100–250 Mbps). El audio se exporta como PCM de 24 bits en una pista MXF separada. La edición de metadatos por elemento incluye título del contenido, tipo de contenido, anotación, clasificación e idioma de audio. Modos de escalado: ajustar (con barras) o llenar (recortar).

#### Secuencia de imágenes
Importar y exportar secuencias de imágenes en PNG, JPEG, TIFF, EXR, DPX, BMP, TGA, SGI, JPEG XL y JPEG 2000. La importación detecta automáticamente la numeración de fotogramas y soporta huecos. Los archivos de audio pueden asociarse a una secuencia para reproducción y exportación. La tasa de fotogramas es configurable por secuencia y puede derivarse automáticamente de la duración del audio asociado. Las exportaciones incluyen archivos secundarios de metadatos opcionales (Markdown o JSON) con información de espacio de color, codec y cámara.

#### Imágenes estáticas animadas
Secuencia de imágenes estáticas animadas construida como GIF, AVIF o PNG animado (APNG), seleccionable desde el menú Configuración de presets.

#### Solo Audio AAC
Archivo AAC de mezcla en descenso a estéreo que mantiene la separación estéreo mientras reduce drásticamente el tamaño del archivo.

#### Solo Audio WAV
Exportación WAV sin comprimir que conserva cada canal de audio siempre que sea posible.

#### 10 presets personalizados de FFMPEG
Diez presets personalizados (C1–C10) te permiten proporcionar tus propios argumentos de salida, sufijos y extensiones. Los parámetros de entrada se gestionan por ti, pero ten en cuenta que las rutas -copy no pueden combinarse con los interruptores de recorte o redirección de audio que se encuentran en Configuración de presets.



#### [TODO / Problemas conocidos](TODO.md)


## Capturas de pantalla

#### Vista de recorte
<img alt="SCR-20260426-ulyb-2" src="https://github.com/user-attachments/assets/0a48088d-e770-402a-a989-dc93d9fcb2c8" />


#### Vista de encuadre
![SCR-20251217-nptb](https://github.com/user-attachments/assets/97745a95-7bda-43bf-873a-bd865e886690)


#### Redirección de audio
<img alt="SCR-20251217-nqcb" src="https://github.com/user-attachments/assets/b7f0ab61-a6f1-4f90-8ec6-2f90b05c6022" />


#### Vista de descarga
<img alt="SCR-20260426-umjw" src="https://github.com/user-attachments/assets/b2704580-464a-473d-9cac-9f1991ba4bb5" />


#### Vista de metadatos
<img alt="SCR-20260426-unem" src="https://github.com/user-attachments/assets/77f2c209-bc92-4cca-8e6c-36414bb0ecf3" />


#### Vista de anulación de código de tiempo
<img alt="SCR-20251217-nqlo" src="https://github.com/user-attachments/assets/7c3d951d-9bbb-402c-9984-2fe46fa7d713" />


#### Vista de configuración
<img alt="SCR-20260426-uoiq" src="https://github.com/user-attachments/assets/26b71bfa-e947-42c8-bc0c-4e3e66e81099" />


#### Reproductor a pantalla completa
<img alt="SCR-20260426-uomf" src="https://github.com/user-attachments/assets/c9af806f-279e-4a1c-a2ee-a4cae8572911" />




---

## Requisitos

|                | Mínimo |
|----------------|---------|
| macOS          | 15.0 (Sequoia) o posterior |
| Hardware       | Apple Silicon (M1 o posterior) |


---

## Uso

1. Inicia la aplicación.
2. Arrastra archivos de video a la ventana **o** haz clic en el botón más para importar archivos.
3. Selecciona un **Preset de exportación** desde el menú de la barra de herramientas.
4. Pulsa el botón verde *Convertir* o presiona ⌘⏎.



Ten en cuenta que este es un proyecto de tiempo libre. Es un proyecto personal por el que no recibo pago.

---

## Licencia

Este proyecto se distribuye bajo la **Licencia Pública General de GNU, versión 3.0**. Consulta el archivo [LICENSE](LICENSE) para ver el texto completo.

El binario FFmpeg incluido se compila con `--enable-gpl` y, por lo tanto, también está licenciado bajo **GPL v2 o posterior**. Este proyecto elige GPL v3 para todo el código, cumpliendo con ese requisito. Consulta la licencia original de FFmpeg en [Licenses/ffmpeg-LICENSE.txt](Licenses/ffmpeg-LICENSE.txt).

El binario asdcp-wrap incluido proviene de [asdcplib](https://github.com/cinecert/asdcplib) de John Hurst, licenciado bajo la **Licencia BSD de 3 Cláusulas**. Consulta [Licenses/asdcplib-LICENSE.txt](Licenses/asdcplib-LICENSE.txt).

---

## Agradecimientos

El procesamiento de color de la función de exportación DCP (Paquete Cinematográfico Digital) se vio influenciado por la excelente documentación del proyecto [DCP-o-matic](https://dcpomatic.com/) sobre la conversión del espacio de color DCI XYZ. DCP-o-matic es un creador de DCP gratuito y de código abierto; consúltalo en https://github.com/cth103/dcpomatic.

Las funciones de inspección de metadatos y autenticidad de contenido C2PA están impulsadas por [SwiftExif](https://github.com/kradalby/SwiftExif).

---

PD: Esta aplicación se llamaba anteriormente Aagedal VideoLoop Converter. Aagedal Media Converter es la misma aplicación, solo con un nuevo nombre que refleja mejor en lo que se ha convertido.
