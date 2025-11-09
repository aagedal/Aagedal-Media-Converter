// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Screenshot capture and HDR/color metadata handling for PreviewPlayerController.

import Foundation
import AppKit
import AVKit
import OSLog

extension PreviewPlayerController {
    
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

    func runFFmpegCapture(executable: URL, arguments: [String]) async throws {
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
    
    // MARK: - Fallback Still Generation
    
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
    
    // MARK: - Format Detection
    
    func screenshotParameters(for stream: VideoMetadata.VideoStream?) -> ScreenshotParameters {
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
}
