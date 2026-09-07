// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Screenshot capture and HDR/color metadata handling for PreviewPlayerController.

import Foundation
import AppKit
import AVKit
import OSLog
import ImageIO
import Darwin

/// Screenshot format options for still image capture
enum ScreenshotFormat: String, CaseIterable, Identifiable, Codable {
    case jpeg = "JPEG"
    case jpegXL = "JPEG XL"
    case avif = "AVIF"
    case png = "PNG"
    case tiff = "TIFF"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .jpegXL: return "jxl"
        case .avif: return "avif"
        case .png: return "png"
        case .tiff: return "tiff"
        }
    }

    var supportsAlpha: Bool {
        switch self {
        case .jpeg, .avif: return false
        case .jpegXL, .png, .tiff: return true
        }
    }
}

/// Alpha channel handling preference for screenshots
enum ScreenshotAlphaHandling: String, CaseIterable, Identifiable, Codable {
    case auto = "auto"
    case useSelectedFormat = "useSelectedFormat"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto (Use PNG or JPEG XL)"
        case .useSelectedFormat: return "Use selected format (discard alpha if unsupported)"
        }
    }
}

/// Bounded, cancellable FFmpeg boundary for still-image capture.
struct ScreenshotCaptureSubprocess: Sendable {
    static let timeout: Duration = .seconds(30 * 60)
    static let diagnosticCaptureLimit = 256 * 1024

    private let subprocessRunner: any SubprocessRunning

    init(subprocessRunner: any SubprocessRunning = SubprocessRunner()) {
        self.subprocessRunner = subprocessRunner
    }

    func run(
        executable: URL,
        arguments: [String],
        sourceURL: URL,
        outputURL: URL
    ) async throws {
        try Task.checkCancellation()

        let privatePaths = Set(arguments.filter { $0.hasPrefix("/") })
            .union([executable.path, sourceURL.path, outputURL.path])
        let request = SubprocessRequest(
            executableURL: executable,
            arguments: arguments,
            timeout: Self.timeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: Self.diagnosticCaptureLimit,
            sensitiveValues: privatePaths
        )

        do {
            let result = try await subprocessRunner.run(request)
            guard result.succeeded else {
                try? FileManager.default.removeItem(at: outputURL)
                let diagnostic = request.redactedDiagnostic(result.standardErrorText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let message = diagnostic.isEmpty
                    ? "FFmpeg exited with status \(result.terminationStatus)."
                    : diagnostic
                throw PreviewPlayerController.ScreenshotError.processFailed(message)
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        } catch SubprocessRunnerError.timedOut {
            try? FileManager.default.removeItem(at: outputURL)
            throw PreviewPlayerController.ScreenshotError.processFailed(
                "Screenshot capture timed out after 30 minutes."
            )
        } catch let error as PreviewPlayerController.ScreenshotError {
            throw error
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw PreviewPlayerController.ScreenshotError.processFailed(
                request.redactedDiagnostic(error.localizedDescription)
            )
        }

        let outputSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard outputSize > 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw PreviewPlayerController.ScreenshotError.outputUnavailable
        }
    }
}

/// Publishes a completed staging file without ever replacing an existing screenshot.
enum ScreenshotOutputPublisher {
    static func publish(stagedURL: URL, preferredURL: URL) throws -> URL {
        let baseName = preferredURL.deletingPathExtension().lastPathComponent
        let fileExtension = preferredURL.pathExtension
        let directory = preferredURL.deletingLastPathComponent()

        for attempt in 0..<1_000 {
            let candidate: URL
            if attempt == 0 {
                candidate = preferredURL
            } else {
                candidate = directory
                    .appendingPathComponent("\(baseName)_\(attempt)")
                    .appendingPathExtension(fileExtension)
            }

            let renameResult = stagedURL.withUnsafeFileSystemRepresentation { sourcePath in
                candidate.withUnsafeFileSystemRepresentation { destinationPath in
                    renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
                }
            }
            if renameResult == 0 {
                return candidate
            }

            let errorNumber = errno
            guard errorNumber == EEXIST else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorNumber))
            }
        }

        throw PreviewPlayerController.ScreenshotError.conversionFailed(
            "Unable to reserve a unique screenshot filename."
        )
    }
}

extension PreviewPlayerController {

    // MARK: - Screenshot UI State
    @MainActor
    var lastScreenshotURL: URL? {
        get { _lastScreenshotURL }
        set { _lastScreenshotURL = newValue }
    }

    // Backing storage to avoid requiring changes in the main controller file
    private static var _lastScreenshotURLStorage = [ObjectIdentifier: URL]()
    private var _lastScreenshotURL: URL? {
        get { Self._lastScreenshotURLStorage[ObjectIdentifier(self)] }
        set { Self._lastScreenshotURLStorage[ObjectIdentifier(self)] = newValue }
    }

    @MainActor
    var showScreenshotOverlay: Bool {
        get { _showScreenshotOverlay ?? false }
        set { _showScreenshotOverlay = newValue }
    }

    private static var _showScreenshotOverlayStorage = [ObjectIdentifier: Bool]()
    private var _showScreenshotOverlay: Bool? {
        get { Self._showScreenshotOverlayStorage[ObjectIdentifier(self)] }
        set { Self._showScreenshotOverlayStorage[ObjectIdentifier(self)] = newValue }
    }

    /// Duration the transient overlay is visible after a successful capture.
    private var screenshotOverlayDuration: TimeInterval { 1.6 }
    
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
    
    enum SecurityAccess {
        case none
        case direct(URL)
        case bookmark(URL)
    }

    struct ScreenshotParameters {
        let fileExtension: String
        let codecArguments: [String]
        let pixelFormat: String?
    }

    static let screenshotDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
    
    // MARK: - Screenshot Capture
    
    func captureScreenshot(to directory: URL) async throws -> URL {
        guard !isCapturingScreenshot else {
            throw ScreenshotError.captureInProgress
        }

        guard player != nil || mpvPlayer != nil else {
            throw ScreenshotError.videoUnavailable
        }

        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else {
            throw ScreenshotError.ffmpegMissing
        }

        isCapturingScreenshot = true
        defer { isCapturingScreenshot = false }

        let captureTime = getCurrentTime() ?? videoItem.effectiveTrimStart

        let parameters = screenshotParameters(for: videoItem.metadata?.primaryVideoStream)
        let sanitizedBaseName = FileNameProcessor.processFileName(videoItem.url.deletingPathExtension().lastPathComponent)
        let timestamp = Self.screenshotDateFormatter.string(from: Date())
        let timeComponent = String(format: "%.3f", captureTime).replacingOccurrences(of: ".", with: "-")
        let fileName = "\(sanitizedBaseName)_\(timestamp)_t\(timeComponent).\(parameters.fileExtension)"
        let outputDirectory = directory

        let fileManager = FileManager.default
        var directoryAccess: SecurityAccess = .none
        if outputDirectory.startAccessingSecurityScopedResource() {
            directoryAccess = .direct(outputDirectory)
        } else if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: outputDirectory) {
            directoryAccess = .bookmark(outputDirectory)
        }

        var videoAccess: SecurityAccess = .none
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

        do {
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            if case .none = directoryAccess {
                throw ScreenshotError.securityScopeDenied
            }
            throw error
        }

        if case .none = directoryAccess {
            let reachable = (try? outputDirectory.checkResourceIsReachable()) ?? false
            guard reachable else {
                throw ScreenshotError.securityScopeDenied
            }
        }

        if case .none = primaryAccess {
            let sourceURL = videoItem.url
            if sourceURL.startAccessingSecurityScopedResource() {
                videoAccess = .direct(sourceURL)
            } else if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: sourceURL) {
                videoAccess = .bookmark(sourceURL)
            }
        }

        let preferredOutputURL = outputDirectory.appendingPathComponent(fileName)
        let stagingOutputURL = outputDirectory
            .appendingPathComponent(".screenshot-\(UUID().uuidString)")
            .appendingPathExtension(parameters.fileExtension)
        defer { try? fileManager.removeItem(at: stagingOutputURL) }

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
        if let videoStream = videoItem.metadata?.primaryVideoStream,
           let fieldOrder = videoStream.fieldOrder?.lowercased(),
           fieldOrder != "progressive" && fieldOrder != "unknown" {
            // Source is interlaced, apply bwdif deinterlacer for still capture
            filterComponents.append("bwdif=mode=send_frame:parity=auto:deint=all")
        }
        
        // Combine filters if we have any
        if !filterComponents.isEmpty {
            arguments += ["-vf", filterComponents.joined(separator: ",")]
        }

        if let pixelFormat = parameters.pixelFormat {
            arguments += ["-pix_fmt", pixelFormat]
        }

        appendColorArguments(from: videoItem.metadata?.primaryVideoStream, to: &arguments)

        arguments += parameters.codecArguments

        arguments += [
            "-y",
            stagingOutputURL.path
        ]

        do {
            try await runFFmpegCapture(
                executable: ffmpegURL,
                arguments: arguments,
                outputURL: stagingOutputURL
            )
        } catch let error as ScreenshotError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ScreenshotError.processFailed(error.localizedDescription)
        }

        let outputURL: URL
        do {
            outputURL = try ScreenshotOutputPublisher.publish(
                stagedURL: stagingOutputURL,
                preferredURL: preferredOutputURL
            )
        } catch let error as ScreenshotError {
            throw error
        } catch {
            throw ScreenshotError.conversionFailed("Unable to save the screenshot.")
        }

        Logger(subsystem: "com.aagedal.MediaConverter", category: "Screenshots").info("Saved screenshot to \(outputURL.path, privacy: .private)")
        lastScreenshotURL = outputURL
        showScreenshotConfirmationOverlay()

        return outputURL
    }

    func runFFmpegCapture(executable: URL, arguments: [String], outputURL: URL) async throws {
        let operationID = UUID()
        let captureTask = Task { [screenshotCaptureSubprocess, sourceURL = videoItem.url] in
            try await screenshotCaptureSubprocess.run(
                executable: executable,
                arguments: arguments,
                sourceURL: sourceURL,
                outputURL: outputURL
            )
        }
        screenshotCaptureOperationID = operationID
        screenshotCaptureTask = captureTask
        defer {
            if screenshotCaptureOperationID == operationID {
                screenshotCaptureOperationID = nil
                screenshotCaptureTask = nil
            }
        }

        try await withTaskCancellationHandler {
            try await captureTask.value
        } onCancel: {
            captureTask.cancel()
        }

        try Task.checkCancellation()
        guard screenshotCaptureOperationID == operationID else {
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        }
    }
    
    // MARK: - UI Helpers
    @MainActor
    func showScreenshotConfirmationOverlay() {
        self.showScreenshotOverlay = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(self.screenshotOverlayDuration))
            if Task.isCancelled { return }
            self.showScreenshotOverlay = false
        }
    }

    // MARK: - Format Detection

    func screenshotParameters(for stream: VideoMetadata.VideoStream?) -> ScreenshotParameters {
        let bitDepth = stream?.bitDepth ?? 8
        let hasAlpha = stream?.hasAlpha ?? false

        Logger(subsystem: "com.aagedal.MediaConverter", category: "Screenshots")
            .debug("Screenshot format detection - bitDepth: \(bitDepth), hasAlpha: \(hasAlpha)")

        // Get user-selected format based on bit depth
        let formatRawValue: String
        if bitDepth > 10 {
            formatRawValue = UserDefaults.standard.string(forKey: AppConstants.screenshotHighBitFormatKey) ?? AppConstants.defaultScreenshotFormat
        } else if bitDepth == 10 {
            formatRawValue = UserDefaults.standard.string(forKey: AppConstants.screenshot10BitFormatKey) ?? AppConstants.defaultScreenshotFormat
        } else {
            formatRawValue = UserDefaults.standard.string(forKey: AppConstants.screenshot8BitFormatKey) ?? AppConstants.defaultScreenshotFormat
        }

        guard let format = ScreenshotFormat(rawValue: formatRawValue) else {
            // Fallback to JPEG XL if invalid
            return formatParameters(for: .jpegXL, bitDepth: bitDepth, hasAlpha: hasAlpha)
        }

        // Handle alpha channel based on preference
        if hasAlpha {
            let alphaHandling = UserDefaults.standard.string(forKey: AppConstants.screenshotAlphaHandlingKey) ?? AppConstants.defaultScreenshotAlphaHandling

            if alphaHandling == ScreenshotAlphaHandling.auto.rawValue {
                // Auto: Use PNG or JPEG XL if selected, otherwise fallback to PNG
                if format.supportsAlpha {
                    return formatParameters(for: format, bitDepth: bitDepth, hasAlpha: true)
                } else {
                    // Fallback to PNG for alpha support
                    return formatParameters(for: .png, bitDepth: bitDepth, hasAlpha: true)
                }
            } else {
                // useSelectedFormat: Use selected format, discard alpha if not supported
                return formatParameters(for: format, bitDepth: bitDepth, hasAlpha: format.supportsAlpha)
            }
        }

        return formatParameters(for: format, bitDepth: bitDepth, hasAlpha: false)
    }

    private func formatParameters(for format: ScreenshotFormat, bitDepth: Int, hasAlpha: Bool) -> ScreenshotParameters {
        switch format {
        case .jpeg:
            // JPEG does not support alpha
            return ScreenshotParameters(
                fileExtension: "jpg",
                codecArguments: ["-c:v", "mjpeg", "-q:v", "1"],
                pixelFormat: "yuvj444p"
            )

        case .jpegXL:
            if bitDepth > 8 {
                return ScreenshotParameters(
                    fileExtension: "jxl",
                    codecArguments: ["-c:v", "libjxl", "-distance", "0.5", "-effort", "7"],
                    pixelFormat: hasAlpha ? "rgba64le" : "rgb48le"
                )
            } else {
                return ScreenshotParameters(
                    fileExtension: "jxl",
                    codecArguments: ["-c:v", "libjxl", "-distance", "0.5", "-effort", "7"],
                    pixelFormat: hasAlpha ? "rgba" : "rgb24"
                )
            }

        case .avif:
            // AVIF does not support alpha in this encoder
            if bitDepth > 8 {
                return ScreenshotParameters(
                    fileExtension: "avif",
                    codecArguments: [
                        "-c:v", "libsvtav1",
                        "-preset", "12",
                        "-crf", "35",
                        "-svtav1-params", "fast-decode=1:enable-overlays=0"
                    ],
                    pixelFormat: bitDepth > 10 ? "yuv444p12le" : "yuv420p10le"
                )
            } else {
                return ScreenshotParameters(
                    fileExtension: "avif",
                    codecArguments: [
                        "-c:v", "libsvtav1",
                        "-preset", "12",
                        "-crf", "35",
                        "-svtav1-params", "fast-decode=1:enable-overlays=0"
                    ],
                    pixelFormat: "yuv420p"
                )
            }

        case .png:
            if bitDepth > 8 {
                return ScreenshotParameters(
                    fileExtension: "png",
                    codecArguments: ["-c:v", "png", "-compression_level", "1"],
                    pixelFormat: hasAlpha ? "rgba64be" : "rgb48be"
                )
            } else {
                return ScreenshotParameters(
                    fileExtension: "png",
                    codecArguments: ["-c:v", "png", "-compression_level", "1"],
                    pixelFormat: hasAlpha ? "rgba" : "rgb24"
                )
            }

        case .tiff:
            if bitDepth > 8 {
                return ScreenshotParameters(
                    fileExtension: "tiff",
                    codecArguments: ["-c:v", "tiff"],
                    pixelFormat: hasAlpha ? "rgba64le" : "rgb48le"
                )
            } else {
                return ScreenshotParameters(
                    fileExtension: "tiff",
                    codecArguments: ["-c:v", "tiff"],
                    pixelFormat: hasAlpha ? "rgba" : "rgb24"
                )
            }
        }
    }
    
    // MARK: - Color Metadata Helpers
    
    func isMissingColorMetadata(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return true
        }

        let normalized = value.lowercased()
        return normalized == "unknown" || normalized == "unspecified" || normalized == "na"
    }

    func appendColorArguments(from stream: VideoMetadata.VideoStream?, to arguments: inout [String]) {
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
    
    // MARK: - Last Screenshot Utilities
    /// Reveals the last screenshot in Finder, if available.
    func revealLastScreenshotInFinder() {
        guard let url = lastScreenshotURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Provides an NSItemProvider for dragging the last screenshot to other apps.
    @MainActor
    func lastScreenshotDragItemProvider() -> NSItemProvider? {
        guard let url = lastScreenshotURL else { return nil }
        let provider = NSItemProvider(object: url as NSURL)
        provider.suggestedName = url.lastPathComponent
        return provider
    }
}
