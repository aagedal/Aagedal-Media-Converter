// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import AppKit
import AVKit
import OSLog

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

private struct ScreenshotFeedback: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

extension LabelStyle where Self == TrailingIconLabelStyle {
    static var trailingIcon: TrailingIconLabelStyle { TrailingIconLabelStyle() }
}

private struct CheckerboardBackground: View {
    private let squareSize: CGFloat = 24
    private let lightColor = Color.white.opacity(0.14)
    private let darkColor = Color.white.opacity(0.06)

    var body: some View {
        Canvas { context, size in
            guard squareSize > 0 else { return }

            let columns = Int(ceil(size.width / squareSize))
            let rows = Int(ceil(size.height / squareSize))

            for row in 0..<rows {
                for column in 0..<columns {
                    let origin = CGPoint(
                        x: CGFloat(column) * squareSize,
                        y: CGFloat(row) * squareSize
                    )
                    let rect = CGRect(
                        origin: origin,
                        size: CGSize(
                            width: min(squareSize, size.width - origin.x),
                            height: min(squareSize, size.height - origin.y)
                        )
                    )

                    let color = ((row + column).isMultiple(of: 2) ? lightColor : darkColor)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .background(Color.black)
    }
}

struct PreviewPlayerView: View {
    @Binding var item: VideoItem
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: PreviewPlayerController
    @State private var activeTrimGestures: Int = 0
    @State private var currentPlaybackTime: Double = 0
    @State private var screenshotFeedback: ScreenshotFeedback?

    init(item: Binding<VideoItem>) {
        self._item = item
        self._controller = StateObject(wrappedValue: PreviewPlayerController(videoItem: item.wrappedValue))
    }

    var body: some View {
        VStack(spacing: 8) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

            trimControls
                .transition(.opacity)

            footer
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(minWidth: 920, idealWidth: 1080, minHeight: 640, idealHeight: 720)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            controller.preparePreview(startTime: item.effectiveTrimStart)
        }
        .onDisappear {
            Task { @MainActor in controller.teardown() }
        }
        .onChange(of: item) { _, newValue in controller.updateVideoItem(newValue) }
        .alert(item: $screenshotFeedback) { feedback in
            Alert(
                title: Text(feedback.title),
                message: Text(feedback.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var playerAspectRatio: CGFloat {
        if let ratio = item.videoDisplayAspectRatio, ratio.isFinite, ratio > 0 {
            return CGFloat(ratio)
        }
        return 16.0 / 9.0
    }

    @ViewBuilder
    private var content: some View {
        if let player = controller.player {
            ZStack {
                CheckerboardBackground()
                
                HStack {
                    PlayerContainerView(
                        player: player,
                        controller: controller,
                        keyHandler: handleKeyCommand
                    )
                }
                .aspectRatio(playerAspectRatio, contentMode: .fit)
                
                if controller.isCapturingScreenshot {
                    ZStack {
                        Color.black.opacity(0.5)
                        
                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(1.2)
                                .tint(.white)
                            
                            Text("Capturing Still…")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        .padding(24)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.black.opacity(0.8))
                        )
                    }
                    .transition(.opacity)
                }
                
                if controller.isGeneratingFallbackPreview {
                    ZStack {
                        Color.black.opacity(0.5)
                        
                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(1.2)
                                .tint(.white)
                            
                            Text("Generating Preview…")
                                .font(.headline)
                                .foregroundColor(.white)
                            
                            Text("This format requires transcoding for playback")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.8))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                        .padding(24)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.black.opacity(0.8))
                        )
                    }
                    .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if controller.isPreparing {
            VStack(spacing: 12) {
                ProgressView().progressViewStyle(.circular)
                Text("Preparing preview…")
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding()
        } else if let message = controller.errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 40))
                Text("Preview unavailable")
                    .font(.headline)
                    .foregroundColor(.white)
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry") {
                    controller.preparePreview(startTime: 0)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        } else {
            Text("Preview not available")
                .foregroundColor(.white.opacity(0.8))
                .padding()
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("Input Duration: \(item.duration)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("| Trimmed duration: \(formattedTime(item.trimmedDuration))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    if let range = controller.fallbackPreviewRange {
                        Text("| Preview: \(formattedTime(range.lowerBound))–\(formattedTime(range.upperBound))")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    }
                }.multilineTextAlignment(.leading)
            }
            Spacer()
            VStack(alignment: .leading) {
                Text("Keyboard shortcuts:").font(.headline)
                Text("I/O: in/out • ⇧I/⇧O: jump • ⌥I/⌥O: clear • ⌘L: loop")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }.padding(.trailing, 10)
            Button(role: .cancel, action: dismiss.callAsFunction) {
                Label("Close", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundColor(.secondary)
                    .font(.system(size: 24))
            }
            .buttonStyle(.plain)
            .help("Close preview")
        }
    }

    private var trimControls: some View {
        let duration = max(item.durationSeconds, 0)
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                TrimTimelineView(
                    trimStart: trimStartBinding,
                    trimEnd: trimEndBinding,
                    duration: duration,
                    playbackTime: currentPlaybackTime,
                    thumbnails: controller.previewAssets?.thumbnails,
                    waveformURL: controller.previewAssets?.waveform,
                    isLoading: controller.isLoadingPreviewAssets,
                    step: 0.1,
                    onEditingChanged: handleTrimEditingChanged,
                    onSeek: { time in
                        controller.seekTo(time)
                    }
                )
                .onReceive(controller.playbackTimePublisher) { time in
                    currentPlaybackTime = time
                }
                HStack(spacing: 12) {

                    
                    Button(action: {
                        controller.seekTo(item.effectiveTrimStart)
                    }) {
                        Label("\(formattedTime(item.effectiveTrimStart))", systemImage: "arrow.left.to.line")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .help("Jump to trim start")

                    HStack {
                        Label("\(formattedTime(currentPlaybackTime))", systemImage: "arrowtriangle.left.and.line.vertical.and.arrowtriangle.right")
                            .font(.system(.subheadline, design: .monospaced))
                            .padding(0)
                    }.padding(.horizontal, 30)

                    Button(action: {
                        controller.seekTo(item.effectiveTrimEnd)
                    }) {
                        Label("\(formattedTime(item.effectiveTrimEnd))", systemImage: "arrow.right.to.line")
                            .labelStyle(.trailingIcon)
                    }
                    .buttonStyle(.plain)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .help("Jump to trim end")
                    
                    Spacer()
                    
                    Button(action: {
                        item.trimStart = nil
                        item.trimEnd = nil
                        controller.refreshPreviewForTrim()
                    }) {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                        .labelStyle(.iconOnly)
                    }
                    .disabled(item.trimStart == nil && item.trimEnd == nil)
                    .help("Reset trim points")

                    Button(action: captureScreenshot) {
                        Label("Capture frame", systemImage: "camera")
                            .labelStyle(.iconOnly)
                    }
                    .disabled(controller.isCapturingScreenshot)
                    .help("Save the current frame as a JPEG")

                    Toggle(isOn: loopBinding) {
                        Label("Loop", systemImage: "repeat")
                            .labelStyle(.iconOnly)
                    }
                    .toggleStyle(.button)
                    .help("Loop playback (⌘L)")
                }
                .font(.subheadline)
            
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var trimStartBinding: Binding<Double> {
        Binding(
            get: { item.trimStart ?? 0 },
            set: { newValue in
                let duration = max(item.durationSeconds, 0)
                let clamped = max(0, min(newValue, duration))
                let sanitized = clamped <= 0.05 ? nil : clamped
                item.trimStart = sanitized
                if let end = item.trimEnd, end < item.effectiveTrimStart {
                    item.trimEnd = sanitized
                }
                // Seek to the new trim start position to show the first frame
                controller.seekTo(item.effectiveTrimStart)
            }
        )
    }

    private var trimEndBinding: Binding<Double> {
        Binding(
            get: { item.trimEnd ?? item.durationSeconds },
            set: { newValue in
                let duration = max(item.durationSeconds, 0)
                let clamped = max(0, min(newValue, duration))
                let minEnd = item.effectiveTrimStart
                let sanitizedValue = max(clamped, minEnd)
                if sanitizedValue >= duration - 0.05 {
                    item.trimEnd = nil
                } else {
                    item.trimEnd = sanitizedValue
                }
                // Seek to the new trim end position to show the last frame
                controller.seekTo(item.effectiveTrimEnd)
            }
        )
    }

    private var loopBinding: Binding<Bool> {
        Binding(
            get: { item.loopPlayback },
            set: { newValue in
                item.loopPlayback = newValue
            }
        )
    }

    private func captureScreenshot() {
        Task {
            let defaults = UserDefaults.standard
            let directoryPath = defaults.string(forKey: AppConstants.screenshotDirectoryKey) ?? AppConstants.defaultScreenshotDirectory.path
            let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)

            do {
                let savedURL = try await controller.captureScreenshot(to: directoryURL)
                screenshotFeedback = ScreenshotFeedback(
                    title: "Frame saved",
                    message: savedURL.path
                )
            } catch {
                screenshotFeedback = ScreenshotFeedback(
                    title: "Capture failed",
                    message: error.localizedDescription
                )
            }
        }
    }


    private func handleTrimEditingChanged(_ editing: Bool) {
        if editing {
            activeTrimGestures += 1
        } else {
            activeTrimGestures = max(activeTrimGestures - 1, 0)
            // No need to refresh since we're seeking in real-time during drag
        }
    }

    private func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
    
    private func handleTrimInPoint(clearToStart: Bool) {
        if clearToStart {
            // Option+I: Clear trim start (set to beginning)
            item.trimStart = nil
        } else {
            // I: Set trim start to current playback position
            if let currentTime = controller.getCurrentTime() {
                let duration = max(item.durationSeconds, 0)
                let clamped = max(0, min(currentTime, duration))
                // Only set if it's not at the very start
                item.trimStart = clamped <= 0.05 ? nil : clamped
                // Ensure trim end is after trim start
                if let end = item.trimEnd, end < item.effectiveTrimStart {
                    item.trimEnd = item.trimStart
                }
            }
        }
    }
    
    private func handleTrimOutPoint(clearToEnd: Bool) {
        if clearToEnd {
            // Option+O: Clear trim end (set to end of video)
            item.trimEnd = nil
        } else {
            // O: Set trim end to current playback position
            if let currentTime = controller.getCurrentTime() {
                let duration = max(item.durationSeconds, 0)
                let clamped = max(0, min(currentTime, duration))
                let minEnd = item.effectiveTrimStart
                let sanitizedValue = max(clamped, minEnd)
                // Only set if it's not at the very end
                if sanitizedValue >= duration - 0.05 {
                    item.trimEnd = nil
                } else {
                    item.trimEnd = sanitizedValue
                }
            }
        }
    }

    private func handleKeyCommand(key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        let lowerKey = key.lowercased()

        if modifiers.contains(.command) {
            switch lowerKey {
            case "l":
                item.loopPlayback.toggle()
                return true
            case "f":
                controller.toggleFullscreen()
                return true
            default:
                return false
            }
        }

        if modifiers.contains(.option) {
            switch lowerKey {
            case "i":
                handleTrimInPoint(clearToStart: true)
                return true
            case "o":
                handleTrimOutPoint(clearToEnd: true)
                return true
            default:
                return false
            }
        }

        // Check for Shift+I/O to jump to trim positions
        // Must have shift, and must NOT have command/option/control
        let hasShift = modifiers.contains(.shift)
        let hasOtherModifiers = !modifiers.intersection([.command, .option, .control]).isEmpty
        
        if hasShift && !hasOtherModifiers {
            switch lowerKey {
            case "i":
                controller.seekTo(item.effectiveTrimStart)
                return true
            case "o":
                controller.seekTo(item.effectiveTrimEnd)
                return true
            default:
                return false
            }
        }

        // Check for plain I/O (no modifiers) to set trim positions
        let disallowedModifiers = modifiers.intersection([.command, .option, .control, .shift])
        if !disallowedModifiers.isEmpty {
            return false
        }

        switch lowerKey {
        case "i":
            handleTrimInPoint(clearToStart: false)
            return true
        case "o":
            handleTrimOutPoint(clearToEnd: false)
            return true
        default:
            return false
        }
    }
}

private final class WeakPreviewPlayerController: @unchecked Sendable {
    weak var value: PreviewPlayerController?

    init(_ value: PreviewPlayerController) {
        self.value = value
    }
}

// MARK: - Controller

@MainActor
final class PreviewPlayerController: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isPreparing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentPlaybackTime: Double = 0
    @Published private(set) var previewAssets: PreviewAssets?
    @Published private(set) var isLoadingPreviewAssets = false
    @Published private(set) var isCapturingScreenshot = false
    @Published private(set) var isGeneratingFallbackPreview = false
    @Published private(set) var fallbackPreviewRange: ClosedRange<Double>?
    @Published private(set) var fallbackStillImage: NSImage?
    @Published private(set) var fallbackStillTime: Double?
    @Published private(set) var isGeneratingFallbackStill = false

    private var videoItem: VideoItem
    private var mp4Session: MP4PreviewSession?
    private var preparationTask: Task<Void, Never>?
    private var previewAssetTask: Task<Void, Never>?
    private var fallbackStillTask: Task<Void, Never>?
    private var loopObserver: Any?
    private var timeObserver: Any?
    private var playbackTimeObserver: Any?
    private weak var timeObserverOwner: AVPlayer?
    private weak var playbackTimeObserverOwner: AVPlayer?
    private var playerItemStatusObserver: Any?
    private var hasSecurityScope = false
    private var usePreviewFallback = false
    weak var playerView: AVPlayerView?

    enum ScreenshotError: LocalizedError {
        case ffmpegMissing
        case videoUnavailable
        case captureInProgress
        case securityScopeDenied
        case processFailed(String)
        case outputUnavailable
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .ffmpegMissing:
                return "FFmpeg binary not found in application bundle."
            case .videoUnavailable:
                return "No active video to capture from."
            case .captureInProgress:
                return "Screenshot capture is already in progress."
            case .securityScopeDenied:
                return "Unable to access the selected screenshot directory."
            case .processFailed(let message):
                return "FFmpeg failed: \(message)"
            case .outputUnavailable:
                return "FFmpeg reported success but the output file is missing."
            case .conversionFailed(let message):
                return "Image conversion failed: \(message)"
            }
        }
    }

    private enum SecurityAccess {
        case none
        case direct(URL)
        case bookmark(URL)
    }

    private struct ScreenshotParameters {
        let fileExtension: String
        let codecArguments: [String]
        let pixelFormat: String?
    }

    private static let screenshotDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private func screenshotParameters(for stream: VideoMetadata.VideoStream?) -> ScreenshotParameters {
        guard let stream else {
            return ScreenshotParameters(
                fileExtension: "jpg",
                codecArguments: ["-c:v", "mjpeg", "-q:v", "1"],
                pixelFormat: "yuvj444p"
            )
        }

        let transfer = stream.colorTransfer?.lowercased()
        let primaries = stream.colorPrimaries?.lowercased()
        let colorSpace = stream.colorSpace?.lowercased()
        let bitDepth = stream.bitDepth ?? 8
        let hdrTransfers: Set<String> = ["smpte2084", "arib-std-b67"]
        let metadataIndicatesHDR = (transfer.map(hdrTransfers.contains) ?? false) || (primaries?.contains("2020") ?? false) || (colorSpace?.contains("2020") ?? false)

        let codec = stream.codec?.lowercased()
        let profile = stream.profile?.lowercased()
        let codecLongName = stream.codecLongName?.lowercased()
        
        // Check for ProRes RAW in multiple ways:
        // 1. Codec name contains "raw" (e.g., "prores_raw", "proresraw")
        // 2. Profile contains "raw"
        // 3. Codec long name contains "raw"
        let isProResRAW = (codec?.contains("prores") == true && codec?.contains("raw") == true) ||
                         (codec == "prores" && profile?.contains("raw") == true) ||
                         (codecLongName?.contains("prores") == true && codecLongName?.contains("raw") == true)
        
        if bitDepth >= 10 || isProResRAW {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "Screenshots").debug("Screenshot format detection - codec: \(codec ?? "nil", privacy: .public), profile: \(profile ?? "nil", privacy: .public), codecLongName: \(codecLongName ?? "nil", privacy: .public), bitDepth: \(bitDepth), isProResRAW: \(isProResRAW)")
        }

        var isHDR = metadataIndicatesHDR

        if !isHDR {
            if isProResRAW {
                isHDR = true
            } else if bitDepth >= 10 {
                let primariesMissing = isMissingColorMetadata(stream.colorPrimaries)
                let transferMissing = isMissingColorMetadata(stream.colorTransfer)
                if primariesMissing && transferMissing {
                    isHDR = true
                }
            }
        }

        if isHDR {
            if isProResRAW {
                return ScreenshotParameters(
                    fileExtension: "png",
                    codecArguments: [
                        "-c:v", "png",
                        "-compression_level", "1"
                    ],
                    pixelFormat: "rgb48be"
                )
            }
            
            let pixelFormat: String
            if bitDepth >= 12 {
                pixelFormat = "yuv420p12le"
            } else {
                pixelFormat = "yuv420p10le"
            }

            return ScreenshotParameters(
                fileExtension: "avif",
                codecArguments: [
                    "-c:v", "libsvtav1",
                    "-pix_fmt", pixelFormat,
                    "-preset", "12",
                    "-crf", "35",
                    "-svtav1-params", "fast-decode=1:enable-overlays=0"
                ],
                pixelFormat: nil
            )
        }

        return ScreenshotParameters(
            fileExtension: "jpg",
            codecArguments: ["-c:v", "mjpeg", "-q:v", "1"],
            pixelFormat: "yuvj444p"
        )
    }

    private func isMissingColorMetadata(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return true
        }

        let normalized = value.lowercased()
        return normalized == "unknown" || normalized == "unspecified" || normalized == "na"
    }

    private func appendColorArguments(from stream: VideoMetadata.VideoStream?, to arguments: inout [String]) {
        guard let stream else { return }

        let primaries = stream.colorPrimaries
        let transfer = stream.colorTransfer
        let space = stream.colorSpace
        let range = stream.colorRange

        if !isMissingColorMetadata(primaries), let normalized = normalizedColorPrimaries(primaries) {
            arguments += ["-color_primaries", normalized]
        }
        if !isMissingColorMetadata(transfer), let normalized = normalizedColorTransfer(transfer) {
            arguments += ["-color_trc", normalized]
        }
        if !isMissingColorMetadata(space), let normalized = normalizedColorSpace(space) {
            arguments += ["-colorspace", normalized]
        }
        if !isMissingColorMetadata(range), let normalized = normalizedColorRange(range) {
            arguments += ["-color_range", normalized]
        }
    }

    private func normalizedColorPrimaries(_ value: String?) -> String? {
        let mapping: [String: String] = [
            "bt2020": "bt2020",
            "bt2020-10": "bt2020",
            "bt2020-12": "bt2020"
        ]
        return normalizedColorValue(value, allowed: [
            "bt709",
            "bt470bg",
            "smpte170m",
            "smpte240m",
            "bt2020",
            "smpte432",
            "smpte432-1"
        ], mapping: mapping)
    }

    private func normalizedColorTransfer(_ value: String?) -> String? {
        let mapping: [String: String] = [
            "bt2020-10": "bt2020-10",
            "bt2020-12": "bt2020-12"
        ]
        return normalizedColorValue(value, allowed: [
            "bt709",
            "smpte2084",
            "arib-std-b67",
            "iec61966-2-4",
            "bt470bg",
            "smpte170m",
            "bt2020-10",
            "bt2020-12"
        ], mapping: mapping)
    }

    private func normalizedColorSpace(_ value: String?) -> String? {
        let mapping: [String: String] = [
            "bt2020": "bt2020nc",
            "bt2020-ncl": "bt2020nc",
            "bt2020-cl": "bt2020c"
        ]
        return normalizedColorValue(value, allowed: [
            "bt709",
            "smpte170m",
            "smpte240m",
            "bt2020nc",
            "bt2020c",
            "bt2020ncl"
        ], mapping: mapping)
    }

    private func normalizedColorRange(_ value: String?) -> String? {
        return normalizedColorValue(value, allowed: ["tv", "pc"], mapping: [
            "limited": "tv",
            "full": "pc"
        ])
    }

    private func normalizedColorValue(_ value: String?, allowed: [String], mapping: [String: String]) -> String? {
        guard let raw = value?.lowercased() else { return nil }
        if let mapped = mapping[raw] {
            return mapped
        }
        if allowed.contains(raw) {
            return raw
        }
        return nil
    }

    var playbackTimePublisher: Published<Double>.Publisher { $currentPlaybackTime }

    init(videoItem: VideoItem) {
        self.videoItem = videoItem
    }

    func updateVideoItem(_ newValue: VideoItem) {
        let previous = videoItem
        videoItem = newValue

        if previous.id != newValue.id || previous.url != newValue.url {
            preparePreview(startTime: newValue.effectiveTrimStart)
            loadPreviewAssets(for: newValue.url)
        } else if previous.loopPlayback != newValue.loopPlayback {
            applyLoopSetting()
        } else if previous.trimStart != newValue.trimStart || previous.trimEnd != newValue.trimEnd {
            // Trim values changed, reinstall time observer with new boundaries
            if let player = player {
                installTimeObserver(for: player)
            }
        }
    }

    func preparePreview(startTime: TimeInterval) {
        teardown()
        isPreparing = true
        errorMessage = nil
        isLoadingPreviewAssets = true
        previewAssets = nil
        usePreviewFallback = false

        let currentItem = videoItem
        
        // Try AVPlayer directly first with security-scoped resource access
        let url = currentItem.url
        
        // First try bookmark-based access (more reliable for sandboxed apps)
        let bookmarkAccess = SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: url)
        let directAccess = !bookmarkAccess && url.startAccessingSecurityScopedResource()
        hasSecurityScope = bookmarkAccess || directAccess
        
        // Create asset with security-scoped access preference
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        
        self.player = player
        
        // Monitor player item status for failures, fallback to HLS if needed
        installPlayerItemStatusObserver(for: playerItem, startTime: startTime)
        
        self.isPreparing = false
        
        // Seek to start time but remain paused (don't auto-play)
        let seekTime = CMTime(seconds: startTime, preferredTimescale: 600)
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        
        installLoopObserver(for: playerItem)
        installTimeObserver(for: player)
        installPlaybackTimeObserver(for: player)
        applyLoopSetting()
        loadPreviewAssets(for: currentItem.url)
    }

    func teardown() {
        preparationTask?.cancel()
        preparationTask = nil
        previewAssetTask?.cancel()
        previewAssetTask = nil
        fallbackStillTask?.cancel()
        fallbackStillTask = nil

        player?.pause()
        
        // Release security-scoped resource only if we acquired it
        if hasSecurityScope {
            let url = videoItem.url
            // Try both release methods to ensure cleanup
            SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: url)
            url.stopAccessingSecurityScopedResource()
            hasSecurityScope = false
        }
        
        player = nil
        if let session = mp4Session {
            mp4Session = nil
            Task { await session.cancel(); await session.cleanup() }
        }

        isPreparing = false
        isGeneratingFallbackPreview = false
        isGeneratingFallbackStill = false
        fallbackPreviewRange = nil
        fallbackStillImage = nil
        fallbackStillTime = nil
        removeLoopObserver()
        removeTimeObserver()
        removePlaybackTimeObserver()
        removePlayerItemStatusObserver()
        usePreviewFallback = false
    }

    func refreshPreviewForTrim() {
        guard let player else {
            preparePreview(startTime: videoItem.effectiveTrimStart)
            return
        }
        
        // Check if currently playing
        let isPlaying = player.rate > 0
        
        // Seek to the new trim start position
        let seekTime = CMTime(seconds: videoItem.effectiveTrimStart, preferredTimescale: 600)
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard finished, let self = self, isPlaying else { return }
                // Only resume playback if it was playing before
                self.player?.play()
            }
        }
    }
    
    func seekTo(_ time: TimeInterval) {
        guard let player else { return }
        let seekTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    func getCurrentTime() -> TimeInterval? {
        guard let player else { return nil }
        let currentTime = player.currentTime()
        return currentTime.seconds.isFinite ? currentTime.seconds : nil
    }
    
    func toggleFullscreen() {
        // Try to get window from playerView first, fallback to key window
        let window = playerView?.window ?? NSApp.keyWindow
        window?.toggleFullScreen(nil)
    }

    func captureScreenshot(to directory: URL) async throws -> URL {
        guard !isCapturingScreenshot else {
            throw ScreenshotError.captureInProgress
        }

        guard player != nil else {
            throw ScreenshotError.videoUnavailable
        }

        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            throw ScreenshotError.ffmpegMissing
        }

        isCapturingScreenshot = true
        defer { isCapturingScreenshot = false }

        let captureTime = getCurrentTime() ?? videoItem.effectiveTrimStart

        let parameters = screenshotParameters(for: videoItem.metadata?.videoStream)
        let sanitizedBaseName = FileNameProcessor.processFileName(videoItem.url.deletingPathExtension().lastPathComponent)
        let timestamp = Self.screenshotDateFormatter.string(from: Date())
        let timeComponent = String(format: "%.3f", captureTime).replacingOccurrences(of: ".", with: "-")
        let fileName = "\(sanitizedBaseName)_\(timestamp)_t\(timeComponent).\(parameters.fileExtension)"
        let outputDirectory = directory

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let outputURL = outputDirectory.appendingPathComponent(fileName)

        var directoryAccess: SecurityAccess = .none
        if outputDirectory.startAccessingSecurityScopedResource() {
            directoryAccess = .direct(outputDirectory)
        } else if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: outputDirectory) {
            directoryAccess = .bookmark(outputDirectory)
        }

        var videoAccess: SecurityAccess = .none
        if !hasSecurityScope {
            let sourceURL = videoItem.url
            if sourceURL.startAccessingSecurityScopedResource() {
                videoAccess = .direct(sourceURL)
            } else if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: sourceURL) {
                videoAccess = .bookmark(sourceURL)
            }
        }

        defer {
            switch directoryAccess {
            case .direct(let url):
                url.stopAccessingSecurityScopedResource()
            case .bookmark(let url):
                SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: url)
            case .none:
                break
            }

            switch videoAccess {
            case .direct(let url):
                url.stopAccessingSecurityScopedResource()
            case .bookmark(let url):
                SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: url)
            case .none:
                break
            }
        }

        if case .none = directoryAccess {
            let reachable = (try? outputDirectory.checkResourceIsReachable()) ?? false
            guard reachable else {
                throw ScreenshotError.securityScopeDenied
            }
        }

        let ffmpegURL = URL(fileURLWithPath: ffmpegPath)

        var arguments: [String] = [
            "-hide_banner",
            "-loglevel", "error",
            "-ss", String(format: "%.6f", captureTime),
            "-i", videoItem.url.path,
            "-frames:v", "1"
        ]
        
        // Build video filter to handle pixel aspect ratio and deinterlacing
        var filterComponents: [String] = []
        
        // Always apply SAR (Sample Aspect Ratio) scaling to correct for non-square pixels
        filterComponents.append("scale=iw*sar:ih")
        
        // Check if source is interlaced and needs deinterlacing
        if let videoStream = videoItem.metadata?.videoStream,
           let fieldOrder = videoStream.fieldOrder?.lowercased(),
           fieldOrder != "progressive" && fieldOrder != "unknown" {
            // Source is interlaced, apply yadif deinterlacer
            filterComponents.append("yadif=mode=send_frame:parity=auto:deint=all")
        }
        
        // Combine filters if we have any
        if !filterComponents.isEmpty {
            arguments += ["-vf", filterComponents.joined(separator: ",")]
        }

        if let pixelFormat = parameters.pixelFormat {
            arguments += ["-pix_fmt", pixelFormat]
        }

        appendColorArguments(from: videoItem.metadata?.videoStream, to: &arguments)

        arguments += parameters.codecArguments

        arguments += [
            "-y",
            outputURL.path
        ]

        do {
            try await runFFmpegCapture(executable: ffmpegURL, arguments: arguments)
        } catch let error as ScreenshotError {
            throw error
        } catch {
            throw ScreenshotError.processFailed(error.localizedDescription)
        }

        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw ScreenshotError.outputUnavailable
        }

        Logger(subsystem: "com.aagedal.MediaConverter", category: "Screenshots").info("Saved screenshot to \(outputURL.path, privacy: .public)")
        return outputURL
    }

    private func runFFmpegCapture(executable: URL, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = Pipe()
                let stderrPipe = Pipe()
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    continuation.resume(returning: ())
                } else {
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: stderrData, encoding: .utf8) ?? "Unknown ffmpeg error"
                    continuation.resume(throwing: ScreenshotError.processFailed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
    }
    
    func generateFallbackStillIfNeeded(for time: TimeInterval) {
        // Only generate if we're using fallback preview and the time is outside the preview range
        guard usePreviewFallback else { return }
        guard let range = fallbackPreviewRange else { return }
        
        // If within range, no still needed
        if range.contains(time) { return }
        
        // If we already have a still for this time (within 1 second tolerance), don't regenerate
        if let existingTime = fallbackStillTime, abs(existingTime - time) < 1.0 { return }
        
        // If already generating, don't start another
        guard !isGeneratingFallbackStill else { return }
        
        fallbackStillTask?.cancel()
        fallbackStillTask = Task { @MainActor in
            isGeneratingFallbackStill = true
            defer { isGeneratingFallbackStill = false }
            
            do {
                let stillImage = try await generateStillImage(at: time)
                self.fallbackStillImage = stillImage
                self.fallbackStillTime = time
                
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .info("Generated fallback still for time \(time, privacy: .public)s")
            } catch {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .error("Failed to generate fallback still: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    private func generateStillImage(at time: TimeInterval) async throws -> NSImage {
        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            throw ScreenshotError.ffmpegMissing
        }
        
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")
        
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }
        
        let sourceURL = videoItem.url
        var videoAccess: SecurityAccess = .none
        if !hasSecurityScope {
            if sourceURL.startAccessingSecurityScopedResource() {
                videoAccess = .direct(sourceURL)
            } else if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: sourceURL) {
                videoAccess = .bookmark(sourceURL)
            }
        }
        
        defer {
            switch videoAccess {
            case .direct(let url):
                url.stopAccessingSecurityScopedResource()
            case .bookmark(let url):
                SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: url)
            case .none:
                break
            }
        }
        
        // Build video filter to handle pixel aspect ratio, deinterlacing, and scaling
        var filterComponents: [String] = []
        
        // Always apply SAR (Sample Aspect Ratio) scaling to correct for non-square pixels
        filterComponents.append("scale=iw*sar:ih")
        
        // Check if source is interlaced and needs deinterlacing
        if let videoStream = videoItem.metadata?.videoStream,
           let fieldOrder = videoStream.fieldOrder?.lowercased(),
           fieldOrder != "progressive" && fieldOrder != "unknown" {
            // Source is interlaced, apply yadif deinterlacer
            filterComponents.append("yadif=mode=send_frame:parity=auto:deint=all")
        }
        
        // Scale to 1080p for preview
        filterComponents.append("scale='if(gt(a,1),-2,1080)':'if(gt(a,1),1080,-2)'")
        
        let arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-ss", String(format: "%.6f", time),
            "-i", sourceURL.path,
            "-frames:v", "1",
            "-vf", filterComponents.joined(separator: ","),
            "-q:v", "2",
            "-y",
            tempURL.path
        ]
        
        let ffmpegURL = URL(fileURLWithPath: ffmpegPath)
        try await runFFmpegCapture(executable: ffmpegURL, arguments: arguments)
        
        guard let image = NSImage(contentsOf: tempURL) else {
            throw ScreenshotError.conversionFailed("Could not load generated image")
        }
        
        return image
    }

    private func installLoopObserver(for item: AVPlayerItem) {
        removeLoopObserver()
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackEnded()
            }
        }
    }

    private func removeLoopObserver() {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
    }
    
    private func installTimeObserver(for player: AVPlayer) {
        removeTimeObserver()

        // Check playback position every 0.1 seconds
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverOwner = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                // Only enforce trim boundaries when looping is enabled
                guard self.videoItem.loopPlayback else { return }

                let currentTime = time.seconds
                let trimStart = self.videoItem.effectiveTrimStart
                let trimEnd = self.videoItem.effectiveTrimEnd

                // Small tolerance to avoid seeking when already at target (prevents playback freeze)
                let tolerance = 0.05

                // Enforce trim boundaries: keep playback within trimStart...trimEnd
                if currentTime < trimStart - tolerance {
                    // Significantly before trim start, seek to trim start
                    let startTime = CMTime(seconds: trimStart, preferredTimescale: 600)
                    self.player?.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
                } else if currentTime >= trimEnd - tolerance {
                    // At or past trim end, loop back to trim start
                    let startTime = CMTime(seconds: trimStart, preferredTimescale: 600)
                    self.player?.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
    }

    private func removeTimeObserver() {
        if let timeObserver {
            let owner = timeObserverOwner ?? player
            owner?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
            self.timeObserverOwner = nil
        }
    }

    private func installPlaybackTimeObserver(for player: AVPlayer) {
        removePlaybackTimeObserver()

        // Update playback time more frequently for smooth UI updates (every 0.05 seconds)
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        playbackTimeObserverOwner = player
        playbackTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let currentTime = time.seconds
                if currentTime.isFinite {
                    self.currentPlaybackTime = currentTime
                }
            }
        }
    }
    
    private func removePlaybackTimeObserver() {
        if let playbackTimeObserver {
            let owner = playbackTimeObserverOwner ?? player
            owner?.removeTimeObserver(playbackTimeObserver)
            self.playbackTimeObserver = nil
            self.playbackTimeObserverOwner = nil
        }
    }

    private func handlePlaybackEnded() {
        guard videoItem.loopPlayback, let player else { return }
        let target = CMTime(seconds: videoItem.effectiveTrimStart, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            player.play()
        }
    }

    private func applyLoopSetting() {
        player?.actionAtItemEnd = videoItem.loopPlayback ? .none : .pause
    }

    private func loadPreviewAssets(for url: URL) {
        previewAssetTask?.cancel()
        isLoadingPreviewAssets = true
        previewAssetTask = Task { [weak self] in
            guard let self else { return }
            do {
                let assets = try await PreviewAssetGenerator.shared.generateAssets(for: url)
                try Task.checkCancellation()
                self.previewAssets = assets
            } catch {
                self.previewAssets = nil
                if (error as? CancellationError) == nil {
                    Logger(subsystem: "com.aagedal.MediaConverter", category: "PreviewAssets").error("Failed to load preview assets for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            self.isLoadingPreviewAssets = false
        }
    }
    
    private func installPlayerItemStatusObserver(for playerItem: AVPlayerItem, startTime: TimeInterval) {
        removePlayerItemStatusObserver()
        
        playerItemStatusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                
                switch item.status {
                case .failed:
                    // Direct playback failed, try HLS fallback
                    Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                        .warning("Direct AVPlayer playback failed: \(item.error?.localizedDescription ?? "unknown error"). Preparing MP4 fallback preview.")
                    self.fallbackToPreview(startTime: startTime)
                    
                case .readyToPlay:
                    // Check if video tracks exist and can be decoded
                    // Some files (like APV) report ready because audio works, but video codec is unsupported
                    let asset = item.asset
                    
                    Task {
                        do {
                            let videoTracks = try await asset.loadTracks(withMediaType: .video)
                            
                            if !videoTracks.isEmpty {
                                // Check if video tracks have valid format descriptions
                                var hasValidVideoFormat = false
                                for track in videoTracks {
                                    let formatDescriptions = try await track.load(.formatDescriptions) as [CMFormatDescription]
                                    if !formatDescriptions.isEmpty {
                                        hasValidVideoFormat = true
                                        break
                                    }
                                }
                                
                                if !hasValidVideoFormat {
                                    Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                                        .warning("AVPlayer ready but video format invalid. Preparing MP4 fallback preview.")
                                    self.fallbackToPreview(startTime: startTime)
                                    return
                                }
                                
                                // Check for truly unsupported video codecs (like APV)
                                for track in videoTracks {
                                    let formatDescriptions = try await track.load(.formatDescriptions) as [CMFormatDescription]
                                    for desc in formatDescriptions {
                                        let codec = CMFormatDescriptionGetMediaSubType(desc)
                                        let codecBytes: [UInt8] = [
                                            UInt8((codec >> 24) & 0xFF),
                                            UInt8((codec >> 16) & 0xFF),
                                            UInt8((codec >> 8) & 0xFF),
                                            UInt8(codec & 0xFF)
                                        ]
                                        let codecString: String
                                        if let fourCC = String(bytes: codecBytes, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters),
                                           fourCC.count == 4 {
                                            codecString = fourCC
                                        } else {
                                            codecString = String(format: "%08X", codec)
                                        }
                                        
                                        Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                                            .debug("Video codec detected: '\(codecString)' (raw: \(codec))")
                                        
                                        // Check for unsupported codecs
                                        // APV codec variants, old/uncommon ProRes variants not supported by AVPlayer
                                        if codecString == "apv1" || codecString == "apvx" ||
                                           codecString == "apch" || codecString == "apcs" ||
                                           codecString == "apco" || codecString == "ap4x" ||
                                           codecString == "ap4h" {
                                            Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                                                .warning("AVPlayer ready but codec '\(codecString)' unsupported. Preparing MP4 fallback preview.")
                                            self.fallbackToPreview(startTime: startTime)
                                            return
                                        }
                                    }
                                }
                            }
                            
                            // Direct playback successful
                            Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                                .debug("Direct AVPlayer playback ready")
                                
                        } catch {
                            // If we can't load tracks, assume it's okay and let AVPlayer try
                            Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                                .debug("Could not verify video tracks, proceeding with playback")
                        }
                    }
                    
                case .unknown:
                    break
                    
                @unknown default:
                    break
                }
            }
        }
    }
    
    private func removePlayerItemStatusObserver() {
        if let playerItemStatusObserver {
            (playerItemStatusObserver as? NSKeyValueObservation)?.invalidate()
            self.playerItemStatusObserver = nil
        }
    }
    
    private func fallbackToPreview(startTime: TimeInterval) {
        guard !usePreviewFallback else {
            errorMessage = "Unable to play this video format"
            return
        }

        usePreviewFallback = true
        isPreparing = true
        errorMessage = nil

        let currentItem = videoItem
        
        // Use the same fingerprint-based cache directory as preview assets
        Task { @MainActor in
            do {
                let cacheDirectory = try await PreviewAssetGenerator.shared.getAssetDirectory(for: currentItem.url)
                self.mp4Session = MP4PreviewSession(sourceURL: currentItem.url, cacheDirectory: cacheDirectory)
                self.startFallbackGeneration(startTime: startTime, currentItem: currentItem)
            } catch {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .error("Failed to create cache directory for fallback preview: \(error.localizedDescription, privacy: .public)")
                self.errorMessage = "Unable to prepare preview: \(error.localizedDescription)"
                self.isPreparing = false
            }
        }
    }
    
    private func startFallbackGeneration(startTime: TimeInterval, currentItem: VideoItem) {

        preparationTask = Task { @MainActor in
            defer { 
                self.isPreparing = false
                self.isGeneratingFallbackPreview = false
            }
            
            self.isGeneratingFallbackPreview = true

            do {
                guard let session = self.mp4Session else {
                    throw MP4PreviewSession.PreviewError.outputMissing
                }

                let previewResult = try await session.generatePreview(startTime: startTime, durationLimit: 30, maxShortEdge: 480)

                try Task.checkCancellation()

                // Track the range covered by the fallback preview
                let rangeStart = previewResult.startTime
                let rangeEnd = previewResult.startTime + previewResult.duration
                self.fallbackPreviewRange = rangeStart...rangeEnd

                let asset = AVURLAsset(url: previewResult.url)
                let playerItem = AVPlayerItem(asset: asset)
                let player = AVPlayer(playerItem: playerItem)

                self.player = player

                installLoopObserver(for: playerItem)
                installTimeObserver(for: player)
                installPlaybackTimeObserver(for: player)
                applyLoopSetting()

                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .info("MP4 fallback playback ready for item \(currentItem.id, privacy: .public), preview range: \(rangeStart, privacy: .public)s - \(rangeEnd, privacy: .public)s")

            } catch is CancellationError {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .debug("MP4 fallback cancelled for item \(currentItem.id, privacy: .public)")
            } catch {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .error("MP4 fallback failed: \(error.localizedDescription, privacy: .public)")
                self.errorMessage = "Unable to play this video: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Player Container

private struct PlayerContainerView: NSViewRepresentable {
    let player: AVPlayer
    let controller: PreviewPlayerController
    let keyHandler: (String, NSEvent.ModifierFlags) -> Bool

    func makeNSView(context: Context) -> ShortcutAwarePlayerView {
        let view = ShortcutAwarePlayerView()
        view.configure(
            player: player,
            controller: controller,
            keyHandler: keyHandler
        )
        return view
    }

    func updateNSView(_ nsView: ShortcutAwarePlayerView, context: Context) {
        nsView.update(player: player, keyHandler: keyHandler)
    }
}

private final class ShortcutAwarePlayerView: AVPlayerView {
    private var keyHandler: ((String, NSEvent.ModifierFlags) -> Bool)?

    func configure(
        player: AVPlayer,
        controller: PreviewPlayerController,
        keyHandler: @escaping (String, NSEvent.ModifierFlags) -> Bool
    ) {
        self.keyHandler = keyHandler
        controlsStyle = .inline
        updatesNowPlayingInfoCenter = false
        showsFullScreenToggleButton = true
        showsFrameSteppingButtons = true
        showsSharingServiceButton = false
        showsTimecodes = true
        videoGravity = .resizeAspect
        allowsVideoFrameAnalysis = false
        self.player = player

        Task { @MainActor in
            controller.playerView = self
        }
    }

    func update(player: AVPlayer, keyHandler: @escaping (String, NSEvent.ModifierFlags) -> Bool) {
        self.keyHandler = keyHandler
        if self.player !== player {
            self.player = player
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            super.keyDown(with: event)
            return
        }

        if keyHandler?(characters, event.modifierFlags) == true {
            return
        }

        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return super.performKeyEquivalent(with: event)
        }

        if keyHandler?(characters, event.modifierFlags) == true {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
