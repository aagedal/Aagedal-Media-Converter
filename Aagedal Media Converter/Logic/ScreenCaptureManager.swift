// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Screen capture pipeline using ScreenCaptureKit + AVAssetWriter.

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import VideoToolbox
import AudioToolbox
import Darwin
import CoreGraphics
import CoreImage
@preconcurrency import ScreenCaptureKit
import OSLog
import os
import AppKit

private enum AudioSettingKeys {
    static let linearPCMIsNonInterleaved = "AVLinearPCMIsNonInterleaved"
}

struct CaptureDisplay: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
    let isMain: Bool
}

/// The capture options shared across every selected display (one preset/audio choice applies to
/// all per-screen streams). `regionRect` is only meaningful for a single-display selection.
struct CaptureSettings: Sendable {
    var frameRate: CaptureFrameRateOption = .auto
    var includeSystemAudio: Bool = true
    var includeMicrophone: Bool = false
    var microphoneDeviceID: String? = nil
    var hideCursor: Bool = false
    var excludeCurrentApp: Bool = false
    var excludedAppBundleIDs: Set<String> = []
    var regionRect: CGRect? = nil
}

enum CapturePreset: String, CaseIterable, Identifiable {
    case hevcGrowing
    case avcGrowing
    case proRes4444Growing
    case hevc42210Bit
    case proRes4444

    var id: String { rawValue }

    /// The preset selected by default (and the fallback when a stored choice no longer
    /// decodes or isn't available). Growing files are the recommended default — they can be
    /// edited while still recording in DaVinci Resolve / Premiere.
    static var defaultPreset: CapturePreset { .hevcGrowing }

    var displayName: String {
        switch self {
        case .hevcGrowing:
            return String(localized: "Growing HEVC 10-bit 4:2:2 (Resolve/Premiere)")
        case .avcGrowing:
            return String(localized: "Growing H.264 (Compatibility)")
        case .proRes4444Growing:
            return String(localized: "Growing ProRes 4444 (Visually Lossless)")
        case .hevc42210Bit:
            return String(localized: "HEVC 10-bit 4:2:2 (Hardware)")
        case .proRes4444:
            return String(localized: "ProRes 4444 (Visually Lossless)")
        }
    }

    var detail: String {
        switch self {
        case .hevcGrowing:
            return String(localized: "Edit while recording in DaVinci Resolve & Premiere. Hardware HEVC 10-bit 4:2:2, fragmented .mov.")
        case .avcGrowing:
            return String(localized: "Edit while recording with maximum compatibility. Hardware H.264, fragmented .mov.")
        case .proRes4444Growing:
            return String(localized: "Edit while recording in DaVinci Resolve & Premiere. ProRes 4444 at a constant frame rate (CFR) — visually lossless, but because ProRes can't compress duplicate frames, a mostly-static screen makes very large files. Needs a ProRes hardware encoder (M1 Pro/Max or later) for high frame rates.")
        case .hevc42210Bit:
            return String(localized: "Hardware HEVC 10-bit 4:2:2; source format determines chroma. Variable frame rate, not flagged as a growing clip — best for importing after recording.")
        case .proRes4444:
            return String(localized: "Visually lossless ProRes 4444 for grading. Variable frame rate (VFR) keeps files smaller when the screen is static. Not flagged as a growing clip, so DaVinci Resolve won't poll it for updates while recording — best for importing afterward.")
        }
    }

    var fileExtension: String {
        "mov"
    }

    var fileType: AVFileType {
        .mov
    }

    var frameRateDetail: String {
        isGrowing
            ? String(localized: "Constant frame rate (CFR): static frames are repeated at the selected rate.")
            : String(localized: "Variable frame rate (VFR): the selected rate is a maximum; static screens may produce fewer frames.")
    }

    var targetFrameRate: Int {
        60
    }

    /// "Growing file": a fragmented `.mov` tagged with the Blackmagic recording
    /// xattr so DaVinci Resolve treats it as a live, edit-while-recording clip
    /// (red REC overlay + fast refresh). See docs/growing-file-research.
    var isGrowing: Bool {
        switch self {
        case .hevcGrowing, .avcGrowing, .proRes4444Growing:
            return true
        case .hevc42210Bit, .proRes4444:
            return false
        }
    }

    static var availablePresets: [CapturePreset] {
        // Growing presets first (recommended for edit-while-recording). Stored
        // defaults that don't decode (e.g. the removed `.x264TS`/`.hevcVTTS`
        // FFmpeg-pipe presets) fall back to `.defaultPreset` at the call sites.
        [.hevcGrowing, .avcGrowing, .proRes4444Growing, .hevc42210Bit, .proRes4444]
    }

    func videoSettings(width: Int, height: Int, frameRate: CaptureFrameRate, hevcProfileOverride: String? = nil) -> [String: Any] {
        let compressionProperties: [String: Any]
        let codec: AVVideoCodecType
        let encoderSpec: [String: Any]?

        switch self {
        case .hevcGrowing:
            codec = .hevc
            var properties: [String: Any] = [
                AVVideoAverageBitRateKey: growingBitrate(width: width, height: height, frameRate: frameRate.framesPerSecond),
                AVVideoExpectedSourceFrameRateKey: frameRate.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: frameRate.nominalRate,          // ~1 s GOP
                AVVideoAllowFrameReorderingKey: false              // low-latency for live edit
            ]
            // 10-bit 4:2:2: prefer Main42210, fall back to Main10, else let the
            // encoder choose (resolved from the actual capture pixel format).
            if let hevcProfileOverride {
                properties[AVVideoProfileLevelKey] = hevcProfileOverride
            }
            compressionProperties = properties
            encoderSpec = nil   // allow hardware encoder
        case .avcGrowing:
            codec = .h264
            compressionProperties = [
                AVVideoAverageBitRateKey: growingBitrate(width: width, height: height, frameRate: frameRate.framesPerSecond),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: frameRate.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: frameRate.nominalRate,          // ~1 s GOP
                AVVideoAllowFrameReorderingKey: false
            ]
            encoderSpec = nil
        case .hevc42210Bit:
            codec = .hevc
            let bitrate = hevcBitrate(width: width, height: height, frameRate: frameRate.framesPerSecond)
            var properties: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate.average,
                AVVideoExpectedSourceFrameRateKey: frameRate.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: frameRate.nominalRate,
                kVTCompressionPropertyKey_DataRateLimits as String: bitrate.dataRateLimits
            ]
            if let hevcProfileOverride {
                properties[AVVideoProfileLevelKey] = hevcProfileOverride
            }
            compressionProperties = properties
            encoderSpec = nil
        case .proRes4444, .proRes4444Growing:
            codec = .proRes4444
            compressionProperties = [:]
            encoderSpec = nil
        }

        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]

        if !compressionProperties.isEmpty {
            settings[AVVideoCompressionPropertiesKey] = compressionProperties
        }

        if let encoderSpec {
            settings[AVVideoEncoderSpecificationKey] = encoderSpec
        }

        return settings
    }

    var audioSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48_000,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AudioSettingKeys.linearPCMIsNonInterleaved: false
        ]
    }

    /// Bitrate for the growing presets — lighter than the archival HEVC 4:2:2
    /// preset so edit-while-recording files stay manageable. ~0.1 bits/pixel.
    private func growingBitrate(width: Int, height: Int, frameRate: Double) -> Int {
        let pixelsPerSecond = Double(width) * Double(height) * Double(frameRate)
        let target = Int(pixelsPerSecond * 0.10)
        return min(max(target, 12_000_000), 120_000_000)
    }

    private func hevcBitrate(width: Int, height: Int, frameRate: Double) -> (average: Int, dataRateLimits: [Int]) {
        let pixelsPerSecond = Double(width) * Double(height) * Double(frameRate)
        let targetBitsPerSecond = pixelsPerSecond * 0.28
        let minBitrate = 50_000_000
        let maxBitrate = 200_000_000
        let clamped = min(max(Int(targetBitsPerSecond), minBitrate), maxBitrate)
        let bytesPerSecond = max(1, clamped / 8)
        return (clamped, [bytesPerSecond, 1])
    }
}

/// Exact frame cadence shared by ScreenCaptureKit, the CFR writer and timecode.
struct CaptureFrameRate: Equatable, Sendable {
    let numerator: Int32
    let denominator: Int32

    init(_ numerator: Int32, denominator: Int32 = 1) {
        precondition(numerator > 0 && denominator > 0)
        self.numerator = numerator
        self.denominator = denominator
    }

    var framesPerSecond: Double { Double(numerator) / Double(denominator) }
    var frameDuration: CMTime { CMTime(value: Int64(denominator), timescale: numerator) }
    var nominalRate: Int { Int(framesPerSecond.rounded()) }
    var droppedFramesPerMinute: Int {
        denominator == 1001 && (numerator == 30000 || numerator == 60000) ? nominalRate / 15 : 0
    }
    var timecodeFlags: UInt32 {
        kCMTimeCodeFlag_24HourMax | (droppedFramesPerMinute > 0 ? kCMTimeCodeFlag_DropFrame : 0)
    }
    var framesPerTimecodeDay: Int {
        nominalRate * 86400 - droppedFramesPerMinute * (1440 - 144)
    }

    func presentationOffset(frameIndex: Int) -> CMTime {
        CMTime(value: Int64(frameIndex) * Int64(denominator), timescale: numerator)
    }

    func timecodeFrame(hour: Int, minute: Int, second: Int, nanosecond: Int = 0) -> Int {
        let totalMinutes = hour * 60 + minute
        // The first 2/4 labels are omitted at every minute except multiples of ten.
        var subFrame = min(nominalRate - 1, Int(Double(nanosecond) / 1_000_000_000 * Double(nominalRate)))
        if second == 0 && minute % 10 != 0 {
            subFrame = max(subFrame, droppedFramesPerMinute)
        }
        let labels = (totalMinutes * 60 + second) * nominalRate + subFrame
        return labels - droppedFramesPerMinute * (totalMinutes - totalMinutes / 10)
    }

    func wrappedTimecodeFrame(start: Int, frameIndex: Int) -> Int {
        (start + frameIndex) % framesPerTimecodeDay
    }
}

enum CaptureFrameRateOption: String, CaseIterable, Identifiable {
    case auto
    case fps25
    case fps2997
    case fps50
    case fps5994
    case fps60

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return String(localized: "Auto (Display)")
        case .fps25: return String(localized: "25 fps (PAL)")
        case .fps2997: return String(localized: "29.97 fps (NTSC)")
        case .fps50: return String(localized: "50 fps (PAL)")
        case .fps5994: return String(localized: "59.94 fps (NTSC)")
        case .fps60: return String(localized: "60 fps")
        }
    }

    var fixedValue: CaptureFrameRate? {
        switch self {
        case .auto: return nil
        case .fps25: return CaptureFrameRate(25)
        case .fps2997: return CaptureFrameRate(30000, denominator: 1001)
        case .fps50: return CaptureFrameRate(50)
        case .fps5994: return CaptureFrameRate(60000, denominator: 1001)
        case .fps60: return CaptureFrameRate(60)
        }
    }
}

enum CaptureDynamicRangeOption: String, CaseIterable, Identifiable {
    case sdr
    case hdrP3CanonicalDisplay

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sdr:
            return String(localized: "SDR (Display)")
        case .hdrP3CanonicalDisplay:
            return String(localized: "HDR Display P3 (macOS 26+)")
        }
    }

    var isHDR: Bool {
        self != .sdr
    }
}

@MainActor
final class ScreenCaptureManager: NSObject, ObservableObject {
    static let shared = ScreenCaptureManager()

    /// Strips the Blackmagic "recording" xattr from any growing-file recording left
    /// tagged by a crash or quit that never reached `finish()`. Call once at launch so
    /// DaVinci Resolve doesn't keep showing a phantom red REC overlay on a dead file.
    nonisolated static func sweepStaleGrowingRecordings() {
        ScreenCaptureWriter.sweepStalePendingGrowingFiles()
    }

    enum CaptureError: LocalizedError {
        case unavailableDisplay
        case accessDenied
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailableDisplay:
                return "No display available for capture."
            case .accessDenied:
                return "Unable to access the output folder."
            case .writerFailed(let message):
                return "Capture writer failed: \(message)"
            }
        }
    }

    /// Displays currently recording (each to its own file). Drives per-tile record/stop UI.
    @Published private(set) var recordingDisplayIDs: Set<CGDirectDisplayID> = []
    @Published private(set) var isProcessing = false
    @Published private(set) var isPreviewing = false
    @Published private(set) var elapsedTime: TimeInterval = 0
    /// All files finalized in the current capture session (primary/earliest first).
    @Published private(set) var lastOutputURLs: [URL] = []
    @Published var errorMessage: String?
    /// Live preview frame per display (preview or recording stream). Keyed by `CGDirectDisplayID`.
    @Published private(set) var previewImages: [CGDirectDisplayID: CGImage] = [:]

    /// True while any display is recording.
    var isRecording: Bool { !recordingDisplayIDs.isEmpty }
    /// Most-recently finalized recording — back-compat for single-file callers.
    var lastOutputURL: URL? { lastOutputURLs.last }
    /// The primary preview image (meter-source display) — back-compat for single-preview callers.
    var previewImage: CGImage? {
        if let id = meterSourceDisplayID, let image = previewImages[id] { return image }
        return previewImages.first?.value
    }
    @Published private(set) var audioLevels: UniversalAudioMeterService.AudioLevels = .silence
    @Published private(set) var microphoneLevels: UniversalAudioMeterService.AudioLevels = .silence
    @Published private(set) var microphoneCaptureStatus: MicrophoneCaptureStatus = .disabled
    @Published private(set) var autoStopDate: Date?

    enum MicrophoneCaptureStatus {
        case disabled
        case authorized
        case denied
    }

    private let microphonePermissionRequest = CaptureMicrophonePermissionRequest()
    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ScreenCapture")

    /// One selected display's live stream — either previewing or recording. Mutated only on the
    /// main actor (the whole manager is `@MainActor`).
    private final class DisplayTile {
        let displayID: CGDirectDisplayID
        let delivery = CaptureSampleDelivery()
        var stream: SCStream?
        var output: CaptureStreamOutput?
        var writer: AnyCaptureOutputWriter?   // non-nil only while recording
        var recordingURL: URL?
        enum Mode { case preview, recording }
        var mode: Mode
        init(displayID: CGDirectDisplayID, mode: Mode) {
            self.displayID = displayID
            self.mode = mode
        }
    }
    private var tiles: [CGDirectDisplayID: DisplayTile] = [:]
    private var stoppingDisplayIDs: Set<CGDirectDisplayID> = []
    private let recordingOperations = CaptureRecordingOperations()
    /// Ordered selection; the first entry is the primary display.
    private var selectedDisplayIDs: [CGDirectDisplayID] = []
    /// Which active tile feeds the audio/mic meters (system audio is global, so only one does).
    private var meterSourceDisplayID: CGDirectDisplayID?
    /// Last-known settings, retained so a tile can rebuild its preview after recording stops and so
    /// newly added displays start previewing with the right options.
    private var currentSettings = CaptureSettings()
    private var currentMaxPreviewWidth: CGFloat = 1280

    private var timerTask: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    private var outputAccess: SecurityAccess = .none
    private var recordingStartDate: Date?
    private override init() {
        super.init()
        refreshMicrophoneAuthorizationStatus()
    }

    // MARK: - Multi-display selection & lifecycle
    //
    // Each selected display owns a `DisplayTile` that is either previewing or recording. The view
    // drives selection via `setSelectedDisplays`, then starts/stops recording per display. Recording
    // is fully independent: one screen can record while another previews or is removed.

    /// Reconcile the live preview tiles to match `ids`. New displays start previewing; deselected
    /// displays are torn down (a recording one is finalized first). Recording tiles for still-selected
    /// displays are left running.
    func setSelectedDisplays(_ ids: [CGDirectDisplayID], settings: CaptureSettings, maxPreviewWidth: CGFloat = 1280) async {
        currentSettings = settings
        currentMaxPreviewWidth = maxPreviewWidth

        let content: SCShareableContent
        do { content = try await ScreenCaptureManager.shareableContent() }
        catch { errorMessage = error.localizedDescription; return }

        var targetIDs = ids
        if targetIDs.isEmpty, let main = selectDisplay(from: content, preferredDisplayID: nil) {
            targetIDs = [main.displayID]
        }
        selectedDisplayIDs = targetIDs
        let targetSet = Set(targetIDs)
        recordingOperations.retireStarts(outside: targetSet)
        updateRecordingSessionOwnership()

        // Tear down tiles no longer selected.
        for (id, tile) in tiles where !targetSet.contains(id) {
            tiles[id] = nil
            previewImages[id] = nil
            recordingDisplayIDs.remove(id)
            await teardownTile(tile)
        }

        guard let microphoneEnabled = await resolveMicrophoneCapture(requested: settings.includeMicrophone) else {
            recomputeMeterSource()
            updatePreviewingFlag()
            return
        }

        // Start preview tiles for newly added displays.
        for display in resolvedDisplays(targetIDs, from: content) where tiles[display.displayID] == nil && !stoppingDisplayIDs.contains(display.displayID) && !recordingOperations.hasStart(displayID: display.displayID) {
            do {
                tiles[display.displayID] = try await buildTile(
                    for: display, content: content, mode: .preview, settings: settings,
                    preset: nil, outputDirectory: nil, dynamicRange: .sdr,
                    microphoneEnabled: microphoneEnabled, maxPreviewWidth: maxPreviewWidth
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        recomputeMeterSource()
        updatePreviewingFlag()
    }

    /// Start recording a single display (transitioning it from preview to recording). Other displays
    /// are unaffected. Safe to call repeatedly to add screens to an in-progress recording.
    func startRecording(displayID: CGDirectDisplayID, preset: CapturePreset, outputDirectory: URL, dynamicRange: CaptureDynamicRangeOption) async {
        guard !isProcessing, !stoppingDisplayIDs.contains(displayID), !recordingDisplayIDs.contains(displayID),
              let operation = recordingOperations.beginStart(displayID: displayID) else { return }
        defer {
            recordingOperations.finishStart(operation)
            updateRecordingSessionOwnership()
        }
        errorMessage = nil

        let content: SCShareableContent
        do { content = try await ScreenCaptureManager.shareableContent() }
        catch {
            if recordingOperations.isCurrent(operation), !Task.isCancelled { errorMessage = error.localizedDescription }
            return
        }
        guard recordingOperations.isCurrent(operation), !Task.isCancelled else { return }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            errorMessage = CaptureError.unavailableDisplay.errorDescription
            return
        }

        guard let microphoneEnabled = await resolveMicrophoneCapture(requested: currentSettings.includeMicrophone),
              recordingOperations.isCurrent(operation), !Task.isCancelled else { return }

        // Acquire output-folder access once for the whole session.
        if case .none = outputAccess {
            let access = startAccessing(outputDirectory: outputDirectory)
            if case .none = access { errorMessage = CaptureError.accessDenied.errorDescription; return }
            outputAccess = access
        }

        // Replace any existing preview tile for this display.
        if let existing = tiles[displayID] {
            tiles[displayID] = nil
            previewImages[displayID] = nil
            await teardownTile(existing)
        }
        guard recordingOperations.isCurrent(operation), !Task.isCancelled else { return }

        do {
            let tile = try await buildTile(
                for: display, content: content, mode: .recording, settings: currentSettings,
                preset: preset, outputDirectory: outputDirectory, dynamicRange: dynamicRange,
                microphoneEnabled: microphoneEnabled, maxPreviewWidth: currentMaxPreviewWidth,
                recordingOperation: operation
            )
            guard recordingOperations.isCurrent(operation), !Task.isCancelled else {
                await teardownTile(tile)
                return
            }
            tiles[displayID] = tile
            if !selectedDisplayIDs.contains(displayID) { selectedDisplayIDs.append(displayID) }
            let wasRecording = !recordingDisplayIDs.isEmpty
            recordingDisplayIDs.insert(displayID)
            if !wasRecording {
                recordingStartDate = Date()
                startTimer()
            }
            logger.info("Recording display=\(displayID, privacy: .public) -> \(tile.recordingURL?.path ?? "?", privacy: .public)")
            recomputeMeterSource()
            updatePreviewingFlag()
        } catch {
            guard recordingOperations.isCurrent(operation), !Task.isCancelled else { return }
            logger.error("Capture start failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            await restorePreviewTile(displayID: displayID)
        }
    }

    /// Start recording every selected display that isn't already recording.
    func startAllRecording(preset: CapturePreset, outputDirectory: URL, dynamicRange: CaptureDynamicRangeOption) async {
        let generation = recordingOperations.generation
        for id in selectedDisplayIDs where !recordingDisplayIDs.contains(id) {
            guard generation == recordingOperations.generation, !Task.isCancelled else { return }
            await startRecording(displayID: id, preset: preset, outputDirectory: outputDirectory, dynamicRange: dynamicRange)
        }
    }

    /// Remove a display from the session entirely (stops/ finalizes it if recording, drops its tile).
    func removeDisplay(_ displayID: CGDirectDisplayID) async {
        let operation = recordingOperations.beginStop()
        defer {
            recordingOperations.finishStop(operation)
            updateRecordingSessionOwnership()
        }
        selectedDisplayIDs.removeAll { $0 == displayID }
        recordingDisplayIDs.remove(displayID)
        let tile = tiles.removeValue(forKey: displayID)
        previewImages[displayID] = nil
        updateRecordingSessionOwnership()
        if let tile { await teardownTile(tile) }
        recomputeMeterSource()
        updatePreviewingFlag()
    }

    // MARK: - Compatibility wrappers (single-display callers)

    /// Single-display recording entry point used by `CaptureModeView` and the scheduled-recording
    /// path. Selects one display and records it.
    func startRecording(
        preset: CapturePreset,
        outputDirectory: URL,
        displayID: CGDirectDisplayID?,
        frameRate: CaptureFrameRateOption,
        dynamicRange: CaptureDynamicRangeOption,
        includeSystemAudio: Bool = true,
        includeMicrophone: Bool,
        microphoneDeviceID: String?,
        hideCursor: Bool,
        excludeCurrentApp: Bool,
        excludedAppBundleIDs: Set<String> = [],
        regionRect: CGRect? = nil
    ) async {
        let generation = recordingOperations.generation
        var settings = CaptureSettings()
        settings.frameRate = frameRate
        settings.includeSystemAudio = includeSystemAudio
        settings.includeMicrophone = includeMicrophone
        settings.microphoneDeviceID = microphoneDeviceID?.isEmpty == false ? microphoneDeviceID : nil
        settings.hideCursor = hideCursor
        settings.excludeCurrentApp = excludeCurrentApp
        settings.excludedAppBundleIDs = excludedAppBundleIDs
        settings.regionRect = regionRect
        currentSettings = settings

        let content: SCShareableContent
        do { content = try await ScreenCaptureManager.shareableContent() }
        catch {
            if generation == recordingOperations.generation, !Task.isCancelled { errorMessage = error.localizedDescription }
            return
        }
        guard generation == recordingOperations.generation, !Task.isCancelled else { return }
        guard let display = selectDisplay(from: content, preferredDisplayID: displayID) else {
            errorMessage = CaptureError.unavailableDisplay.errorDescription; return
        }
        selectedDisplayIDs = [display.displayID]
        await startRecording(displayID: display.displayID, preset: preset, outputDirectory: outputDirectory, dynamicRange: dynamicRange)
    }

    // MARK: - Tile construction & teardown

    private func resolvedDisplays(_ ids: [CGDirectDisplayID], from content: SCShareableContent) -> [SCDisplay] {
        var result: [SCDisplay] = []
        var seen = Set<CGDirectDisplayID>()
        for id in ids where !seen.contains(id) {
            if let display = content.displays.first(where: { $0.displayID == id }) {
                result.append(display)
                seen.insert(id)
            }
        }
        return result
    }

    /// Builds and starts one display's stream (preview or recording). Reuses the same config/filter/
    /// writer helpers as before, parameterized by mode. The per-stream sample handler routes the
    /// preview frame to `previewImages[displayID]` and (only for the meter-source display) updates the
    /// audio/mic meters.
    private func buildTile(
        for display: SCDisplay,
        content: SCShareableContent,
        mode: DisplayTile.Mode,
        settings: CaptureSettings,
        preset: CapturePreset?,
        outputDirectory: URL?,
        dynamicRange: CaptureDynamicRangeOption,
        microphoneEnabled: Bool,
        maxPreviewWidth: CGFloat,
        recordingOperation: CaptureRecordingOperations.Start? = nil
    ) async throws -> DisplayTile {
        let displayID = display.displayID
        let tile = DisplayTile(displayID: displayID, mode: mode)
        let delivery = tile.delivery
        if let recordingOperation { recordingOperations.registerDelivery(delivery, for: recordingOperation) }
        let regionRect = settings.regionRect   // only set for single-display selections

        let pixelResolution: CGSize
        let sourceRect: CGRect
        if let regionRect {
            sourceRect = regionRect
            pixelResolution = regionPixelResolution(for: display, region: regionRect)
        } else {
            pixelResolution = displayPixelResolution(for: display)
            sourceRect = displaySourceRect(for: display)
        }

        let config: SCStreamConfiguration
        var writer: AnyCaptureOutputWriter?
        var recordingURL: URL?

        switch mode {
        case .recording:
            guard let preset, let outputDirectory else { throw CaptureError.writerFailed("Missing preset or output directory") }
            let resolution = pixelResolution
            let destinationRect = CGRect(origin: .zero, size: resolution)
            let frameRate = resolvedFrameRate(option: settings.frameRate, display: display, fallback: preset.targetFrameRate)
            let effectiveDynamicRange = normalizedDynamicRange(dynamicRange)
            let url = try prepareOutputURL(for: preset, directory: outputDirectory, display: display)
            let pixelFormat = pixelFormat(for: preset, dynamicRange: effectiveDynamicRange)
            config = makeStreamConfiguration(
                resolution: resolution, frameRate: frameRate, pixelFormat: pixelFormat,
                sourceRect: sourceRect, destinationRect: destinationRect, dynamicRange: effectiveDynamicRange
            )
            config.showsCursor = !settings.hideCursor
            if microphoneEnabled, #available(macOS 15, *) {
                config.captureMicrophone = true
                if let mic = settings.microphoneDeviceID { config.microphoneCaptureDeviceID = mic }
            }
            let hevcProfileOverride = resolveHEVCProfileOverride(
                preset: preset, width: Int(resolution.width), height: Int(resolution.height), pixelFormat: config.pixelFormat
            )
            let w: AnyCaptureOutputWriter = try ScreenCaptureWriter(
                outputURL: url, fileType: preset.fileType,
                videoSettings: preset.videoSettings(width: Int(resolution.width), height: Int(resolution.height), frameRate: frameRate, hevcProfileOverride: hevcProfileOverride),
                audioSettings: preset.audioSettings, dynamicRange: effectiveDynamicRange,
                includeMicrophone: microphoneEnabled, isGrowing: preset.isGrowing, frameRate: frameRate
            )
            w.setErrorHandler { [weak self] error in
                Task { @MainActor in
                    guard delivery.isActive else { return }
                    self?.errorMessage = error.localizedDescription
                }
            }
            writer = w
            recordingURL = url
        case .preview:
            let previewResolution = scaledPreviewResolution(from: pixelResolution, maxWidth: max(1, maxPreviewWidth))
            let destinationRect = CGRect(origin: .zero, size: previewResolution)
            let requestedPreviewRate = resolvedFrameRate(option: settings.frameRate, display: display, fallback: 30)
            let previewFrameRate = requestedPreviewRate.framesPerSecond > 60 ? CaptureFrameRate(60) : requestedPreviewRate
            config = makeStreamConfiguration(
                resolution: previewResolution, frameRate: previewFrameRate, pixelFormat: kCVPixelFormatType_32BGRA,
                sourceRect: sourceRect, destinationRect: destinationRect, dynamicRange: .sdr
            )
            config.showsCursor = !settings.hideCursor
            if microphoneEnabled, #available(macOS 15, *) {
                config.captureMicrophone = true
                if let mic = settings.microphoneDeviceID { config.microphoneCaptureDeviceID = mic }
            }
        }

        let filter = contentFilter(for: display, content: content, excludeCurrentApp: settings.excludeCurrentApp, excludedAppBundleIDs: settings.excludedAppBundleIDs)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)

        let outputQueue = DispatchQueue(label: "com.aagedal.capture.\(displayID)")
        let previewContext = CIContext()
        var lastPreviewSeconds: Double = 0
        var lastAudioSeconds: Double = 0
        var lastMicrophoneSeconds: Double = 0
        let isRecordingMode = (mode == .recording)
        let skipSystemAudio = !settings.includeSystemAudio
        let output = CaptureStreamOutput(queue: outputQueue) { [weak self, weak writer] sampleBuffer, type in
            guard delivery.isActive else { return }
            // Write to the file only while recording; skip muted system audio.
            if isRecordingMode, !(type == .audio && skipSystemAudio) {
                delivery.ifActive { writer?.append(sampleBuffer: sampleBuffer, type: type) }
            }

            if #available(macOS 15, *), type == .microphone {
                if let levels = ScreenCaptureManager.audioLevels(from: sampleBuffer, lastTimestamp: &lastMicrophoneSeconds) {
                    Task { @MainActor [weak self] in
                        guard delivery.isActive, let self, self.meterSourceDisplayID == displayID else { return }
                        self.microphoneLevels = levels
                    }
                }
                return
            }

            switch type {
            case .screen:
                if let image = ScreenCaptureManager.previewImage(from: sampleBuffer, context: previewContext, lastTimestamp: &lastPreviewSeconds) {
                    Task { @MainActor [weak self] in
                        guard delivery.isActive else { return }
                        self?.previewImages[displayID] = image
                    }
                }
            case .audio:
                if let levels = ScreenCaptureManager.audioLevels(from: sampleBuffer, lastTimestamp: &lastAudioSeconds) {
                    Task { @MainActor [weak self] in
                        guard delivery.isActive, let self, self.meterSourceDisplayID == displayID else { return }
                        self.audioLevels = levels
                    }
                }
            default:
                break
            }
        }

        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: outputQueue)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: outputQueue)
        if microphoneEnabled, #available(macOS 15, *) {
            try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: outputQueue)
        }
        try await stream.startCapture()

        tile.stream = stream
        tile.output = output
        tile.writer = writer
        tile.recordingURL = recordingURL
        return tile
    }

    /// Retires sample delivery and bounds the framework stop callback.
    private func stopStream(for tile: DisplayTile) async {
        // Retire delivery before suspending: callbacks already queued on the main
        // actor must not overwrite a replacement tile or its meter readings.
        tile.delivery.invalidate()
        guard let stream = tile.stream else { return }
        let operation = CaptureStreamStopOperation(stream: stream, output: tile.output)
        tile.stream = nil
        tile.output = nil
        do {
            try await CaptureStreamShutdown.stop { try await operation.stop() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Stops a tile and finalizes its recording, clearing the growing-file marker.
    private func teardownTile(_ tile: DisplayTile) async {
        let operation = tile.mode == .recording ? recordingOperations.beginStop() : nil
        defer {
            if let operation { recordingOperations.finishStop(operation) }
            updateRecordingSessionOwnership()
        }
        updateRecordingSessionOwnership()
        microphonePermissionRequest.cancel()
        await stopStream(for: tile)
        if tile.mode == .recording, let writer = tile.writer {
            do { try await writer.finish() } catch { errorMessage = error.localizedDescription }
            if let url = tile.recordingURL { lastOutputURLs.append(url) }
        }
        tile.stream = nil
        tile.output = nil
        tile.writer = nil
    }

    /// Rebuilds a live preview tile for a display (e.g. after its recording stops) if it's still
    /// selected.
    private func restorePreviewTile(displayID: CGDirectDisplayID) async {
        guard tiles[displayID] == nil, selectedDisplayIDs.contains(displayID) else { return }
        let content: SCShareableContent
        do { content = try await ScreenCaptureManager.shareableContent() } catch { return }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            previewImages[displayID] = nil
            return
        }
        guard let microphoneEnabled = await resolveMicrophoneCapture(requested: currentSettings.includeMicrophone) else { return }
        do {
            tiles[displayID] = try await buildTile(
                for: display, content: content, mode: .preview, settings: currentSettings,
                preset: nil, outputDirectory: nil, dynamicRange: .sdr,
                microphoneEnabled: microphoneEnabled, maxPreviewWidth: currentMaxPreviewWidth
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        recomputeMeterSource()
        updatePreviewingFlag()
    }

    private func recomputeMeterSource() {
        let candidate: CGDirectDisplayID?
        if let lowestRecording = recordingDisplayIDs.min() {
            candidate = lowestRecording
        } else if let firstSelected = selectedDisplayIDs.first(where: { tiles[$0] != nil }) {
            candidate = firstSelected
        } else {
            candidate = tiles.keys.min()
        }
        if candidate != meterSourceDisplayID {
            meterSourceDisplayID = candidate
            audioLevels = .silence
            microphoneLevels = .silence
        }
    }

    private func updatePreviewingFlag() {
        isPreviewing = tiles.values.contains { $0.mode == .preview }
    }

    private func updateRecordingSessionOwnership() {
        let processing = recordingDisplayIDs.isEmpty && recordingOperations.hasPendingCleanup
        // Observers treat a false publication as completed recording cleanup.
        if isProcessing != processing { isProcessing = processing }
        guard recordingDisplayIDs.isEmpty, !recordingOperations.hasPendingOperations else { return }
        stopTimersAndReleaseAccess()
    }

    private func stopTimersAndReleaseAccess() {
        timerTask?.cancel()
        timerTask = nil
        elapsedTime = 0
        recordingStartDate = nil
        autoStopTask?.cancel()
        autoStopTask = nil
        autoStopDate = nil
        releaseAccess()
    }

    /// Stops one display's recording. If other displays are still recording, the session continues
    /// and this display drops back to a live preview tile. If it was the last one, the session ends
    /// (which the overlay observes via `isProcessing` to show the post-recording summary).
    func stopRecording(displayID: CGDirectDisplayID) async {
        let operation = recordingOperations.beginStop()
        defer {
            recordingOperations.finishStop(operation)
            updateRecordingSessionOwnership()
        }
        microphonePermissionRequest.cancel()
        guard recordingDisplayIDs.contains(displayID), let tile = tiles[displayID] else { return }
        stoppingDisplayIDs.insert(displayID)
        defer { stoppingDisplayIDs.remove(displayID) }
        let isLast = recordingDisplayIDs.count == 1
        recordingDisplayIDs.remove(displayID)
        updateRecordingSessionOwnership()

        tiles[displayID] = nil
        await stopStream(for: tile)
        let writer = tile.writer
        let url = tile.recordingURL
        tile.stream = nil
        tile.output = nil
        tile.writer = nil
        if let writer {
            do { try await writer.finish() } catch { errorMessage = error.localizedDescription }
        }
        if let url { lastOutputURLs.append(url) }

        if isLast {
            previewImages[displayID] = nil
        } else if selectedDisplayIDs.contains(displayID) {
            await restorePreviewTile(displayID: displayID)
        } else {
            previewImages[displayID] = nil
        }
        recomputeMeterSource()
        updatePreviewingFlag()
    }

    /// Stops every display that is recording (the global Stop / auto-stop path). Finalizes all files,
    /// then ends the session.
    func stopAllRecording() async {
        let operation = recordingOperations.beginStop()
        defer {
            recordingOperations.finishStop(operation)
            updateRecordingSessionOwnership()
        }
        microphonePermissionRequest.cancel()
        let ids = Array(recordingDisplayIDs)
        guard !ids.isEmpty else { return }
        logger.info("Stopping all screen capture (\(ids.count, privacy: .public) display(s))")

        // Detach the exact tiles owned by this stop before any suspension.
        let stoppedTiles = ids.compactMap { tiles.removeValue(forKey: $0) }
        recordingDisplayIDs.subtract(ids)
        updateRecordingSessionOwnership()
        stoppingDisplayIDs.formUnion(ids)
        defer { stoppingDisplayIDs.subtract(ids) }
        for tile in stoppedTiles { tile.delivery.invalidate() }
        for tile in stoppedTiles { await stopStream(for: tile) }
        for tile in stoppedTiles {
            let id = tile.displayID
            let writer = tile.writer
            let url = tile.recordingURL
            tile.stream = nil
            tile.output = nil
            tile.writer = nil
            if let writer {
                do { try await writer.finish() } catch { errorMessage = error.localizedDescription }
            }
            if let url { lastOutputURLs.append(url) }
            previewImages[id] = nil
        }

        recomputeMeterSource()
        updatePreviewingFlag()
    }

    /// Back-compat no-argument stop — stops every recording display.
    func stopRecording() async {
        await stopAllRecording()
    }

    func setAutoStop(after duration: TimeInterval) {
        autoStopTask?.cancel()
        guard duration > 0 else {
            autoStopDate = nil
            autoStopTask = nil
            return
        }
        autoStopDate = Date().addingTimeInterval(duration)
        autoStopTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, self.isRecording else { return }
            await self.stopRecording()
        }
    }

    func cancelAutoStop() {
        autoStopTask?.cancel()
        autoStopTask = nil
        autoStopDate = nil
    }

    /// Extends the current auto-stop by `delta` seconds. If no auto-stop is active, this starts a
    /// fresh one `delta` seconds from now (`base` is 0 when `autoStopDate` is nil).
    func extendAutoStop(by delta: TimeInterval) {
        // Only meaningful while recording; otherwise we'd set a phantom autoStopDate that the
        // status UI would surface for a recording that isn't running.
        guard isRecording else { return }
        let base = max(0, autoStopDate?.timeIntervalSinceNow ?? 0)
        setAutoStop(after: base + delta)
    }

    /// Single-display preview entry point (used by `CaptureModeView`). Reconciles the selection to the
    /// one display, which starts its live preview tile. `cachedContent` is accepted for source
    /// compatibility but no longer used (selection re-fetches shareable content).
    func startPreview(
        displayID: CGDirectDisplayID?,
        frameRate: CaptureFrameRateOption,
        includeMicrophone: Bool,
        microphoneDeviceID: String?,
        hideCursor: Bool,
        excludeCurrentApp: Bool,
        excludedAppBundleIDs: Set<String> = [],
        cachedContent: SCShareableContent? = nil,
        regionRect: CGRect? = nil,
        maxPreviewWidth: CGFloat = 1280
    ) async {
        guard !isRecording else { return }
        var settings = CaptureSettings()
        settings.frameRate = frameRate
        settings.includeMicrophone = includeMicrophone
        settings.microphoneDeviceID = microphoneDeviceID?.isEmpty == false ? microphoneDeviceID : nil
        settings.hideCursor = hideCursor
        settings.excludeCurrentApp = excludeCurrentApp
        settings.excludedAppBundleIDs = excludedAppBundleIDs
        settings.regionRect = regionRect
        let ids = displayID.map { [$0] } ?? []
        await setSelectedDisplays(ids, settings: settings, maxPreviewWidth: maxPreviewWidth)
    }

    /// Tears down all *preview* tiles (recording tiles keep running). Used on view disappear.
    func stopPreview() async {
        microphonePermissionRequest.cancel()
        for (id, tile) in tiles where tile.mode == .preview {
            tiles[id] = nil
            previewImages[id] = nil
            await stopStream(for: tile)
        }
        selectedDisplayIDs.removeAll { tiles[$0] == nil }
        recomputeMeterSource()
        updatePreviewingFlag()
        if !isRecording {
            microphoneLevels = .silence
            audioLevels = .silence
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        let start = recordingStartDate ?? Date()
        timerTask = Task { @MainActor in
            while !Task.isCancelled {
                elapsedTime = Date().timeIntervalSince(start)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func releaseAccess() {
        switch outputAccess {
        case .direct(let url):
            url.stopAccessingSecurityScopedResource()
        case .bookmark(let url):
            SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: url)
        case .none:
            break
        }
        outputAccess = .none
    }

    private func selectDisplay(from content: SCShareableContent, preferredDisplayID: CGDirectDisplayID?) -> SCDisplay? {
        if let preferredDisplayID {
            if let preferred = content.displays.first(where: { $0.displayID == preferredDisplayID }) {
                return preferred
            }
        }

        if let mainDisplayID = ScreenCaptureManager.mainDisplayID() {
            return content.displays.first(where: { $0.displayID == mainDisplayID }) ?? content.displays.first
        }
        return content.displays.first
    }

    private func makeStreamConfiguration(
        resolution: CGSize,
        frameRate: CaptureFrameRate,
        pixelFormat: OSType?,
        sourceRect: CGRect,
        destinationRect: CGRect,
        dynamicRange: CaptureDynamicRangeOption
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        if dynamicRange != .sdr, #available(macOS 15, *) {
            switch dynamicRange {
            case .hdrP3CanonicalDisplay:
                config.captureDynamicRange = .hdrCanonicalDisplay
                config.colorSpaceName = CGColorSpace.displayP3_PQ
                config.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
            case .sdr:
                break
            }
        }
        config.width = Int(resolution.width)
        config.height = Int(resolution.height)
        config.minimumFrameInterval = frameRate.frameDuration
        if let pixelFormat {
            config.pixelFormat = pixelFormat
        }
        config.scalesToFit = true
        config.sourceRect = sourceRect
        config.destinationRect = destinationRect
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = false
        return config
    }

    private func pixelFormat(for preset: CapturePreset, dynamicRange: CaptureDynamicRangeOption) -> OSType? {
        switch dynamicRange {
        case .hdrP3CanonicalDisplay:
            return kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
        case .sdr:
            break
        }
        if preset == .hevc42210Bit || preset == .hevcGrowing {
            return kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
        }
        return kCVPixelFormatType_32BGRA
    }

    private func frameRate(for display: SCDisplay, fallback: Int) -> Int {
        if let screenNumber = NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
           screenNumber == display.displayID,
           let maxFPS = NSScreen.main?.maximumFramesPerSecond,
           maxFPS > 0 {
            return maxFPS
        }

        if let matchingScreen = NSScreen.screens.first(where: {
            guard let screenID = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return false
            }
            return screenID == display.displayID
        }) {
            return max(1, matchingScreen.maximumFramesPerSecond)
        }

        return max(1, fallback)
    }

    private func resolvedFrameRate(
        option: CaptureFrameRateOption,
        display: SCDisplay,
        fallback: Int
    ) -> CaptureFrameRate {
        if let fixed = option.fixedValue {
            return fixed
        }
        return CaptureFrameRate(Int32(frameRate(for: display, fallback: fallback)))
    }

    private func normalizedDynamicRange(_ option: CaptureDynamicRangeOption) -> CaptureDynamicRangeOption {
        if option != .sdr, !isHDRRecordingSupported {
            return .sdr
        }
        return option
    }

    private var isHDRRecordingSupported: Bool {
        if #available(macOS 26, *) {
            return true
        }
        return false
    }

    @MainActor
    func refreshMicrophoneAuthorizationStatus() {
        microphonePermissionRequest.cancel()
        guard #available(macOS 15, *) else {
            microphoneCaptureStatus = .disabled
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneCaptureStatus = .authorized
        case .denied, .restricted:
            microphoneCaptureStatus = .denied
        default:
            microphoneCaptureStatus = .disabled
        }
    }

    @MainActor
    func requestMicrophonePermission() async {
        _ = await resolveMicrophoneCapture(requested: true)
    }

    /// Nil aborts setup; false is a resolved decision to capture without a microphone.
    private func resolveMicrophoneCapture(requested: Bool) async -> Bool? {
        guard !Task.isCancelled else { return nil }
        microphonePermissionRequest.cancel()
        guard requested else {
            microphoneCaptureStatus = .disabled
            return false
        }
        guard #available(macOS 15, *) else {
            microphoneCaptureStatus = .disabled
            return false
        }

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            microphoneCaptureStatus = .authorized
            return true
        case .notDetermined:
            microphoneCaptureStatus = .disabled
            do {
                let granted = try await microphonePermissionRequest.request { completion in
                    AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
                }
                microphoneCaptureStatus = granted ? .authorized : .denied
                return granted
            } catch NonJoiningTaskDeadlineError.timedOut {
                errorMessage = String(localized: "Timed out waiting for microphone permission. Check microphone access in System Settings and try again.")
                return nil
            } catch {
                // A cancelled or superseded prompt must not resume capture setup.
                return nil
            }
        case .denied, .restricted:
            microphoneCaptureStatus = .denied
            return false
        @unknown default:
            microphoneCaptureStatus = .denied
            return false
        }
    }

    private func displayPixelResolution(for display: SCDisplay) -> CGSize {
        let displayID = display.displayID
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            let pixelWidth = mode.pixelWidth
            let pixelHeight = mode.pixelHeight
            if pixelWidth > 0 && pixelHeight > 0 {
                return CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
            }
        }
        let pixelWidth = CGDisplayPixelsWide(displayID)
        let pixelHeight = CGDisplayPixelsHigh(displayID)
        if pixelWidth > 0 && pixelHeight > 0 {
            return CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        }
        return CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
    }

    private func displaySourceRect(for display: SCDisplay) -> CGRect {
        if let screen = ScreenCaptureManager.screen(for: display.displayID) {
            return CGRect(origin: .zero, size: screen.frame.size)
        }
        return CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
    }

    private func scaledPreviewResolution(from pixelResolution: CGSize, maxWidth: CGFloat) -> CGSize {
        guard pixelResolution.width > 0, pixelResolution.height > 0 else {
            return pixelResolution
        }
        let scale = min(1.0, maxWidth / pixelResolution.width)
        let width = (pixelResolution.width * scale).rounded()
        let height = (pixelResolution.height * scale).rounded()
        return CGSize(width: width, height: height)
    }

    private func regionPixelResolution(for display: SCDisplay, region: CGRect) -> CGSize {
        let fullPointSize = displaySourceRect(for: display).size
        let fullPixelSize = displayPixelResolution(for: display)
        let scaleX = fullPixelSize.width / fullPointSize.width
        let scaleY = fullPixelSize.height / fullPointSize.height
        let w = Int(region.width * scaleX)
        let h = Int(region.height * scaleY)
        return CGSize(width: CGFloat((w / 2) * 2), height: CGFloat((h / 2) * 2))
    }

    private func startAccessing(outputDirectory: URL) -> SecurityAccess {
        if outputDirectory.startAccessingSecurityScopedResource() {
            return .direct(outputDirectory)
        }
        if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: outputDirectory) {
            return .bookmark(outputDirectory)
        }
        return .none
    }

    /// Mints a unique output URL for one display, tagging the file name with the display's name so
    /// simultaneous per-screen recordings don't collide: `ScreenCapture_<timestamp>_<DisplayName>.mov`.
    private func prepareOutputURL(for preset: CapturePreset, directory: URL, display: SCDisplay) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = formatter.string(from: Date())

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let rawName = ScreenCaptureManager.displayName(for: display.displayID) ?? "Display \(display.displayID)"
        let safeName = sanitizeFileComponent(rawName)
        let baseName = "ScreenCapture_\(timestamp)_\(safeName)"

        var outputURL = directory.appendingPathComponent("\(baseName).\(preset.fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: outputURL.path) {
            outputURL = directory.appendingPathComponent("\(baseName)_\(counter).\(preset.fileExtension)")
            counter += 1
        }
        return outputURL
    }

    /// Strips filesystem-unsafe characters from a display name so it can be used in a file name.
    private func sanitizeFileComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = value.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Display" : trimmed
    }

    private func resolveHEVCProfileOverride(
        preset: CapturePreset,
        width: Int,
        height: Int,
        pixelFormat: OSType
    ) -> String? {
        guard preset == .hevc42210Bit || preset == .hevcGrowing else { return nil }
        guard isTenBitPixelFormat(pixelFormat) else {
            logger.warning("HEVC capture input is 8-bit; letting the encoder select a compatible profile.")
            return nil
        }
        if supportsHEVCMain42210(width: width, height: height, pixelFormat: pixelFormat) {
            return kVTProfileLevel_HEVC_Main42210_AutoLevel as String
        }
        if supportsHEVCMain10(width: width, height: height, pixelFormat: pixelFormat) {
            logger.warning("HEVC Main42210 not supported; falling back to Main10.")
            return kVTProfileLevel_HEVC_Main10_AutoLevel as String
        }
        logger.warning("HEVC Main10 not supported for capture input; letting the encoder select a compatible profile.")
        return nil
    }

    private func supportsHEVCMain42210(width: Int, height: Int, pixelFormat: OSType) -> Bool {
        var session: VTCompressionSession?
        let encoderSpec: [String: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
        ]
        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: bufferAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            return false
        }

        defer {
            VTCompressionSessionInvalidate(session)
        }

        let profileStatus = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_HEVC_Main42210_AutoLevel
        )
        return profileStatus == noErr
    }

    private func supportsHEVCMain10(width: Int, height: Int, pixelFormat: OSType) -> Bool {
        var session: VTCompressionSession?
        let encoderSpec: [String: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
        ]
        let bufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: bufferAttributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else {
            return false
        }

        defer {
            VTCompressionSessionInvalidate(session)
        }

        let profileStatus = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_HEVC_Main10_AutoLevel
        )
        return profileStatus == noErr
    }

    private func isTenBitPixelFormat(_ pixelFormat: OSType) -> Bool {
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_ARGB2101010LEPacked:
            return true
        default:
            return false
        }
    }

    private enum SecurityAccess {
        case none
        case direct(URL)
        case bookmark(URL)
    }

    static func shareableContent() async throws -> SCShareableContent {
        try await ScreenCaptureContentDiscovery.current()
    }

    private func contentFilter(
        for display: SCDisplay,
        content: SCShareableContent,
        excludeCurrentApp: Bool,
        excludedAppBundleIDs: Set<String> = []
    ) -> SCContentFilter {
        var excludedApps: [SCRunningApplication] = []

        if excludeCurrentApp,
           let bundleID = Bundle.main.bundleIdentifier,
           let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) {
            excludedApps.append(app)
        }

        for bundleID in excludedAppBundleIDs {
            if let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) {
                excludedApps.append(app)
            }
        }

        return SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
    }

    nonisolated private static func previewImage(
        from sampleBuffer: CMSampleBuffer,
        context: CIContext,
        lastTimestamp: inout Double
    ) -> CGImage? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = CMTimeGetSeconds(presentationTime)
        if seconds.isFinite, seconds - lastTimestamp < 0.05 {
            return nil
        }
        if seconds.isFinite {
            lastTimestamp = seconds
        }

        let image = CIImage(cvPixelBuffer: imageBuffer)
        return context.createCGImage(image, from: image.extent)
    }

    nonisolated private static func audioLevels(
        from sampleBuffer: CMSampleBuffer,
        lastTimestamp: inout Double
    ) -> UniversalAudioMeterService.AudioLevels? {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = CMTimeGetSeconds(presentationTime)
        if seconds.isFinite, seconds - lastTimestamp < 0.05 {
            return nil
        }
        if seconds.isFinite {
            lastTimestamp = seconds
        }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }

        let asbd = asbdPointer.pointee
        let channelCount = Int(asbd.mChannelsPerFrame)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard channelCount > 0, frameCount > 0 else { return nil }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInt = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let isBigEndian = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let bytesPerFrame = Int(asbd.mBytesPerFrame)
        let inferredBytesPerSample = max(1, (bitsPerChannel + 7) / 8)
        let bytesPerSample: Int
        if bytesPerFrame > 0 {
            bytesPerSample = max(1, isNonInterleaved ? bytesPerFrame : bytesPerFrame / max(1, channelCount))
        } else {
            bytesPerSample = inferredBytesPerSample
        }

        let bufferList = AudioBufferList.allocate(maximumBuffers: channelCount)
        defer { free(bufferList.unsafeMutablePointer) }
        var blockBuffer: CMBlockBuffer?

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: bufferList.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channelCount),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr else { return nil }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(bufferList.unsafeMutablePointer)
        let maxChannels = min(channelCount, 2)
        var peaks = [Float](repeating: 0, count: maxChannels)

        func sampleValue(from pointer: UnsafeRawPointer, index: Int) -> Float {
            let byteOffset = index * bytesPerSample
            if isFloat && (bitsPerChannel == 32 || (bitsPerChannel == 0 && bytesPerSample == 4)) {
                return pointer.advanced(by: byteOffset).bindMemory(to: Float.self, capacity: 1).pointee
            }
            if isFloat && (bitsPerChannel == 64 || (bitsPerChannel == 0 && bytesPerSample == 8)) {
                let value = pointer.advanced(by: byteOffset).bindMemory(to: Double.self, capacity: 1).pointee
                return Float(value)
            }
            if isSignedInt && (bitsPerChannel == 16 || bytesPerSample == 2) {
                let value = pointer.advanced(by: byteOffset).bindMemory(to: Int16.self, capacity: 1).pointee
                return Float(value) / Float(Int16.max)
            }
            if isSignedInt && (bitsPerChannel == 24 || bytesPerSample == 3 || bytesPerSample == 4) {
                let base = pointer.advanced(by: byteOffset)
                let b0 = Int32(base.load(as: UInt8.self))
                let b1 = Int32(base.load(fromByteOffset: 1, as: UInt8.self))
                let b2 = Int32(base.load(fromByteOffset: 2, as: UInt8.self))
                let raw: Int32
                if isBigEndian {
                    raw = (b0 << 16) | (b1 << 8) | b2
                } else {
                    raw = (b2 << 16) | (b1 << 8) | b0
                }
                var signed = raw
                if signed & 0x800000 != 0 {
                    signed |= ~0xFFFFFF
                }
                return Float(signed) / Float(1 << 23)
            }
            if isSignedInt && (bitsPerChannel == 32 || bytesPerSample == 4) {
                let value = pointer.advanced(by: byteOffset).bindMemory(to: Int32.self, capacity: 1).pointee
                return Float(value) / Float(Int32.max)
            }
            return 0
        }

        if isNonInterleaved {
            for channel in 0..<maxChannels {
                guard let data = audioBuffers[channel].mData else { continue }
                for frame in 0..<frameCount {
                    let value = sampleValue(from: data, index: frame)
                    peaks[channel] = max(peaks[channel], abs(value))
                }
            }
        } else if let data = audioBuffers.first?.mData {
            for frame in 0..<frameCount {
                for channel in 0..<maxChannels {
                    let index = frame * channelCount + channel
                    let value = sampleValue(from: data, index: index)
                    peaks[channel] = max(peaks[channel], abs(value))
                }
            }
        }

        func toDb(_ amplitude: Float) -> Float {
            guard amplitude > 0 else { return -60 }
            return max(-60, 20 * log10(amplitude))
        }

        let leftDb = toDb(peaks.first ?? 0)
        let rightDb = toDb(peaks.count > 1 ? peaks[1] : peaks.first ?? 0)
        let peakDb = max(leftDb, rightDb)
        return UniversalAudioMeterService.AudioLevels(
            leftChannel: leftDb,
            rightChannel: rightDb,
            peak: peakDb
        )
    }

    static func availableDisplays() async throws -> [CaptureDisplay] {
        let content = try await shareableContent()
        return displays(from: content)
    }

    static func displays(from content: SCShareableContent) -> [CaptureDisplay] {
        let mainDisplayID = mainDisplayID()
        return content.displays.map { display in
            let name = displayName(for: display.displayID)
            return CaptureDisplay(
                id: display.displayID,
                name: name ?? "Display \(display.displayID)",
                width: display.width,
                height: display.height,
                isMain: display.displayID == mainDisplayID
            )
        }
    }

    @available(macOS 15, *)
    static func availableMicrophones() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return discovery.devices
    }

    private static func mainDisplayID() -> CGDirectDisplayID? {
        guard let mainScreen = NSScreen.main,
              let screenNumber = mainScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return nil
        }
        return screenNumber
    }

    private static func displayName(for displayID: CGDirectDisplayID) -> String? {
        guard let screen = screen(for: displayID) else { return nil }
        return screen.localizedName
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        for screen in NSScreen.screens {
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                continue
            }
            if screenNumber == displayID {
                return screen
            }
        }
        return nil
    }
}

/// ScreenCaptureKit can leave discovery suspended while the capture service is
/// unavailable. Return promptly on cancellation or deadline without joining its
/// framework callback; the late snapshot has no side effects and is discarded.
enum ScreenCaptureContentDiscovery {
    static func current() async throws -> SCShareableContent {
        let snapshot = try await discover {
            ScreenCaptureContentSnapshot(content: try await SCShareableContent.current)
        }
        return snapshot.content
    }

    static func discover<Snapshot: Sendable>(
        timeout: Duration = .seconds(15),
        provider: @escaping @Sendable () async throws -> Snapshot
    ) async throws -> Snapshot {
        do {
            let snapshot = try await NonJoiningTaskDeadline.run(timeout: timeout) {
                try Task.checkCancellation()
                return try await provider()
            }
            try Task.checkCancellation()
            return snapshot
        } catch NonJoiningTaskDeadlineError.timedOut {
            throw ScreenCaptureContentDiscoveryError.timedOut
        }
    }
}

/// This immutable framework snapshot is only read after its producer returns.
/// ScreenCaptureKit does not declare the Objective-C snapshot Sendable.
private struct ScreenCaptureContentSnapshot: @unchecked Sendable {
    let content: SCShareableContent
}

enum ScreenCaptureContentDiscoveryError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        String(localized: "Timed out while discovering screens and windows. Try starting capture again.")
    }
}

/// Owns a permission wait independently of AVFoundation's system prompt. The prompt
/// cannot be dismissed programmatically; a late response must not revive a cancelled
/// or superseded request. A missing callback never holds the capture UI indefinitely.
@MainActor
final class CaptureMicrophonePermissionRequest {
    private var activeID: UUID?
    private var task: Task<Bool, Error>?

    func cancel() {
        activeID = nil
        task?.cancel()
        task = nil
    }

    func request(
        timeout: Duration = .seconds(60),
        start: @escaping @Sendable (@escaping @Sendable (Bool) -> Void) -> Void
    ) async throws -> Bool {
        cancel()
        let id = UUID()
        activeID = id
        let pending = Task {
            try await NonJoiningTaskDeadline.run(timeout: timeout) {
                try Task.checkCancellation()
                return await withCheckedContinuation { continuation in
                    start { continuation.resume(returning: $0) }
                }
            }
        }
        task = pending
        defer {
            if activeID == id {
                activeID = nil
                task = nil
            }
        }
        do {
            let granted = try await withTaskCancellationHandler {
                try await pending.value
            } onCancel: {
                pending.cancel()
            }
            try Task.checkCancellation()
            guard activeID == id else { throw CancellationError() }
            return granted
        } catch {
            try Task.checkCancellation()
            guard activeID == id else { throw CancellationError() }
            throw error
        }
    }
}

private protocol CaptureOutputWriter: AnyObject, Sendable {
    func append(sampleBuffer: CMSampleBuffer, type: SCStreamOutputType)
    func finish() async throws
    func setErrorHandler(_ handler: @escaping @Sendable (Error) -> Void)
}

private typealias AnyCaptureOutputWriter = any CaptureOutputWriter & Sendable

enum CaptureWriterFinalizationError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Timed out while finalizing the screen recording. The file may be incomplete."
        }
    }
}

/// Bounds AVAssetWriter's callback-based finalization without joining a callback that
/// never arrives. The callback operation retains its writer independently so returning
/// on timeout or cancellation cannot release framework state that may still complete late.
enum CaptureWriterFinalization {
    static let timeout: Duration = .seconds(60)

    static func wait(
        timeout: Duration = timeout,
        start: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void
    ) async throws {
        do {
            try await NonJoiningTaskDeadline.run(timeout: timeout) {
                await withCheckedContinuation { continuation in
                    start {
                        continuation.resume()
                    }
                }
            }
        } catch NonJoiningTaskDeadlineError.timedOut {
            throw CaptureWriterFinalizationError.timedOut
        }
    }
}

private final class CaptureAssetWriterFinalizationBox: @unchecked Sendable {
    let writer: AVAssetWriter

    init(writer: AVAssetWriter) {
        self.writer = writer
    }

    func start(completion: @escaping @Sendable () -> Void) {
        writer.finishWriting { [self] in
            // Keep the writer alive until AVFoundation actually invokes its callback,
            // even when the caller has already returned on timeout or cancellation.
            withExtendedLifetime(self) {
                completion()
            }
        }
    }
}

/// Both tracks must accept the same frame before the CFR cursor advances. A
/// blocked timecode input must never silently create a gap in the timecode track.
enum CaptureFrameEmission {
    /// Keep each synchronous pass short so Stop and task cancellation can run
    /// even when a large backlog meets an encoder that is continuously ready.
    static func drain(
        remainingFrameCount: Int,
        checkDeadline: () throws -> Void,
        emit: () throws -> Bool
    ) throws -> Bool {
        for _ in 0..<min(max(remainingFrameCount, 0), 32) {
            try checkDeadline()
            guard try emit() else { return false }
        }
        return remainingFrameCount <= 32
    }

    static func append(
        videoReady: Bool,
        timecodeReady: Bool,
        appendVideo: () throws -> Void,
        appendTimecode: () throws -> Void
    ) throws -> Bool {
        guard videoReady, timecodeReady else { return false }
        try appendVideo()
        try appendTimecode()
        return true
    }
}

final class ScreenCaptureWriter: CaptureOutputWriter, @unchecked Sendable {
    private let outputURL: URL
    private let fileType: AVFileType
    private let videoSettings: [String: Any]
    private let audioSettings: [String: Any]
    private let dynamicRange: CaptureDynamicRangeOption
    private let includeMicrophone: Bool
    /// Growing preset: fragmented `.mov` + CFR pump + timecode track + the
    /// Blackmagic recording xattr (the DaVinci Resolve growing-file trigger).
    private let isGrowing: Bool
    private let frameRate: CaptureFrameRate
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var timecodeInput: AVAssetWriterInput?
    private var timecodeFormat: CMTimeCodeFormatDescription?
    private var cfrVideoFormat: CMVideoFormatDescription?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var hasVideoInput = false
    private var hasAudioInput = false
    private var hasMicrophoneInput = false
    private var hasTimecodeInput = false
    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ScreenCaptureWriter")
    private var started = false
    private var finished = false
    private var writeError: Error?
    private var videoSampleCount = 0
    private var audioSampleCount = 0
    private var microphoneSampleCount = 0
    private var errorHandler: (@Sendable (Error) -> Void)?

    // CFR pump (growing presets only): SCStream is variable-rate, so we re-emit
    // the latest frame on a fixed clock to produce a constant-frame-rate file.
    private let bufferLock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    private var copyPool: CVPixelBufferPool?
    private var cfrTimer: DispatchSourceTimer?
    private let cfrQueue = DispatchQueue(label: "com.aagedal.capture.cfr")
    private let currentTime: @Sendable () -> CMTime
    private var sessionStartPTS: CMTime = .zero
    private var emittedFrameIndex = 0
    private var timecodeStartFrame = 0

    init(
        outputURL: URL,
        fileType: AVFileType,
        videoSettings: [String: Any],
        audioSettings: [String: Any],
        dynamicRange: CaptureDynamicRangeOption,
        includeMicrophone: Bool,
        isGrowing: Bool = false,
        frameRate: CaptureFrameRate = CaptureFrameRate(60),
        currentTime: @escaping @Sendable () -> CMTime = { CMClockGetTime(CMClockGetHostTimeClock()) }
    ) throws {
        self.outputURL = outputURL
        self.fileType = fileType
        self.videoSettings = videoSettings
        self.audioSettings = audioSettings
        self.dynamicRange = dynamicRange
        self.includeMicrophone = includeMicrophone
        self.isGrowing = isGrowing
        self.frameRate = frameRate
        self.currentTime = currentTime
    }

    func append(sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard !finished, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard writeError == nil else { return }
        if let writer, writer.status == .failed {
            recordError(writer.error ?? CaptureWriterError.videoAppendFailed)
            return
        }

        if !started {
            guard type == .screen else {
                return
            }
            do {
                try setupWriterIfNeeded(sampleBuffer: sampleBuffer)
            } catch {
                recordError(error)
                return
            }

            if let writer {
                let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let startTime = isGrowing
                    ? CMTimeConvertScale(sourceTime, timescale: frameRate.numerator, method: .roundTowardZero)
                    : sourceTime
                writer.startWriting()
                writer.startSession(atSourceTime: startTime)
                started = true
                if writer.status == .failed {
                    recordError(writer.error ?? CaptureWriterError.writerStartFailed)
                    return
                }
                logger.info("Capture writer started.")
                if isGrowing {
                    sessionStartPTS = startTime
                    setRecordingXattr()      // the DaVinci Resolve growing-file trigger
                    startCFRPump()
                }
            }
        }

        if #available(macOS 15, *), type == .microphone {
            if hasMicrophoneInput, let microphoneInput, microphoneInput.isReadyForMoreMediaData {
                if microphoneSampleCount == 0 {
                    logger.info("First microphone sample received.")
                }
                microphoneSampleCount += 1
                if !microphoneInput.append(sampleBuffer) {
                    recordError(writer?.error ?? CaptureWriterError.microphoneAppendFailed)
                }
            }
            return
        }

        switch type {
        case .screen:
            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                return
            }
            applyColorAttachments(to: imageBuffer, dynamicRange: dynamicRange)
            if isGrowing {
                // Growing presets don't append here — the CFR pump re-emits the
                // latest frame on a fixed clock. Stash a private copy so SCStream
                // can recycle its buffer immediately.
                storeLatestFrame(imageBuffer)
                return
            }
            if hasVideoInput, let videoInput, videoInput.isReadyForMoreMediaData {
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let appended: Bool
                if let adaptor = pixelBufferAdaptor {
                    appended = adaptor.append(imageBuffer, withPresentationTime: presentationTime)
                } else {
                    appended = videoInput.append(sampleBuffer)
                }
                if appended {
                    if videoSampleCount == 0 {
                        logger.info("First video sample received.")
                    }
                    videoSampleCount += 1
                } else {
                    recordError(writer?.error ?? CaptureWriterError.videoAppendFailed)
                }
            }
        case .audio:
            if hasAudioInput, let audioInput, audioInput.isReadyForMoreMediaData {
                if audioSampleCount == 0 {
                    logger.info("First audio sample received.")
                }
                audioSampleCount += 1
                if !audioInput.append(sampleBuffer) {
                    recordError(writer?.error ?? CaptureWriterError.audioAppendFailed)
                }
            }
        default:
            break
        }
    }

    func finish() async throws {
        guard !finished else { return }

        // Freeze the endpoint before waiting for encoder backpressure, so the
        // recording cannot grow while its final frames are being drained.
        let stopTime = currentTime()
        finished = true
        stopCFRPump()
        if isGrowing, started, writeError == nil {
            await flushCFRFrames(through: stopTime)
        }
        bufferLock.withLock { latestPixelBuffer = nil }
        // The recording xattr only marks a file as *currently growing*; a
        // finished file carries none (matches the reference recorder).
        if isGrowing {
            clearRecordingXattr()
        }

        guard let writer else {
            if let error = writeError {
                throw error
            }
            return
        }

        guard started else {
            writer.cancelWriting()
            if let error = writeError ?? writer.error {
                throw error
            }
            return
        }

        if isGrowing, videoSampleCount > 0 {
            // With only one video frame, AVAssetWriter cannot infer cadence
            // from adjacent timestamps and may otherwise extend its duration.
            writer.endSession(atSourceTime: CMTimeAdd(
                sessionStartPTS,
                frameRate.presentationOffset(frameIndex: emittedFrameIndex)
            ))
        }

        if hasVideoInput {
            videoInput?.markAsFinished()
        }
        if hasAudioInput {
            audioInput?.markAsFinished()
        }
        if hasMicrophoneInput {
            microphoneInput?.markAsFinished()
        }
        if hasTimecodeInput {
            timecodeInput?.markAsFinished()
        }

        let finalization = CaptureAssetWriterFinalizationBox(writer: writer)
        try await CaptureWriterFinalization.wait {
            finalization.start(completion: $0)
        }

        if let error = writeError ?? writer.error {
            throw error
        }
        if videoSampleCount == 0 {
            throw CaptureWriterError.noVideoFrames
        }
    }

    func setErrorHandler(_ handler: @escaping @Sendable (Error) -> Void) {
        errorHandler = handler
    }

    private func setupWriterIfNeeded(sampleBuffer: CMSampleBuffer) throws {
        guard writer == nil else { return }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        if isGrowing {
            // Preserve the exact rational endpoint in the movie edit timeline too;
            // the default 600 Hz movie timescale rounds NTSC track durations.
            writer.movieTimeScale = frameRate.numerator
            // ~1 s fragments so the file is a valid growing movie on disk.
            writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
        }
        let formatHint = CMSampleBufferGetFormatDescription(sampleBuffer)
        let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        let pixelFormat = imageBuffer.map { CVPixelBufferGetPixelFormatType($0) } ?? 0
        let bufferWidth = imageBuffer.map { CVPixelBufferGetWidth($0) } ?? 0
        let bufferHeight = imageBuffer.map { CVPixelBufferGetHeight($0) } ?? 0
        if pixelFormat != 0 {
            logger.info("Capture pixel format: \(pixelFormat, privacy: .public)")
        }
        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings,
            sourceFormatHint: formatHint
        )
        videoInput.expectsMediaDataInRealTime = true
        if isGrowing { videoInput.mediaTimeScale = frameRate.numerator }

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        var microphoneInput: AVAssetWriterInput?
        if includeMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            microphoneInput = input
        }

        hasVideoInput = writer.canAdd(videoInput)
        if hasVideoInput {
            writer.add(videoInput)
            var sourceAttributes: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            if pixelFormat != 0 {
                sourceAttributes[kCVPixelBufferPixelFormatTypeKey as String] = pixelFormat
            }
            if bufferWidth > 0, bufferHeight > 0 {
                sourceAttributes[kCVPixelBufferWidthKey as String] = bufferWidth
                sourceAttributes[kCVPixelBufferHeightKey as String] = bufferHeight
            }
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: sourceAttributes
            )
        } else {
            throw CaptureWriterError.videoInputNotSupported
        }

        hasAudioInput = writer.canAdd(audioInput)
        if hasAudioInput {
            writer.add(audioInput)
        } else {
            recordError(CaptureWriterError.audioInputNotSupported)
        }

        if let microphoneInput {
            hasMicrophoneInput = writer.canAdd(microphoneInput)
            if hasMicrophoneInput {
                writer.add(microphoneInput)
            } else {
                recordError(CaptureWriterError.microphoneInputNotSupported)
            }
        }

        if isGrowing {
            setupTimecodeTrack(on: writer, videoInput: videoInput)
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.microphoneInput = microphoneInput
    }

    /// Adds a per-frame `tmcd` timecode track (growing presets) starting at
    /// wall-clock time-of-day, associated with the video track. Must run before
    /// `startWriting()`.
    private func setupTimecodeTrack(on writer: AVAssetWriter, videoInput: AVAssetWriterInput) {
        var tcFormat: CMTimeCodeFormatDescription?
        let status = CMTimeCodeFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
            frameDuration: frameRate.frameDuration,
            frameQuanta: UInt32(frameRate.nominalRate),
            flags: frameRate.timecodeFlags,
            extensions: nil,
            formatDescriptionOut: &tcFormat
        )
        guard status == noErr, let tcFormat else { return }
        let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: tcFormat)
        input.mediaTimeScale = frameRate.numerator
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return }
        writer.add(input)
        if videoInput.canAddTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.timecode.rawValue) {
            videoInput.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.timecode.rawValue)
        }
        timecodeInput = input
        timecodeFormat = tcFormat
        hasTimecodeInput = true

        let comps = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: Date())
        timecodeStartFrame = frameRate.timecodeFrame(
            hour: comps.hour ?? 0, minute: comps.minute ?? 0,
            second: comps.second ?? 0, nanosecond: comps.nanosecond ?? 0
        )
    }

    // MARK: - Growing-file CFR pump

    /// Stash a private copy of the latest screen frame so SCStream can recycle
    /// its buffer immediately (we re-append our copy from the CFR timer).
    private func storeLatestFrame(_ imageBuffer: CVImageBuffer) {
        guard let copy = copyIntoPool(imageBuffer) else { return }
        bufferLock.lock()
        latestPixelBuffer = copy
        bufferLock.unlock()
    }

    private func copyIntoPool(_ source: CVImageBuffer) -> CVPixelBuffer? {
        if copyPool == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(source),
                kCVPixelBufferWidthKey as String: CVPixelBufferGetWidth(source),
                kCVPixelBufferHeightKey as String: CVPixelBufferGetHeight(source),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess else {
                return nil
            }
            copyPool = pool
        }
        guard let pool = copyPool else { return nil }
        var destinationOptional: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destinationOptional) == kCVReturnSuccess,
              let destination = destinationOptional else {
            return nil
        }
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        let planeCount = CVPixelBufferGetPlaneCount(source)
        if planeCount == 0 {
            if let src = CVPixelBufferGetBaseAddress(source),
               let dst = CVPixelBufferGetBaseAddress(destination) {
                let rowBytes = min(CVPixelBufferGetBytesPerRow(source), CVPixelBufferGetBytesPerRow(destination))
                // The pool is sized from the first frame; clamp to the destination height so a
                // later, taller frame can never memcpy past the destination allocation.
                let height = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(destination))
                let srcBpr = CVPixelBufferGetBytesPerRow(source)
                let dstBpr = CVPixelBufferGetBytesPerRow(destination)
                for row in 0..<height { memcpy(dst + row * dstBpr, src + row * srcBpr, rowBytes) }
            }
        } else {
            for plane in 0..<planeCount {
                guard let src = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dst = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else { continue }
                let srcBpr = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let dstBpr = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                let rowBytes = min(srcBpr, dstBpr)
                // Clamp to the destination plane height (see note above).
                let height = min(CVPixelBufferGetHeightOfPlane(source, plane), CVPixelBufferGetHeightOfPlane(destination, plane))
                for row in 0..<height { memcpy(dst + row * dstBpr, src + row * srcBpr, rowBytes) }
            }
        }
        CVBufferPropagateAttachments(source, destination)
        return destination
    }

    private func startCFRPump() {
        let interval = 1.0 / frameRate.framesPerSecond
        let timer = DispatchSource.makeTimerSource(queue: cfrQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.pumpTick() }
        cfrTimer = timer
        timer.resume()
    }

    private func stopCFRPump() {
        cfrTimer?.cancel()
        cfrTimer = nil
        // Drain any in-flight tick so nothing appends after markAsFinished().
        cfrQueue.sync { }
    }

    /// Retry transient encoder backpressure without blocking a dispatch queue or
    /// extending the captured endpoint. A stalled encoder must still allow Stop
    /// to complete and report an incomplete recording.
    private func flushCFRFrames(through stopTime: CMTime) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while writeError == nil {
            if Task.isCancelled {
                recordError(CancellationError())
                return
            }
            let drained = cfrQueue.sync { emitCFRFrames(through: stopTime, deadline: deadline) }
            if drained { return }
            if ContinuousClock.now >= deadline {
                recordError(CaptureWriterError.finalFrameFlushTimedOut)
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                recordError(error)
                return
            }
        }
    }

    /// Emit duplicate frames up to the current host-clock position so the file
    /// is constant-frame-rate even while the screen is static.
    private func pumpTick() {
        guard !finished, writeError == nil else { return }
        _ = emitCFRFrames(through: currentTime())
    }

    /// Returns false when captured frames need another bounded emission pass.
    private func emitCFRFrames(through time: CMTime, deadline: ContinuousClock.Instant? = nil) -> Bool {
        guard writeError == nil else { return true }
        guard let videoInput else { return true }
        bufferLock.lock()
        let buffer = latestPixelBuffer
        bufferLock.unlock()
        guard let buffer else { return true }   // no frame captured yet

        let elapsed = CMTimeGetSeconds(CMTimeSubtract(time, sessionStartPTS))
        guard elapsed.isFinite, elapsed >= 0 else { return true }
        let targetIndex = Int(elapsed * frameRate.framesPerSecond)

        do {
            return try CaptureFrameEmission.drain(
                remainingFrameCount: targetIndex - emittedFrameIndex + 1,
                checkDeadline: {
                    if let deadline, ContinuousClock.now >= deadline {
                        throw CaptureWriterError.finalFrameFlushTimedOut
                    }
                },
                emit: {
                    guard writeError == nil else { return false }
                    let pts = CMTimeAdd(
                        sessionStartPTS,
                        frameRate.presentationOffset(frameIndex: emittedFrameIndex)
                    )
                    let appended = try CaptureFrameEmission.append(
                        videoReady: videoInput.isReadyForMoreMediaData,
                        timecodeReady: !hasTimecodeInput || timecodeInput?.isReadyForMoreMediaData == true,
                        appendVideo: {
                            try appendCFRVideoFrame(buffer, at: pts, to: videoInput)
                            if videoSampleCount == 0 { logger.info("First video frame emitted (CFR).") }
                            videoSampleCount += 1
                        },
                        appendTimecode: { try appendTimecode(frameIndex: emittedFrameIndex) }
                    )
                    if appended { emittedFrameIndex += 1 }
                    return appended
                }
            )
        } catch {
            recordError(error)
            return true
        }
    }

    /// The pixel-buffer adaptor supplies no sample duration. Explicit timing is
    /// essential for a single-frame recording, where no adjacent PTS exists for
    /// AVAssetWriter to infer the requested cadence.
    private func appendCFRVideoFrame(_ buffer: CVPixelBuffer, at pts: CMTime, to input: AVAssetWriterInput) throws {
        // Color attachments are applied after the original capture sample's
        // format was created. Build the format from our copied buffer so Core
        // Media's image/format validation sees the actual emitted attachments.
        let format: CMVideoFormatDescription
        if let cached = cfrVideoFormat, CMVideoFormatDescriptionMatchesImageBuffer(cached, imageBuffer: buffer) {
            format = cached
        } else {
            var description: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: buffer,
                formatDescriptionOut: &description
            ) == noErr, let description else {
                throw CaptureWriterError.videoBufferUnavailable
            }
            cfrVideoFormat = description
            format = description
        }
        var timing = CMSampleTimingInfo(
            duration: frameRate.frameDuration,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample else {
            throw CaptureWriterError.videoBufferUnavailable
        }
        guard input.append(sample) else {
            throw writer?.error ?? CaptureWriterError.videoAppendFailed
        }
    }

    private func appendTimecode(frameIndex: Int) throws {
        guard hasTimecodeInput else { return }
        guard let input = timecodeInput, let format = timecodeFormat else {
            throw CaptureWriterError.timecodeAppendFailed
        }
        var frameNumber = UInt32(frameRate.wrappedTimecodeFrame(start: timecodeStartFrame, frameIndex: frameIndex)).bigEndian
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 4,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 4,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer) == noErr,
            let blockBuffer else { throw CaptureWriterError.timecodeAppendFailed }
        let copied = withUnsafeBytes(of: &frameNumber) { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: 4) == noErr
        }
        guard copied else { throw CaptureWriterError.timecodeAppendFailed }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: frameRate.frameDuration,
            presentationTimeStamp: CMTimeAdd(
                sessionStartPTS,
                frameRate.presentationOffset(frameIndex: frameIndex)
            ),
            decodeTimeStamp: .invalid
        )
        var sampleSize = 4
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr,
            let sample else { throw CaptureWriterError.timecodeAppendFailed }
        guard input.append(sample) else {
            throw writer?.error ?? CaptureWriterError.timecodeAppendFailed
        }
    }

    // MARK: - Growing-file xattr (DaVinci Resolve trigger)

    private func setRecordingXattr() {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        let json = "{\"r\":1, \"uuid\":\"\(uuid)\"}"
        let bytes = Array(json.utf8)
        let result = bytes.withUnsafeBytes { raw in
            setxattr(outputURL.path, Self.recordingXattrName, raw.baseAddress, bytes.count, 0, 0)
        }
        if result != 0 {
            logger.warning("Failed to set growing-file xattr (errno \(errno, privacy: .public)).")
        } else {
            // Remember the tagged file so a crash/quit before finish() can be swept on next launch.
            Self.registerPendingGrowingPath(outputURL.path)
        }
    }

    private func clearRecordingXattr() {
        let result = removexattr(outputURL.path, Self.recordingXattrName, 0)
        if result != 0 && errno != ENOATTR {
            logger.warning("Failed to clear growing-file xattr (errno \(errno, privacy: .public)).")
        }
        Self.unregisterPendingGrowingPath(outputURL.path)
    }

    // MARK: - Growing-file xattr bookkeeping (crash/quit recovery)

    fileprivate static let recordingXattrName = "com.blackmagicdesign.metadata:recording"

    private static func registerPendingGrowingPath(_ path: String) {
        let defaults = UserDefaults.standard
        var paths = defaults.stringArray(forKey: AppConstants.pendingGrowingRecordingPathsKey) ?? []
        guard !paths.contains(path) else { return }
        paths.append(path)
        defaults.set(paths, forKey: AppConstants.pendingGrowingRecordingPathsKey)
    }

    private static func unregisterPendingGrowingPath(_ path: String) {
        let defaults = UserDefaults.standard
        guard var paths = defaults.stringArray(forKey: AppConstants.pendingGrowingRecordingPathsKey),
              paths.contains(path) else { return }
        paths.removeAll { $0 == path }
        if paths.isEmpty {
            defaults.removeObject(forKey: AppConstants.pendingGrowingRecordingPathsKey)
        } else {
            defaults.set(paths, forKey: AppConstants.pendingGrowingRecordingPathsKey)
        }
    }

    /// Strips the Blackmagic "recording" xattr from any growing file left tagged by a
    /// recording that never reached `finish()` (app crash or quit). Call once at launch.
    static func sweepStalePendingGrowingFiles() {
        let defaults = UserDefaults.standard
        guard let paths = defaults.stringArray(forKey: AppConstants.pendingGrowingRecordingPathsKey),
              !paths.isEmpty else { return }
        for path in paths {
            removexattr(path, recordingXattrName, 0)
        }
        defaults.removeObject(forKey: AppConstants.pendingGrowingRecordingPathsKey)
    }

    private func recordError(_ error: Error) {
        writeError = error
        let nsError = error as NSError
        logger.error("Capture writer error: \(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) \(nsError.localizedDescription, privacy: .public)")
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            logger.error("Underlying error: \(underlying.domain, privacy: .public) code=\(underlying.code, privacy: .public) \(underlying.localizedDescription, privacy: .public)")
        }
        // A write failure stops the file from growing further, so clear the "recording"
        // tag now rather than leaving it stuck until the user manually stops. The pump
        // self-guards on `writeError` and is fully torn down later in finish(); we must
        // not call stopCFRPump() here because recordError can run on the pump's own queue.
        if isGrowing {
            clearRecordingXattr()
        }
        errorHandler?(error)
    }

    private func applyColorAttachments(
        to imageBuffer: CVImageBuffer,
        dynamicRange: CaptureDynamicRangeOption
    ) {
        switch dynamicRange {
        case .sdr:
            CVBufferSetAttachment(
                imageBuffer,
                kCVImageBufferColorPrimariesKey,
                kCVImageBufferColorPrimaries_ITU_R_709_2,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                imageBuffer,
                kCVImageBufferTransferFunctionKey,
                kCVImageBufferTransferFunction_ITU_R_709_2,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                imageBuffer,
                kCVImageBufferYCbCrMatrixKey,
                kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                imageBuffer,
                "ColorRange" as CFString,
                "FullRange" as CFString,
                .shouldPropagate
            )
        case .hdrP3CanonicalDisplay:
            CVBufferSetAttachment(
                imageBuffer,
                kCVImageBufferColorPrimariesKey,
                kCVImageBufferColorPrimaries_P3_D65,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                imageBuffer,
                kCVImageBufferTransferFunctionKey,
                kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                imageBuffer,
                kCVImageBufferYCbCrMatrixKey,
                kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                imageBuffer,
                "ColorRange" as CFString,
                "VideoRange" as CFString,
                .shouldPropagate
            )
        }
    }

    private enum CaptureWriterError: LocalizedError {
        case videoInputNotSupported
        case audioInputNotSupported
        case microphoneInputNotSupported
        case writerStartFailed
        case videoAppendFailed
        case audioAppendFailed
        case microphoneAppendFailed
        case timecodeAppendFailed
        case finalFrameFlushTimedOut
        case noVideoFrames
        case videoBufferUnavailable

        var errorDescription: String? {
            switch self {
            case .videoInputNotSupported:
                return "Video input could not be added to the capture writer."
            case .audioInputNotSupported:
                return "Audio input could not be added to the capture writer."
            case .microphoneInputNotSupported:
                return "Microphone input could not be added to the capture writer."
            case .writerStartFailed:
                return "Failed to start the capture writer."
            case .videoAppendFailed:
                return "Failed to append video samples to the capture writer."
            case .audioAppendFailed:
                return "Failed to append audio samples to the capture writer."
            case .microphoneAppendFailed:
                return "Failed to append microphone samples to the capture writer."
            case .timecodeAppendFailed:
                return String(localized: "Failed to append timecode samples to the capture writer.")
            case .finalFrameFlushTimedOut:
                return String(localized: "Timed out while writing the final screen recording frames. The file may be incomplete.")
            case .noVideoFrames:
                return "No video frames were captured. Check Screen Recording permission."
            case .videoBufferUnavailable:
                return "Video pixel buffer was unavailable for capture."
            }
        }
    }
}

/// Reservations span every suspension in a recording start or finalization. Stop
/// retires the current generation immediately, while old reservations retain the
/// shared folder scope until their late work and cleanup have actually returned.
@MainActor
final class CaptureRecordingOperations {
    struct Start: Hashable {
        let id = UUID()
        let displayID: CGDirectDisplayID
        let generation: UInt64
    }

    private(set) var generation: UInt64 = 0
    private var starts: Set<Start> = []
    private var stops: Set<UUID> = []
    private var deliveries: [UUID: CaptureSampleDelivery] = [:]

    var hasPendingOperations: Bool { !starts.isEmpty || !stops.isEmpty }
    var hasPendingCleanup: Bool {
        !stops.isEmpty || starts.contains { $0.generation != generation }
    }

    func beginStart(displayID: CGDirectDisplayID) -> Start? {
        guard !hasPendingCleanup, !starts.contains(where: { $0.displayID == displayID }) else { return nil }
        let operation = Start(displayID: displayID, generation: generation)
        starts.insert(operation)
        return operation
    }

    func isCurrent(_ operation: Start) -> Bool {
        starts.contains(operation) && operation.generation == generation
    }

    func hasStart(displayID: CGDirectDisplayID) -> Bool {
        starts.contains { $0.displayID == displayID }
    }

    func registerDelivery(_ delivery: CaptureSampleDelivery, for operation: Start) {
        guard isCurrent(operation) else { delivery.invalidate(); return }
        deliveries[operation.id] = delivery
    }

    func finishStart(_ operation: Start) {
        starts.remove(operation)
        deliveries[operation.id] = nil
    }

    func retireStarts(outside displayIDs: Set<CGDirectDisplayID>) {
        guard starts.contains(where: { !displayIDs.contains($0.displayID) }) else { return }
        retireStarts()
    }

    private func retireStarts() {
        generation &+= 1
        for delivery in deliveries.values { delivery.invalidate() }
    }

    func beginStop() -> UUID {
        retireStarts()
        let operation = UUID()
        stops.insert(operation)
        return operation
    }

    func finishStop(_ operation: UUID) {
        stops.remove(operation)
    }
}

/// A retired stream can continue delivering samples after its stop deadline. This
/// fence is shared with queued UI updates so late delivery cannot revive the tile.
final class CaptureSampleDelivery: Sendable {
    private let active = OSAllocatedUnfairLock(initialState: true)

    var isActive: Bool { active.withLock { $0 } }

    func invalidate() {
        active.withLock { $0 = false }
    }

    /// Serialize the short writer handoff with retirement so finalization cannot
    /// race a sample that passed an earlier active-state check.
    func ifActive(_ operation: () -> Void) {
        // The nonescaping sample handler runs synchronously on its existing
        // delivery queue; locking does not transfer its captures to another task.
        active.withLockUnchecked { if $0 { operation() } }
    }
}

/// Cleanup is deliberately independent of caller cancellation. The deadline does
/// not join a non-cooperative framework callback; the operation retains ownership
/// of the retired stream and output until that callback eventually returns.
enum CaptureStreamShutdown {
    static func stop(
        timeout: Duration = .seconds(15),
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await Task.detached {
            do {
                try await NonJoiningTaskDeadline.run(timeout: timeout, operation: operation)
            } catch NonJoiningTaskDeadlineError.timedOut {
                throw CaptureStreamShutdownError.timedOut
            }
        }.value
    }
}

enum CaptureStreamShutdownError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        String(localized: "Timed out while stopping screen capture. The recording may be incomplete.")
    }
}

private final class CaptureStreamStopOperation: @unchecked Sendable {
    let stream: SCStream
    let output: CaptureStreamOutput?

    init(stream: SCStream, output: CaptureStreamOutput?) {
        self.stream = stream
        self.output = output
    }

    func stop() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.stopCapture { [self] error in
                withExtendedLifetime(self) {
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
    }
}

private final class CaptureStreamOutput: NSObject, SCStreamOutput {
    let queue: DispatchQueue
    private let handler: (CMSampleBuffer, SCStreamOutputType) -> Void

    init(queue: DispatchQueue, handler: @escaping (CMSampleBuffer, SCStreamOutputType) -> Void) {
        self.queue = queue
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        handler(sampleBuffer, type)
    }
}
