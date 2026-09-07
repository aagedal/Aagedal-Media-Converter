# Aagedal Media Converter

<img alt="SCR-20260426-ugrc" src="https://github.com/user-attachments/assets/213e64a6-f382-4562-b4cf-797ad1e0f368" />



A lightweight minimalist macOS application that is simple on the surface, but with powerful features baked in. Powered by FFMPEG, FFPROBE, MPV, SwiftMediaMetadata, yt-dlp, rclone, whisper.cpp under the hood and written entirely in Swift / SwiftUI.

Completely free and open source. Private and local. (An optional update checker is activated by default, but it can be turned off.)

A passion project; I made this for myself because I need it to be efficient at my job. I just wanted to share.

Note that most of this app is vibe-coded.


---

## Installation

### Homebrew
```bash
brew tap aagedal/tap && brew install --cask aagedal-media-converter
```

### Manual download
[Download the current release](https://github.com/aagedal/Aagedal-Media-Converter/releases/latest)


---


## Key Features
- **Quick to launch and easy to use**
- **Batch Convert** almost every video and audio file (alternative to Shutter Encoder or Handbrake)
- **Play** in full screen with TimeCode view and JKL playback controls (alternative to IINA or VLC)
- **View and compare metadata**, including C2PA presence check (alternative to MediaInfo)
- **Download** videos from websites, with support for scheduling and live stream download
- **Screen recording** with system sound, and optional separate microphone track (alternative to OBS)
- **Transcribe** video and audio files to SRT subtitles
- **Upload** to server after conversion


### General
- Preview and encode almost every video file that exists
- Import and export **image sequences** (PNG, TIFF, EXR, DPX, JPEG 2000, and more) with audio association and frame rate control
- Export **DCP (Digital Cinema Package)** for cinema playback, with SMPTE-compliant JPEG 2000 XYZ color space encoding
- Batch conversion, watch folder, progress bar,
- Trim, crop, reroute or remove audio tracks, merge clips (if in the same format)
- Metadata view with comparison
- Lots of [keyboard shortcuts](KeyboardShortcuts.md): most features are accessible without using a mouse
- Lots of settings if you want to customize
- Automatically check for updates with a subtle update notification, can be turned off.
- Download from YouTube, TikTok etc. (yt-dlp)
- Transcribe to SRT (whisper.cpp)
- Upload to FTP (rclone)
- Check for C2PA signature (SwiftMediaMetadata)
- Screen recording in HDR with system sound, and optional microphone recording to separate audio track


### Batch conversion
- Automatically encode all the files in the queue
- Reorder files by drag and drop to reorder encoding queue
- Delete files from the queue while encoding

### Watch folder
- Automatically import files from a specified folder
- Works along the manual drag and drop window, collecting all encodes into one window
- Optional auto-delete and ignore files in the watch folder
- Activate by pressing the eye-icon in the main window toolbar

### Preview files
- Common NLE shortcuts like JKL and arrow keys
- A simple audio meter (CMD + A)
- Uses native macOS player for compatible files, for smooth playback even in reverse
- Invisible fallback to MPVKit player for files not supported by macOS natively (though reverse playback is less reliable)


### Quick adjustments
- Trim using UI handles or I/O keyboard shortcut
- Timecode can be copied from the source, set manually or be removed
- Crop the video with on screen controls – accessible in the trim view by pressing C or the crop icon.
    - Does not work with the Stream Copy preset
- Audio Track deletion and rearrangement
    - Does not work with the Stream Copy preset

### Merge queued files
- Merge files into one if they are the same codec, resolution, frame rate, bit depth, and audio tracks.
- The first clip in the queue works as a master for timecode and crop.
- Allows trimming and Copy Stream at the same time, allowing you to trim and merge files without any quality loss. (Some metadata may be lost)

### Generate Audio Waveform Animation
- Generate Audio Waveform Animations for audio only files
- 5 different presets, with color and normalization options

### Quickly Grab Screenshots at source resoltuion and bit depth
In the trim player there is a camera button that allows capturing still images. Images will automatically be captured at source resolution. By default the app will capture screenshots in JPEG XL. Format for screenshots and can be changed in the settings on a per bit-depth basis. Also a setting to specify what to do with alpha-channel video.


### Export and file-naming
- By default the app will remove spaces and special characters. æ, ø, å is replaced with ae, o and aa.
- The app will preview the filename after processing
- Warning if file already exists, 
- After encoding there is an icon to show the converted file in the export directory
- After encoding there is a draggable icon, making it possible to drag and open the encoded file directly in another app to copy to a new directory.

- Set default preset in the settings menu
- Set default export location


### Metadata
- Per file comment field, to add an optional comment to the file metadata. Useful for embedding credit information
- Optional date tag (Generated [YYYYMMDD]), prefix and suffix in the comment field before the comment.
- View and compare metadata

### 15-Second Autoplay Warning for VideoLoop presets
Web browsers often refuse to autoplay long, looping videos with sound. The app shows a yellow ⚠️ icon when the VideoLoop presets are applied to clips longer than 15 seconds, encouraging you to trim the video or pick another preset.

### App Intents
1. Add to Encode Cue
2. Convert Video Immediately (using the default preset).


---

## Export Presets
All presets can be set as default on launch, and all except the default can be hidden from the preset selector.

#### Video Loop
Optimized for seamless silent loops. Encodes with x264 at CRF 23 (roughly 3–9 Mbps variable bitrate), strips audio, and limits the shortest edge to 1080 px for web playback.
Automatic duration warning shows when a Video Loop clip exceeds 15 seconds so you can trim it before autoplaying on the web.

#### Video Loop w/ Audio
Same x264 settings as the muted loop but keeps every audio track as 128 kbps AAC while still capping the shortest edge at 1080 px.

#### H.264 / AVC
Highly compatible H.264/AVC encoding with a choice between fast VideoToolbox hardware encoding or quality-focused libx264 software encoding with CRF control plus MP4, MOV, and MKV containers.

#### H.265 / HEVC
Modern 10-bit H.265/HEVC encoding. Hardware encoding via VideoToolbox keeps exports quick, while libx265 software encoding can be chosen for maximum compression efficiency.

#### AV1
Next-generation SVT-AV1 encoding with 10-bit support. The best compression efficiency in the app, but it is software only (no hardware acceleration on macOS).

#### TV (HEVC 10-bit 4:2:2)
Broadcast delivery format with hardware HEVC 10-bit 4:2:2, configurable resolution/framerate, automatic bitrate scaling, and preservation of all audio channels as 24-bit PCM.

#### TV (AVC-Intra)
Broadcast delivery format in an MXF container. AVC-Intra 10-bit 4:2:2 offers selectable classes (50/100/200 Mbps), resolution, and frame rate plus 4/8/16 mono audio channels as 24-bit PCM.

#### Stream copy
Copies the existing audio and video streams into a new file. Its strength is keeping the original codecs, metadata, and extension, so it pairs well with trimming or merging tasks.

#### ProRes
Apple ProRes (yuv422p10) for edit-friendly masters. Includes the first video and audio streams, keeps 24-bit PCM audio, and targets standard ProRes bitrates. The default ProRes profile can be chosen in Preset Settings.

#### Proxy
Lightweight proxy creation in HEVC, ProRes Proxy, or DNxHR with configurable resolution limits. Retains every audio channel as uncompressed PCM, which is ideal for offline editing and pairing with a dedicated Proxy sub-folder next to the source material.

#### DCP (Digital Cinema Package)
SMPTE-compliant Digital Cinema Package export. Encodes video as JPEG 2000 in 12-bit XYZ color space with BT.709 input conversion, wraps to MXF using asdcp-wrap, and generates all required SMPTE XML (CPL, PKL, ASSETMAP, VOLINDEX). Supports 2K and 4K Flat, Scope, and Full container sizes at 24/25/30/48 fps with configurable bitrate (100–250 Mbps). Audio is exported as 24-bit PCM in a separate MXF track. Per-item metadata editing includes content title, content kind, annotation, rating, and audio language. Scaling modes: fit (letterbox) or fill (crop).

#### Image Sequence
Import and export image sequences in PNG, JPEG, TIFF, EXR, DPX, BMP, TGA, SGI, JPEG XL, and JPEG 2000. Import auto-detects frame numbering and supports gaps. Audio files can be associated with a sequence for playback and export. Frame rate is configurable per-sequence and can be auto-derived from associated audio duration. Exports include optional metadata sidecar files (Markdown or JSON) with color space, codec, and camera information.

#### Animated Stills
Animated still sequence built as GIF, AVIF, or animated PNG (APNG), selectable from the Preset Settings menu.

#### Audio Only AAC
Stereo down-mix AAC file that keeps stereo spacing while drastically reducing file size.

#### Audio Only WAV
Uncompressed WAV export that retains every audio channel wherever possible.

#### 10 Custom FFMPEG presets
Ten custom presets (C1–C10) let you supply your own output arguments, suffixes, and extensions. Input parameters are handled for you, but note that -copy paths cannot combine with the crop or audio-routing toggles that live in Preset Settings.



#### [TODO / Known issues](TODO.md)


## Screenshots

#### Trim View
<img alt="SCR-20260426-ulyb-2" src="https://github.com/user-attachments/assets/0a48088d-e770-402a-a989-dc93d9fcb2c8" />


#### Crop view
![SCR-20251217-nptb](https://github.com/user-attachments/assets/97745a95-7bda-43bf-873a-bd865e886690)


#### Audio rerouting
<img alt="SCR-20251217-nqcb" src="https://github.com/user-attachments/assets/b7f0ab61-a6f1-4f90-8ec6-2f90b05c6022" />


#### Download view
<img alt="SCR-20260426-umjw" src="https://github.com/user-attachments/assets/b2704580-464a-473d-9cac-9f1991ba4bb5" />


#### Metadata view
<img alt="SCR-20260426-unem" src="https://github.com/user-attachments/assets/77f2c209-bc92-4cca-8e6c-36414bb0ecf3" />


#### Timecode override view
<img alt="SCR-20251217-nqlo" src="https://github.com/user-attachments/assets/7c3d951d-9bbb-402c-9984-2fe46fa7d713" />


#### Settings view
<img alt="SCR-20260426-uoiq" src="https://github.com/user-attachments/assets/26b71bfa-e947-42c8-bc0c-4e3e66e81099" />


#### Full screen player
<img alt="SCR-20260426-uomf" src="https://github.com/user-attachments/assets/c9af806f-279e-4a1c-a2ee-a4cae8572911" />




---

## Requirements

|                | Minimum |
|----------------|---------|
| macOS          | 15.0 (Sequoia) or later |
| Hardware       | Apple Silicon (M1 or later) |


---

## Usage

1. Launch the app.
2. Drag video files onto the window **or** click the plus button to import files.
3. Select an **Export Preset** from the toolbar menu.
4. Hit the green *Convert* button or press ⌘⏎.



Note that this is a sparetime project. I this is a passion project I don't get paid for.

---

## License

This project is distributed under the **GNU General Public License, version 3.0**. See the [LICENSE](LICENSE) file for the complete text.

The bundled FFmpeg binary is compiled with `--enable-gpl` and is therefore also licensed under **GPL v2 or later**. This project chooses GPL v3 for all code, satisfying that requirement. See the original FFmpeg license in [Licenses/ffmpeg-LICENSE.txt](Licenses/ffmpeg-LICENSE.txt).

The bundled asdcp-wrap binary is from [asdcplib](https://github.com/cinecert/asdcplib) by John Hurst, licensed under the **BSD 3-Clause License**. See [Licenses/asdcplib-LICENSE.txt](Licenses/asdcplib-LICENSE.txt).

---

## Acknowledgments

The DCP (Digital Cinema Package) export feature's color processing was informed by the [DCP-o-matic](https://dcpomatic.com/) project's excellent documentation on DCI XYZ color space conversion. DCP-o-matic is a free, open-source DCP creator — check it out at https://github.com/cth103/dcpomatic.

Metadata inspection and C2PA content authenticity features are powered by [SwiftMediaMetadata](https://github.com/aagedal/SwiftMediaMetadata).

---

PS! This app was previously called Aagedal VideoLoop Converter. Aagedal Media Converter is the same app, just with a new name that better reflects what it has become.
