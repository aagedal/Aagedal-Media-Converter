# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Aagedal Media Converter is a macOS application for batch video encoding, built in Swift with SwiftUI and AppKit. It uses a bundled FFmpeg for conversion and analysis, AVPlayer for preview of Apple-native formats and MPV (via MPVKit) for everything else. The project targets macOS 15.0+ on Apple Silicon (x86_64 is excluded).

**Key characteristics:**
- GPL-3.0 licensed (bundled GPL FFmpeg and MPV), distributed by direct download, Homebrew and Sparkle updates — never the Mac App Store
- Not sandboxed (see File Access below)
- Swift 6 language mode with strict concurrency
- Grew quickly by "vibe-coding"; since mid-2026 it has a large unit test suite (about 1,800 tests) and local CI
- Feature branches merge to `main` through pull requests

## Plans and docs

- `IMPROVEMENT_PLAN.md` — the current, short backlog. Keep it short; put details in a dated `docs/` file and link it.
- `docs/improvement-history-2026.md` — the detailed work log up to 2026-10-18 (the former plan). Section numbers such as "2.2" refer to it.
- `docs/` also holds feature plans (`AUDIO-METERING-PLAN.md`, `encode-history-plan.md`, `transcription-pipeline-plan.md`, `ytdlp-rs-integration.md`), report formats, validation records and dependency provenance.
- `CHANGELOG.md` — user-facing release notes, newest first.
- `TODO.md` — historical checklist; all items are done.

## Building and Running

`xcode-select` may point at the Command Line Tools on this machine; prefix `xcodebuild` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if it complains that it requires Xcode.

### Build Commands
```bash
# Open in Xcode
open "Aagedal Media Converter.xcodeproj"

# Build from command line
xcodebuild -project "Aagedal Media Converter.xcodeproj" \
  -scheme "Aagedal Media Converter" \
  -configuration Debug \
  build

# Build for release
xcodebuild -project "Aagedal Media Converter.xcodeproj" \
  -scheme "Aagedal Media Converter" \
  -configuration Release \
  build
```

### Dependencies
- **Swift packages** (resolved by Xcode): MPVKit (fork at github.com/aagedal/MPVKit, the MPV player), SwiftMediaMetadata (metadata probing) and Sparkle (updates). Release builds skip package updates, so resolve new pins in the release checkout first with `-resolvePackageDependencies`.
- **Bundled binaries** in `Aagedal Media Converter/Binaries/`: ffmpeg, AV2 tools (`avmenc`/`avmdec`), BMX/MXF tools, rclone, tesseract, ssimulacra2, yt-dlp-rs and the NeMo speech runtime. Every bundled executable and dylib is recorded in `BundledDependencies.json`, which CI regenerates and checks.
- **Managed downloads**: yt-dlp and similar tools are installed or updated at runtime (`Logic/YTDLP/ManagedToolStore.swift`), with Homebrew or custom paths resolved by `Utils/BinaryPathResolver.swift`.

### Adding source files
The project uses explicit file references for `Logic/` and `UI/`. A new `.swift` file compiles only after it is added to `project.pbxproj` by hand: a `PBXBuildFile`, a `PBXFileReference`, a child in the owning `PBXGroup`, and an entry in the target's Sources build phase. Model these on a neighbouring file; readable custom IDs are fine.

### Running Tests
```bash
# Run all tests
xcodebuild test -project "Aagedal Media Converter.xcodeproj" \
  -scheme "Aagedal Media Converter"

# Run specific test target
xcodebuild test -project "Aagedal Media Converter.xcodeproj" \
  -scheme "Aagedal Media Converter" \
  -only-testing:"Aagedal Media ConverterTests"
```

### Local CI (run before pushing or opening a PR)
GitHub Actions no longer validates pull requests, only `main`, tags, the weekly schedule and manual runs. Run the same checks locally and report the result in the PR's testing notes:
```bash
scripts/ci-local.sh            # manifest, script tests, localizations, Debug build, unit tests
scripts/ci-local.sh --release  # also the Release build and bundle verification
```
Logs and `.xcresult` bundles go to `~/Library/Caches/AagedalMediaConverter-CI/Results`. Only one run happens at a time; others wait for the lock.

## Code Architecture

### High-Level Structure

```
UI Layer (SwiftUI + AppKit queue table)
    ↓
ConversionManager (actor) - Queue management, progress tracking, merge planning
    ↓
FFMPEGConverter (actor) - Process execution, progress parsing, AV2/package paths
    ↓
FFMPEGCommandBuilder - FFmpeg argument construction
```

A second engine, `ApplicationJobService` (`Logic/AgentAccess/ApplicationJobContract.swift`), runs jobs submitted by Shortcuts and the local MCP helper (`AgentHelper/`, target "Aagedal Media Converter MCP"). Its rows are projected into the same queue UI. Converging the two engines is on the roadmap.

### Key Architectural Patterns

#### 1. Conversion Pipeline
- **ConversionManager** (`Logic/ConversionManager.swift`): Actor that orchestrates the conversion queue
  - Manages conversion state and queue ordering
  - Merge compatibility (`evaluateMergeCompatibility()`, policy in `Logic/MergeCompatibilityPolicy.swift`) and merge planning (`buildMergePlan()`)
  - Provides progress updates via AsyncStream

- **FFMPEGConverter** (`Logic/Conversion/FFMPEGConverter.swift`): Actor that executes FFmpeg and related tools
  - Spawns processes through the shared `Utils/SubprocessRunner.swift`
  - Parses progress (`FFMPEGProgressParser.swift`) and handles cancellation
  - Also owns AV2 (chunked) encoding and Matroska muxing, AVC-Intra/MCA handling and output validation

- **FFMPEGCommandBuilder** (`Logic/Conversion/FFMPEGCommandBuilder.swift`): Builds FFmpeg arguments (`buildCommand()`)
  - Constructs arguments from an `ExportPreset` plus per-item settings (trim, crop, audio routing, waveform)
  - Supports custom presets (`Logic/Preset/PresetManager.swift`)

- Package and delivery formats have their own services in `Logic/Conversion/`: DCP (`DCPService`, `DCPValidator`), IMF (`IMFManifestWriter`), MXF via BMX (`BMXService`, `NativeMXFMerge`), AV2 (`AV2CommandBuilder`, `IVFConcatenator`, `MatroskaMuxer`).

#### 2. Preview and Playback
- **PreviewPlayerController** (`Logic/TrimPlayer/PreviewPlayerController.swift`): Main controller
  - Uses AVPlayer for Apple-native formats and `MPVPlayer` for everything else (`setupMPV`)
  - Extensions: `_Screenshot`, `_Observers`
- **MPVPlayer** (`Logic/MPV/MPVPlayer.swift`): libmpv wrapper rendering into `MPVMetalLayer`
- **PreviewAssetGenerator** (`Logic/Previews/PreviewAssetGenerator.swift`): Caches thumbnails and waveforms
- **Audio meters**: `Logic/Previews/SourceAudioMeter.swift` (default, measures the source with FFmpeg) and `MPVAudioMeterHistory.swift` (timestamped MPV playback measurements; see `docs/AUDIO-METERING-PLAN.md`)
- Fullscreen player views are in `UI/FullscreenPlayer/`; trim and crop UI in `UI/TrimPlayerViews/`

#### 3. Audio Routing System
- **AudioRoutingService** (`Logic/Conversion/AudioRoutingService.swift`): Reads input audio tracks and builds typed routing plans (`makePlan`) and FFmpeg mapping/codec arguments
- **AudioRoutingModels** (`Logic/AudioRoutingModels.swift`): Data models for routing configurations
  - Supports mono/stereo conversion, channel splitting, and mapping
  - Incompatible with waveform video generation when using splitToMono

#### 4. Data Flow
- **VideoItem** (`Logic/VideoFilesUtil.swift`, `struct VideoItem`): Main model representing a file in the queue
  - Sendable struct with UUID identity
  - Tracks conversion status, progress, trim points, metadata and per-item settings
- **VideoMetadataService** (`Logic/VideoMetadataService.swift`): Cached metadata lookup, used by merge checks. Probing uses SwiftMediaMetadata (`Logic/Metadata/`) and FFmpeg (`Logic/Conversion/FFMPEGProbeService.swift`).

#### 5. Queue Row Rendering (AppKit, not SwiftUI)

Queue rows are rendered by an `NSTableView`, not SwiftUI. (A former SwiftUI `VideoFileRowView` was replaced for performance; `VideoFileRowView.swift` now only holds the `ThumbnailCache`/`ThumbnailDecoder` utilities used by the table view.)

- **VideoQueueTableView** (`UI/VideoQueueViews/VideoQueueTableView.swift`): `NSViewRepresentable` wrapping an `NSTableView`. Dequeues `VideoFileCellView` and `EncodingGroupHeaderCellView` with `makeView(withIdentifier:)`.
- **VideoFileCellView** (`UI/VideoQueueViews/VideoFileCellView.swift`): AppKit `NSTableCellView` subclass. All real click handlers, layout, NSButtons, NSTextFields, and `mouseDown` overrides live here.
  - Extensions: `+Actions.swift` (state → UI updates for toggle buttons), `+Thumbnail.swift` (tracking areas, hover state, badges), `+Comment.swift`, `+Preset.swift`.
- **CellAction** (`UI/VideoQueueViews/CellConfiguration.swift`): enum that cells raise; handled in `VideoQueueTableView.handleCellAction`. Add a new case here when adding a new interaction that needs to reach ContentView.

**Rules of thumb when modifying queue-item interactions:**
- Click handlers are `@objc` methods on `VideoFileCellView` wired via `button.target = self, button.action = #selector(...)`.
- Modifier-key detection happens inside those handlers via `NSEvent.modifierFlags`. NSTableView reserves plain Shift-click and plain Cmd-click for selection — use `Shift+Cmd` for custom modifier shortcuts (reaches the handler with flags intact).
- For hit-testing nested labels in `mouseDown`, use `label.convert(label.bounds, to: self)` — `label.frame` is in the parent stack's coordinate space, not the cell's. Getting this wrong silently breaks click regions.
- New inter-view callbacks must be threaded **ContentView → VideoFileListView → VideoQueueTableView → handleCellAction**. Each layer declares `var onXxx: (…) -> Void` and forwards. Swift requires call-site argument order to match the struct's declaration order.
- Group header rows use a separate `EncodingGroupHeaderCellView` — similar pattern but distinct.

### Directory Structure

```
Aagedal Media Converter/
├── Logic/
│   ├── Conversion/         # FFmpeg pipeline, presets, DCP/IMF/MXF/AV2, waveform rendering
│   ├── AgentAccess/        # ApplicationJobService and the local MCP transport
│   ├── Analytics/          # Loudness, peak, phase, silence, bitrate and video-event analysis
│   ├── History/            # Encode history, last-session restore, statistics
│   ├── Import/             # Folder, camera card (P2, …), IMF and image-sequence import
│   ├── Metadata/           # SwiftMediaMetadata probing, C2PA, metadata export
│   ├── MPV/                # libmpv player and Metal layer
│   ├── Previews/           # Preview assets and audio meters
│   ├── Subtitles/          # PGS/VOBSUB parsing and OCR (Vision, Tesseract)
│   ├── Sync/               # Settings sync via iCloud Drive folder
│   ├── TrimPlayer/         # PreviewPlayerController and extensions
│   ├── Upload/             # rclone uploads and FileZilla import
│   ├── WatchFolder/        # Watch-folder import (FSEvents + ledger)
│   ├── Whisper/, Parakeet/, Nemotron/   # Transcription engines
│   ├── Transcription/      # Word-level Whisper pipeline: speech-only audio, wav2vec2 alignment, speakers, cues
│   ├── YTDLP/              # Downloads (yt-dlp, yt-dlp-rs) and managed tool updates
│   ├── ConversionManager.swift, VideoFilesUtil.swift, VideoMetadataService.swift,
│   └── ScreenCaptureManager.swift, AudioRoutingModels.swift, …
├── UI/                     # ContentView plus VideoQueueViews, TrimPlayerViews, FullscreenPlayer,
│                           # SettingsView, MetadataView, History, Conversion, Components, AssistiveViews
├── Utils/                  # AppConstants, SubprocessRunner, BinaryPathResolver,
│                           # SecurityScopedBookmarkManager, TimecodeFormatter, …
├── AppIntents/             # Shortcuts intents and hand-off to the app
├── Binaries/               # Bundled executables
├── Resources/              # Assets, sounds, icons, string catalog
└── Aagedal_Media_Converter_App.swift
AgentHelper/                # MCP helper executable
scripts/                    # ci-local.sh, release.sh, manifest/notice generators, benchmarks
```

## Important Technical Details

### FFmpeg Integration
- Bundled in `Aagedal Media Converter/Binaries/`; paths resolved by `Utils/BinaryPathResolver.swift` (bundled, Homebrew or custom)
- The bundled ffmpeg is built in a separate repository; before shipping a new one, check `otool -L` shows no Homebrew paths
- Progress parsing happens via stderr monitoring (see `FFMPEGProgressParser.swift`)
- Command construction is centralized in `FFMPEGCommandBuilder`

### Preview Cache Management
- Preview assets cached in the Application Support directory (`PreviewAssets/`)
- Three cleanup policies: purgeOnLaunch, purgeOnQuit, manual (`PreviewCacheCleanupPolicy.swift`)

### Merge Feature
- Evaluates compatibility by comparing codecs, resolution, frame rate, aspect ratio
- Creates concat demuxer list files for FFmpeg; MXF merges can use BMX (`NativeMXFMerge`)
- Handles trimmed clips by generating temporary stream-copied segments
- See `ConversionManager.evaluateMergeCompatibility()` and `buildMergePlan()`

### Audio Waveform Video Generation
- Generates video from audio-only files (`NativeWaveformVideoRenderer` and FFmpeg filters)
- Configurable resolution, colors, normalization, styles
- Incompatible with `splitToMono` audio routing (needs separate audio output)
- Falls back to synthesized solid color video if waveform disabled

### File Access (not sandboxed)
- `ENABLE_APP_SANDBOX = NO`; entitlements carry only `com.apple.security.cs.disable-library-validation` (for the hardened runtime + bundled dylib loading), nothing sandbox-related. There is no iCloud entitlement either: settings sync writes JSON straight into the iCloud Drive folder on disk.
- `SecurityScopedBookmarkManager` is still used to persist user folder/file choices (output folder, watch folder, custom binary paths) across launches — `URL.bookmarkData` survives relaunch even without the sandbox. The matching `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` pairs in call sites are no-ops without the sandbox; they remain in the code as cheap, harmless defence in case sandboxing is ever re-enabled.
- A common pattern in I/O paths (conversion, preview, metadata probe) is "try direct file access first, fall back to bookmark on failure." The bookmark fallback is effectively dead code without the sandbox but harmless; only remove it if you also remove the upstream bookmark plumbing.

### Concurrency
- Swift 6 strict concurrency: new code must be concurrency-clean (for example `MainActor.assumeIsolated` inside `.main`-queue NotificationCenter or DispatchSource closures)
- `ConversionManager`, `FFMPEGConverter` and `ApplicationJobService` are actors
- External processes go through `SubprocessRunner`, which owns cancellation and draining
- Progress updates via `AsyncStream<Double>`

### Localization
- User-visible strings live in the string catalog with English and Norwegian (nb) translations at minimum
- `scripts/check-localizations.py` (part of local CI) fails on missing entries

## Common Development Patterns

### Adding New Export Presets
1. Add a case to the `ExportPreset` enum in `Logic/Conversion/ExportPreset.swift`
2. Fill in its file extension, suffix, display name and description
3. Add FFmpeg command logic in `FFMPEGCommandBuilder.buildCommand()`
4. Add command-generation tests; update the preset picker UI if needed

### Modifying FFmpeg Commands
- Edit `FFMPEGCommandBuilder.buildCommand()` for preset-based changes
- Custom presets are managed by `PresetManager` (older single custom-preset keys are `AppConstants.customPreset*Key`)
- Cover changes with command-generation tests

### Working with Preview System
- Native formats: AVPlayer
- Non-native formats: `MPVPlayer`
- Always balance security-scoped access (`stopAccessingSecurityScopedResource()`)

### Audio Routing Changes
- Change plan and argument logic in `AudioRoutingService` and models in `AudioRoutingModels.swift`
- Check compatibility with waveform generation (splitToMono is incompatible)
- Test with various channel configurations (mono, stereo, 5.1, etc.)

## Supported File Formats

See `AppConstants.supportedVideoExtensions` for the full list. Key formats:
- Video: mp4, mov, mkv, avi, webm, flv, m4v, mpg, mts, mxf
- Audio: aac, mp3, wav, flac, m4a, opus, ogg
- Packages and cards: DCP, IMF, P2 and other camera cards, image sequences
- Apple-specific: apv

## Known Issues & Workarounds

1. **Waveform incompatible with splitToMono** - By design (needs separate outputs)
2. **MPV Metal crash on crop toggle during seek** - Rare crash when toggling crop mode (C key) while actively dragging the playhead in the trim view. Metal validation asserts `renderTargetWidth must be <= minimum attachment width` because MoltenVK's Vulkan swapchain extent and the CAMetalLayer drawableSize go out of sync during the resize. Mitigated by deferred drawableSize updates in `MPVMetalLayer.deferResizes`, but the race window cannot be fully closed without synchronization with MPV's render thread. Only affects MPV-rendered files (non-native codecs like MXF). Reproducible with Metal validation enabled; may manifest as a brief black border in the bottom-right without validation.
3. **Release-configuration MCP tests** - Four `ApplicationJobContractTests` cases fail in a Release test build because their port override is `#if DEBUG`

## Testing Approach

- Unit tests live in `Aagedal Media ConverterTests/`; UI smoke tests in `Aagedal Media ConverterUITests/`. Many tests generate small media fixtures with the bundled ffmpeg.
- Run `scripts/ci-local.sh` before pushing; add focused tests for regressions.
- Manual checks still matter for:
  - Various input formats (especially non-Apple codecs) and preview playback in both AVPlayer and MPV
  - Merge with compatible/incompatible files
  - Audio routing with different channel configurations
  - Bookmark persistence: after selecting an output / watch folder, quit and relaunch, then verify the folder is still active without a re-prompt
