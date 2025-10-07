# Aagedal VideoLoop Converter

A lightweight macOS application for converting video files into formats that **loop seamlessly** and play reliably across platforms and web browsers. Powered by FFmpeg under the hood and written entirely in Swift / SwiftUI.

Note that most of this version of the app is vibe-coded.

<img width="940" alt="SCR-20250624-sxdp-2" src="https://github.com/user-attachments/assets/9e5de672-1881-482b-aada-3ea7d2194d21" />
<img width="981" alt="SCR-20250624-syba" src="https://github.com/user-attachments/assets/1219abd7-445c-493e-a95e-ffa3bb229c11" />

---

## Key Features

- **Drag-and-Drop** or File Picker import
- Batch conversion with per-file progress and overall dock progress indicator
- **Export Presets**  
  • Video Loop (silent)  
  • Video Loop w/ Audio  
  • TV Quality HD / 4K  
  • ProRes (editing)  
  • Animated AVIF  
  • HEVC Proxy 1080 p
- Automatic duration warning if a VideoLoop clip exceeds 15s (short videos are best for auto-playing and looping on webpages)
- Sandboxed with Security-Scoped Bookmarks for persistent file access
- Language support: English and Norwegian

---

## Requirements

|                | Minimum |
|----------------|---------|
| macOS          | 15.0 (Sonoma) |
| Hardware       | Apple Silicon (M1 or later) |


## Building & Running

1. Clone the repository:
   ```bash
   git clone https://github.com/your-username/Aagedal-VideoLoop-Converter-2.0.git
   cd Aagedal-VideoLoop-Converter-2.0
   ```
2. Open `Aagedal VideoLoop Converter 2.0.xcodeproj` in Xcode.
3. Select the *Aagedal VideoLoop Converter 2.0* scheme and **Run** (⌘R).

> The project uses Swift Strict Concurrency (`complete`) and upcoming language features—Xcode 16 is required.

---

## Usage

1. Launch the app.
2. Drag video files onto the window **or** click the plus button to import files.
3. Select an **Export Preset** from the toolbar menu.
4. Hit the green *Convert* button or press ⌘⏎.

### 15-Second Autoplay Warning

Web browsers often refuse to autoplay long, looping videos with sound. The app shows a yellow ⚠️ icon when the VideoLoop presets are applied to clips longer than 15 seconds, encouraging you to trim the video or pick another preset.

### App Intents

Not tested with macOS 26 Tahoe, but in macOS 15 you have two available App Shortcuts available in the macOS Shortcuts app:
1. Add to Encode Cue
2. Convert Video Immediately (using the default VideoLoop-preset).

---

## Preset Details

| Preset | Extension | Purpose | Notes |
|--------|-----------|---------|-------|
| Video Loop | .mp4 | Small, silent loops for web GIF replacement. x264 very slow for high quality vs. file size. | H.264, CRF 23, 1080p max |
| Video Loop w/ Audio | .mp4 | Same as above, but with added aac audio track. Selects first audio track, downsamples if more than two channels (stereo). | H.264 @192 kbps AAC audio |
| TV Quality HD | .mov | High-bitrate HEVC for HD playback. HW encoding. Keeps all audio tracks, but encodes them as LPCM. | 10-bit 4:2:0, 18 Mbps |
| TV Quality 4K | .mov | 4K HEVC variant. Likely also good for YouTube. HW encoding. Keeps all audio tracks, but encodes them as LPCM. | 10-bit 4:2:0, 60 Mbps |
| ProRes | .mov | Editing master | Apple ProRes 422. HW encoding. Keeps all audio tracks, but encodes them as LPCM.|
| Animated AVIF | .avif | Modern GIF replacement. WARNING: Playback on Apple Devices before M3 / A17 Pro is bad. Also often larger than the x264 encode with the same quality, even if the encode speed is about the same. | AV1 (svtav1) encoder 720p max |
| HEVC Proxy 1080p | .mov | Low-bitrate proxy for NLEs. HW encoding. Keeps all audio tracks, but encodes them as LPCM. | 6 Mbps, 10-bit, 1080p resolution. |

---
## Plans for the future?
This is a sparetime project, and I don't know when I will update it.

#### Missing features?
1. App Intents for other formats than VideoLoop. (+ testing for macOS 26 Spotlight actions.)
2. Ability to change the default encoding format. (This would be easy to implement, actually not sure why I didn't add it to this release. Probably a 2.1 release.)
3. FFMPEG is currently used for all decodes and encodes. Ideally I think I should use the macOS native tools when possible. But don't worry, x264 is here to stay for VideoLoop encoding, at least until Apple improves their native software encoder.
4. Add the ability to encode a VideoLoop using the Apple native APIs, both software and hardware, as to make it easier to compare how much (or little) improvements you get from x264.
5. New preset for high bitrate 12-bit 4:4:4 VP9 encoding for archival?
6. Change infrastructure so that the user can prefer to use ffmpeg installed using Homebrew. (If this app isn't updated, the user could still get support for new input formats.)
7. Make it possible to install this app using Homebrew cask.
8. New preset for Animated JPEG XL? Animated AVIF will likely remain better, but this could be an interesting addition.
9. Update the preset UI, to be more usable with more presets.
10. Add ability to reorder list, and the ability to shift select multiple list items for deletion or resetting of status.


### Unlikely to be implemented
1. Custom bitrate settings and resolution settings. There are other more complex apps for that. I just needed a few simple presets for my own common workflows.

---

## License

This project is distributed under the **GNU General Public License, version 3.0**. See the [LICENSE](LICENSE) file for the complete text.

The bundled FFmpeg binary is compiled with `--enable-gpl` and is therefore also licensed under **GPL v2 or later**. This project chooses GPL v3 for all code, satisfying that requirement. See the original FFmpeg license in [Licenses/ffmpeg-LICENSE.txt](Licenses/ffmpeg-LICENSE.txt).
