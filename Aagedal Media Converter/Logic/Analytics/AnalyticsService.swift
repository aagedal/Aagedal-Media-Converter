// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

protocol AnalyticsMediaInfoProviding: Sendable {
    func duration(for file: URL) async -> Double?
    func resolution(for file: URL) async -> (width: Int, height: Int)?
}

private struct DefaultAnalyticsMediaInfoProvider: AnalyticsMediaInfoProviding {
    func duration(for file: URL) async -> Double? {
        await SwiftExifMediaProbe.duration(for: file)
    }

    func resolution(for file: URL) async -> (width: Int, height: Int)? {
        guard SwiftExifMediaProbe.canReadVideo(file),
              let meta = try? await SwiftExifMediaProbe.readVideo(file),
              let primary = meta.videoStreams.first(where: { $0.isAttachedPic != true }),
              let width = primary.width,
              let height = primary.height else {
            return nil
        }
        return (width, height)
    }
}

/// Service for running video quality analytics using FFmpeg (VMAF, PSNR, SSIMULACRA2)
actor AnalyticsService {
    static let shared = AnalyticsService()

    private static let metricTimeout: Duration = .seconds(12 * 60 * 60)
    private static let frameExtractionTimeout: Duration = .seconds(10 * 60)
    private static let frameComparisonTimeout: Duration = .seconds(2 * 60)
    private static let mediaInfoTimeout: Duration = .seconds(15)
    private static let diagnosticCaptureLimit = 256 * 1024

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "AnalyticsService")
    private let subprocessRunner: any SubprocessRunning
    private let ffmpegPathProvider: @Sendable () -> String?
    private let ssimulacra2PathProvider: @Sendable () -> String?
    private let mediaInfoProvider: any AnalyticsMediaInfoProviding
    private let mediaInfoTimeout: Duration
    private var activeAnalysisID: UUID?
    private var currentMetricTask: Task<MetricResult, Error>?

    init(
        subprocessRunner: any SubprocessRunning = SubprocessRunner(),
        ffmpegPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.ffmpegPath },
        ssimulacra2PathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.ssimulacra2Path },
        mediaInfoProvider: any AnalyticsMediaInfoProviding = DefaultAnalyticsMediaInfoProvider(),
        mediaInfoTimeout: Duration = AnalyticsService.mediaInfoTimeout
    ) {
        self.subprocessRunner = subprocessRunner
        self.ffmpegPathProvider = ffmpegPathProvider
        self.ssimulacra2PathProvider = ssimulacra2PathProvider
        self.mediaInfoProvider = mediaInfoProvider
        self.mediaInfoTimeout = mediaInfoTimeout
    }

    /// Runs all enabled metrics sequentially for a source/encoded pair
    /// - Parameters:
    ///   - sourceFile: The original source video file
    ///   - encodedFile: The encoded output file
    ///   - enabledMetrics: Which metrics to compute
    ///   - vmafModel: VMAF model variant to use
    ///   - ssimulacra2MaxFrames: Captured frame sampling limit for this operation
    ///   - progress: Callback with (currentMetric, progress 0-1)
    /// - Returns: Array of metric results
    func runAnalytics(
        sourceFile: URL,
        encodedFile: URL,
        enabledMetrics: [QualityMetric],
        vmafModel: VMAFModel,
        ssimulacra2MaxFrames: Int = AppConstants.defaultSSIMULACRA2MaxFrames,
        progress: @escaping @Sendable (QualityMetric, Double) -> Void
    ) async throws -> [MetricResult] {
        guard !Task.isCancelled else { throw AnalyticsError.cancelled }

        currentMetricTask?.cancel()
        let analysisID = UUID()
        activeAnalysisID = analysisID
        defer {
            if activeAnalysisID == analysisID {
                activeAnalysisID = nil
                currentMetricTask = nil
            }
        }

        guard let ffmpegPath = ffmpegPathProvider() else {
            throw AnalyticsError.ffmpegNotFound
        }

        // Reject directories explicitly — `fileExists(atPath:)` alone returns true for folders,
        // which would let callers (e.g. DCP/IMF package outputs) sail past validation and
        // surface a confusing FFmpeg error instead.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceFile.path, isDirectory: &isDir), !isDir.boolValue else {
            throw AnalyticsError.sourceFileNotFound
        }
        isDir = false
        guard FileManager.default.fileExists(atPath: encodedFile.path, isDirectory: &isDir), !isDir.boolValue else {
            throw AnalyticsError.encodedFileNotFound
        }

        var results: [MetricResult] = []

        for metric in enabledMetrics {
            guard activeAnalysisID == analysisID, !Task.isCancelled else {
                throw AnalyticsError.cancelled
            }

            let metricTask = Task {
                try await self.runMetric(
                    metric,
                    ffmpegPath: ffmpegPath,
                    sourceFile: sourceFile,
                    encodedFile: encodedFile,
                    vmafModel: vmafModel,
                    ssimulacra2MaxFrames: ssimulacra2MaxFrames
                ) { metricProgress in
                    progress(metric, metricProgress)
                }
            }
            currentMetricTask = metricTask

            do {
                let result = try await withTaskCancellationHandler {
                    try await metricTask.value
                } onCancel: {
                    metricTask.cancel()
                }
                guard activeAnalysisID == analysisID, !Task.isCancelled else {
                    throw AnalyticsError.cancelled
                }
                currentMetricTask = nil
                results.append(result)
            } catch is CancellationError {
                throw AnalyticsError.cancelled
            } catch let error as AnalyticsError {
                if case .cancelled = error {
                    throw AnalyticsError.cancelled
                }
                logger.error("\(metric.displayName, privacy: .public) failed: \(error.localizedDescription, privacy: .private(mask: .hash))")
                throw error
            } catch {
                logger.error("\(metric.displayName, privacy: .public) failed: \(error.localizedDescription, privacy: .private(mask: .hash))")
                throw AnalyticsError.metricFailed(metric, error.localizedDescription)
            }
        }

        return results
    }

    /// Cancels the current analysis
    func cancelAnalysis() {
        activeAnalysisID = nil
        currentMetricTask?.cancel()
        currentMetricTask = nil
    }

    // MARK: - Single Metric Execution

    private func runMetric(
        _ metric: QualityMetric,
        ffmpegPath: String,
        sourceFile: URL,
        encodedFile: URL,
        vmafModel: VMAFModel,
        ssimulacra2MaxFrames: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MetricResult {
        logger.info("Starting \(metric.displayName, privacy: .public) analysis")

        // SSIMULACRA2 uses a separate binary (ssimulacra2_rs), not an FFmpeg filter
        if metric == .ssimulacra2 {
            return try await runSSIMULACRA2Metric(
                ffmpegPath: ffmpegPath,
                sourceFile: sourceFile,
                encodedFile: encodedFile,
                maxFrames: ssimulacra2MaxFrames,
                progress: progress
            )
        }

        // Build arguments based on metric type
        var vmafLogURL: URL? = nil
        var arguments: [String]

        switch metric {
        case .vmaf:
            let tempDir = FileManager.default.temporaryDirectory
            let logFile = tempDir.appendingPathComponent("vmaf_\(UUID().uuidString).json")
            vmafLogURL = logFile
            arguments = buildVMAFArguments(
                encodedFile: encodedFile,
                sourceFile: sourceFile,
                model: vmafModel,
                logPath: logFile
            )
        case .psnr:
            arguments = buildPSNRArguments(
                encodedFile: encodedFile,
                sourceFile: sourceFile
            )
        case .xpsnr:
            arguments = buildXPSNRArguments(
                encodedFile: encodedFile,
                sourceFile: sourceFile
            )
        case .ssimulacra2:
            throw AnalyticsError.metricFailed(.ssimulacra2, "SSIMULACRA2 uses a dedicated binary and should not reach the FFmpeg path")
        }
        arguments.insert("-nostdin", at: 0)
        defer {
            if let vmafLogURL {
                try? FileManager.default.removeItem(at: vmafLogURL)
            }
        }

        let sensitiveValues = Set(
            [ffmpegPath, sourceFile.path, encodedFile.path, vmafLogURL?.path]
                .compactMap { $0 }
        )
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: arguments,
            timeout: Self.metricTimeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: Self.diagnosticCaptureLimit,
            sensitiveValues: sensitiveValues
        )
        let progressParser = AnalyticsFFmpegProgressParser(progress: progress)
        let processResult: SubprocessResult

        do {
            processResult = try await subprocessRunner.run(request) { chunk in
                if case .standardError = chunk.stream {
                    progressParser.consume(chunk.data)
                }
            }
        } catch is CancellationError {
            throw AnalyticsError.cancelled
        } catch let error as SubprocessRunnerError {
            switch error {
            case .failedToStart(_, let underlying):
                throw AnalyticsError.metricFailed(
                    metric,
                    request.redactedDiagnostic(underlying, limit: 500)
                )
            case .timedOut:
                throw AnalyticsError.metricFailed(metric, "FFmpeg exceeded the 12-hour analytics limit")
            }
        } catch {
            throw AnalyticsError.metricFailed(
                metric,
                request.redactedDiagnostic(error.localizedDescription, limit: 500)
            )
        }
        guard !Task.isCancelled else { throw AnalyticsError.cancelled }
        progressParser.finish()

        let stderrOutput = processResult.standardErrorText
        guard processResult.succeeded else {
            let diagnostic = request.redactedDiagnostic(
                stderrOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                limit: 500
            )
            let detail = diagnostic.isEmpty ? "unknown error" : diagnostic
            throw AnalyticsError.metricFailed(
                metric,
                "FFmpeg exited \(processResult.terminationStatus): \(detail)"
            )
        }

        // Parse results
        let result: MetricResult
        switch metric {
        case .vmaf:
            guard let logURL = vmafLogURL else {
                throw AnalyticsError.parsingFailed("VMAF log file not created")
            }
            result = try parseVMAFResults(from: logURL)
        case .psnr:
            result = try parsePSNRResults(from: stderrOutput)
        case .xpsnr:
            result = try parseXPSNRResults(from: stderrOutput)
        case .ssimulacra2:
            throw AnalyticsError.parsingFailed("SSIMULACRA2 uses a dedicated binary and should not reach the FFmpeg parsing path")
        }

        progress(1.0)
        logger.info("\(metric.displayName, privacy: .public) complete: \(result.formattedScore, privacy: .public) (\(result.qualityRating, privacy: .public))")

        return result
    }

    // MARK: - FFmpeg Command Construction

    private func buildVMAFArguments(
        encodedFile: URL,
        sourceFile: URL,
        model: VMAFModel,
        logPath: URL
    ) -> [String] {
        let escapedLogPath = logPath.path.replacingOccurrences(of: ":", with: "\\:")
        let vmafOpts = "libvmaf=model=version=\(model.rawValue):log_path=\(escapedLogPath):log_fmt=json"
        // scale2ref scales source (input 1) to match encoded (input 0) dimensions
        let filter = "[1:v][0:v]scale2ref=flags=bicubic[ref][dist];[dist][ref]\(vmafOpts)"
        return [
            "-i", encodedFile.path,
            "-i", sourceFile.path,
            "-filter_complex", filter,
            "-f", "null",
            "-"
        ]
    }

    private func buildPSNRArguments(
        encodedFile: URL,
        sourceFile: URL
    ) -> [String] {
        let filter = "[1:v][0:v]scale2ref=flags=bicubic[ref][dist];[dist][ref]psnr"
        return [
            "-i", encodedFile.path,
            "-i", sourceFile.path,
            "-filter_complex", filter,
            "-f", "null",
            "-"
        ]
    }

    private func buildXPSNRArguments(
        encodedFile: URL,
        sourceFile: URL
    ) -> [String] {
        // XPSNR expects reference first, distorted second
        // scale2ref scales source (input 0) to match encoded (input 1) dimensions
        let filter = "[0:v][1:v]scale2ref=flags=bicubic[ref][dist];[ref][dist]xpsnr"
        return [
            "-i", sourceFile.path,
            "-i", encodedFile.path,
            "-lavfi", filter,
            "-f", "null",
            "-"
        ]
    }

    // MARK: - SSIMULACRA2 (Frame-Based)

    /// Runs SSIMULACRA2 analysis by extracting frames and comparing with ssimulacra2_rs binary
    private func runSSIMULACRA2Metric(
        ffmpegPath: String,
        sourceFile: URL,
        encodedFile: URL,
        maxFrames: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MetricResult {
        guard let ssimulacra2Path = ssimulacra2PathProvider() else {
            throw AnalyticsError.ssimulacra2NotFound
        }

        let duration = try await getVideoDuration(for: encodedFile)
        let resolution = try await getVideoResolution(for: sourceFile)

        let frameCount = max(1, maxFrames > 0 ? maxFrames : AppConstants.defaultSSIMULACRA2MaxFrames)
        let actualFrameCount = min(frameCount, max(1, Int(duration)))
        let interval = duration / Double(actualFrameCount)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssimulacra2_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        var scores: [Double] = []

        for i in 0..<actualFrameCount {
            guard !Task.isCancelled else { throw AnalyticsError.cancelled }

            let timestamp = Double(i) * interval
            let sourceFrame = tempDir.appendingPathComponent("source_\(String(format: "%04d", i)).png")
            let encodedFrame = tempDir.appendingPathComponent("encoded_\(String(format: "%04d", i)).png")

            // Extract frames from both videos
            try await extractFrame(ffmpegPath: ffmpegPath, input: sourceFile, timestamp: timestamp, output: sourceFrame, scaleFilter: nil)
            try await extractFrame(ffmpegPath: ffmpegPath, input: encodedFile, timestamp: timestamp, output: encodedFrame, scaleFilter: "scale=\(resolution.width):\(resolution.height)")

            // Compare with ssimulacra2_rs
            let score = try await compareFrames(ssimulacra2Path: ssimulacra2Path, source: sourceFrame, encoded: encodedFrame)
            guard !Task.isCancelled else { throw AnalyticsError.cancelled }
            scores.append(score)

            // Clean up frames immediately to save disk space
            try? FileManager.default.removeItem(at: sourceFrame)
            try? FileManager.default.removeItem(at: encodedFrame)

            let currentProgress = Double(i + 1) / Double(actualFrameCount)
            progress(min(currentProgress, 0.99))
        }

        guard !scores.isEmpty else {
            throw AnalyticsError.parsingFailed("No SSIMULACRA2 scores were computed")
        }

        let mean = scores.reduce(0, +) / Double(scores.count)
        progress(1.0)

        logger.info("SSIMULACRA2 complete: \(String(format: "%.1f", mean), privacy: .public) (sampled \(scores.count) frames)")

        return MetricResult(
            metric: .ssimulacra2,
            overallScore: mean,
            min: scores.min(),
            max: scores.max(),
            unit: "score",
            channelScores: nil
        )
    }

    /// Extracts a single frame from a video at the given timestamp
    private func extractFrame(ffmpegPath: String, input: URL, timestamp: Double, output: URL, scaleFilter: String?) async throws {
        var args = [
            "-nostdin",
            "-ss", String(format: "%.3f", timestamp),
            "-i", input.path
        ]
        if let scaleFilter = scaleFilter {
            args += ["-vf", scaleFilter]
        }
        args += [
            "-frames:v", "1",
            "-update", "1",
            "-y",
            output.path
        ]
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: args,
            timeout: Self.frameExtractionTimeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 32 * 1024,
            sensitiveValues: [ffmpegPath, input.path, output.path]
        )

        do {
            let result = try await subprocessRunner.run(request)
            guard result.succeeded else {
                let diagnostic = request.redactedDiagnostic(
                    result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines),
                    limit: 300
                )
                let suffix = diagnostic.isEmpty ? "" : ": \(diagnostic)"
                throw AnalyticsError.metricFailed(
                    .ssimulacra2,
                    "Failed to extract frame at \(String(format: "%.1f", timestamp))s (exit \(result.terminationStatus))\(suffix)"
                )
            }
        } catch is CancellationError {
            throw AnalyticsError.cancelled
        } catch let error as SubprocessRunnerError {
            switch error {
            case .failedToStart(_, let underlying):
                throw AnalyticsError.metricFailed(.ssimulacra2, request.redactedDiagnostic(underlying, limit: 300))
            case .timedOut:
                throw AnalyticsError.metricFailed(.ssimulacra2, "Frame extraction exceeded the 10-minute limit")
            }
        }
    }

    /// Compares two image files using ssimulacra2_rs and returns the score
    private func compareFrames(ssimulacra2Path: String, source: URL, encoded: URL) async throws -> Double {
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ssimulacra2Path),
            arguments: ["image", source.path, encoded.path],
            timeout: Self.frameComparisonTimeout,
            standardOutputCaptureLimit: 4 * 1024,
            standardErrorCaptureLimit: 32 * 1024,
            sensitiveValues: [ssimulacra2Path, source.path, encoded.path]
        )
        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(request)
        } catch is CancellationError {
            throw AnalyticsError.cancelled
        } catch let error as SubprocessRunnerError {
            switch error {
            case .failedToStart(_, let underlying):
                throw AnalyticsError.metricFailed(.ssimulacra2, request.redactedDiagnostic(underlying, limit: 300))
            case .timedOut:
                throw AnalyticsError.metricFailed(.ssimulacra2, "Frame comparison exceeded the 2-minute limit")
            }
        }

        guard result.succeeded else {
            let diagnostic = request.redactedDiagnostic(
                result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines),
                limit: 300
            )
            let detail = diagnostic.isEmpty ? "unknown error" : diagnostic
            throw AnalyticsError.metricFailed(
                .ssimulacra2,
                "ssimulacra2_rs exited \(result.terminationStatus): \(detail)"
            )
        }

        let output = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)

        // Output format: "Score: 97.53500802"
        let scoreString = output.hasPrefix("Score:") ? output.dropFirst(6).trimmingCharacters(in: .whitespaces) : output
        guard let score = Double(scoreString) else {
            throw AnalyticsError.parsingFailed("Could not parse ssimulacra2_rs output: \(output)")
        }

        return score
    }

    /// Gets video duration in seconds via SwiftMediaMetadata (AVFoundation fallback).
    private func getVideoDuration(for file: URL) async throws -> Double {
        let provider = mediaInfoProvider
        let duration: Double?
        do {
            duration = try await NonJoiningTaskDeadline.run(timeout: mediaInfoTimeout) {
                await provider.duration(for: file)
            }
        } catch is CancellationError {
            throw AnalyticsError.cancelled
        } catch NonJoiningTaskDeadlineError.timedOut {
            throw AnalyticsError.metricFailed(
                .ssimulacra2,
                "Media duration discovery exceeded the 15-second limit"
            )
        } catch {
            throw AnalyticsError.metricFailed(.ssimulacra2, "Could not determine video duration")
        }

        guard let duration, duration > 0 else {
            throw AnalyticsError.metricFailed(.ssimulacra2, "Could not determine video duration")
        }
        return duration
    }

    /// Gets video resolution (width x height) via SwiftMediaMetadata.
    private func getVideoResolution(for file: URL) async throws -> (width: Int, height: Int) {
        let provider = mediaInfoProvider
        let resolution: (width: Int, height: Int)?
        do {
            resolution = try await NonJoiningTaskDeadline.run(timeout: mediaInfoTimeout) {
                await provider.resolution(for: file)
            }
        } catch is CancellationError {
            throw AnalyticsError.cancelled
        } catch NonJoiningTaskDeadlineError.timedOut {
            throw AnalyticsError.metricFailed(
                .ssimulacra2,
                "Media resolution discovery exceeded the 15-second limit"
            )
        } catch {
            throw AnalyticsError.metricFailed(.ssimulacra2, "Could not determine video resolution")
        }

        guard let resolution else {
            throw AnalyticsError.metricFailed(.ssimulacra2, "Could not determine video resolution")
        }
        return resolution
    }

    // MARK: - Result Parsing

    private func parseVMAFResults(from jsonURL: URL) throws -> MetricResult {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw AnalyticsError.parsingFailed("VMAF log file not found")
        }

        let data = try Data(contentsOf: jsonURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnalyticsError.parsingFailed("Invalid VMAF JSON")
        }

        // Navigate: pooled_metrics -> vmaf -> mean/min/max
        guard let pooledMetrics = json["pooled_metrics"] as? [String: Any],
              let vmafMetrics = pooledMetrics["vmaf"] as? [String: Any],
              let mean = vmafMetrics["mean"] as? Double else {
            throw AnalyticsError.parsingFailed("Could not extract VMAF scores from JSON")
        }

        let min = vmafMetrics["min"] as? Double
        let max = vmafMetrics["max"] as? Double

        return MetricResult(
            metric: .vmaf,
            overallScore: mean,
            min: min,
            max: max,
            unit: "score",
            channelScores: nil
        )
    }

    private func parsePSNRResults(from stderrOutput: String) throws -> MetricResult {
        // Parse: [Parsed_psnr_0 @ ...] PSNR y:38.12 u:42.34 v:43.56 average:39.01 min:25.67 max:48.90
        let pattern = #"PSNR\s+y:([\d.]+)\s+u:([\d.]+)\s+v:([\d.]+)\s+average:([\d.]+)\s+min:([\d.]+)\s+max:([\d.]+)"#

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: stderrOutput, range: NSRange(stderrOutput.startIndex..., in: stderrOutput)) else {
            throw AnalyticsError.parsingFailed("Could not find PSNR summary in FFmpeg output")
        }

        func extractDouble(_ index: Int) -> Double? {
            guard let range = Range(match.range(at: index), in: stderrOutput) else { return nil }
            return Double(stderrOutput[range])
        }

        guard let y = extractDouble(1),
              let u = extractDouble(2),
              let v = extractDouble(3),
              let average = extractDouble(4),
              let min = extractDouble(5),
              let max = extractDouble(6) else {
            throw AnalyticsError.parsingFailed("Could not parse PSNR values")
        }

        return MetricResult(
            metric: .psnr,
            overallScore: average,
            min: min,
            max: max,
            unit: "dB",
            channelScores: ["Y": y, "U": u, "V": v]
        )
    }

    private func parseXPSNRResults(from stderrOutput: String) throws -> MetricResult {
        // Parse: [Parsed_xpsnr_1 @ 0x...] XPSNR  y: 35.0515  u: 49.0707  v: 50.7158  (minimum: 35.0515)
        let pattern = #"XPSNR\s+y:\s*([\d.]+)\s+u:\s*([\d.]+)\s+v:\s*([\d.]+)\s+\(minimum:\s*([\d.]+)\)"#

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: stderrOutput, range: NSRange(stderrOutput.startIndex..., in: stderrOutput)) else {
            throw AnalyticsError.parsingFailed("Could not find XPSNR summary in FFmpeg output")
        }

        func extractDouble(_ index: Int) -> Double? {
            guard let range = Range(match.range(at: index), in: stderrOutput) else { return nil }
            return Double(stderrOutput[range])
        }

        guard let y = extractDouble(1),
              let u = extractDouble(2),
              let v = extractDouble(3),
              let minimum = extractDouble(4) else {
            throw AnalyticsError.parsingFailed("Could not parse XPSNR values")
        }

        // Weighted XPSNR: (6*Y + U + V) / 8 (luma-weighted average)
        let weighted = (6.0 * y + u + v) / 8.0

        return MetricResult(
            metric: .xpsnr,
            overallScore: weighted,
            min: minimum,
            max: nil,
            unit: "dB",
            channelScores: ["Y": y, "U": u, "V": v]
        )
    }

}

/// Serializes FFmpeg's arbitrary stderr chunks into complete CR/LF records before
/// interpreting duration and timestamp progress.
private final class AnalyticsFFmpegProgressParser: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (Double) -> Void
    private var duration: Double?
    private var lastReportedProgress = 0.0
    private var pendingText = ""

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            pendingText += String(decoding: data, as: UTF8.self)
            while let separator = pendingText.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                let record = String(pendingText[..<separator])
                pendingText.removeSubrange(...separator)
                parse(record)
            }
            if pendingText.count > 8 * 1024 {
                pendingText = String(pendingText.suffix(8 * 1024))
            }
        }
    }

    func finish() {
        lock.withLock {
            guard !pendingText.isEmpty else { return }
            let record = pendingText
            pendingText = ""
            parse(record)
        }
    }

    private func parse(_ text: String) {
        if duration == nil {
            duration = ParsingUtils.parseDuration(from: text)
        }
        guard let (fraction, _) = ParsingUtils.parseTimeProgress(
            from: text,
            totalDuration: duration
        ) else { return }

        let cappedFraction = min(fraction, 0.99)
        guard cappedFraction - lastReportedProgress >= 0.01 else { return }
        lastReportedProgress = cappedFraction
        progress(cappedFraction)
    }
}
