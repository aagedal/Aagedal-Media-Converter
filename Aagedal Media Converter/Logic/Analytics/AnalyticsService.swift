// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

protocol AnalyticsMediaInfoProviding: Sendable {
    func duration(for file: URL) async -> Double?
    func resolution(for file: URL) async -> (width: Int, height: Int)?
    func bitDepth(for file: URL) async -> Int?
    func timing(for file: URL) async -> AnalyticsTiming?
    func pixelFormat(for file: URL, ffmpegPath: String) async -> String?
}

extension AnalyticsMediaInfoProviding {
    func bitDepth(for file: URL) async -> Int? { nil }
    func timing(for file: URL) async -> AnalyticsTiming? { nil }
    func pixelFormat(for file: URL, ffmpegPath: String) async -> String? { nil }
}

private struct DefaultAnalyticsMediaInfoProvider: AnalyticsMediaInfoProviding {
    let subprocessRunner: any SubprocessRunning

    func timing(for file: URL) async -> AnalyticsTiming? {
        if file.pathExtension.lowercased() == "ivf", let header = IVFHeaderParser.parse(url: file) {
            return AnalyticsTiming(duration: header.durationSeconds,
                frameRate: header.fpsNumerator > 0 && header.fpsDenominator > 0
                    ? Double(header.fpsNumerator) / Double(header.fpsDenominator) : nil,
                frameCount: header.frameCount > 0 ? header.frameCount : nil)
        }
        guard let meta = try? await SwiftExifMediaProbe.readVideo(file),
              let stream = meta.videoStreams.first(where: { $0.isAttachedPic != true }) else { return nil }
        let video = VideoMetadataService.mapVideoStream(stream)
        let duration: Double?
        if let streamDuration = video.duration { duration = streamDuration }
        else { duration = await SwiftExifMediaProbe.duration(for: file) }
        return AnalyticsTiming(duration: duration, frameRate: video.frameRate?.value, frameCount: stream.frameCount)
    }

    func pixelFormat(for file: URL, ffmpegPath: String) async -> String? {
        let metadataFormat = try? await NonJoiningTaskDeadline.run(timeout: .seconds(15)) {
            guard let meta = try? await SwiftExifMediaProbe.readVideo(file),
                  let stream = meta.videoStreams.first(where: { $0.isAttachedPic != true }) else { return nil as String? }
            return VideoMetadataService.mapVideoStream(stream).pixelFormat
        }
        if let metadataFormat { return metadataFormat }
        guard !Task.isCancelled else { return nil }
        // Container metadata may omit FFV1's pixel layout. Decode one frame with
        // the captured FFmpeg and read its stream description instead of guessing.
        let request = SubprocessRequest(executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: ["-nostdin", "-hide_banner", "-i", file.path, "-map", "0:v:0",
                        "-frames:v", "1", "-an", "-f", "null", "-"],
            timeout: .seconds(15), standardOutputCaptureLimit: 0, standardErrorCaptureLimit: 32 * 1024,
            sensitiveValues: [ffmpegPath, file.path])
        guard let result = try? await subprocessRunner.run(request), result.succeeded,
              let regex = try? NSRegularExpression(pattern: "Video:[^\\n]*?,\\s*([a-z][a-z0-9_]+)(?:\\(|,|\\s)"),
              let match = regex.firstMatch(in: result.standardErrorText, range: NSRange(result.standardErrorText.startIndex..., in: result.standardErrorText)),
              let range = Range(match.range(at: 1), in: result.standardErrorText) else { return nil }
        return String(result.standardErrorText[range])
    }

    func bitDepth(for file: URL) async -> Int? {
        guard SwiftExifMediaProbe.canReadVideo(file),
              let meta = try? await SwiftExifMediaProbe.readVideo(file),
              let primary = meta.videoStreams.first(where: { $0.isAttachedPic != true }) else {
            return nil
        }
        return VideoMetadataService.mapVideoStream(primary).bitDepth
    }

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

/// Owns scoped input access and any lossless inspection intermediate.
/// Views retain the lease for the whole playback session, including source/encoded switches.
final class AnalyticsPreviewAsset: Sendable {
    let url: URL
    let originalURL: URL
    private let access: SecurityScopedAccess
    private let scratch: URL

    init(url: URL, originalURL: URL, access: SecurityScopedAccess, scratch: URL) {
        self.url = url
        self.originalURL = originalURL
        self.access = access
        self.scratch = scratch
    }

    deinit {
        try? FileManager.default.removeItem(at: scratch)
        SecurityScopedBookmarkManager.shared.stopAccessing(access)
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
    private let avmdecPathProvider: @Sendable () -> String?
    private let ssimulacra2PathProvider: @Sendable () -> String?
    private let mediaInfoProvider: any AnalyticsMediaInfoProviding
    private let mediaInfoTimeout: Duration
    private var activeAnalysisID: UUID?
    private var activeAnalysisRunID: UUID?
    private var analysisTasks: [UUID: (operationID: UUID, task: Task<[MetricResult], Error>)] = [:]
    @TaskLocal private static var runningAnalysisRunID: UUID?

    init(
        subprocessRunner: any SubprocessRunning = SubprocessRunner(),
        ffmpegPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.ffmpegPath },
        ssimulacra2PathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.ssimulacra2Path },
        avmdecPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.avmdecPath },
        mediaInfoProvider: (any AnalyticsMediaInfoProviding)? = nil,
        mediaInfoTimeout: Duration = AnalyticsService.mediaInfoTimeout
    ) {
        self.avmdecPathProvider = avmdecPathProvider
        self.subprocessRunner = subprocessRunner
        self.ffmpegPathProvider = ffmpegPathProvider
        self.ssimulacra2PathProvider = ssimulacra2PathProvider
        self.mediaInfoProvider = mediaInfoProvider ?? DefaultAnalyticsMediaInfoProvider(subprocessRunner: subprocessRunner)
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
        sourceRange: AnalyticsSourceRange = AnalyticsSourceRange(),
        enabledMetrics: [QualityMetric],
        vmafModel: VMAFModel,
        ssimulacra2MaxFrames: Int = AppConstants.defaultSSIMULACRA2MaxFrames,
        comparisonResolution: AnalyticsComparisonResolution = .encoded,
        operationID: UUID = UUID(),
        progress: @escaping @Sendable (QualityMetric, Double) -> Void
    ) async throws -> [MetricResult] {
        guard !Task.isCancelled else { throw AnalyticsError.cancelled }
        guard sourceRange.isValid else { throw AnalyticsError.parsingFailed("Invalid source interval for quality analysis") }

        for metricTask in analysisTasks.values { metricTask.task.cancel() }
        let analysisID = operationID
        let runID = UUID()
        activeAnalysisID = analysisID
        activeAnalysisRunID = runID
        defer {
            analysisTasks.removeValue(forKey: runID)
            if activeAnalysisRunID == runID {
                activeAnalysisID = nil
                activeAnalysisRunID = nil
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

        let task = Task {
            try await Self.$runningAnalysisRunID.withValue(runID) {
                try await self.executeAnalysis(
                    sourceFile: sourceFile, encodedFile: encodedFile, sourceRange: sourceRange,
                    enabledMetrics: enabledMetrics, vmafModel: vmafModel,
                    maxFrames: ssimulacra2MaxFrames, resolution: comparisonResolution,
                    ffmpegPath: ffmpegPath, progress: progress
                )
            }
        }
        analysisTasks[runID] = (analysisID, task)
        do {
            let results = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard activeAnalysisRunID == runID, !Task.isCancelled else { throw AnalyticsError.cancelled }
            return results
        } catch is CancellationError {
            throw AnalyticsError.cancelled
        }
    }

    /// Preparation and cleanup live inside the registered task, so cancellation drains
    /// decoder work and removes intermediates before returning to callers.
    private func executeAnalysis(
        sourceFile: URL, encodedFile: URL, sourceRange: AnalyticsSourceRange,
        enabledMetrics: [QualityMetric], vmafModel: VMAFModel, maxFrames: Int,
        resolution: AnalyticsComparisonResolution, ffmpegPath: String,
        progress: @escaping @Sendable (QualityMetric, Double) -> Void
    ) async throws -> [MetricResult] {
        guard !enabledMetrics.isEmpty else { return [] }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("analytics_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let source = try await prepareInput(sourceFile, output: scratch.appendingPathComponent("source.mkv"), ffmpegPath: ffmpegPath)
        let encoded = sourceFile == encodedFile ? source : try await prepareInput(encodedFile, output: scratch.appendingPathComponent("encoded.mkv"), ffmpegPath: ffmpegPath)
        let provider = mediaInfoProvider
        let timings = try? await NonJoiningTaskDeadline.run(timeout: mediaInfoTimeout) {
            let sourceTiming = await provider.timing(for: sourceFile)
            let encodedTiming = await provider.timing(for: encodedFile)
            return (sourceTiming, encodedTiming)
        }
        try Task.checkCancellation()
        let dimensions: (width: Int, height: Int)?
        do {
            dimensions = try await getVideoResolution(for: resolution == .source ? source : encoded)
        } catch {
            try Task.checkCancellation()
            // FFmpeg can resolve dimensions itself; frame extraction needs known geometry.
            if enabledMetrics.contains(.ssimulacra2) { throw error }
            dimensions = nil
        }
        var warnings = AnalyticsComparison.timingWarnings(source: timings?.0, encoded: timings?.1, range: sourceRange)
        if source != sourceFile || encoded != encodedFile {
            warnings.append("AV2 analysis reconstructs timestamps at the decoder’s reported frame rate.")
        }
        let comparison = AnalyticsComparison(
            resolution: resolution, width: dimensions?.width, height: dimensions?.height,
            scaling: "bicubic", sourceRange: sourceRange, vmafModel: nil,
            sourceTiming: timings?.0, encodedTiming: timings?.1,
            warnings: warnings
        )
        var results: [MetricResult] = []
        for metric in enabledMetrics {
            try Task.checkCancellation()
            var result = try await runMetric(metric, ffmpegPath: ffmpegPath, sourceFile: source, encodedFile: encoded,
                                             sourceRange: sourceRange, vmafModel: vmafModel,
                                             ssimulacra2MaxFrames: maxFrames, comparisonResolution: resolution, comparisonDimensions: dimensions) {
                progress(metric, $0)
            }
            try Task.checkCancellation()
            let sampling = result.comparison
            result.comparison = AnalyticsComparison(
                resolution: comparison.resolution, width: comparison.width ?? sampling?.width, height: comparison.height ?? sampling?.height,
                scaling: comparison.scaling, sourceRange: sourceRange,
                vmafModel: metric == .vmaf ? vmafModel : nil,
                sampleCount: sampling?.sampleCount, sampleTimestamps: sampling?.sampleTimestamps,
                sourceVideoStart: sampling?.sourceVideoStart, encodedVideoStart: sampling?.encodedVideoStart,
                samplingPolicy: sampling?.samplingPolicy, comparedDuration: sampling?.comparedDuration,
                pixelProcessing: sampling?.pixelProcessing ?? (metric == .vmaf && vmafModel.usesV1Features
                    ? "YUV 4:2:0 10-bit before scaling" : metric == .xpsnr
                        ? "Native color planes; XPSNR excludes alpha" : "Native pixel format"),
                sourceTiming: comparison.sourceTiming, encodedTiming: comparison.encodedTiming,
                warnings: comparison.warnings + (sampling?.warnings ?? [])
            )
            results.append(result)
        }
        return results
    }

    /// Independent of analysis ownership: opening/closing an inspector never cancels a metric run.
    func prepareQualityPreview(_ input: URL) async throws -> AnalyticsPreviewAsset {
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: input)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("quality_preview_\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            guard let ffmpeg = ffmpegPathProvider() else { throw AnalyticsError.ffmpegNotFound }
            let url = try await prepareInput(input, output: scratch.appendingPathComponent("preview.mkv"), ffmpegPath: ffmpeg)
            try Task.checkCancellation()
            return AnalyticsPreviewAsset(url: url, originalURL: input, access: access, scratch: scratch)
        } catch {
            try? FileManager.default.removeItem(at: scratch)
            SecurityScopedBookmarkManager.shared.stopAccessing(access)
            throw error
        }
    }

    private func prepareInput(_ input: URL, output: URL, ffmpegPath: String) async throws -> URL {
        try Task.checkCancellation()
        let ext = input.pathExtension.lowercased()
        let isAV2 = (ext == "ivf" && (IVFHeaderParser.parse(url: input)?.isAV2 ?? false))
            || (["mkv", "webm"].contains(ext) && FFMPEGConverter.matroskaContainsAV2(url: input))
        guard isAV2 else { return input }
        guard let decoder = avmdecPathProvider() else {
            throw AnalyticsError.parsingFailed("The bundled AV2 decoder is missing. Reinstall the app to restore it.")
        }
        let sensitive: Set<String> = [input.path, output.path, decoder, ffmpegPath]
        let producer = SubprocessRequest(executableURL: URL(fileURLWithPath: decoder),
            arguments: [input.path, "-o", "-"], timeout: Self.metricTimeout,
            standardOutputCaptureLimit: 0, standardErrorCaptureLimit: Self.diagnosticCaptureLimit,
            sensitiveValues: sensitive)
        // FFV1 preserves native Y4M bit depth/chroma, while avoiding an uncompressed
        // whole-video scratch file. Decode once, reuse for every metric and sample.
        let consumer = SubprocessRequest(executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: ["-y", "-nostdin", "-hide_banner", "-f", "yuv4mpegpipe", "-i", "pipe:0",
                        "-map", "0:v:0", "-an", "-c:v", "ffv1", "-level", "3", "-fps_mode", "passthrough", output.path],
            timeout: Self.metricTimeout, standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: Self.diagnosticCaptureLimit, sensitiveValues: sensitive)
        let result: SubprocessPipelineResult
        do {
            result = try await subprocessRunner.runPipeline(producer: producer, consumer: consumer, drainProducer: true)
        } catch is CancellationError {
            throw AnalyticsError.cancelled
        } catch {
            throw AnalyticsError.parsingFailed("AV2 decoding failed. " + consumer.redactedDiagnostic(error.localizedDescription, limit: 500))
        }
        try Task.checkCancellation()
        guard case .completed(let decoded) = result.producer, decoded.succeeded, result.consumer.succeeded else {
            let detail: String
            if case .completed(let decoded) = result.producer, !decoded.succeeded {
                detail = producer.redactedDiagnostic(decoded.standardErrorText, limit: 500)
            } else { detail = consumer.redactedDiagnostic(result.consumer.standardErrorText, limit: 500) }
            throw AnalyticsError.parsingFailed("AV2 decoding failed. \(detail)")
        }
        return output
    }

    /// Cancels the captured analyses and waits for their helpers and scratch cleanup to drain.
    func cancelAnalysis(operationID: UUID? = nil) async {
        let tasks = analysisTasks.filter { operationID == nil || $0.value.operationID == operationID }
        if operationID == nil || activeAnalysisID == operationID {
            activeAnalysisID = nil
            activeAnalysisRunID = nil
        }
        for metricTask in tasks.values { metricTask.task.cancel() }
        // Superseded tasks stay registered until their own run unwinds. A targeted
        // cancellation can still join an old reader without touching a replacement.
        // A helper that requests cancellation must not join helpers from inside
        // their execution, where a callback can otherwise introduce a wait cycle.
        guard Self.runningAnalysisRunID == nil else { return }
        for metricTask in tasks.values {
            _ = await metricTask.task.result
        }
    }

    // MARK: - Single Metric Execution

    private func runMetric(
        _ metric: QualityMetric,
        ffmpegPath: String,
        sourceFile: URL,
        encodedFile: URL,
        sourceRange: AnalyticsSourceRange,
        vmafModel: VMAFModel,
        ssimulacra2MaxFrames: Int,
        comparisonResolution: AnalyticsComparisonResolution,
        comparisonDimensions: (width: Int, height: Int)?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MetricResult {
        logger.info("Starting \(metric.displayName, privacy: .public) analysis")

        // SSIMULACRA2 uses a separate binary (ssimulacra2_rs), not an FFmpeg filter
        if metric == .ssimulacra2 {
            return try await runSSIMULACRA2Metric(
                ffmpegPath: ffmpegPath,
                sourceFile: sourceFile,
                encodedFile: encodedFile,
                sourceRange: sourceRange,
                maxFrames: ssimulacra2MaxFrames,
                comparisonResolution: comparisonResolution,
                comparisonDimensions: comparisonDimensions,
                progress: progress
            )
        }

        // Build arguments based on metric type
        var vmafLogURL: URL? = nil
        var frameLogURL: URL? = nil
        var arguments: [String]

        switch metric {
        case .vmaf:
            let tempDir = FileManager.default.temporaryDirectory
            let logFile = tempDir.appendingPathComponent("vmaf_\(UUID().uuidString).json")
            vmafLogURL = logFile
            let encodedBitDepth: Int?
            if vmafModel.usesV1Features {
                let provider = mediaInfoProvider
                do {
                    encodedBitDepth = try await NonJoiningTaskDeadline.run(timeout: mediaInfoTimeout) {
                        await provider.bitDepth(for: encodedFile)
                    }
                } catch is CancellationError {
                    throw AnalyticsError.cancelled
                } catch {
                    // Metadata is optional; CAMBI can infer depth from its input.
                    encodedBitDepth = nil
                }
            } else {
                encodedBitDepth = nil
            }
            arguments = buildVMAFArguments(
                encodedFile: encodedFile,
                sourceFile: sourceFile,
                sourceRange: sourceRange,
                model: vmafModel,
                logPath: logFile,
                encodedBitDepth: encodedBitDepth,
                comparisonResolution: comparisonResolution
            )
        case .psnr:
            frameLogURL = FileManager.default.temporaryDirectory.appendingPathComponent("psnr_\(UUID().uuidString).log")
            arguments = buildPSNRArguments(
                encodedFile: encodedFile,
                sourceFile: sourceFile,
                sourceRange: sourceRange,
                comparisonResolution: comparisonResolution,
                statsURL: frameLogURL
            )
        case .xpsnr:
            frameLogURL = FileManager.default.temporaryDirectory.appendingPathComponent("xpsnr_\(UUID().uuidString).log")
            arguments = buildXPSNRArguments(
                encodedFile: encodedFile,
                sourceFile: sourceFile,
                sourceRange: sourceRange,
                comparisonResolution: comparisonResolution,
                statsURL: frameLogURL
            )
        case .ssimulacra2:
            throw AnalyticsError.metricFailed(.ssimulacra2, "SSIMULACRA2 uses a dedicated binary and should not reach the FFmpeg path")
        }
        if let filterIndex = arguments.firstIndex(where: { $0 == "-filter_complex" || $0 == "-lavfi" }), filterIndex + 1 < arguments.count {
            arguments[filterIndex + 1] += ",showinfo=checksum=0"
        }
        arguments.insert("-nostdin", at: 0)
        defer {
            for file in [vmafLogURL, frameLogURL].compactMap({ $0 }) { try? FileManager.default.removeItem(at: file) }
        }

        let sensitiveValues = Set(
            [ffmpegPath, sourceFile.path, encodedFile.path, vmafLogURL?.path, frameLogURL?.path]
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
        var result: MetricResult
        switch metric {
        case .vmaf:
            guard let logURL = vmafLogURL else {
                throw AnalyticsError.parsingFailed("VMAF log file not created")
            }
            result = try parseVMAFResults(from: logURL, timestamps: progressParser.frameTimestamps)
        case .psnr:
            result = try Self.parsePSNRResults(from: stderrOutput)
        case .xpsnr:
            result = try Self.parseXPSNRResults(from: stderrOutput)
        case .ssimulacra2:
            throw AnalyticsError.parsingFailed("SSIMULACRA2 uses a dedicated binary and should not reach the FFmpeg parsing path")
        }

        if let frameLogURL, let log = try? String(contentsOf: frameLogURL, encoding: .utf8) {
            result.samples = Self.parseFrameScores(log, metric: metric, timestamps: progressParser.frameTimestamps)
        }
        progress(1.0)
        logger.info("\(metric.displayName, privacy: .public) complete: \(result.formattedScore, privacy: .public) (\(result.qualityRating, privacy: .public))")

        return result
    }

    // MARK: - FFmpeg Command Construction

    static func scalingFilter(_ resolution: AnalyticsComparisonResolution) -> String {
        resolution == .encoded
            ? "[src][enc]scale2ref=flags=bicubic[ref][dist]"
            : "[enc][src]scale2ref=flags=bicubic[dist][ref]"
    }

    func buildVMAFArguments(
        encodedFile: URL,
        sourceFile: URL,
        sourceRange: AnalyticsSourceRange,
        model: VMAFModel,
        logPath: URL,
        encodedBitDepth: Int? = nil,
        comparisonResolution: AnalyticsComparisonResolution = .encoded
    ) -> [String] {
        let escapedLogPath = logPath.path.replacingOccurrences(of: ":", with: "\\:")
        var modelOptions = "version=\(model.rawValue)"
        if model.usesV1Features, let encodedBitDepth, (8...16).contains(encodedBitDepth) {
            // Escape the model option separator through the outer filter parser.
            modelOptions += "\\\\:cambi.enc_bitdepth=\(encodedBitDepth)"
        }
        let vmafOpts = "libvmaf=model=\(modelOptions):log_path=\(escapedLogPath):log_fmt=json"
        let filter: String
        if model.usesV1Features {
            // Promote both inputs before scaling to preserve banding information.
            filter = "[1:v]setpts=PTS-STARTPTS,format=yuv420p10le[src];[0:v]setpts=PTS-STARTPTS,format=yuv420p10le[enc];\(Self.scalingFilter(comparisonResolution));[dist][ref]\(vmafOpts):shortest=1"
        } else {
            // Preserve the legacy preprocessing for comparisons with earlier scores.
            filter = "[1:v]setpts=PTS-STARTPTS[src];[0:v]setpts=PTS-STARTPTS[enc];\(Self.scalingFilter(comparisonResolution));[dist][ref]\(vmafOpts):shortest=1"
        }
        return [
            "-i", encodedFile.path
        ] + sourceRange.inputArguments + [
            "-i", sourceFile.path,
            "-filter_complex", filter,
            "-an", "-f", "null",
            "-"
        ]
    }

    private func buildPSNRArguments(
        encodedFile: URL,
        sourceFile: URL,
        sourceRange: AnalyticsSourceRange,
        comparisonResolution: AnalyticsComparisonResolution,
        statsURL: URL? = nil
    ) -> [String] {
        let stats = statsURL.map { "stats_file=\($0.path.replacingOccurrences(of: ":", with: "\\:")):" } ?? ""
        let filter = "[1:v]setpts=PTS-STARTPTS[src];[0:v]setpts=PTS-STARTPTS[enc];\(Self.scalingFilter(comparisonResolution));[dist][ref]psnr=\(stats)shortest=1"
        return [
            "-i", encodedFile.path
        ] + sourceRange.inputArguments + [
            "-i", sourceFile.path,
            "-filter_complex", filter,
            "-an", "-f", "null",
            "-"
        ]
    }

    private func buildXPSNRArguments(
        encodedFile: URL,
        sourceFile: URL,
        sourceRange: AnalyticsSourceRange,
        comparisonResolution: AnalyticsComparisonResolution,
        statsURL: URL? = nil
    ) -> [String] {
        // XPSNR expects reference first, distorted second
        // scale2ref scales source (input 0) to match encoded (input 1) dimensions
        let stats = statsURL.map { "stats_file=\($0.path.replacingOccurrences(of: ":", with: "\\:")):" } ?? ""
        let filter = "[0:v]setpts=PTS-STARTPTS[src];[1:v]setpts=PTS-STARTPTS[enc];\(Self.scalingFilter(comparisonResolution));[ref][dist]xpsnr=\(stats)shortest=1"
        return sourceRange.inputArguments + [
            "-i", sourceFile.path,
            "-i", encodedFile.path,
            "-lavfi", filter,
            "-an", "-f", "null",
            "-"
        ]
    }

    // MARK: - SSIMULACRA2 (Frame-Based)

    /// Runs SSIMULACRA2 analysis by extracting frames and comparing with ssimulacra2_rs binary
    private func runSSIMULACRA2Metric(
        ffmpegPath: String,
        sourceFile: URL,
        encodedFile: URL,
        sourceRange: AnalyticsSourceRange,
        maxFrames: Int,
        comparisonResolution: AnalyticsComparisonResolution,
        comparisonDimensions: (width: Int, height: Int)?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MetricResult {
        guard let ssimulacra2Path = ssimulacra2PathProvider() else {
            throw AnalyticsError.ssimulacra2NotFound
        }

        let encodedDuration = try await getVideoDuration(for: encodedFile)
        let sourceDuration = try await getVideoDuration(for: sourceFile)
        let duration = min(encodedDuration, sourceRange.duration ?? encodedDuration, max(0, sourceDuration - sourceRange.start))
        guard duration.isFinite, duration > 0 else {
            throw AnalyticsError.parsingFailed("Source interval and encoded video have no overlapping duration")
        }
        let resolution: (width: Int, height: Int)
        if let comparisonDimensions { resolution = comparisonDimensions }
        else { resolution = try await getVideoResolution(for: comparisonResolution == .source ? sourceFile : encodedFile) }

        let provider = mediaInfoProvider
        // Pixel discovery may launch a bounded helper; join it on cancellation before
        // releasing scratch files, just like metric extraction and AV2 decoding.
        let sourceFormat = await provider.pixelFormat(for: sourceFile, ffmpegPath: ffmpegPath)
        try Task.checkCancellation()
        let encodedFormat = await provider.pixelFormat(for: encodedFile, ffmpegPath: ffmpegPath)
        try Task.checkCancellation()
        let sourceScale = Self.frameScaleFilter(width: resolution.width, height: resolution.height, pixelFormat: sourceFormat)
        let encodedScale = Self.frameScaleFilter(width: resolution.width, height: resolution.height, pixelFormat: encodedFormat)
        let frameCount = max(1, maxFrames > 0 ? maxFrames : AppConstants.defaultSSIMULACRA2MaxFrames)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssimulacra2_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }

        // Decode once to discover actual presentation times, including VFR gaps. The
        // on-disk index keeps memory independent of program length.
        let sourceIndex = try await decodedFrameIndex(ffmpegPath: ffmpegPath, input: sourceFile,
            output: tempDir.appendingPathComponent("source.index"), duration: sourceDuration) { progress(min(0.1, $0 * 0.1)) }
        progress(0.1)
        let encodedIndex = sourceFile == encodedFile ? sourceIndex : try await decodedFrameIndex(
            ffmpegPath: ffmpegPath, input: encodedFile, output: tempDir.appendingPathComponent("encoded.index"), duration: encodedDuration) { progress(0.1 + min(0.1, $0 * 0.1)) }
        progress(0.2)
        var sourceFirst = sourceIndex.lowerBound(seconds: sourceRange.start)
        if sourceRange.start > 0 {
            // Input seeking rounds to the demuxer's native timebase. Observe that
            // actual first frame rather than imposing a different nanosecond trim.
            let trimmed = try await decodedFrameIndex(ffmpegPath: ffmpegPath, input: sourceFile,
                output: tempDir.appendingPathComponent("trim.index"), duration: sourceDuration,
                firstFrameAfter: sourceRange.start) { _ in }
            sourceFirst = sourceIndex.lowerBound(seconds: trimmed.seconds(at: 0))
            guard sourceFirst < sourceIndex.count, sourceIndex.pts(at: sourceFirst) == trimmed.pts(at: 0) else {
                throw AnalyticsError.parsingFailed("Could not verify the first decoded frame of the source trim")
            }
        }
        guard sourceFirst < sourceIndex.count else {
            throw AnalyticsError.parsingFailed("No source video frames in the selected interval")
        }
        let sourceStart = sourceIndex.seconds(at: sourceFirst)
        let encodedStart = encodedIndex.seconds(at: 0)
        let overlap = min(max(0, (sourceRange.end ?? sourceIndex.endSeconds) - sourceStart),
            max(0, sourceIndex.endSeconds - sourceStart), max(0, encodedIndex.endSeconds - encodedStart))
        let eligibleEnd = encodedIndex.lowerBound(seconds: encodedStart + overlap)
        guard eligibleEnd > 0, overlap > 0 else {
            throw AnalyticsError.parsingFailed("No overlapping decoded video frames")
        }
        let sourceEnd = sourceIndex.lowerBound(seconds: min(sourceRange.end ?? sourceIndex.endSeconds, sourceIndex.endSeconds))
        let actualFrameCount = min(frameCount, eligibleEnd)
        var samples: [QualitySample] = []
        for i in 0..<actualFrameCount {
            try Task.checkCancellation()
            let ordinal = actualFrameCount == 1 ? 0 : Int((Double(i) * Double(eligibleEnd - 1) / Double(actualFrameCount - 1)).rounded())
            let seconds = encodedIndex.seconds(at: ordinal) - encodedStart
            // Sample-and-hold: the reference frame visible at this output time.
            var target = sourceStart + seconds
            let next = sourceIndex.lowerBound(seconds: target)
            let previous = max(sourceFirst, min(sourceEnd - 1, next - 1))
            let nearest = next < sourceEnd && abs(sourceIndex.seconds(at: next) - target) < abs(sourceIndex.seconds(at: previous) - target) ? next : previous
            // A coarser output timebase can round an otherwise identical frame
            // just before its reference PTS. Absorb only that measured uncertainty.
            let tolerance = encodedIndex.timestampTick / 2 + 0.000000001
            if abs(sourceIndex.seconds(at: nearest) - target) <= tolerance { target = sourceIndex.seconds(at: nearest) }
            var sourceOrdinal = min(sourceEnd - 1, max(sourceFirst, sourceIndex.upperBound(seconds: target) - 1))
            let firstAtTarget = sourceIndex.lowerBound(seconds: target)
            if firstAtTarget <= sourceOrdinal, firstAtTarget < sourceIndex.count,
               abs(sourceIndex.seconds(at: firstAtTarget) - target) < 0.0000000005 {
                let occurrence = ordinal - encodedIndex.lowerBound(seconds: encodedIndex.seconds(at: ordinal))
                sourceOrdinal = min(sourceOrdinal, firstAtTarget + occurrence)
            }
            let sourceFrame = try await extractIndexedFrame(ffmpegPath: ffmpegPath, input: sourceFile,
                index: sourceIndex, ordinal: sourceOrdinal, directory: tempDir, prefix: "source", scaleFilter: sourceScale)
            let encodedFrame = try await extractIndexedFrame(ffmpegPath: ffmpegPath, input: encodedFile,
                index: encodedIndex, ordinal: ordinal, directory: tempDir, prefix: "encoded", scaleFilter: encodedScale)
            let score = try await compareFrames(ssimulacra2Path: ssimulacra2Path, source: sourceFrame, encoded: encodedFrame)
            try Task.checkCancellation()
            samples.append(QualitySample(frame: ordinal, seconds: seconds, score: score,
                framePair: QualityFramePair(sourceFrame: sourceOrdinal, sourceSeconds: sourceIndex.seconds(at: sourceOrdinal),
                    encodedFrame: ordinal, encodedSeconds: encodedIndex.seconds(at: ordinal))))
            try FileManager.default.removeItem(at: sourceFrame)
            try FileManager.default.removeItem(at: encodedFrame)
            progress(min(0.2 + 0.8 * Double(i + 1) / Double(actualFrameCount), 0.99))
        }
        let scores = samples.map(\.score)

        guard !scores.isEmpty else {
            throw AnalyticsError.parsingFailed("No SSIMULACRA2 scores were computed")
        }

        let mean = scores.reduce(0, +) / Double(scores.count)
        guard mean.isFinite else { throw AnalyticsError.parsingFailed("Nonfinite SSIMULACRA2 average") }
        progress(1.0)

        logger.info("SSIMULACRA2 complete: \(String(format: "%.1f", mean), privacy: .public) (sampled \(scores.count) frames)")

        return MetricResult(
            metric: .ssimulacra2,
            overallScore: mean,
            min: scores.min(),
            max: scores.max(),
            unit: "score",
            channelScores: nil,
            comparison: AnalyticsComparison(
                resolution: comparisonResolution, width: resolution.width, height: resolution.height,
                scaling: "bicubic", sourceRange: sourceRange, vmafModel: nil,
                sampleCount: scores.count, sampleTimestamps: samples.map(\.seconds),
                sourceVideoStart: sourceStart, encodedVideoStart: encodedStart,
                samplingPolicy: "Evenly spaced decoded frame ordinals; reference sample-and-hold with output timebase rounding tolerance and matching duplicate occurrence; verified FFmpeg input trim", comparedDuration: overlap,
                pixelProcessing: "Resize before 16-bit RGB conversion (source: \(sourceFormat ?? "auto"), encoded: \(encodedFormat ?? "auto"))",
                sourceTiming: nil, encodedTiming: nil,
                warnings: sourceFormat == nil || encodedFormat == nil
                    ? ["Native pixel format could not be verified; FFmpeg selected the resize/conversion format."] : []
            ),
            samples: samples
        )
    }

    /// Keep resizing in the native pixel format. Otherwise filter negotiation can
    /// combine YUV resizing with RGB conversion and use different chroma resampling.
    private static func frameScaleFilter(width: Int, height: Int, pixelFormat: String?) -> String {
        var filter = "scale=\(width):\(height):flags=bicubic"
        if let pixelFormat, !pixelFormat.isEmpty,
           pixelFormat.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) {
            filter += ",format=\(pixelFormat)"
        }
        return filter
    }

    private func decodedFrameIndex(ffmpegPath: String, input: URL, output: URL, duration: Double,
        firstFrameAfter: Double? = nil, progress: @escaping @Sendable (Double) -> Void) async throws -> DecodedQualityFrameIndex {
        let collector = try DecodedQualityFrameCollector(url: output, duration: duration, progress: progress)
        var arguments = ["-hide_banner", "-nostdin", "-nostats", "-xerror", "-copyts", "-start_at_zero"]
        if let firstFrameAfter { arguments += ["-ss", String(format: "%.6f", firstFrameAfter)] }
        arguments += ["-i", input.path, "-map", "0:v:0", "-an", "-vf", "showinfo@amc_native=checksum=0,settb=1/1000000000,showinfo@amc_index=checksum=0"]
        if firstFrameAfter != nil { arguments += ["-frames:v", "1"] }
        arguments += ["-fps_mode", "passthrough", "-f", "null", "-"]
        let request = SubprocessRequest(executableURL: URL(fileURLWithPath: ffmpegPath), arguments: arguments,
            timeout: Self.metricTimeout, standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 32 * 1024, sensitiveValues: [ffmpegPath, input.path, output.path])
        let result = try await subprocessRunner.run(request) { chunk in
            if case .standardError = chunk.stream { collector.consume(chunk.data) }
        }
        try Task.checkCancellation()
        guard result.succeeded else {
            throw AnalyticsError.metricFailed(.ssimulacra2, "Decoded frame discovery failed: " + request.redactedDiagnostic(result.standardErrorText, limit: 300))
        }
        return try collector.finish()
    }

    /// Verify the timestamp embedded by the PNG muxer. Seeking is an optimization;
    /// ordinal decoding is the authority for duplicate PTS and unseekable inputs.
    private func extractIndexedFrame(ffmpegPath: String, input: URL, index: DecodedQualityFrameIndex,
        ordinal: Int, directory: URL, prefix: String, scaleFilter: String) async throws -> URL {
        let pts = index.pts(at: ordinal)
        let pattern = directory.appendingPathComponent("\(prefix)-%d.png")
        let expected = directory.appendingPathComponent("\(prefix)-\(pts).png")
        let duplicate = (ordinal > 0 && index.pts(at: ordinal - 1) == pts)
            || (ordinal + 1 < index.count && index.pts(at: ordinal + 1) == pts)
        for useOrdinal in duplicate ? [true] : [false, true] {
            try Task.checkCancellation()
            var args = ["-hide_banner", "-nostdin", "-xerror", "-copyts", "-start_at_zero"]
            if !useOrdinal && pts > 0 {
                // Seek before the frame, never after a rounded fractional timestamp.
                let microseconds = max(0, pts / 1000 - 2)
                args += ["-ss", String(format: "%.6f", Double(microseconds) / 1_000_000)]
            }
            args += ["-i", input.path, "-map", "0:v:0", "-an", "-vf",
                (useOrdinal ? "select=eq(n\\,\(ordinal))," : "") + scaleFilter + ",settb=1/1000000000",
                "-enc_time_base", "filter", "-fps_mode", "passthrough", "-frames:v", "1",
                "-pix_fmt", "rgb48be", "-frame_pts", "1", "-y", pattern.path]
            let request = SubprocessRequest(executableURL: URL(fileURLWithPath: ffmpegPath), arguments: args,
                timeout: Self.frameExtractionTimeout, standardOutputCaptureLimit: 0,
                standardErrorCaptureLimit: 32 * 1024, sensitiveValues: [ffmpegPath, input.path, pattern.path, directory.path])
            let result = try await subprocessRunner.run(request)
            try Task.checkCancellation()
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(prefix + "-") && $0.pathExtension == "png" }
            if result.succeeded, files.count == 1, files.first?.lastPathComponent == expected.lastPathComponent { return expected }
            for file in files { try? FileManager.default.removeItem(at: file) }
            if useOrdinal {
                throw AnalyticsError.metricFailed(.ssimulacra2, "Could not verify decoded frame \(ordinal): " + request.redactedDiagnostic(result.standardErrorText, limit: 300))
            }
        }
        throw AnalyticsError.parsingFailed("No verified video frame was extracted")
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
            try Task.checkCancellation()
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
        guard let score = Double(scoreString), score.isFinite else {
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

    private func parseVMAFResults(from jsonURL: URL, timestamps: [Int: Double] = [:]) throws -> MetricResult {
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
            channelScores: nil,
            samples: (json["frames"] as? [[String: Any]] ?? []).compactMap { frame in
                guard let index = frame["frameNum"] as? Int, let seconds = timestamps[index],
                      let metrics = frame["metrics"] as? [String: Any], let score = metrics["vmaf"] as? Double,
                      score.isFinite else { return nil }
                return QualitySample(frame: index, seconds: seconds, score: score)
            }
        )
    }

    private static let scoreFieldRegex = try! NSRegularExpression(pattern: #"\b([a-z_]+):\s*([^\s()]+)"#)
    private static let scoreFrameIndexRegex = try! NSRegularExpression(pattern: #"^n:\s*(\d+)\b"#)

    /// The PSNR/XPSNR stats index is one-based; showinfo's output frame index is zero-based.
    static func parseFrameScores(_ log: String, metric: QualityMetric, timestamps: [Int: Double]) -> [QualitySample] {
        guard metric == .psnr || metric == .xpsnr else { return [] }
        return log.split(whereSeparator: \.isNewline).compactMap { line in
            let text = String(line)
            guard let match = scoreFrameIndexRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text), let number = Int(text[range]), number > 0,
                  let seconds = timestamps[number - 1], seconds.isFinite, seconds >= 0 else { return nil }
            let score: Double
            if metric == .psnr {
                guard let value = scoreFields(in: text)["psnr_avg"] else { return nil }
                score = value
            } else {
                guard let channels = componentScores(in: text) else { return nil }
                // Report the worst color plane, as recommended for XPSNR.
                // Averaging logarithmic scores lets one perfect channel conceal
                // finite distortion in every other channel.
                score = channels.values.min()!
            }
            guard !score.isNaN, score != -.infinity else { return nil }
            return QualitySample(frame: number - 1, seconds: seconds, score: score)
        }
    }

    /// Parse named fields, preserving positive infinity for exact matches. A
    /// malformed/nonfinite field cannot silently disappear from a channel set.
    private static func scoreFields(in text: String) -> [String: Double] {
        var fields: [String: Double] = [:]
        for match in scoreFieldRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let keyRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { continue }
            let key = String(text[keyRange])
            let value = Double(text[valueRange]) ?? .nan
            if fields[key] != nil { fields[key] = .nan }
            else { fields[key] = value }
        }
        return fields
    }

    private static func componentScores(in text: String) -> [String: Double]? {
        let fields = scoreFields(in: text)
        let components = fields.filter { ["y", "u", "v", "r", "g", "b", "a"].contains($0.key) }
        let keys = Set(components.keys)
        guard [Set(["y"]), Set(["y", "a"]), Set(["y", "u", "v"]), Set(["y", "u", "v", "a"]),
               Set(["r", "g", "b"]), Set(["r", "g", "b", "a"])].contains(keys),
              components.values.allSatisfy({ !$0.isNaN && $0 != -.infinity }) else { return nil }
        return Dictionary(uniqueKeysWithValues: components.map { ($0.key.uppercased(), $0.value) })
    }

    static func parsePSNRResults(from stderrOutput: String) throws -> MetricResult {
        guard let line = stderrOutput.split(whereSeparator: \.isNewline).last(where: { $0.contains("PSNR ") && !$0.contains("XPSNR ") }),
              let channels = componentScores(in: String(line)) else {
            throw AnalyticsError.parsingFailed("Could not find PSNR summary in FFmpeg output")
        }
        let fields = scoreFields(in: String(line))
        guard let average = fields["average"], let minimum = fields["min"], let maximum = fields["max"],
              [average, minimum, maximum].allSatisfy({ !$0.isNaN && $0 != -.infinity }),
              minimum <= average, average <= maximum else {
            throw AnalyticsError.parsingFailed("Could not parse PSNR values")
        }
        return MetricResult(metric: .psnr, overallScore: average, min: minimum, max: maximum,
                            unit: "dB", channelScores: channels, scoreAggregation: "pooled_mse_all_components")
    }

    static func parseXPSNRResults(from stderrOutput: String) throws -> MetricResult {
        guard let line = stderrOutput.split(whereSeparator: \.isNewline).last(where: { $0.contains("XPSNR ") }),
              let channels = componentScores(in: String(line)), let minimum = channels.values.min() else {
            throw AnalyticsError.parsingFailed("Could not find XPSNR summary in FFmpeg output")
        }
        if let reported = scoreFields(in: String(line))["minimum"], reported != minimum {
            throw AnalyticsError.parsingFailed("Inconsistent XPSNR channel minimum")
        }
        // FFmpeg's minimum is across whole-program channel averages, not a
        // temporal minimum. Keep it as the overall score and leave frame extrema
        // to the timeline, instead of labelling a channel average as a frame min.
        return MetricResult(metric: .xpsnr, overallScore: minimum, min: nil, max: nil,
                            unit: "dB", channelScores: channels, scoreAggregation: "minimum_channel_average")
    }

}


/// Measures one audio presentation from one complete file. The measurement is made
/// on the joined PCM before null output encoding; graph samples are not averaged
/// to obtain the gated, whole-program integrated value.
actor LoudnessAnalysisService {
    static let shared = LoudnessAnalysisService()

    private let runner: any SubprocessRunning
    private let ffmpegPathProvider: @Sendable () -> String?

    init(
        runner: any SubprocessRunning = SubprocessRunner(),
        ffmpegPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.ffmpegPath }
    ) {
        self.runner = runner
        self.ffmpegPathProvider = ffmpegPathProvider
    }

    func analyze(file: URL, presentation: LoudnessPresentation) async throws -> LoudnessResults {
        try Task.checkCancellation()
        guard let ffmpegPath = ffmpegPathProvider() else { throw AnalyticsError.ffmpegNotFound }
        guard !presentation.streamIndices.isEmpty,
              Set(presentation.streamIndices).count == presentation.streamIndices.count,
              presentation.streamIndices.allSatisfy({ $0 >= 0 }) else {
            throw AnalyticsError.parsingFailed("Invalid loudness track grouping")
        }
        if case .surround51(let indices) = presentation, indices.count != 6 {
            throw AnalyticsError.parsingFailed("A 5.1 grouping requires exactly six mono tracks")
        }

        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: file)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }

        // Validate original timestamps before reframing can conceal gaps or
        // amerge can truncate unequal tracks. Use the same injected runner so
        // batch limits and cancellation cover preflight as well as measurement.
        let timing = try await AudioPeakAnalysisService(runner: runner, ffmpegPathProvider: { ffmpegPath })
            .validateGroupedTracks(file: file, presentation: presentation)
        let outputTiming = timing.map { _ in GroupedPeakTimingCollector(trackCount: 1, requireMono: false) }
        let graph = Self.filterGraph(for: presentation)
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: ["-hide_banner", "-nostdin", "-nostats", "-xerror", "-progress", "pipe:1", "-i", file.path,
                        "-filter_complex", graph, "-map", "[metered]", "-f", "null", "-"],
            timeout: .seconds(12 * 60 * 60),
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 64 * 1024,
            sensitiveValues: [ffmpegPath, file.path]
        )
        let collector = LoudnessLogCollector()
        let result = try await runner.run(request) { chunk in
            if case .standardOutput = chunk.stream { collector.consume(chunk.data) }
            outputTiming?.consume(chunk)
        }
        try Task.checkCancellation()
        collector.finish()
        guard result.succeeded else {
            throw AnalyticsError.parsingFailed(request.redactedDiagnostic(result.standardErrorText, limit: 500))
        }
        if let timing, let outputTiming {
            let decoded = try outputTiming.finish()
            guard decoded.samples == timing.samples, decoded.rate == timing.rate,
                  decoded.start == timing.start else {
                throw AnalyticsError.parsingFailed("Grouped loudness analysis did not preserve every source sample.")
            }
        }
        return try collector.results(presentation: presentation, summary: result.standardErrorText)
    }

    /// Run up to two independent programs at once, returning reports in selection
    /// order while publishing each completed report. Structured cancellation drains
    /// both active subprocesses before the batch finishes.
    func analyze(
        file: URL,
        presentations: [LoudnessPresentation],
        onResult: @escaping @Sendable (LoudnessResults) async -> Void = { _ in }
    ) async throws -> [LoudnessResults] {
        guard Set(presentations.map(\.id)).count == presentations.count else {
            throw AnalyticsError.parsingFailed("Select each audio presentation only once")
        }
        return try await withThrowingTaskGroup(of: LoudnessResults.self) { group in
            var nextIndex = 0
            var measured: [String: LoudnessResults] = [:]
            func enqueue(_ presentation: LoudnessPresentation) {
                group.addTask {
                    try Task.checkCancellation()
                    return try await self.analyze(file: file, presentation: presentation)
                }
            }
            while nextIndex < min(2, presentations.count) {
                enqueue(presentations[nextIndex])
                nextIndex += 1
            }
            while let result = try await group.next() {
                try Task.checkCancellation()
                measured[result.presentation.id] = result
                await onResult(result)
                if nextIndex < presentations.count {
                    enqueue(presentations[nextIndex])
                    nextIndex += 1
                }
            }
            try Task.checkCancellation()
            return presentations.compactMap { measured[$0.id] }
        }
    }

    static func filterGraph(for presentation: LoudnessPresentation) -> String {
        // Inspect merged source frames before resetting the report's timeline.
        // This checks that every preflight sample survives the grouping graph.
        let timing: String
        if case .track = presentation { timing = "" }
        else { timing = "asettb=1/sr,ashowinfo@amc_peak_timing_0," }
        // ebur128 does not drain its internal true-peak resampler at EOF.
        // Give that measurement symmetric zero context on a separate branch;
        // the gated integrated/LRA and timeline branch remains unpadded.
        let measurement = timing + "asplit=2[loudness_input][true_peak_input];"
            + "[true_peak_input]adelay=100:all=1,apad=pad_dur=0.1,"
            + "ebur128@amc_true_peak=peak=true:framelog=verbose,anullsink;"
            + "[loudness_input]asetpts=PTS-STARTPTS,"
            + "ebur128@amc_loudness=metadata=1:peak=none:framelog=verbose,"
            + "astats=metadata=1:reset=1:measure_perchannel=none:measure_overall=Peak_level+RMS_level,"
            + "ametadata=print:file=-"
        return AudioPeakAnalysisService.filterGraph(for: presentation, measurementFilter: measurement, outputLabel: "metered")
    }
}

/// FFmpeg reports 10 measurements per second. Retain the readings for accurate
/// graph decimation while always parsing its separate gated final summary.
private final class LoudnessLogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var samples: [LoudnessSample] = []
    private var frameSeconds: Double?
    private var frameValues: [String: Double] = [:]

    func consume(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        pending += String(decoding: data, as: UTF8.self)
        while let end = pending.firstIndex(of: "\n") {
            let line = String(pending[..<end])
            pending.removeSubrange(...end)
            parse(line)
        }
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty { parse(pending) }
        finishFrame()
        pending = ""
    }

    func results(presentation: LoudnessPresentation, summary: String) throws -> LoudnessResults {
        lock.lock()
        defer { lock.unlock() }
        func finalSummary(named name: String) throws -> String {
            guard let filter = summary.range(of: "[ebur128@\(name) ", options: .backwards),
                  let header = summary.range(of: "Summary:", range: filter.upperBound..<summary.endIndex) else {
                throw AnalyticsError.parsingFailed("FFmpeg did not report a loudness summary")
            }
            let suffix = summary[header.upperBound...]
            let end = suffix.range(of: "[ebur128@")?.lowerBound ?? summary.endIndex
            return String(summary[header.upperBound..<end])
        }
        let final = try finalSummary(named: "amc_loudness")
        let peakSummary = try finalSummary(named: "amc_true_peak")
        guard let integrated = Self.value(after: "Integrated loudness:", key: "I:", in: final),
              let range = Self.value(after: "Loudness range:", key: "LRA:", in: final) else {
            throw AnalyticsError.parsingFailed("Incomplete loudness summary")
        }
        let peak = Self.value(after: "True peak:", key: "Peak:", in: peakSummary)
        return LoudnessResults(
            presentation: presentation,
            integratedLUFS: integrated,
            loudnessRangeLU: range,
            maximumTruePeakDBTP: peak,
            samples: samples
        )
    }

    private func parse(_ line: String) {
        if line.hasPrefix("frame:") {
            finishFrame()
            frameSeconds = Self.number(after: "pts_time:", in: line).flatMap { $0 >= 0 ? $0 : nil }
            return
        }
        guard frameSeconds != nil, line.hasPrefix("lavfi."),
              let separator = line.firstIndex(of: "=") else { return }
        let key = String(line[..<separator])
        // Silence yields -inf for peak/RMS. Preserve it as a missing reading;
        // only finite values reach chart scales or exported numbers.
        if let number = Double(line[line.index(after: separator)...]), number.isFinite {
            frameValues[key] = number
        }
    }

    private func finishFrame() {
        defer {
            frameSeconds = nil
            frameValues.removeAll(keepingCapacity: true)
        }
        guard let seconds = frameSeconds, !frameValues.isEmpty else { return }
        let momentary = frameValues["lavfi.r128.M"]
        let shortTerm = frameValues["lavfi.r128.S"]
        samples.append(LoudnessSample(
            seconds: seconds,
            momentaryLUFS: momentary.flatMap { $0 <= -70 ? nil : $0 },
            shortTermLUFS: shortTerm.flatMap { $0 <= -70 ? nil : $0 },
            peakDBFS: frameValues["lavfi.astats.Overall.Peak_level"],
            rmsDBFS: frameValues["lavfi.astats.Overall.RMS_level"]
        ))
    }

    private static func value(after section: String, key: String, in summary: String) -> Double? {
        guard let start = summary.range(of: section) else { return nil }
        return number(after: key, in: String(summary[start.upperBound...]))
    }

    private static func number(after key: String, in text: String) -> Double? {
        guard let range = text.range(of: key) else { return nil }
        let suffix = text[range.upperBound...].drop(while: { $0.isWhitespace })
        let token = suffix.prefix(while: { !$0.isWhitespace })
        guard let number = Double(token), number.isFinite else { return nil }
        return number
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
    private var timestamps: [Int: Double] = [:]
    private static let timestampRegex = try! NSRegularExpression(pattern: #"\bn:\s*(\d+).*?\bpts_time:([\d.eE+\-]+)"#)
    var frameTimestamps: [Int: Double] { lock.withLock { timestamps } }

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
        if text.contains("showinfo"),
           let match = Self.timestampRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let frameRange = Range(match.range(at: 1), in: text), let timeRange = Range(match.range(at: 2), in: text),
           let frame = Int(text[frameRange]), let seconds = Double(text[timeRange]), seconds.isFinite, seconds >= 0 {
            timestamps[frame] = seconds
        }
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

/// Fixed-width, memory-mapped timestamps avoid retaining every decoded frame in RAM.
private struct DecodedQualityFrameIndex: Sendable {
    let data: Data
    let endSeconds: Double
    let timestampTick: Double
    var count: Int { data.count / MemoryLayout<Int64>.size }
    func pts(at index: Int) -> Int64 {
        data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 8, as: Int64.self) }
    }
    func seconds(at index: Int) -> Double { Double(pts(at: index)) / 1_000_000_000 }
    func lowerBound(seconds: Double) -> Int { bound(seconds: seconds, inclusive: false) }
    func upperBound(seconds: Double) -> Int { bound(seconds: seconds, inclusive: true) }
    private func bound(seconds: Double, inclusive: Bool) -> Int {
        var low = 0
        var high = count
        // Round to the indexing timebase, avoiding floating point noise at exact PTS.
        let target = (seconds * 1_000_000_000).rounded()
        while low < high {
            let middle = (low + high) / 2
            let value = Double(pts(at: middle))
            if value < target || (inclusive && value == target) { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

/// Only FFmpeg's named showinfo filter contributes records. Output chunks can split
/// lines anywhere; the parser retains one bounded line and batches index writes.
private final class DecodedQualityFrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let handle: FileHandle
    private let pattern = try! NSRegularExpression(pattern: #"n:\s*(\d+)\s+pts:\s*(-?\d+)"#)
    private var pending = Data()
    private var records = Data()
    private var count = 0
    private var lastPTS: Int64?
    private var lastDuration: Int64 = 0
    private var timestampTick = 0.0
    private let timebasePattern = try! NSRegularExpression(pattern: #"config in time_base:\s*(\d+)/(\d+)"#)
    private let durationPattern = try! NSRegularExpression(pattern: #"duration:\s*(\d+)"#)
    private let duration: Double
    private let progress: @Sendable (Double) -> Void
    private var lastProgress = 0.0
    private var failure: Error?

    init(url: URL, duration: Double, progress: @escaping @Sendable (Double) -> Void) throws {
        self.url = url
        self.duration = duration
        self.progress = progress
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw AnalyticsError.parsingFailed("Could not create decoded frame index")
        }
        handle = try FileHandle(forWritingTo: url)
    }
    deinit { try? handle.close() }

    func consume(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return }
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<newline], as: UTF8.self)
            pending.removeSubrange(...newline)
            parse(line)
        }
        if pending.count > 128 * 1024 {
            failure = AnalyticsError.parsingFailed("Oversized decoded frame record")
        }
    }

    private func parse(_ line: String) {
        guard failure == nil else { return }
        let ns = line as NSString
        if line.contains("showinfo@amc_native"),
           let match = timebasePattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
           let numerator = Double(ns.substring(with: match.range(at: 1))),
           let denominator = Double(ns.substring(with: match.range(at: 2))), denominator > 0 {
            timestampTick = max(timestampTick, numerator / denominator)
        }
        guard line.contains("showinfo@amc_index"), line.contains(" n:") else { return }
        guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              let ordinal = Int(ns.substring(with: match.range(at: 1))), ordinal == count,
              var pts = Int64(ns.substring(with: match.range(at: 2))),
              lastPTS.map({ pts >= $0 }) ?? true else {
            failure = AnalyticsError.parsingFailed("Invalid or nonmonotonic decoded video timestamps")
            return
        }
        lastPTS = pts
        if let match = durationPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
            lastDuration = Int64(ns.substring(with: match.range(at: 1))) ?? 0
        } else { lastDuration = 0 }
        let fraction = min(1, max(0, Double(pts) / 1_000_000_000 / duration))
        if fraction - lastProgress >= 0.01 { lastProgress = fraction; progress(fraction) }
        count += 1
        withUnsafeBytes(of: &pts) { records.append(contentsOf: $0) }
        if records.count >= 64 * 1024 { flush() }
    }

    private func flush() {
        do { try handle.write(contentsOf: records); records.removeAll(keepingCapacity: true) }
        catch { failure = error }
    }

    func finish() throws -> DecodedQualityFrameIndex {
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty { parse(String(decoding: pending, as: UTF8.self)); pending.removeAll() }
        flush()
        try handle.close()
        if let failure { throw failure }
        guard count > 0 else { throw AnalyticsError.parsingFailed("No decoded video timestamps were found") }
        // A missing final-frame duration cannot establish how long the last
        // reference is visible. Conservatively exclude that frame instead of
        // extending it through a possible audio-only tail.
        let endSeconds = Double(lastPTS ?? 0) / 1_000_000_000 + Double(lastDuration) / 1_000_000_000
        return DecodedQualityFrameIndex(data: try Data(contentsOf: url, options: .alwaysMapped), endSeconds: endSeconds, timestampTick: timestampTick)
    }
}
