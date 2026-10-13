// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general
    @State private var sidebarCollapsed = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @AppStorage(AppConstants.settingsTabToOpenKey) private var requestedTab = ""

    private enum SettingsTab: String, CaseIterable, Hashable {
        case general
        case encoding
        case fileNames
        case metadata
        case presets
        case screenshots
        case screenCapture
        case waveform
        case watchFolder
        case ytdlp
        case upload
        case whisper
        case ocr
        case analytics
        case sync
        case updates
        case shortcuts
        case agentAccess
        case tools

        var label: String {
            switch self {
            case .general: return String(localized: "General", comment: "Settings sidebar tab.")
            case .agentAccess: return String(localized: "Agent Access", comment: "Settings sidebar tab.")
            case .encoding: return String(localized: "Encoding Groups", comment: "Settings sidebar tab.")
            case .fileNames: return String(localized: "File Names", comment: "Settings sidebar tab.")
            case .metadata: return String(localized: "Metadata", comment: "Settings sidebar tab.")
            case .presets: return String(localized: "Presets", comment: "Settings sidebar tab.")
            case .screenshots: return String(localized: "Screenshots", comment: "Settings sidebar tab.")
            case .screenCapture: return String(localized: "Screen Capture", comment: "Settings sidebar tab.")
            case .waveform: return String(localized: "Audio Waveform", comment: "Settings sidebar tab.")
            case .watchFolder: return String(localized: "Watch Folder", comment: "Settings sidebar tab.")
            case .ytdlp: return String(localized: "Downloads", comment: "Settings sidebar tab.")
            case .upload: return String(localized: "Upload", comment: "Settings sidebar tab.")
            case .whisper: return String(localized: "Transcription", comment: "Settings sidebar tab.")
            case .ocr: return String(localized: "OCR", comment: "Settings sidebar tab.")
            case .analytics: return String(localized: "Analytics", comment: "Settings sidebar tab.")
            case .sync: return String(localized: "Sync", comment: "Settings sidebar tab.")
            case .updates: return String(localized: "Updates", comment: "Settings sidebar tab.")
            case .tools: return String(localized: "Tool Diagnostics", comment: "Settings sidebar tab.")
            case .shortcuts: return String(localized: "Shortcuts", comment: "Settings sidebar tab.")
            }
        }

        // Keep this index aligned with the labels in each pane so searches work
        // in the selected app language, including individual setting names.
        var searchTerms: [String] {
            switch self {
            case .general:
                return [
                    String(localized: "Output Location"),
                    String(localized: "Save encoded files next to original"),
                    String(localized: "Place in subfolder"),
                    String(localized: "Subfolder name:"),
                    String(localized: "Custom name"),
                    String(localized: "Use preset suffix"),
                    String(localized: "Folder name:"),
                    String(localized: "Encoded files will be saved in the same folder as the source file."),
                    String(localized: "Default Output Folder:"),
                    String(localized: "Automatically delete old encodes"),
                    String(localized: "Delete files older than:"),
                    String(localized: "Retry Cleanup"),
                    String(localized: "Only completed files created by this app are moved to Trash. Older, unmarked files are kept. Cleanup only applies to the default output folder."),
                    String(localized: "Queue Display"),
                    String(localized: "Use compact list view"),
                    String(localized: "Compact mode hides comment fields, file sizes, and duration to show more items at once. Action buttons appear in a row under each filename."),
                    String(localized: "Timecode Display"),
                    String(localized: "Default timecode mode:"),
                    String(localized: "Sets the initial timecode display mode when opening the trim view or fullscreen player. You can toggle modes during playback by pressing T."),
                    String(localized: "Sounds"),
                    String(localized: "Play sound when encoding completes"),
                    String(localized: "Play sound when an error occurs"),
                    String(localized: "Reset Behavior"),
                    String(localized: "Reset also clears trim, crop, and audio routing"),
                    String(localized: "Preview Cache"),
                    String(localized: "Cleanup policy")
                ]
            case .encoding:
                return [
                    String(localized: "Export timeline markers"),
                    String(localized: "Save cuts and marked notes in a Resolve marker EDL beside stitched files and embed chapters in MOV, MP4, M4V, and MKV. Cut titles include the source timecode at each clip’s trimmed in-point when available. If source chapters exist, ask before replacing them."),
                    String(localized: "New Group Defaults"),
                    String(localized: "Merge clips by default"),
                    String(localized: "Sequential filename numbering by default"),
                    String(localized: "Merge and sequential naming are mutually exclusive — turning one on switches the other off, both on the card and in these defaults.")
                ]
            case .fileNames:
                return [
                    String(localized: "File Names"),
                    String(localized: "Enable filename processing"),
                    String(localized: "Replace spaces with underscores"),
                    String(localized: "Convert Scandinavian characters (æ, ø, å)"),
                    String(localized: "Remove special characters:"),
                    String(localized: "Include preset suffix in filename"),
                    String(localized: "When disabled, output filenames will not include preset-specific suffixes."),
                    String(localized: "Custom Filename Template"),
                    String(localized: "Use custom filename template"),
                    String(localized: "Template:"),
                    String(localized: "Date format:"),
                    String(localized: "Counter padding:"),
                    String(localized: "1 (1, 2, 3)"),
                    String(localized: "2 (01, 02, 03)"),
                    String(localized: "3 (001, 002, 003)"),
                    String(localized: "4 (0001, 0002, 0003)"),
                    String(localized: "5 (00001, 00002)"),
                    String(localized: "6 (000001, 000002)"),
                    String(localized: "Next counter:"),
                    String(localized: "Reset to 1"),
                    String(localized: "Available variables:"),
                    String(localized: "{sourceName} — original file name (sanitized)"),
                    String(localized: "{date} — current date using the format above"),
                    String(localized: "{counter} — sequence number, allocated per imported file"),
                    String(localized: "{presetSuffix} — preset's suffix (e.g. _h264, _tv); suppresses auto-append"),
                    String(localized: "{resolution} — preset's target resolution (e.g. 1080p), empty if unlimited"),
                    String(localized: "{framerate} — preset's target framerate (e.g. 50p, 24), empty if source"),
                    String(localized: "Per-item overrides"),
                    String(localized: "You can still rename individual files in the queue by double-clicking the output filename. Manual overrides take precedence over this template.")
                ]
            case .metadata:
                return [
                    String(localized: "Queue Row Display"),
                    String(localized: "Control which metadata controls are shown on each video row in the queue."),
                    String(localized: "Show date tag button"),
                    String(localized: "Metadata Preservation"),
                    String(localized: "Include date tag on new files"),
                    String(localized: "The date tag precedes any custom comment you enter on the video card."),
                    String(localized: "Comment Formatting"),
                    String(localized: "Configure optional prefix/suffix for metadata comments and how the date tag is formatted."),
                    String(localized: "Pipe ( | )"),
                    String(localized: "Dash ( - )"),
                    String(localized: "Colon ( : )"),
                    String(localized: "Comma ( , )"),
                    String(localized: "Space"),
                    String(localized: "None"),
                    String(localized: "Preview (sample comment):"),
                    String(localized: "Timecode Defaults"),
                    String(localized: "Default timecode mode for new files:"),
                    String(localized: "Default Mode"),
                    String(localized: "Ignore trim offset for stitched timecode"),
                    String(localized: "By default, stitched output starts at the first clip’s source timecode plus its trim-in offset. Enable this to use its original starting timecode. Manual timecode is always used exactly as entered."),
                    String(localized: "The timecode from the source file will be copied to the output."),
                    String(localized: "Enter a default start timecode for output files."),
                    String(localized: "Timecode Value:"),
                    String(localized: "10"),
                    String(localized: "1"),
                    String(localized: "Format: HH:MM:SS:FF (00-23 hours, 00-29 frames @ 30fps) or HH:MM:SS;FF for drop-frame"),
                    String(localized: "No timecode will be written to output files by default."),
                    String(localized: "Metadata Comment"),
                    String(localized: "The metadata comment is embedded in the exported file and can be viewed in video players or file inspectors. It's composed of:"),
                    String(localized: "Full comment preview:")
                ]
            case .presets:
                return [
                    String(localized: "EXPERIMENTAL"),
                    String(localized: "Set as Default"),
                    String(localized: "Format"),
                    String(localized: "Quality"),
                    String(localized: "Best (1)"),
                    String(localized: "High (2)"),
                    String(localized: "Good (5)"),
                    String(localized: "Medium (10)"),
                    String(localized: "Low (20)"),
                    String(localized: "Frame Number Padding"),
                    String(localized: "4 digits"),
                    String(localized: "5 digits"),
                    String(localized: "6 digits"),
                    String(localized: "8 digits"),
                    String(localized: "Metadata Sidecar"),
                    String(localized: "Include a file with source color space and technical specs"),
                    String(localized: "Sidecar Format"),
                    String(localized: "Resolution"),
                    String(localized: "Frame Rate"),
                    String(localized: "Video Bitrate"),
                    String(localized: "Scaling"),
                    String(localized: "Keep JP2 image sequence"),
                    String(localized: "JPEG 2000 video in MXF with 24-bit PCM audio. XYZ color space (DCI P3)."),
                    String(localized: "Experimental IMF export. Validate the package in your target mastering or delivery tool before use. This version writes a single video track and one PCM audio track; packaged subtitles and multi-track audio are not yet supported."),
                    String(localized: "Color"),
                    String(localized: "Keep intermediate files"),
                    String(localized: "JPEG 2000 video in MXF (App #2e), one PCM audio track, and CPL/PKL/ASSETMAP manifests."),
                    String(localized: "ProRes Profile"),
                    String(localized: "Apple ProRes video in MXF (RDD 45). PCM audio and CPL/PKL/ASSETMAP manifests."),
                    String(localized: "Bit Depth"),
                    String(localized: "Bitrate"),
                    String(localized: "Audio Codec"),
                    String(localized: "Encoder"),
                    String(localized: "Quality (CRF)"),
                    String(localized: "Encoding Speed"),
                    String(localized: "Container"),
                    String(localized: "Resolution Limit"),
                    String(localized: "Audio Bitrate"),
                    String(localized: "AV1 encoding uses SVT-AV1 (software). No hardware acceleration available."),
                    String(localized: "Encoding Speed (Preset)"),
                    String(localized: "Tune"),
                    String(localized: "Film Grain Synthesis"),
                    String(localized: "Film Grain Denoise"),
                    String(localized: "Sharpness"),
                    String(localized: "Variance Boost"),
                    String(localized: "Variance Boost Curve"),
                    String(localized: "Fast Decode"),
                    String(localized: "Experimental. AV2 is encoded by the bundled avmenc (AOM AVM) encoder. The app can split the encode across all CPU cores for a large speed-up, and optionally mux the result with audio into a Matroska (.mkv) file. AV2 is very new — the output needs an AV2-capable decoder to play and cannot be previewed inside this app yet."),
                    String(localized: "Audio"),
                    String(localized: "Rate Control"),
                    String(localized: "Quality (QP)"),
                    String(localized: "Best quality"),
                    String(localized: "Smallest file"),
                    String(localized: "Target Bitrate"),
                    String(localized: "kbps"),
                    String(localized: "Framerate"),
                    String(localized: "AVC-Intra Class"),
                    String(localized: "Audio Channels"),
                    String(localized: "Default MCA Labels"),
                    String(localized: "Used when the source has no MCA labels and no per-track override is set. Choose 'None' to leave the audio essence unlabelled."),
                    String(localized: "1-channel default"),
                    String(localized: "None"),
                    String(localized: "2-channel default"),
                    String(localized: "6-channel default"),
                    String(localized: "8-channel default"),
                    String(localized: "Codec"),
                    String(localized: "Mute audio by default"),
                    String(localized: "When enabled, new files will be muted automatically when VideoLoop is selected"),
                    String(localized: "Keep Subtitles"),
                    String(localized: "Copy subtitle streams from the source file into the output"),
                    String(localized: "Subtitles may be out of sync when trimming. Bitmap subtitles (PGS, DVB) are not supported in MP4/MOV — use MKV instead."),
                    String(localized: "Show in preset picker"),
                    String(localized: "Custom Preset Configuration"),
                    String(localized: "Activate Preset"),
                    String(localized: "Specify the arguments passed to ffmpeg (without including the `ffmpeg` command itself)."),
                    String(localized: "Feature Support"),
                    String(localized: "Apply crop configuration"),
                    String(localized: "When enabled, crop settings will be applied to files using this preset"),
                    String(localized: "Apply audio routing configuration"),
                    String(localized: "When enabled, audio track routing will be applied to files using this preset"),
                    String(localized: "Output file suffix"),
                    String(localized: "Output extension"),
                    String(localized: "Display name"),
                    String(localized: "Preserve all original metadata"),
                    "H.264",
                    "H.265",
                    "AV1",
                    "AV2",
                    "ProRes",
                    "Proxy",
                    "DCP",
                    "IMF",
                    String(localized: "Stream Copy")
                ]
            case .screenshots:
                return [
                    String(localized: "Screenshot Folder"),
                    String(localized: "Formats"),
                    String(localized: "Select the image format for screenshots based on source bit depth."),
                    String(localized: "Transparency"),
                    String(localized: "Alpha channel"),
                    String(localized: "Choose how to handle screenshots with alpha transparency.")
                ]
            case .screenCapture:
                return [
                    String(localized: "Preset"),
                    String(localized: "Default Preset"),
                    String(localized: "Capture Options"),
                    String(localized: "Frame Rate"),
                    String(localized: "Dynamic Range"),
                    String(localized: "HDR capture requires macOS 26 or later."),
                    String(localized: "Hide cursor"),
                    String(localized: "Hide app window"),
                    String(localized: "Output Folder"),
                    String(localized: "Capture Output Folder:")
                ]
            case .waveform:
                return [
                    String(localized: "Defaults"),
                    String(localized: "Enable waveform video by default"),
                    String(localized: "Normalize audio levels"),
                    String(localized: "Output"),
                    String(localized: "Renderer"),
                    String(localized: "Colors"),
                    String(localized: "Use foreground gradient"),
                    String(localized: "Use background gradient"),
                    String(localized: "Colors accept six-digit HEX values (e.g. #1A2B3C).")
                ]
            case .watchFolder:
                return [
                    String(localized: "Watch Folder"),
                    String(localized: "Watch Folder:"),
                    String(localized: "No folder selected"),
                    String(localized: "When Watch Folder Mode is enabled in the toolbar, the app will automatically scan this folder every 5 seconds for new video files and add them to the conversion queue."),
                    String(localized: "Activate Watch Folder on app launch"),
                    String(localized: "Keep Mac awake while watching"),
                    String(localized: "Ignore files older than"),
                    String(localized: "Automatically delete files older than"),
                    String(localized: "Select the watch folder again to allow automatic cleanup. Monitoring remains available until access is renewed."),
                    String(localized: "Renew Access"),
                    String(localized: "File settling time")
                ]
            case .ytdlp:
                return [
                    String(localized: "yt-dlp (Video Downloads)"),
                    String(localized: "Checking..."),
                    String(localized: "yt-dlp not installed"),
                    String(localized: "Source:"),
                    String(localized: "Source"),
                    String(localized: "App Download"),
                    String(localized: "Homebrew"),
                    String(localized: "Custom"),
                    String(localized: "Selected source not found."),
                    String(localized: "Downloading..."),
                    String(localized: "The app-downloaded yt-dlp has slower startup (~20-30 seconds). For faster downloads, install via Homebrew."),
                    String(localized: "1. Run this command in Terminal:"),
                    String(localized: "brew install yt-dlp"),
                    String(localized: "Custom yt-dlp path:"),
                    String(localized: "Browse..."),
                    String(localized: "Homebrew yt-dlp starts downloads much faster than the app-downloaded version."),
                    String(localized: "deno (JavaScript Runtime)"),
                    String(localized: "deno not installed"),
                    String(localized: "Custom deno path:"),
                    String(localized: "deno provides the JavaScript runtime needed by yt-dlp to handle modern YouTube extraction challenges. It can be auto-downloaded on first use."),
                    String(localized: "Authentication"),
                    String(localized: "Use browser cookies to access age-restricted, private, or member-only content."),
                    String(localized: "Browser:"),
                    String(localized: "None"),
                    String(localized: "Note: The browser should be closed for best results. On macOS, you may need to grant Full Disk Access to the app in System Settings > Privacy & Security."),
                    String(localized: "Download Automation"),
                    String(localized: "Auto-encode after download"),
                    String(localized: "When enabled, new downloads will automatically start encoding after the download completes."),
                    String(localized: "Auto-upload after download"),
                    String(localized: "When enabled, new downloads will be uploaded after encoding completes. Requires upload to be configured in Settings > Upload."),
                    String(localized: "Upload not configured"),
                    String(localized: "Download Folder"),
                    String(localized: "Download Folder:"),
                    String(localized: "Downloads from yt-dlp are saved here before conversion."),
                    String(localized: "Filename restrictions:"),
                    String(localized: "Allow private network downloads"),
                    String(localized: "Off by default. When off, URLs pointing to LAN, loopback, link-local, or `.local` hosts are rejected. Turn on to download from a local media server (Jellyfin, Plex, etc.)."),
                    String(localized: "FFmpeg (Conversion)"),
                    String(localized: "FFmpeg: Not found"),
                    String(localized: "App (Bundled)"),
                    String(localized: "Custom FFmpeg path:"),
                    String(localized: "Refresh Versions"),
                    String(localized: "About"),
                    String(localized: "The app includes a bundled ffmpeg binary. You can optionally point at a Homebrew or custom ffmpeg if you need specific features or codecs. Metadata reading (including chapters) is handled in-process by SwiftMediaMetadata — no external ffprobe is required."),
                    String(localized: "yt-dlp enables downloading videos from YouTube and other sites. It can be auto-downloaded from GitHub or installed via Homebrew. Downloaded videos are automatically queued for conversion.")
                ]
            case .upload:
                return [
                    String(localized: "Saved upload profiles could not be read. Your saved data has been preserved. Restore a settings backup or repair the saved profiles, then reopen Settings."),
                    String(localized: "Not installed"),
                    String(localized: "Bundled"),
                    String(localized: "rclone"),
                    String(localized: "Source:"),
                    String(localized: "Source"),
                    String(localized: "App (Bundled)"),
                    String(localized: "Homebrew"),
                    String(localized: "Custom"),
                    String(localized: "Using a minimal rclone build shipped with the app, trimmed to only the backends this app needs."),
                    String(localized: "Using the rclone installed via Homebrew at /opt/homebrew/bin/rclone."),
                    String(localized: "rclone was not found at /opt/homebrew/bin/rclone."),
                    String(localized: "To install via Homebrew, run this in Terminal:"),
                    String(localized: "brew install rclone"),
                    String(localized: "Custom rclone path:"),
                    String(localized: "Browse..."),
                    String(localized: "This file is not a valid rclone binary (failed `--version` check)."),
                    String(localized: "Upload Profile"),
                    String(localized: "Protocol"),
                    String(localized: "No upload profiles yet. Click + to create one."),
                    String(localized: "No profiles"),
                    String(localized: "Import from FileZilla…"),
                    String(localized: "Use FTPS (TLS encryption)"),
                    String(localized: "Password"),
                    String(localized: "SSH Key"),
                    String(localized: "us-east-1 (N. Virginia)"),
                    String(localized: "us-east-2 (Ohio)"),
                    String(localized: "us-west-1 (N. California)"),
                    String(localized: "us-west-2 (Oregon)"),
                    String(localized: "eu-west-1 (Ireland)"),
                    String(localized: "eu-west-2 (London)"),
                    String(localized: "eu-central-1 (Frankfurt)"),
                    String(localized: "eu-north-1 (Stockholm)"),
                    String(localized: "ap-northeast-1 (Tokyo)"),
                    String(localized: "ap-southeast-1 (Singapore)"),
                    String(localized: "ap-southeast-2 (Sydney)"),
                    String(localized: "Google Drive support is not yet implemented."),
                    String(localized: "Please use FTP, SFTP, SMB, or S3 for now."),
                    String(localized: "Upload Behavior"),
                    String(localized: "Enable upload by default for new items"),
                    String(localized: "When enabled, new items added to the queue will automatically upload after conversion."),
                    String(localized: "Number of times to retry a failed upload before giving up."),
                    String(localized: "Test Connection"),
                    String(localized: "Connection successful")
                ]
            case .whisper:
                return [
                    String(localized: "Default Transcription Engine"),
                    String(localized: "Engine:"),
                    String(localized: "Whisper (FFmpeg built-in)"),
                    String(localized: "Parakeet (NeMo MLX)"),
                    String(localized: "The default engine used when enabling transcription on new items. You can override per item in the queue."),
                    String(localized: "Embed subtitles into output file"),
                    String(localized: "When enabled, the generated SRT will be muxed into the output video file as a subtitle track after transcription completes. The external SRT file is kept as well."),
                    String(localized: "Not all subtitle formats are compatible with MP4 and MOV containers. SRT subtitles will be converted to mov_text for MP4/MOV. For full compatibility, use MKV as the output format."),
                    String(localized: "Language"),
                    String(localized: "Browse…"),
                    String(localized: "Cancel"),
                    String(localized: "Delete All Models"),
                    String(localized: "This will delete all downloaded Whisper models. You will need to re-download them to use transcription."),
                    String(localized: "whisper.cpp (Subtitle Generation)"),
                    String(localized: "Checking..."),
                    String(localized: "whisper.cpp not available"),
                    String(localized: "Ready"),
                    String(localized: "Download a model below to enable subtitle generation."),
                    String(localized: "Models"),
                    String(localized: "Download models for transcription. Larger models are more accurate but slower and require more RAM."),
                    String(localized: "Selected"),
                    String(localized: "Select"),
                    String(localized: "Default Settings"),
                    String(localized: "Enable subtitles by default for new items"),
                    String(localized: "When enabled, new video files added to the queue will have subtitle generation enabled automatically."),
                    String(localized: "Default model:"),
                    String(localized: "(custom file)"),
                    String(localized: "(not downloaded)"),
                    String(localized: "Default language:"),
                    String(localized: "Use 'Auto-detect' for mixed-language content. Specifying a language can improve accuracy for single-language audio."),
                    String(localized: "Max line length:"),
                    String(localized: "Controls the maximum characters per subtitle line. Default is 42, which works well for most video players. Use lower values for mobile devices."),
                    String(localized: "About"),
                    String(localized: "whisper.cpp is a high-performance C++ implementation of OpenAI's Whisper speech recognition model. It can transcribe audio in multiple languages and generate SRT subtitle files."),
                    String(localized: "Subtitles are generated from the audio track after conversion completes. The SRT file is saved alongside the output video."),
                    String(localized: "Custom model path:"),
                    String(localized: "Browse..."),
                    String(localized: "Custom model not found."),
                    String(localized: "parakeet-mlx (NeMo ASR on Apple Silicon)"),
                    String(localized: "Parakeet Models"),
                    String(localized: "Parakeet Default Settings"),
                    String(localized: "About Parakeet"),
                    String(localized: "parakeet-mlx not installed"),
                    String(localized: "parakeet-mlx is a Python package that runs speech recognition locally on Apple Silicon. Install it to enable Parakeet transcription:"),
                    String(localized: "Custom path:"),
                    String(localized: "Binary not found at custom path."),
                    String(localized: "Models are downloaded automatically on first use via HuggingFace Hub. You can also manage cached models here."),
                    String(localized: "Delete All Cached Models"),
                    String(localized: "Multilingual"),
                    String(localized: "·"),
                    String(localized: "Parakeet is NVIDIA's state-of-the-art automatic speech recognition model, optimized for Apple Silicon via the MLX framework. It can produce highly accurate transcriptions with word-level timestamps."),
                    String(localized: "Models are cached in ~/.cache/huggingface/hub/ and downloaded on first use.")
                ]
            case .ocr:
                return [
                    String(localized: "OCR Engine"),
                    String(localized: "Engine"),
                    String(localized: "Tesseract OCR (Subtitle Conversion)"),
                    String(localized: "Checking…"),
                    String(localized: "Ready"),
                    String(localized: "Tesseract not found"),
                    String(localized: "Bundle the tesseract binary in Binaries/"),
                    String(localized: "brew install tesseract"),
                    String(localized: "Tesseract is required for OCR subtitle conversion. Install via Homebrew or bundle the binary with the app."),
                    String(localized: "Binary Source"),
                    String(localized: "Source:"),
                    String(localized: "Source"),
                    String(localized: "App (Bundled)"),
                    String(localized: "Homebrew"),
                    String(localized: "Custom"),
                    String(localized: "Custom tesseract path:"),
                    String(localized: "Browse…"),
                    String(localized: "Recognition Language"),
                    String(localized: "No tessdata found. Bundle eng.traineddata in Resources/tessdata/ or add it to the tessdata folder below."),
                    String(localized: "Language"),
                    String(localized: "The language must match the subtitle language. More .traineddata files can be added to the tessdata folder."),
                    String(localized: "Vision did not report any supported languages on this system."),
                    String(localized: "Auto-detected subtitle stream language overrides this when present in the source file."),
                    String(localized: "Tessdata Folder"),
                    String(localized: "Add extra language files (.traineddata) for Tesseract here:"),
                    String(localized: "Reveal in Finder"),
                    String(localized: "About"),
                    String(localized: "OCR converts picture-based subtitles (Blu-ray PGS, DVD VOBSUB) to SRT text. It reads the original subtitle images from the source file — no audio processing required."),
                    String(localized: "Accuracy is typically 99%+ for commercial Blu-ray titles with clean, high-contrast subtitle images. Stylised fonts, coloured text, or non-Latin scripts may reduce accuracy."),
                    String(localized: "Tesseract OCR is open source and licensed under the Apache 2.0 License."),
                    String(localized: "Apple Vision is part of macOS and runs locally on the GPU. It often produces cleaner output than Tesseract for printed Latin-script text and supports several non-Latin scripts as well.")
                ]
            case .analytics:
                return [
                    String(localized: "Automation"),
                    String(localized: "Automatically run analytics after conversion"),
                    String(localized: "When enabled, quality analytics will run on each file immediately after encoding completes."),
                    String(localized: "Auto-export analytics results"),
                    String(localized: "Export Format"),
                    String(localized: "Analytics results will be saved next to the encoded file after each analysis completes."),
                    String(localized: "Quality Metrics"),
                    String(localized: "Number of frames sampled evenly across the video for comparison. More frames gives higher accuracy but takes longer."),
                    String(localized: "VMAF Settings"),
                    String(localized: "VMAF Model")
                ]
            case .sync:
                return [
                    String(localized: "Sync settings and custom presets"),
                    String(localized: "Sync"),
                    String(localized: "Keeps your presets and preferences in sync across Macs through a single settings file. The newest change wins; you'll be notified when settings arrive from another Mac."),
                    String(localized: "Location"),
                    String(localized: "Store settings in:"),
                    String(localized: "iCloud Drive"),
                    String(localized: "Custom folder"),
                    String(localized: "Choose…"),
                    String(localized: "Status"),
                    String(localized: "Last synced"),
                    String(localized: "Never"),
                    String(localized: "Sync Now"),
                    String(localized: "Export Settings…"),
                    String(localized: "Import Settings…"),
                    String(localized: "Reveal Backups in Finder"),
                    String(localized: "Manual Backup"),
                    String(localized: "Export a settings file you can keep as a backup or import on another Mac. The app also keeps automatic local backups before applying any incoming settings — open them in Finder and use “Import Settings…” to roll back.")
                ]
            case .updates:
                return [
                    String(localized: "Aagedal Media Converter"),
                    String(localized: "Minimalist FFMPEG frontend written in Swift and SwiftUI."),
                    String(localized: "FFMPEG version: 9.0.1"),
                    String(localized: "Updates"),
                    String(localized: "Automatically check for updates"),
                    String(localized: "Check frequency"),
                    String(localized: "Checking..."),
                    String(localized: "Release Notes"),
                    String(localized: "Download"),
                    String(localized: "App is up to date"),
                    String(localized: "Check Now"),
                    String(localized: "Install updates automatically")
                ]
            case .shortcuts:
                return [

                ]
            case .agentAccess:
                return [
                    String(localized: "When enabled, the signed helper accepts requests from local MCP clients and sends them to this app. The app remains the owner of every accepted conversion."),
                    String(localized: "Test Connection"),
                    String(localized: "MCP client"),
                    String(localized: "Add this stdio server to a local MCP client. Keep the app installed at the same location after configuring the client."),
                    String(localized: "Add this entry to your opencode.json configuration, then restart OpenCode. Keep the app installed at the same location."),
                    String(localized: "Run this command in Terminal, then restart the client. Keep the app installed at the same location."),
                    String(localized: "Copy Setup"),
                    String(localized: "Show Helper in Finder"),
                    String(localized: "Files in these folders and their subfolders are available to local MCP clients. Conversions use the app's default output folder unless another writable folder is selected in the app. MCP requests cannot approve new locations."),
                    String(localized: "Remove"),
                    String(localized: "Add Source Folder…"),
                    String(localized: "Turning access off rejects new connections. Jobs already accepted by the app continue and remain available in job history.")
                ]
            case .tools:
                return [
                    String(localized: "Check the active bundled, Homebrew, or custom tools selected in Settings. Each version check has a five-second limit."),
                    String(localized: "Tool Diagnostics"),
                    String(localized: "Open Transcription Settings"),
                    String(localized: "Parakeet is optional and only needed for Parakeet transcription. Install uv using the linked instructions, then run this command in Terminal:"),
                    String(localized: "In Transcription settings, select Parakeet. If it is installed elsewhere, use Custom path to select parakeet-mlx. Download a model before transcribing."),
                    String(localized: "Open Analytics Settings"),
                    String(localized: "Only Parakeet transcription needs this model. In Transcription settings, select Parakeet, install its tool if needed, then download the selected model or choose an available model."),
                    String(localized: "In Transcription settings, select Whisper and download the selected model. For a custom model, select the file again to restore access, or choose an available model."),
                    String(localized: "In Downloads settings, choose App Download and install or update the tool. For Homebrew, follow the installation instructions there; for Custom, select an executable file again."),
                    String(localized: "Open Downloads Settings"),
                    String(localized: "In Upload settings, select App (Bundled) for rclone. If using Homebrew or Custom, check the selected installation and executable path."),
                    String(localized: "Open Upload Settings"),
                    String(localized: "In OCR settings, select the bundled Tesseract or select an installed custom executable. If the bundled tool is unavailable, reinstall the app."),
                    String(localized: "Open OCR Settings"),
                    String(localized: "In Downloads settings, select the bundled FFmpeg or select an installed custom executable. If the bundled tool is unavailable, reinstall the app."),
                    String(localized: "This helper is bundled with the app. Reinstall the app if it is missing or incompatible."),
                    String(localized: "After making changes, return here and click Check Tools again.")
                ]
            }
        }

        func matches(_ query: String) -> Bool {
            query.isEmpty || ([label, rawValue] + searchTerms).contains { $0.localizedStandardContains(query) }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .agentAccess: return "network"
            case .encoding: return "rectangle.stack"
            case .fileNames: return "textformat"
            case .metadata: return "info.circle"
            case .presets: return "slider.horizontal.3"
            case .screenshots: return "camera.on.rectangle"
            case .screenCapture: return "record.circle"
            case .waveform: return "waveform"
            case .watchFolder: return "eye.fill"
            case .ytdlp: return "arrow.down.circle"
            case .upload: return "icloud.and.arrow.up"
            case .whisper: return "captions.bubble"
            case .ocr: return "character.magnify"
            case .analytics: return "chart.bar.xaxis"
            case .sync: return "arrow.clockwise.icloud"
            case .updates: return "arrow.triangle.2.circlepath"
            case .tools: return "stethoscope"
            case .shortcuts: return "command"
            }
        }
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleTabs: [SettingsTab] {
        SettingsTab.allCases.filter { $0.matches(searchQuery) }
    }

    // Prevents deselection when clicking the already-selected row
    private var tabSelection: Binding<SettingsTab?> {
        Binding(get: { selectedTab }, set: { if let t = $0 { selectedTab = t } })
    }

    @ViewBuilder
    private var contentView: some View {
        switch selectedTab {
        case .general: GeneralSettingsView()
        case .agentAccess: AgentAccessSettingsView()
        case .encoding: EncodingSettingsView()
        case .fileNames: FileNameSettingsView()
        case .metadata: MetadataSettingsView()
        case .presets: PresetsSettingsView()
        case .screenshots: ScreenshotSettingsView()
        case .screenCapture: ScreenCaptureSettingsView()
        case .waveform: WaveformSettingsView()
        case .watchFolder: WatchFolderSettingsView()
        case .ytdlp: YTDLPSettingsView()
        case .upload: UploadSettingsView()
        case .whisper: TranscriptionSettingsView()
        case .ocr: TesseractSettingsView()
        case .analytics: AnalyticsSettingsView()
        case .sync: SyncSettingsView()
        case .updates: UpdateSettingsView()
        case .shortcuts: ShortcutsSettingsView()
        case .tools:
            ToolDiagnosticsSettingsView { destination in
                if let tab = SettingsTab(rawValue: destination) { selectTab(tab) }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            TextField("Search settings", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings.search")
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("settings.search.clear")
            }
        }
        .padding(8)
        .accessibilityElement(children: .contain)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if !sidebarCollapsed { searchField }
                List(visibleTabs, id: \.self, selection: tabSelection) { tab in
                    if sidebarCollapsed {
                        Label(tab.label, systemImage: tab.icon)
                            .labelStyle(.iconOnly)
                            .help(tab.label)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("settings.tab.\(tab.rawValue)")
                            .accessibilityLabel(tab.label)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Label(tab.label, systemImage: tab.icon)
                            if !searchQuery.isEmpty,
                               let match = tab.searchTerms.first(where: { $0.localizedStandardContains(searchQuery) }),
                               !tab.label.localizedStandardContains(searchQuery) {
                                Text(match)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .accessibilityIdentifier("settings.tab.\(tab.rawValue)")
                            .accessibilityLabel(tab.label)
                    }
                }
                .listStyle(.sidebar)
                // macOS outlines expose AXValue; generic groups do not. Keep the
                // Settings navigation state on this stable accessibility element.
                .accessibilityIdentifier("settings.root")
                .accessibilityValue(selectedTab.rawValue)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        Divider()
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                sidebarCollapsed.toggle()
                                if sidebarCollapsed { searchText = "" }
                            }
                        } label: {
                            Image(systemName: "sidebar.leading")
                                .frame(maxWidth: .infinity, alignment: sidebarCollapsed ? .center : .leading)
                                .padding(.leading, sidebarCollapsed ? 0 : 10)
                                .frame(height: 32)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(sidebarCollapsed ? "Show Sidebar" : "Hide Sidebar")
                        .accessibilityIdentifier("settings.toggleSidebar")
                        .accessibilityLabel(sidebarCollapsed ? String(localized: "Show Sidebar") : String(localized: "Hide Sidebar"))
                    }
                    .background(Color(NSColor.windowBackgroundColor))
                }
            }
            .frame(width: sidebarCollapsed ? 46 : 195)
            .overlay {
                if visibleTabs.isEmpty {
                    Text("No matching settings")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                        .accessibilityIdentifier("settings.search.empty")
                }
            }
            .clipped()

            Divider()

            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, idealWidth: 900, maxWidth: .infinity, minHeight: 540, idealHeight: 600, maxHeight: .infinity)
        .navigationTitle("Settings – Aagedal Media Converter")
        .background {
            // Keyboard shortcuts for tab switching (Control+1-9, 0 to avoid conflict with main window's CMD+1-9, 0 preset selection)
            VStack(spacing: 0) {
                Button("") {
                    sidebarCollapsed = false
                    searchFocused = true
                }
                .keyboardShortcut("f", modifiers: .command)
                Button("") { selectTab(.general) }
                    .keyboardShortcut("1", modifiers: .control)
                Button("") { selectTab(.metadata) }
                    .keyboardShortcut("2", modifiers: .control)
                Button("") { selectTab(.presets) }
                    .keyboardShortcut("3", modifiers: .control)
                Button("") { selectTab(.screenCapture) }
                    .keyboardShortcut("4", modifiers: .control)
                Button("") { selectTab(.waveform) }
                    .keyboardShortcut("5", modifiers: .control)
                Button("") { selectTab(.watchFolder) }
                    .keyboardShortcut("6", modifiers: .control)
                Button("") { selectTab(.ytdlp) }
                    .keyboardShortcut("7", modifiers: .control)
                Button("") { selectTab(.upload) }
                    .keyboardShortcut("8", modifiers: .control)
                Button("") { selectTab(.whisper) }
                    .keyboardShortcut("9", modifiers: .control)
                Button("") { selectTab(.analytics) }
                    .keyboardShortcut("0", modifiers: .control)
                Button("") { selectTab(.updates) }
                    .keyboardShortcut("a", modifiers: .control)
                Button("") { selectTab(.shortcuts) }
                    .keyboardShortcut("k", modifiers: .control)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
        .onChange(of: searchText) { _, _ in
            if !visibleTabs.contains(selectedTab), let first = visibleTabs.first {
                selectedTab = first
            }
        }
        .onAppear {
            openRequestedTab()
        }
        .onChange(of: requestedTab) { _, _ in openRequestedTab() }
    }

    private func selectTab(_ tab: SettingsTab) {
        searchText = ""
        selectedTab = tab
    }

    private func openRequestedTab() {
        guard !requestedTab.isEmpty else { return }
        if let tab = SettingsTab(rawValue: requestedTab) {
            searchText = ""
            selectedTab = tab
        }
        requestedTab = ""
    }
}

#Preview {
    SettingsView()
}
