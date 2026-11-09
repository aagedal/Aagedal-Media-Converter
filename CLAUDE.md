# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Aagedal Media Converter is a macOS application for batch video encoding, built entirely in Swift/SwiftUI. It's a sandboxed app using FFMPEG/FFPROBE for conversion and VLCKit for video preview/playback. The project targets macOS 15.0+ and Apple Silicon (M1 or later).

**Key characteristics:**
- Most of the codebase is "vibe-coded" (rapid prototyping style)
- GPL-3.0 licensed (due to bundled FFMPEG with GPL)
- Uses Security-Scoped Bookmarks for persistent file access in sandbox
- Currently in active development on the `vlckit_dev` branch

## Building and Running

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
- **VLCKit**: Managed via Carthage (binary dependency)
  - Install: `carthage update --use-xcframeworks --platform macOS`
  - Location: `Carthage/Build/VLCKit.xcframework`
- **FFMPEG/FFPROBE**: Bundled binaries in `Aagedal Media Converter/Binaries/`

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
Logs and `.xcresult` bundles go to `~/Library/Caches/AagedalMediaConverter-CI/Results`.

## Code Architecture

### High-Level Structure

The app follows a SwiftUI architecture with the main conversion logic isolated in actor-based services:

```
UI Layer (SwiftUI)
    ↓
ConversionManager (actor) - Queue management, progress tracking, merge planning
    ↓
FFMPEGConverter (actor) - Process execution and progress parsing
    ↓
FFMPEGCommandBuilder - FFMPEG argument construction
```

### Key Architectural Patterns

#### 1. Conversion Pipeline
- **ConversionManager** (`Logic/ConversionManager.swift`): Actor that orchestrates the entire conversion queue
  - Manages conversion state and queue ordering
  - Handles merge compatibility evaluation for multi-file exports
  - Provides progress updates via AsyncStream
  - Coordinates with FFMPEGConverter for actual encoding

- **FFMPEGConverter** (`Logic/Conversion/FFMPEGConverter.swift`): Actor that executes FFMPEG processes
  - Spawns and monitors FFMPEG processes
  - Parses stderr for progress information
  - Handles process cancellation

- **FFMPEGCommandBuilder** (`Logic/Conversion/FFMPEGCommandBuilder.swift`): Pure functions for building FFMPEG commands
  - Constructs arguments based on ExportPreset
  - Handles trim points, audio routing, waveform generation
  - Supports custom presets with user-defined FFMPEG arguments

#### 2. Video Preview System (Dual-Player Architecture)
The app uses a sophisticated dual-player system to handle both native and non-native formats:

- **PreviewPlayerController** (`Logic/TrimPlayer/PreviewPlayerController.swift`): Main controller
  - Manages AVPlayer for native formats (Apple-supported codecs)
  - Falls back to VLCPlayer for non-native formats
  - Coordinates between HLS chunk-based preview and MP4 preview sessions
  - Extensions: `+Screenshot`, `+FallbackPreview`, `+Observers`

- **Preview Sessions**:
  - **HLSPreviewSession** (`Logic/Previews/HLSPreviewSession.swift`): Generates 5-second HLS chunks for scrubbing
  - **MP4PreviewSession** (`Logic/Previews/MP4PreviewSession.swift`): Direct MP4 preview for compatible files
  - **PreviewAssetGenerator** (`Logic/Previews/PreviewAssetGenerator.swift`): Caches thumbnails and waveforms

- **VLCPlayer** (`Logic/VLC/VLCPlayer.swift`): Wrapper around VLCKit for non-native playback
  - Used as fallback when AVPlayer cannot handle the format
  - Provides unified playback interface matching AVPlayer behavior

#### 3. Audio Routing System
Recent addition (see git history) for flexible audio channel manipulation:

- **AudioRoutingService** (`Logic/Conversion/AudioRoutingService.swift`): Analyzes input audio and generates FFMPEG filter chains
- **AudioRoutingModels** (`Logic/AudioRoutingModels.swift`): Data models for routing configurations
  - Supports mono/stereo conversion, channel splitting, and mapping
  - Incompatible with waveform video generation when using splitToMono

#### 4. Data Flow
- **VideoItem** (`Logic/VideoFilesUtil.swift:474`): Main model representing a file in the queue
  - Sendable struct with UUID identity
  - Tracks conversion status, progress, trim points, metadata
  - Audio routing configuration stored per-item

- **VideoMetadataService** (`Logic/VideoMetadataService.swift`): Probes files using FFPROBE
  - Cached metadata lookup
  - Used for merge compatibility checks

#### 5. Queue Row Rendering (AppKit, not SwiftUI)

Queue rows are rendered by an `NSTableView`, not SwiftUI. (A former SwiftUI `VideoFileRowView` was replaced for performance; `VideoFileRowView.swift` now only holds the `ThumbnailCache`/`ThumbnailDecoder` utilities used by the table view.)

- **VideoQueueTableView** (`UI/VideoQueueViews/VideoQueueTableView.swift`): `NSViewRepresentable` wrapping an `NSTableView`. Registers and dequeues `VideoFileCellView` at line ~450.
- **VideoFileCellView** (`UI/VideoQueueViews/VideoFileCellView.swift`, ~1445 lines): AppKit `NSTableCellView` subclass. All real click handlers, layout, NSButtons, NSTextFields, and `mouseDown` overrides live here.
  - Extensions: `+Actions.swift` (state → UI updates for toggle buttons), `+Thumbnail.swift` (tracking areas, hover state, badges), `+Comment.swift`.
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
├── Logic/                          # Business logic and services
│   ├── Conversion/                 # FFMPEG conversion pipeline
│   │   ├── ConversionManager.swift
│   │   ├── FFMPEGConverter.swift
│   │   ├── FFMPEGCommandBuilder.swift
│   │   ├── FFMPEGProbeService.swift
│   │   ├── FFMPEGProgressParser.swift
│   │   ├── ExportPreset.swift
│   │   └── AudioRoutingService.swift
│   ├── Previews/                   # Preview asset generation
│   │   ├── HLSPreviewSession.swift
│   │   ├── MP4PreviewSession.swift
│   │   ├── PreviewAssetGenerator.swift
│   │   └── PreviewAssetResourceLoader.swift
│   ├── TrimPlayer/                 # Video player for preview/trim
│   │   ├── PreviewPlayerController.swift
│   │   ├── PreviewPlayerController_Screenshot.swift
│   │   ├── PreviewPlayerController_FallbackPreview.swift
│   │   ├── PreviewPlayerController_Observers.swift
│   │   └── UniversalAudioMeterService.swift
│   ├── VLC/                        # VLCKit wrapper
│   │   └── VLCPlayer.swift
│   ├── WatchFolder/                # Auto-import from folder
│   │   ├── WatchFolderManager.swift
│   │   └── WatchFolderDurationUnit.swift
│   ├── VideoFilesUtil.swift        # VideoItem model and utilities
│   ├── VideoMetadataService.swift
│   ├── AudioRoutingModels.swift
│   ├── FileNameProcessor.swift
│   ├── SoundManager.swift
│   └── UpdateChecker.swift
├── UI/                             # SwiftUI views
│   ├── ContentView.swift
│   ├── VideoQueueViews/            # Main queue interface
│   ├── TrimPlayerViews/            # Preview/trim UI
│   ├── SettingsView/               # App settings
│   ├── Conversion/                 # Conversion controls
│   ├── Components/                 # Reusable UI components
│   ├── MetadataView/
│   └── AssistiveViews/
├── Utils/                          # Utilities and constants
│   ├── AppConstants.swift
│   ├── SecurityScopedBookmarkManager.swift
│   └── AudioWaveformPreferences.swift
├── AppIntents/                     # macOS Shortcuts support
│   ├── AddToEncodeQueueIntent.swift
│   └── ConvertImmediatelyIntent.swift
├── Binaries/                       # FFMPEG/FFPROBE executables
├── Resources/                      # Assets, sounds, icons
└── Aagedal_Media_Converter_App.swift
```

## Important Technical Details

### FFMPEG Integration
- Binaries located in `Aagedal Media Converter/Binaries/`
- Access via `Bundle.main.path(forResource: "ffmpeg", ofType: nil)`
- Progress parsing happens via stderr monitoring (see `FFMPEGProgressParser.swift`)
- Command construction is centralized in `FFMPEGCommandBuilder`

### Preview Cache Management
- Preview assets cached in Application Support directory
- Three cleanup policies: purgeOnLaunch, purgeOnQuit, manual
- HLS chunks are temporary 5-second segments for scrubbing
- Waveforms and thumbnails persisted in `PreviewAssets/` subdirectory

### Merge Feature
- Evaluates compatibility by comparing codecs, resolution, frame rate, aspect ratio
- Creates concat demuxer list files for FFMPEG
- Handles trimmed clips by generating temporary stream-copied segments
- See `ConversionManager.evaluateMergeCompatibility()` and `buildMergePlan()`

### Audio Waveform Video Generation
- Uses FFMPEG `showwavespic` filter to generate video from audio-only files
- Configurable resolution, colors, normalization, styles
- Incompatible with `splitToMono` audio routing (needs separate audio output)
- Falls back to synthesized solid color video if waveform disabled

### File Access (not sandboxed)
- `ENABLE_APP_SANDBOX = NO`; entitlements carry only `com.apple.security.cs.disable-library-validation` (for the hardened runtime + bundled dylib loading), nothing sandbox-related.
- `SecurityScopedBookmarkManager` is still used to persist user folder/file choices (output folder, watch folder, custom binary paths) across launches — `URL.bookmarkData` survives relaunch even without the sandbox. The matching `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` pairs in call sites are no-ops without the sandbox; they remain in the code as cheap, harmless defence in case sandboxing is ever re-enabled.
- A common pattern in I/O paths (conversion, preview, metadata probe) is "try direct file access first, fall back to bookmark on failure." The bookmark fallback is effectively dead code without the sandbox but harmless; only remove it if you also remove the upstream bookmark plumbing.

### QTGMC Deinterlacing (Metal)
- Optional replacement for the built-in `bwdif` stage (Settings → Encoding → Deinterlacing), in `Logic/Conversion/QTGMC/`.
- `FFMPEGConverter.convert` builds the normal command first; only when it contains `QTGMCPipelinePlan.builtInDeinterlaceStage` is it rebuilt with a Y4M pipe as input 0 and the source as input 1 (`QTGMCPipelinePlan.encoderArguments` removes the bwdif stage and redirects audio/subtitle/metadata references to input 1).
- Runs as `ffmpeg decoder → QTGMCFrameTransform → ffmpeg encoder` through `SubprocessRunning.runPipeline(transform:)`. Trims decode a 3-frame pre-roll that the transform drops.
- `QTGMCMetalDeinterlacer` schedules the kernels in `QTGMC.metal` (NNEDI3, search clip, hierarchical block ME, MDegrain-style smoothing, resharpen, lossless de-combing). The shader is a bundle resource compiled at runtime (`makeLibrary(source:)`), not a build-time Metal target. NNEDI3 weights: `Resources/nnedi3_weights.bin` (notice in `Licenses/nnedi3-LICENSE.txt`).

### Concurrency
- Heavy use of Swift Concurrency (async/await, actors)
- `ConversionManager` and `FFMPEGConverter` are actors
- Progress updates via `AsyncStream<Double>`
- Background preview generation with Task cancellation support

## Common Development Patterns

### Adding New Export Presets
1. Add case to `ExportPreset` enum in `Logic/Conversion/ExportPreset.swift`
2. Implement `fileExtension`, `description`, `fileSuffix` properties
3. Add FFMPEG command logic in `FFMPEGCommandBuilder.buildCommand()`
4. Update preset picker UI if needed

### Modifying FFMPEG Commands
- Edit `FFMPEGCommandBuilder.buildCommand()` for preset-based changes
- Custom presets stored in UserDefaults (see `AppConstants.customPreset*Key`)
- Test with FFMPEG stderr logging enabled (`print()` statements in `FFMPEGConverter`)

### Working with Preview System
- Native formats: AVPlayer handles automatically
- Non-native: VLCPlayer fallback triggers when AVPlayer fails
- Chunk generation: `HLSPreviewSession.generateChunk()` creates 5s segments
- Always clean up security-scoped access (`stopAccessingSecurityScopedResource()`)

### Audio Routing Changes
- Modify `AudioRoutingService.buildFilterGraph()` for filter chain logic
- Update `AudioRoutingModels.swift` for new routing modes
- Check compatibility with waveform generation (splitToMono is incompatible)
- Test with various channel configurations (mono, stereo, 5.1, etc.)

## Supported File Formats

See `AppConstants.supportedVideoExtensions` for the full list. Key formats:
- Video: mp4, mov, mkv, avi, webm, flv, m4v, mpg, mts, mxf
- Audio: aac, mp3, wav, flac, m4a, opus, ogg
- Apple-specific: apv (chunk-based files requiring AVP fallback player)

## Known Issues & Workarounds

1. **Lagging scrolling with many queued items** - Performance optimization needed
2. **Audio track selection for APV files** - Fixed in recent commits
3. **Waveform incompatible with splitToMono** - By design (needs separate outputs)
4. **MPV Metal crash on crop toggle during seek** - Rare crash when toggling crop mode (C key) while actively dragging the playhead in the trim view. Metal validation asserts `renderTargetWidth must be <= minimum attachment width` because MoltenVK's Vulkan swapchain extent and the CAMetalLayer drawableSize go out of sync during the resize. Mitigated by deferred drawableSize updates in `MPVMetalLayer.deferResizes`, but the race window cannot be fully closed without synchronization with MPV's render thread. Only affects MPV-rendered files (non-native codecs like MXF). Reproducible with Metal validation enabled; may manifest as a brief black border in the bottom-right without validation.

## Testing Approach

The codebase is "vibe-coded" with minimal test coverage. When making changes:
- Test with various input formats (especially non-Apple codecs)
- Verify preview playback works for both native and VLC fallback
- Check merge feature with compatible/incompatible files
- Test audio routing with different channel configurations
- Confirm bookmark persistence: after selecting an output / watch folder, quit and relaunch, then verify the folder is still active without a re-prompt
