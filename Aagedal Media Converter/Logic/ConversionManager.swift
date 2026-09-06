// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import AVFoundation
import Foundation
import SwiftUI
import AppKit
import OSLog

/// FFmpeg-style ETA strings are always `HH:MM:SS` (see ParsingUtils.parseTimeProgress).
/// Anything else from the converter's progressUpdate is a stage label like
/// "Wrapping audio essence 42%" or "Closing file...".
private let etaDurationRegex: NSRegularExpression = {
    // swiftlint:disable:next force_try
    try! NSRegularExpression(pattern: #"^\d{2}:\d{2}:\d{2}$"#)
}()

private func progressIsDuration(_ s: String?) -> Bool {
    guard let s, !s.isEmpty else { return false }
    let range = NSRange(s.startIndex..., in: s)
    return etaDurationRegex.firstMatch(in: s, range: range) != nil
}

@MainActor
enum SubtitleEmbeddingCommit {
    /// Keeps attempt validation and filesystem publication in one synchronous
    /// MainActor critical section. `replaceItemAt` preserves the destination if
    /// publication fails, unlike a remove-then-move sequence.
    static func publishIfCurrent(
        temporaryURL: URL,
        destinationURL: URL,
        isCurrent: () -> Bool,
        didPublish: () -> Void
    ) throws -> Bool {
        guard isCurrent() else { return false }
        _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
        didPublish()
        return true
    }
}

enum SubtitleEmbeddingSubprocessError: LocalizedError {
    case failed(status: Int32, diagnostic: String)
    case missingOutput
    case timedOut
    case failedToStart(String)

    var errorDescription: String? {
        switch self {
        case .failed(let status, let diagnostic):
            let detail = diagnostic.isEmpty ? "" : ": \(diagnostic)"
            return "Subtitle embedding failed with exit code \(status)\(detail)"
        case .missingOutput:
            return "Subtitle embedding completed without producing a valid output file."
        case .timedOut:
            return "Subtitle embedding timed out after 12 hours."
        case .failedToStart(let diagnostic):
            return "Unable to start subtitle embedding: \(diagnostic)"
        }
    }
}

/// One-shot FFmpeg subtitle mux behind the shared cancellable subprocess boundary.
/// The caller owns publication of the staged output after this returns successfully.
struct SubtitleEmbeddingSubprocess: Sendable {
    static let timeout: Duration = .seconds(12 * 60 * 60)
    static let diagnosticCaptureLimit = 256 * 1024

    private let subprocessRunner: any SubprocessRunning

    init(subprocessRunner: any SubprocessRunning = SubprocessRunner()) {
        self.subprocessRunner = subprocessRunner
    }

    func run(
        ffmpegPath: String,
        srtURL: URL,
        videoURL: URL,
        stagedURL: URL,
        subtitleCodec: String,
        languageCode: String?
    ) async throws {
        var arguments = [
            "-y",
            "-i", videoURL.path,
            "-i", srtURL.path,
            "-map", "0",
            "-map", "1:s",
            "-c", "copy",
            "-c:s", subtitleCodec,
        ]
        if let languageCode {
            arguments.append(contentsOf: ["-metadata:s:s:0", "language=\(languageCode)"])
        }
        arguments.append(stagedURL.path)

        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: arguments,
            timeout: Self.timeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: Self.diagnosticCaptureLimit,
            sensitiveValues: [ffmpegPath, srtURL.path, videoURL.path, stagedURL.path]
        )

        do {
            let result = try await subprocessRunner.run(request)
            try Task.checkCancellation()
            guard result.succeeded else {
                throw SubtitleEmbeddingSubprocessError.failed(
                    status: result.terminationStatus,
                    diagnostic: request.redactedDiagnostic(result.standardErrorText)
                )
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: stagedURL)
            throw CancellationError()
        } catch let error as SubprocessRunnerError {
            try? FileManager.default.removeItem(at: stagedURL)
            switch error {
            case .timedOut:
                throw SubtitleEmbeddingSubprocessError.timedOut
            case .failedToStart(_, let underlying):
                throw SubtitleEmbeddingSubprocessError.failedToStart(
                    request.redactedDiagnostic(underlying)
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)
            throw error
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: stagedURL.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0 else {
            try? FileManager.default.removeItem(at: stagedURL)
            throw SubtitleEmbeddingSubprocessError.missingOutput
        }
    }
}

private final class SubtitleEmbeddingOwnership: @unchecked Sendable {
    private let current = OSAllocatedUnfairLock(initialState: true)

    func whileCurrent<T>(_ operation: () throws -> T) rethrows -> T? {
        try current.withLockUnchecked { isCurrent in
            guard isCurrent else { return nil }
            return try operation()
        }
    }

    func invalidate() {
        current.withLock { $0 = false }
    }
}

struct MergePreparationSubprocess: Sendable {
    private let subprocessRunner: any SubprocessRunning

    init(subprocessRunner: any SubprocessRunning = SubprocessRunner()) {
        self.subprocessRunner = subprocessRunner
    }

    func runFFmpeg(
        at executablePath: String,
        arguments: [String],
        outputURL: URL,
        context: String
    ) async -> Bool {
        let privatePaths = Set(
            arguments.filter { $0.hasPrefix("/") }
        ).union([executablePath, outputURL.path])
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            timeout: .seconds(12 * 60 * 60),
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 256 * 1024,
            sensitiveValues: privatePaths
        )
        let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "MergeCompatibility")

        do {
            let result = try await subprocessRunner.run(request)
            guard result.succeeded else {
                try? FileManager.default.removeItem(at: outputURL)
                let diagnostic = request.redactedDiagnostic(result.standardErrorText)
                logger.error("FFmpeg \(context, privacy: .private) failed with code \(result.terminationStatus). \(diagnostic, privacy: .public)")
                return false
            }

            guard let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value > 0 else {
                try? FileManager.default.removeItem(at: outputURL)
                logger.error("FFmpeg \(context, privacy: .private) completed without a nonempty output")
                return false
            }
            return true
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: outputURL)
            return false
        } catch let error as SubprocessRunnerError {
            try? FileManager.default.removeItem(at: outputURL)
            switch error {
            case .timedOut:
                logger.error("FFmpeg \(context, privacy: .private) timed out after 12 hours")
            case .failedToStart(_, let underlying):
                let diagnostic = request.redactedDiagnostic(underlying)
                logger.error("Failed to launch FFmpeg \(context, privacy: .private): \(diagnostic, privacy: .public)")
            }
            return false
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            let diagnostic = request.redactedDiagnostic(error.localizedDescription)
            logger.error("FFmpeg \(context, privacy: .private) failed: \(diagnostic, privacy: .public)")
            return false
        }
    }
}

actor ConversionManager: Sendable {
    @MainActor static let shared = ConversionManager()
    private let mergePreparationSubprocess: MergePreparationSubprocess
    private let subtitleEmbeddingSubprocess: SubtitleEmbeddingSubprocess
    private let ffmpegPathProvider: @Sendable () -> String?
    private let transcriptionSettings: any TranscriptionSettingsProviding
    private let ocrSettings: any OCRSettingsProviding
    private let analyticsSettings: any AnalyticsSettingsProviding

    init(
        subprocessRunner: any SubprocessRunning = SubprocessRunner(),
        ffmpegPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.ffmpegPath },
        transcriptionSettings: any TranscriptionSettingsProviding = PostConversionSettings(),
        ocrSettings: any OCRSettingsProviding = PostConversionSettings(),
        analyticsSettings: any AnalyticsSettingsProviding = PostConversionSettings()
    ) {
        self.mergePreparationSubprocess = MergePreparationSubprocess(subprocessRunner: subprocessRunner)
        self.subtitleEmbeddingSubprocess = SubtitleEmbeddingSubprocess(subprocessRunner: subprocessRunner)
        self.ffmpegPathProvider = ffmpegPathProvider
        self.transcriptionSettings = transcriptionSettings
        self.ocrSettings = ocrSettings
        self.analyticsSettings = analyticsSettings
    }

    enum ConversionStatus {
        case waiting
        case converting
        case done
        case failed
        case cancelled
    }
    

    private var isConverting = false
    private var currentProcess: Process?
    private var ffmpegConverter = FFMPEGConverter()
    private var conversionQueue: [VideoItem] = []
    private var currentDroppedFiles: Binding<[VideoItem]>?
    private var currentOutputFolder: String?
    private var currentPreset: ExportPreset = .videoLoop
    private var allowedItemIDs: Set<UUID>? = nil
    private var activeBatchID: UUID?
    private var batchCompletionContinuation: (
        batchID: UUID,
        continuation: CheckedContinuation<Void, Never>
    )?
    private struct SubtitleEmbeddingAttempt {
        let id: UUID
        let operationID: UUID?
        let ownership: SubtitleEmbeddingOwnership
        let task: Task<Void, Error>
    }
    private var subtitleEmbeddingAttempts: [UUID: SubtitleEmbeddingAttempt] = [:]

    // Progress tracking with Swift Concurrency
    private var progressContinuation: AsyncStream<Double>.Continuation?
    private var progressStream: AsyncStream<Double>?
    // Periodic task that yields overall progress every few seconds while converting
    private var progressTimerTask: Task<Void, Never>?
    // Track URLs that have active security-scoped access during conversion
    private var activeSecurityScopedURLs: Set<URL> = []
    private struct MergePlan {
        let itemIDs: [UUID]
        let listFileURL: URL
        let outputBaseURL: URL
        let outputFolder: String
        let preset: ExportPreset
        let comment: String
        let includeDateTag: Bool
        let waveformRequest: WaveformVideoRequest?
        let synthesizedVideoRequest: SynthesizedVideoRequest?
        let segments: [MergeSegment]
        let temporaryClipURLs: [URL]
        let totalDuration: Double?
        var hasExecuted: Bool
        /// Whether source clips had audio — used for post-export verification
        let sourceHasAudio: Bool
        /// Conformance target for two-pass force merge (nil for standard merge)
        let conformanceTarget: ConformanceTarget?
    }

    private struct MergeSegment {
        let itemID: UUID
        let originalURL: URL
        let preparedURL: URL
        let trimStart: Double?
        let trimEnd: Double?
        let isTemporary: Bool
        let duration: Double?
        /// Whether this segment was re-encoded for conformance (informational)
        let isConformed: Bool
    }

    // MARK: - Conformance Merge Types

    /// Captures the reference clip's format that non-matching clips must conform to.
    struct ConformanceTarget: Sendable {
        let referenceItemID: UUID
        let referenceURL: URL
        // Video
        let videoCodec: String
        let width: Int
        let height: Int
        let frameRate: Double?
        let pixelFormat: String?
        let pixelAspectRatio: String?
        let isInterlaced: Bool
        // Audio
        let audioCodec: String?
        let audioChannels: Int?
        let audioSampleRate: Int?
        // Container
        let containerExtension: String

        /// Builds a ConformanceTarget from a clip's metadata and URL.
        static func from(metadata: VideoMetadata, url: URL) -> ConformanceTarget? {
            guard let video = metadata.primaryVideoStream,
                  let codec = video.codec,
                  let width = video.width,
                  let height = video.height else { return nil }

            let audio = metadata.audioStreams.first
            return ConformanceTarget(
                referenceItemID: UUID(), // Caller should set this properly
                referenceURL: url,
                videoCodec: codec,
                width: width,
                height: height,
                frameRate: video.frameRate?.value,
                pixelFormat: video.pixelFormat,
                pixelAspectRatio: video.pixelAspectRatio?.stringValue,
                isInterlaced: video.isInterlaced ?? false,
                audioCodec: audio?.codec,
                audioChannels: audio?.channels,
                audioSampleRate: audio?.sampleRate,
                containerExtension: url.pathExtension.lowercased()
            )
        }

        /// Human-readable summary of the target format.
        var formatSummary: String {
            var parts: [String] = []
            parts.append("\(width)x\(height)")
            parts.append(videoCodec)
            if let fr = frameRate { parts.append("\(Int(fr.rounded()))fps") }
            if let ac = audioCodec, let ch = audioChannels {
                let sr = audioSampleRate.map { " \($0 / 1000)kHz" } ?? ""
                parts.append("\(ch)ch \(ac)\(sr)")
            }
            return parts.joined(separator: ", ")
        }
    }

    /// Per-clip analysis of what needs to change for conformance merge.
    struct ConformanceAnalysis: Sendable, Identifiable {
        let id: UUID  // itemID
        let itemName: String
        let needsVideoReencode: Bool
        let needsAudioReencode: Bool
        let videoMismatches: [String]
        let audioMismatches: [String]

        var needsConformance: Bool { needsVideoReencode || needsAudioReencode }
    }
    private var mergePlan: MergePlan?
    private var mergePreparationTask: (id: UUID, itemID: UUID, task: Task<Bool, Never>)?
    private var mergePreparationScope: (batchID: UUID, itemIDs: Set<UUID>)?
    private var invalidatedMergePreparationBatchIDs: Set<UUID> = []
    private var lastMergeMetadata: [UUID: VideoMetadata] = [:]
    private let mergeLogger = Logger(subsystem: "com.aagedal.MediaConverter", category: "MergeCompatibility")
    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ConversionManager")
    
    func progressUpdates() -> AsyncStream<Double> {
        let stream = AsyncStream(Double.self) { continuation in
            // Store the continuation directly without using a weak self capture
            // since we're not mutating any actor state here
            let task = Task {
                self.setProgressContinuation(continuation)
            }
            
            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    await self.clearProgressContinuation()
                }
            }
        }
        progressStream = stream
        return stream
    }
    
    private func setProgressContinuation(_ continuation: AsyncStream<Double>.Continuation) {
        progressContinuation = continuation
    }
    
    private func clearProgressContinuation() {
        progressContinuation = nil
    }

    // MARK: - Periodic Progress Timer
        /// Starts a periodic task that emits overall progress every 3 s
    private func startProgressTimer(droppedFiles: Binding<[VideoItem]>) {
        progressTimerTask?.cancel()
        
                progressTimerTask = Task { [weak self] in
            guard let self else { return }
            while await self.isConverting {
                await self.updateOverallProgress(droppedFiles: droppedFiles)
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            }
        }
    }

    private func buildMergePlan(
        from items: [VideoItem],
        preset: ExportPreset,
        outputFolder: String,
        groupName: String? = nil,
        batchID: UUID
    ) async -> MergePlan? {
        guard isMergePreparationActive(batchID),
              case .compatible = await evaluateMergeCompatibility(for: items, preset: preset),
              isMergePreparationActive(batchID) else {
            return nil
        }

        let waitingItems = items.filter { $0.status == .waiting }
        guard waitingItems.count >= 2 else { return nil }

        let orderedWaitingItems = waitingItems
        let itemIDs = orderedWaitingItems.map { $0.id }

        let durationLookup = buildDurationLookup(for: orderedWaitingItems, metadata: lastMergeMetadata)

        guard let (segments, temporaryFiles, totalDuration) = await prepareMergeSegments(
            from: orderedWaitingItems,
            durationLookup: durationLookup,
            batchID: batchID
        ) else {
            return nil
        }

        guard let listFileURL = createConcatListFile(for: segments) else {
            cleanupTemporaryFiles(temporaryFiles)
            return nil
        }

        guard let firstItem = orderedWaitingItems.first else { return nil }

        let resolvedOutputFolder = VideoFileUtils.resolveOutputFolder(for: firstItem.url, defaultOutputFolder: outputFolder, preset: preset) ?? outputFolder

        // Ensure the output directory exists with proper security-scoped access
        let resolvedOutputFolderURL = URL(fileURLWithPath: resolvedOutputFolder)
        guard ensureDirectoryAccessible(at: resolvedOutputFolderURL) else {
            mergeLogger.error("Failed to access output directory for merge: \(resolvedOutputFolder)")
            cleanupTemporaryFiles(temporaryFiles)
            return nil
        }

        let mergeBaseName: String
        if let name = groupName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty {
            mergeBaseName = FileNameProcessor.processFileName(name)
        } else if let override = firstItem.outputFileNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            mergeBaseName = FileNameProcessor.processFileName((override as NSString).deletingPathExtension)
        } else {
            let suffixPart = FileNameProcessor.includePresetSuffix ? preset.fileSuffix : ""
            mergeBaseName = FileNameProcessor.processFileName(firstItem.url.deletingPathExtension().lastPathComponent)
                + suffixPart
                + "_merge"
        }
        let baseOutputURL = URL(fileURLWithPath: resolvedOutputFolder)
            .appendingPathComponent(mergeBaseName)

        let waveformPreferences = AudioWaveformPreferences.loadConfig()
        let resolvedWaveformResolution = preset.resolvedWaveformResolution(defaultResolution: waveformPreferences.resolution)

        // Check if waveform generation is compatible with audio routing
        let canGenerateWaveform = {
            guard preset != .streamCopy else { return false }
            guard orderedWaitingItems.contains(where: { $0.requiresWaveformVideo }) else { return false }
            // splitToMono is incompatible with waveform video (needs 2 separate audio outputs)
            // If any audio-only item uses splitToMono, disable waveform for all
            if orderedWaitingItems.contains(where: { item in
                guard item.requiresWaveformVideo else { return false }
                if case .splitToMono = item.audioRoutingConfig?.channelOperation {
                    return true
                }
                return false
            }) {
                return false
            }
            return true
        }()

        let waveformRequest: WaveformVideoRequest? = canGenerateWaveform ? {
            return WaveformVideoRequest(
                width: Int(resolvedWaveformResolution.width),
                height: Int(resolvedWaveformResolution.height),
                backgroundHex: waveformPreferences.backgroundHex,
                foregroundHex: waveformPreferences.foregroundHex,
                normalizeAudio: waveformPreferences.normalizeAudio,
                style: waveformPreferences.style,
                frameRate: waveformPreferences.frameRate,
                renderingEngine: waveformPreferences.renderingEngine,
                swiftStyle: waveformPreferences.swiftStyle,
                bandCount: waveformPreferences.bandCount,
                frequencyDistribution: waveformPreferences.frequencyDistribution,
                foregroundGradientEnabled: waveformPreferences.foregroundGradientEnabled,
                foregroundGradientEndHex: waveformPreferences.foregroundGradientEndHex,
                backgroundGradientEnabled: waveformPreferences.backgroundGradientEnabled,
                backgroundGradientEndHex: waveformPreferences.backgroundGradientEndHex,
                waveformOpacity: waveformPreferences.waveformOpacity
            )
        }() : nil

        let synthesizedVideoRequest: SynthesizedVideoRequest? = {
            guard waveformRequest == nil else { return nil }
            guard preset.outputsVideoTrack else { return nil }
            guard orderedWaitingItems.contains(where: { !$0.hasVideoStream }) else { return nil }
            // splitToMono is incompatible with video generation (needs 2 separate audio outputs)
            if orderedWaitingItems.contains(where: { item in
                guard !item.hasVideoStream else { return false }
                if case .splitToMono = item.audioRoutingConfig?.channelOperation {
                    return true
                }
                return false
            }) {
                return nil
            }
            return SynthesizedVideoRequest(
                width: Int(resolvedWaveformResolution.width),
                height: Int(resolvedWaveformResolution.height),
                backgroundHex: waveformPreferences.backgroundHex,
                frameRate: waveformPreferences.frameRate,
                includeAudio: true
            )
        }()

        // Check if any source clip has audio (for post-export verification)
        let sourceHasAudio = orderedWaitingItems.contains { item in
            if let meta = lastMergeMetadata[item.id] {
                return !(meta.audioStreams.isEmpty)
            }
            return false
        }

        return MergePlan(
            itemIDs: itemIDs,
            listFileURL: listFileURL,
            outputBaseURL: baseOutputURL,
            outputFolder: outputFolder,
            preset: preset,
            comment: firstItem.comment,
            includeDateTag: firstItem.includeDateTag,
            waveformRequest: waveformRequest,
            synthesizedVideoRequest: synthesizedVideoRequest,
            segments: segments,
            temporaryClipURLs: temporaryFiles,
            totalDuration: totalDuration,
            hasExecuted: false,
            sourceHasAudio: sourceHasAudio,
            conformanceTarget: nil
        )
    }

    private func prepareMergeSegments(
        from items: [VideoItem],
        durationLookup: [UUID: Double],
        batchID: UUID
    ) async -> ([MergeSegment], [URL], Double?)? {
        var segments: [MergeSegment] = []
        var temporaryFiles: [URL] = []
        var totalDuration: Double = 0

        for item in items {
            guard isMergePreparationActive(batchID) else {
                cleanupTemporaryFiles(temporaryFiles)
                return nil
            }
            let baseDuration = durationLookup[item.id]
            let hasTrim = hasActiveTrim(item)
            let segmentDuration = resolveSegmentDuration(for: item, baseDuration: baseDuration, hasTrim: hasTrim)
            if let segmentDuration {
                totalDuration += segmentDuration
            }

            if hasTrim {
                guard let trimmedURL = await prepareTrimmedClip(for: item, batchID: batchID) else {
                    cleanupTemporaryFiles(temporaryFiles)
                    return nil
                }
                let segment = MergeSegment(
                    itemID: item.id,
                    originalURL: item.url,
                    preparedURL: trimmedURL,
                    trimStart: item.trimStart,
                    trimEnd: item.trimEnd,
                    isTemporary: true,
                    duration: segmentDuration,
                    isConformed: false
                )
                segments.append(segment)
                temporaryFiles.append(trimmedURL)
            } else {
                let segment = MergeSegment(
                    itemID: item.id,
                    originalURL: item.url,
                    preparedURL: item.url,
                    trimStart: item.trimStart,
                    trimEnd: item.trimEnd,
                    isTemporary: false,
                    duration: segmentDuration,
                    isConformed: false
                )
                segments.append(segment)
            }
        }

        let resolvedTotal = totalDuration > 0 ? totalDuration : nil
        return (segments, temporaryFiles, resolvedTotal)
    }

    private func buildDurationLookup(for items: [VideoItem], metadata: [UUID: VideoMetadata]) -> [UUID: Double] {
        items.reduce(into: [:]) { result, item in
            if let duration = resolveBaseDuration(for: item, metadata: metadata[item.id]), duration > 0 {
                result[item.id] = duration
            }
        }
    }

    private func resolveBaseDuration(for item: VideoItem, metadata: VideoMetadata?) -> Double? {
        if let metadataDuration = metadata?.duration, metadataDuration > 0 {
            return metadataDuration
        }
        if item.durationSeconds > 0 {
            return item.durationSeconds
        }
        return nil
    }

    private func resolveSegmentDuration(for item: VideoItem, baseDuration: Double?, hasTrim: Bool) -> Double? {
        if hasTrim {
            let trimmed = max(item.trimmedDuration, 0)
            if trimmed > 0 {
                return trimmed
            }
        }
        return baseDuration
    }

    private func hasActiveTrim(_ item: VideoItem) -> Bool {
        if let trimStart = item.trimStart, trimStart > 0.0005 {
            return true
        }
        if item.trimEnd != nil {
            return true
        }
        return false
    }

    private func prepareTrimmedClip(for item: VideoItem, batchID: UUID) async -> URL? {
        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else {
            mergeLogger.error("FFmpeg binary not found while preparing trimmed clip for \(item.name, privacy: .public)")
            return nil
        }

        let fileExtension = item.url.pathExtension.isEmpty ? "mp4" : item.url.pathExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trimmed_\(UUID().uuidString).\(fileExtension)")

        let start = max(item.effectiveTrimStart, 0)
        let hasStartTrim = start > 0.0005
        let hasEndTrim = item.trimEnd != nil
        let duration = max(item.effectiveTrimEnd - start, 0)

        if hasEndTrim && duration <= 0.01 {
            mergeLogger.error("Invalid trim duration for \(item.name, privacy: .public). Start=\(start, privacy: .public) end=\(item.effectiveTrimEnd, privacy: .public)")
            return nil
        }

        var arguments = ["-y"]
        if hasStartTrim {
            arguments.append(contentsOf: ["-ss", FFMPEGCommandBuilder.ffmpegTimeString(from: start)])
        }

        arguments.append(contentsOf: ["-i", item.url.path])

        if hasEndTrim {
            arguments.append(contentsOf: ["-t", FFMPEGCommandBuilder.ffmpegTimeString(from: duration)])
        }

        arguments.append(contentsOf: ["-c", "copy", "-avoid_negative_ts", "make_zero", tempURL.path])

        let success = await runMergePreparationFFmpeg(
            at: ffmpegPath,
            arguments: arguments,
            outputURL: tempURL,
            itemID: item.id,
            batchID: batchID,
            context: "trim \(item.name)"
        )
        return success ? tempURL : nil
    }

    private func runMergePreparationFFmpeg(
        at executablePath: String,
        arguments: [String],
        outputURL: URL,
        itemID: UUID,
        batchID: UUID,
        context: String
    ) async -> Bool {
        guard isMergePreparationActive(batchID) else { return false }
        let operationID = UUID()
        let task = Task {
            await mergePreparationSubprocess.runFFmpeg(
                at: executablePath,
                arguments: arguments,
                outputURL: outputURL,
                context: context
            )
        }
        mergePreparationTask = (operationID, itemID, task)
        let succeeded = await task.value
        if mergePreparationTask?.id == operationID {
            mergePreparationTask = nil
        }
        guard isMergePreparationActive(batchID) else {
            try? FileManager.default.removeItem(at: outputURL)
            return false
        }
        return succeeded
    }

    private func cancelMergePreparation() {
        mergePreparationTask?.task.cancel()
        mergePreparationTask = nil
    }

    private func cancelMergePreparation(for itemID: UUID) {
        if let scope = mergePreparationScope, scope.itemIDs.contains(itemID) {
            invalidatedMergePreparationBatchIDs.insert(scope.batchID)
            cancelMergePreparation()
        } else if mergePreparationTask?.itemID == itemID {
            cancelMergePreparation()
        }
    }

    private func isMergePreparationActive(_ batchID: UUID) -> Bool {
        isBatchActive(batchID) && !invalidatedMergePreparationBatchIDs.contains(batchID)
    }

    private func beginMergePreparation(batchID: UUID, items: [VideoItem]) {
        invalidatedMergePreparationBatchIDs.remove(batchID)
        mergePreparationScope = (batchID, Set(items.filter { $0.status == .waiting }.map(\.id)))
    }

    private func finishMergePreparation(batchID: UUID) {
        if mergePreparationScope?.batchID == batchID {
            mergePreparationScope = nil
        }
        invalidatedMergePreparationBatchIDs.remove(batchID)
    }

    private func cleanupTemporaryFiles(_ urls: [URL]) {
        for url in urls {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                mergeLogger.warning("Failed to remove temporary file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func executeMergePlan(droppedFiles: Binding<[VideoItem]>, batchID: UUID) async {
        guard activeBatchID == batchID, let plan = mergePlan else { return }

        let indices: [Int] = plan.itemIDs.compactMap { id in
            droppedFiles.wrappedValue.firstIndex(where: { $0.id == id })
        }

        guard indices.count == plan.itemIDs.count else {
            cleanupMergeArtifacts(for: plan)
            mergePlan = nil
            await convertNextFile(
                droppedFiles: droppedFiles,
                outputFolder: plan.outputFolder,
                preset: plan.preset,
                batchID: batchID
            )
            return
        }

        await MainActor.run {
            for index in indices {
                droppedFiles.wrappedValue[index].status = .converting
                droppedFiles.wrappedValue[index].progress = 0
                droppedFiles.wrappedValue[index].eta = nil
            }
        }

        let inputItems = indices.compactMap { droppedFiles.wrappedValue[$0] }
        guard let primaryInput = inputItems.first else {
            cleanupMergeArtifacts(for: plan)
            mergePlan = nil
            return
        }

        let customInputs = ["-f", "concat", "-safe", "0", "-i", plan.listFileURL.path]

        let mergeOutputArguments: [String]? = plan.preset == .streamCopy ? [
            "-map", "-0:d?",
            "-map", "-0:t?",
            "-ignore_unknown"
        ] : nil

        // For merges, always use the first clip's timecode as the master
        // If no timecode config is set, create one with preserveSource mode
        let mergeTimecodeConfig: TimecodeConfig? = {
            if let existing = primaryInput.timecodeConfig {
                return existing
            }
            // Auto-create a preserveSource config for merges to use first clip as master
            return TimecodeConfig(mode: .preserveSource)
        }()

        // For merges, use the first clip's audio routing as the master
        // This applies the same audio routing to the entire concatenated stream
        let mergeAudioRoutingConfig = primaryInput.audioRoutingConfig

        // For merges, use the first clip's crop settings as the master
        // The crop filter will apply to the entire concatenated stream
        // Note: Crop requires re-encoding and won't work with Stream Copy preset
        let mergeCropConfig = primaryInput.cropConfig

        let mergeRequest = ConversionRequest(
            inputURL: primaryInput.url,
            outputURL: plan.outputBaseURL,
            preset: plan.preset,
            comment: plan.comment,
            includeDateTag: plan.includeDateTag,
            expectedDuration: plan.totalDuration,
            videoFrameRate: primaryInput.metadata?.primaryVideoStream?.frameRate?.value,
            audioRoutingConfig: mergeAudioRoutingConfig,
            cropConfig: mergeCropConfig,
            timecodeConfig: mergeTimecodeConfig,
            isMuted: plan.preset == .streamCopy ? false : primaryInput.isMuted,
            waveformRequest: plan.waveformRequest,
            synthesizedVideoRequest: plan.synthesizedVideoRequest,
            waveformBackgroundImageURL: primaryInput.waveformBackgroundImageURL,
            customInputArguments: customInputs,
            additionalOutputArguments: mergeOutputArguments
        )

        // Throttle UI updates to ~4 Hz to avoid SwiftUI re-render storms during encoding
        let mergeUIThrottle = OSAllocatedUnfairLock(initialState: Date.distantPast)
        let av2Settings = plan.preset == .av2 ? AV2Settings() : nil
        let outputExtension = av2Settings?.container.fileExtension
            ?? plan.preset.outputExtension(for: plan.segments.first?.originalURL)
        await ffmpegConverter.convert(
            request: mergeRequest,
            av2Settings: av2Settings,
            progressUpdate: { progress, status in
                let now = Date()
                let shouldUpdate = mergeUIThrottle.withLock { last -> Bool in
                    guard progress < 1.0 else { return true }
                    guard now.timeIntervalSince(last) >= 0.25 else { return false }
                    last = now
                    return true
                }
                guard shouldUpdate else { return }
                let isDuration = progressIsDuration(status)
                Task { @MainActor in
                    for index in indices {
                        droppedFiles.wrappedValue[index].progress = progress
                        if isDuration {
                            droppedFiles.wrappedValue[index].eta = status
                            droppedFiles.wrappedValue[index].statusMessage = nil
                        } else {
                            droppedFiles.wrappedValue[index].statusMessage = status
                        }
                    }
                }
            },
            completion: { success, errorReason in
                Task { [weak self] in
                    guard let self else { return }
                    await self.handleMergeCompletion(
                        plan: plan,
                        outputExtension: outputExtension,
                        indices: indices,
                        success: success,
                        errorReason: errorReason,
                        droppedFiles: droppedFiles,
                        batchID: batchID
                    )
                }
            }
        )
    }

    private func createConcatListFile(for segments: [MergeSegment]) -> URL? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("concat_\(UUID().uuidString).txt")
        let content = segments.map { segment -> String in
            let escapedPath = segment.preparedURL.path.replacingOccurrences(of: "'", with: "'\\''")
            return "file '\(escapedPath)'"
        }.joined(separator: "\n")

        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            return nil
        }
    }

    private func cleanupMergeArtifacts(for plan: MergePlan) {
        do {
            try FileManager.default.removeItem(at: plan.listFileURL)
        } catch {
            mergeLogger.warning("Failed to remove concat list file \(plan.listFileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        cleanupTemporaryFiles(plan.temporaryClipURLs)
    }

    // MARK: - Conformance Merge

    /// Re-encodes a single clip to match the conformance target format.
    private func prepareConformedClip(
        for item: VideoItem,
        target: ConformanceTarget,
        batchID: UUID
    ) async -> URL? {
        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else {
            mergeLogger.error("FFmpeg binary not found while preparing conformed clip for \(item.name, privacy: .public)")
            return nil
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conformed_\(UUID().uuidString).\(target.containerExtension)")

        let arguments = FFMPEGCommandBuilder.buildConformanceArguments(
            inputURL: item.url,
            outputURL: tempURL,
            target: target,
            trimStart: item.trimStart,
            trimEnd: item.trimEnd
        )

        mergeLogger.info("Conforming \(item.name, privacy: .public) to \(target.formatSummary, privacy: .public)")
        let success = await runMergePreparationFFmpeg(
            at: ffmpegPath,
            arguments: arguments,
            outputURL: tempURL,
            itemID: item.id,
            batchID: batchID,
            context: "conform \(item.name)"
        )
        if success {
            return tempURL
        } else {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
    }

    /// Prepares merge segments with conformance re-encoding for mismatched clips.
    private func prepareConformanceMergeSegments(
        from items: [VideoItem],
        durationLookup: [UUID: Double],
        target: ConformanceTarget,
        metadata: [UUID: VideoMetadata],
        batchID: UUID,
        statusUpdate: @MainActor @Sendable (String) -> Void
    ) async -> ([MergeSegment], [URL], Double?)? {
        var segments: [MergeSegment] = []
        var temporaryFiles: [URL] = []
        var totalDuration: Double = 0

        for (index, item) in items.enumerated() {
            guard !Task.isCancelled, isMergePreparationActive(batchID) else {
                cleanupTemporaryFiles(temporaryFiles)
                return nil
            }

            let segmentDuration = durationLookup[item.id] ?? item.durationSeconds
            totalDuration += segmentDuration

            // Check if this item matches the reference format
            let analysis = ConversionManager.analyzeConformance(
                items: [item],
                referenceItemID: target.referenceItemID,
                metadata: metadata
            ).first

            let needsConformance = analysis?.needsConformance ?? true

            if needsConformance {
                // Re-encode to match reference (trim applied in same pass)
                await statusUpdate("Conforming clip \(index + 1) of \(items.count): \(item.name)")
                guard let conformedURL = await prepareConformedClip(
                    for: item,
                    target: target,
                    batchID: batchID
                ) else {
                    cleanupTemporaryFiles(temporaryFiles)
                    return nil
                }
                segments.append(MergeSegment(
                    itemID: item.id, originalURL: item.url, preparedURL: conformedURL,
                    trimStart: item.trimStart, trimEnd: item.trimEnd,
                    isTemporary: true, duration: segmentDuration, isConformed: true
                ))
                temporaryFiles.append(conformedURL)
            } else if hasActiveTrim(item) {
                // Already matches but needs trim — stream copy trim
                guard let trimmedURL = await prepareTrimmedClip(for: item, batchID: batchID) else {
                    cleanupTemporaryFiles(temporaryFiles)
                    return nil
                }
                segments.append(MergeSegment(
                    itemID: item.id, originalURL: item.url, preparedURL: trimmedURL,
                    trimStart: item.trimStart, trimEnd: item.trimEnd,
                    isTemporary: true, duration: segmentDuration, isConformed: false
                ))
                temporaryFiles.append(trimmedURL)
            } else {
                // Already matches, no trim — use original
                segments.append(MergeSegment(
                    itemID: item.id, originalURL: item.url, preparedURL: item.url,
                    trimStart: nil, trimEnd: nil,
                    isTemporary: false, duration: segmentDuration, isConformed: false
                ))
            }
        }

        return (segments, temporaryFiles, totalDuration)
    }

    /// Builds a conformance merge plan where mismatched clips are re-encoded to match the reference.
    private func buildConformanceMergePlan(
        from items: [VideoItem],
        metadata: [UUID: VideoMetadata],
        referenceItemID: UUID,
        outputFolder: String,
        groupName: String? = nil,
        batchID: UUID,
        statusUpdate: @MainActor @Sendable (String) -> Void
    ) async -> MergePlan? {
        guard isMergePreparationActive(batchID) else { return nil }
        let waitingItems = items.filter { $0.status == .waiting }
        guard waitingItems.count >= 2 else { return nil }

        guard let refMeta = metadata[referenceItemID],
              let refItem = waitingItems.first(where: { $0.id == referenceItemID }) else {
            mergeLogger.error("Conformance reference item not found")
            return nil
        }

        guard var target = ConformanceTarget.from(metadata: refMeta, url: refItem.url) else {
            mergeLogger.error("Failed to build conformance target from reference metadata")
            return nil
        }
        // Fix the referenceItemID (factory uses UUID() placeholder)
        target = ConformanceTarget(
            referenceItemID: referenceItemID,
            referenceURL: target.referenceURL,
            videoCodec: target.videoCodec,
            width: target.width, height: target.height,
            frameRate: target.frameRate,
            pixelFormat: target.pixelFormat,
            pixelAspectRatio: target.pixelAspectRatio,
            isInterlaced: target.isInterlaced,
            audioCodec: target.audioCodec,
            audioChannels: target.audioChannels,
            audioSampleRate: target.audioSampleRate,
            containerExtension: target.containerExtension
        )

        // Check that the reference codec is encodable
        if FFMPEGCommandBuilder.ffmpegVideoEncoder(for: target.videoCodec) == nil {
            mergeLogger.error("Cannot encode to codec '\(target.videoCodec, privacy: .public)' — unsupported for conformance")
            return nil
        }

        let orderedWaitingItems = waitingItems
        let itemIDs = orderedWaitingItems.map { $0.id }
        let durationLookup = buildDurationLookup(for: orderedWaitingItems, metadata: metadata)

        guard let (segments, temporaryFiles, totalDuration) = await prepareConformanceMergeSegments(
            from: orderedWaitingItems,
            durationLookup: durationLookup,
            target: target,
            metadata: metadata,
            batchID: batchID,
            statusUpdate: statusUpdate
        ) else {
            return nil
        }

        guard let listFileURL = createConcatListFile(for: segments) else {
            cleanupTemporaryFiles(temporaryFiles)
            return nil
        }

        let firstItem = orderedWaitingItems[0]
        let baseName = groupName ?? firstItem.comment
        let resolvedOutputFolder: String
        if let url = URL(string: outputFolder) {
            resolvedOutputFolder = url.path
        } else {
            resolvedOutputFolder = outputFolder
        }

        let outputBaseName = FileNameProcessor.processFileName(baseName.isEmpty ? firstItem.name : baseName)
        let baseOutputURL = URL(fileURLWithPath: resolvedOutputFolder).appendingPathComponent(outputBaseName)

        let sourceHasAudio = target.audioCodec != nil

        return MergePlan(
            itemIDs: itemIDs,
            listFileURL: listFileURL,
            outputBaseURL: baseOutputURL,
            outputFolder: outputFolder,
            preset: .streamCopy, // Concat pass always uses stream copy
            comment: firstItem.comment,
            includeDateTag: firstItem.includeDateTag,
            waveformRequest: nil,
            synthesizedVideoRequest: nil,
            segments: segments,
            temporaryClipURLs: temporaryFiles,
            totalDuration: totalDuration,
            hasExecuted: false,
            sourceHasAudio: sourceHasAudio,
            conformanceTarget: target
        )
    }

    private func handleMergeCompletion(
        plan: MergePlan,
        outputExtension: String,
        indices: [Int],
        success: Bool,
        errorReason: String?,
        droppedFiles: Binding<[VideoItem]>,
        batchID: UUID
    ) async {
        guard isBatchActive(batchID) else { return }

        let finalURL = plan.outputBaseURL.appendingPathExtension(outputExtension)

        // Capture file size - try with security-scoped access
        var outputFileSizeBytes: Int64?
        if success {
            let outputFolderURL = finalURL.deletingLastPathComponent()
            let access = SecurityScopedBookmarkManager.shared.startAccessing(url: outputFolderURL)
            defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path),
               let fileSize = attrs[.size] as? Int64 {
                outputFileSizeBytes = fileSize
            }
        }

        await MainActor.run {
            for index in indices {
                guard droppedFiles.wrappedValue.indices.contains(index) else { continue }
                if droppedFiles.wrappedValue[index].status != .cancelled {
                    droppedFiles.wrappedValue[index].status = success ? .done : .failed
                    droppedFiles.wrappedValue[index].progress = success ? 1.0 : 0.0
                    droppedFiles.wrappedValue[index].outputURL = success ? finalURL : nil
                    droppedFiles.wrappedValue[index].outputFileSizeBytes = outputFileSizeBytes
                    droppedFiles.wrappedValue[index].conversionError = success ? nil : errorReason
                    droppedFiles.wrappedValue[index].eta = nil
                    droppedFiles.wrappedValue[index].statusMessage = nil
                }
            }
        }

        // Post-export verification: check output has expected streams
        if success, plan.sourceHasAudio {
            Task {
                if let result = await FFMPEGProbeService.verifyOutputStreams(for: finalURL) {
                    if result.audioStreamCount == 0 {
                        mergeLogger.error("POST-EXPORT WARNING: Source clips had audio but output '\(finalURL.lastPathComponent, privacy: .public)' has no audio streams")
                        await MainActor.run {
                            if let firstIdx = indices.first, droppedFiles.wrappedValue.indices.contains(firstIdx) {
                                droppedFiles.wrappedValue[firstIdx].conversionError =
                                    "Warning: Audio missing in output. Source clips had audio but the merged file has none."
                            }
                        }
                    }
                }
            }
        }

        // Trigger upload for merged output (upload once since all items share the same file)
        if let itemID = ConversionUploadFollowUp.itemID(
            afterSuccess: success, mergedIndices: indices, items: droppedFiles.wrappedValue
        ) {
            Task {
                await UploadManager.shared.startUpload(itemID: itemID)
            }
        }

        // Trigger analytics for merged output (once since all items share the same file).
        // Merge always uses .streamCopy, so the resolver is a no-op for this path today —
        // we route through it anyway to avoid a regression if merge ever produces packages.
        if success,
           let firstAnalyticsIdx = indices.first(where: { droppedFiles.wrappedValue[$0].analyticsEnabled }),
           let outputURL = droppedFiles.wrappedValue[firstAnalyticsIdx].outputURL {
            let itemID = droppedFiles.wrappedValue[firstAnalyticsIdx].id
            let sourceURL = droppedFiles.wrappedValue[firstAnalyticsIdx].url
            if let analyticsURL = self.resolveAnalyticsSourceURL(for: outputURL, preset: plan.preset) {
                Task {
                    await self.runAnalytics(
                        for: itemID,
                        sourceURL: sourceURL,
                        encodedURL: analyticsURL,
                        droppedFiles: droppedFiles
                    )
                }
            } else {
                await MainActor.run {
                    if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                        droppedFiles.wrappedValue[idx].analyticsStatus = .failed("Could not locate wrapped video essence in package")
                    }
                }
            }
        }

        cleanupMergeArtifacts(for: plan)
        mergePlan = nil

        if isConverting, activeBatchID == batchID {
            await convertNextFile(
                droppedFiles: droppedFiles,
                outputFolder: plan.outputFolder,
                preset: plan.preset,
                batchID: batchID
            )
        }

        Task { @MainActor in
            if success {
                SoundManager.shared.playSuccess()
            } else {
                SoundManager.shared.playError()
            }
        }
    }


    private func stopProgressTimer() {
        progressTimerTask?.cancel()
        progressTimerTask = nil
    }

    // MARK: - Security-Scoped Resource Management

    /// Ensures an input file is accessible, using security-scoped bookmarks if needed.
    /// - Returns: true if the file is accessible, false otherwise
    private func ensureInputFileAccessible(at url: URL) -> Bool {
        let fileManager = FileManager.default
        let success = withSecurityScopedAccessFallback(at: url) {
            fileManager.isReadableFile(atPath: url.path)
        }
        if !success {
            logger.error("Failed to access input file with any access method: \(url.path, privacy: .public)")
        }
        return success
    }

    /// Ensures a directory exists and is accessible, using security-scoped bookmarks if needed.
    /// - Returns: true if the directory was created/accessible, false otherwise
    private func ensureDirectoryAccessible(at url: URL) -> Bool {
        let fileManager = FileManager.default
        let success = withSecurityScopedAccessFallback(at: url) {
            (try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)) != nil
        }
        if !success {
            logger.error("Failed to create directory with any access method: \(url.path, privacy: .public)")
        }
        return success
    }

    /// Runs `attempt` while escalating through security-scoped access fallbacks:
    /// direct → bookmark(url) → bookmark(parent) → startAccess(url) → startAccess(parent).
    /// On success, any acquired access is retained in `activeSecurityScopedURLs` for
    /// later balanced release via `releaseAllSecurityScopedAccess()`. On failure at
    /// a given step, that step's access is stopped before trying the next.
    private func withSecurityScopedAccessFallback(at url: URL, attempt: () -> Bool) -> Bool {
        // First try: no access acquisition — works if we already have permission.
        if attempt() { return true }

        // Helper: given a URL on which startAccessingSecurityScopedResource() has
        // already returned true, track it and run `attempt`. Releases on failure.
        func runAttemptAndTrack(_ acquiredURL: URL) -> Bool {
            activeSecurityScopedURLs.insert(acquiredURL)
            if attempt() { return true }
            acquiredURL.stopAccessingSecurityScopedResource()
            activeSecurityScopedURLs.remove(acquiredURL)
            return false
        }

        let parentURL = url.deletingLastPathComponent()

        // Second try: bookmark for this exact URL.
        if let resolvedURL = SecurityScopedBookmarkManager.shared.resolveBookmark(for: url),
           resolvedURL.startAccessingSecurityScopedResource(),
           runAttemptAndTrack(resolvedURL) {
            return true
        }

        // Third try: bookmark for parent directory.
        if let resolvedParent = SecurityScopedBookmarkManager.shared.resolveBookmark(for: parentURL),
           resolvedParent.startAccessingSecurityScopedResource(),
           runAttemptAndTrack(resolvedParent) {
            return true
        }

        // Fourth try: direct access on the URL (e.g. granted via NSOpenPanel).
        if url.startAccessingSecurityScopedResource(),
           runAttemptAndTrack(url) {
            return true
        }

        // Fifth try: direct access on parent URL.
        if parentURL.startAccessingSecurityScopedResource(),
           runAttemptAndTrack(parentURL) {
            return true
        }

        return false
    }

    /// Releases all security-scoped resource access acquired during conversion
    private func releaseAllSecurityScopedAccess() {
        for url in activeSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopedURLs.removeAll()
    }

    func isConvertingStatus() -> Bool {
        return isConverting
    }

    func evaluateMergeCompatibility(
        for items: [VideoItem],
        preset: ExportPreset,
        metadataTimeout: Duration = BoundedVideoMetadataProbe.defaultTimeout,
        metadataProbe: @escaping @Sendable (URL) async throws -> VideoMetadata = {
            try await VideoMetadataService.shared.metadata(for: $0)
        }
    ) async -> MergeCompatibilityResult {
        lastMergeMetadata = [:]
        // Filter for waiting items, excluding downloads and scheduled downloads
        let waitingItems = items.filter {
            $0.status == .waiting &&
            !$0.isDownloading &&
            $0.scheduledDownloadTime == nil &&
            !$0.isImageSequence // Image sequences are incompatible with merge
        }
        mergeLogger.debug("Evaluating merge compatibility for \(waitingItems.count) waiting clips")
        guard waitingItems.count >= 2 else {
            mergeLogger.debug("Merge incompatible: insufficient items (\(waitingItems.count))")
            return .insufficientItems(waitingItems.count)
        }

        var resolvedMetadata: [UUID: VideoMetadata] = [:]
        for item in waitingItems {
            if Task.isCancelled { return .cancelled }

            if let metadata = item.metadata {
                resolvedMetadata[item.id] = metadata
                continue
            }

            do {
                let metadata = try await BoundedVideoMetadataProbe.metadata(
                    for: item.url,
                    timeout: metadataTimeout,
                    probe: metadataProbe
                )
                resolvedMetadata[item.id] = metadata
            } catch is CancellationError {
                return .cancelled
            } catch {
                mergeLogger.debug("Merge incompatible: metadata unavailable for \(item.name, privacy: .public) – \(error.localizedDescription, privacy: .public)")
                return .metadataUnavailable(item)
            }
        }

        // Populate metadata early so it's available even when clips are incompatible
        // (needed for conformance merge reference picker in the UI)
        lastMergeMetadata = resolvedMetadata

        guard let firstItem = waitingItems.first,
              let referenceMetadata = resolvedMetadata[firstItem.id],
              !referenceMetadata.videoStreams.isEmpty else {
            mergeLogger.debug("Merge incompatible: reference clip missing video track")
            return .missingVideoTrack
        }

        let referenceVideoStreams = referenceMetadata.videoStreams
        let referenceAudio = referenceMetadata.audioStreams.first

        logMetadataSummary(for: waitingItems, metadata: resolvedMetadata)

        for item in waitingItems {
            guard let metadata = resolvedMetadata[item.id], !metadata.videoStreams.isEmpty else {
                mergeLogger.debug("Merge incompatible: \(item.name, privacy: .public) missing video track")
                return .missingVideoTrack
            }

            // Check that video stream count matches
            if metadata.videoStreams.count != referenceVideoStreams.count {
                mergeLogger.debug("Merge incompatible: video stream count mismatch for \(item.name, privacy: .public) \(metadata.videoStreams.count) vs \(referenceVideoStreams.count)")
                // If both have at least one video stream, report as codec mismatch; otherwise missing track
                if metadata.primaryVideoStream != nil && !referenceVideoStreams.isEmpty {
                    return .videoCodecMismatch(item)
                }
                return .missingVideoTrack
            }

            // Compare all video streams
            for (index, (video, referenceVideo)) in zip(metadata.videoStreams, referenceVideoStreams).enumerated() {
                if !stringsEqual(video.codec, referenceVideo.codec) {
                    mergeLogger.debug("Merge incompatible: video codec mismatch in stream \(index) \(item.name, privacy: .public) \(video.codec ?? "unknown", privacy: .public) vs \(referenceVideo.codec ?? "unknown", privacy: .public)")
                    return .videoCodecMismatch(item)
                }

                if video.width != referenceVideo.width || video.height != referenceVideo.height {
                    mergeLogger.debug("Merge incompatible: resolution mismatch in stream \(index) for \(item.name, privacy: .public) \(video.width ?? 0)x\(video.height ?? 0) vs \(referenceVideo.width ?? 0)x\(referenceVideo.height ?? 0)")
                    return .resolutionMismatch(item, expected: referenceVideo)
                }

                if !ratiosEqual(video.pixelAspectRatio, referenceVideo.pixelAspectRatio) {
                    mergeLogger.debug("Merge incompatible: pixel aspect mismatch in stream \(index) for \(item.name, privacy: .public) \(video.pixelAspectRatio?.stringValue ?? "n/a", privacy: .public) vs \(referenceVideo.pixelAspectRatio?.stringValue ?? "n/a", privacy: .public)")
                    return .pixelAspectMismatch(item)
                }

                if !frameRatesEqual(video.frameRate, referenceVideo.frameRate) {
                    mergeLogger.debug("Merge incompatible: frame rate mismatch in stream \(index) for \(item.name, privacy: .public) \(video.frameRate?.stringValue ?? "n/a", privacy: .public) vs \(referenceVideo.frameRate?.stringValue ?? "n/a", privacy: .public)")
                    return .frameRateMismatch(item)
                }
            }

            switch (referenceAudio, metadata.audioStreams.first) {
            case (nil, nil):
                break
            case (nil, .some), (.some, nil):
                mergeLogger.debug("Merge incompatible: audio presence mismatch for \(item.name, privacy: .public)")
                return .audioPresenceMismatch(item)
            case let (.some(refAudio), .some(audio)):
                if audio.channels != refAudio.channels {
                    mergeLogger.debug("Merge incompatible: audio channel mismatch for \(item.name, privacy: .public) \(self.describeInt(audio.channels), privacy: .public) vs \(self.describeInt(refAudio.channels), privacy: .public)")
                    return .audioChannelMismatch(item)
                }
                if audio.sampleRate != refAudio.sampleRate {
                    mergeLogger.debug("Merge incompatible: audio sample rate mismatch for \(item.name, privacy: .public) \(self.describeInt(audio.sampleRate), privacy: .public) vs \(self.describeInt(refAudio.sampleRate), privacy: .public)")
                    return .audioSampleRateMismatch(item)
                }
                if !stringsEqual(audio.codec, refAudio.codec) {
                    mergeLogger.debug("Merge incompatible: audio codec mismatch for \(item.name, privacy: .public) \(audio.codec ?? "unknown", privacy: .public) vs \(refAudio.codec ?? "unknown", privacy: .public)")
                    return .audioCodecMismatch(item)
                }
            }
        }

        mergeLogger.debug("Merge compatibility: PASSED for \(waitingItems.count) clips")
        return .compatible
    }

    private func logMetadataSummary(for items: [VideoItem], metadata: [UUID: VideoMetadata]) {
        for item in items {
            guard let data = metadata[item.id] else { continue }
            let video = data.primaryVideoStream
            let audio = data.audioStreams.first
            mergeLogger.debug(
                "Clip \(item.name, privacy: .public): videoStreams=\(data.videoStreams.count) videoCodec=\(video?.codec ?? "none", privacy: .public) resolution=\(video?.width ?? 0)x\(video?.height ?? 0) par=\(video?.pixelAspectRatio?.stringValue ?? "n/a", privacy: .public) frameRate=\(video?.frameRate?.stringValue ?? "n/a", privacy: .public) audioCodec=\(audio?.codec ?? "none", privacy: .public) channels=\(self.describeInt(audio?.channels), privacy: .public) sampleRate=\(self.describeInt(audio?.sampleRate), privacy: .public)"
            )
        }
    }

    private func describeInt(_ value: Int?) -> String {
        value.map(String.init) ?? "nil"
    }

    enum MergeCompatibilityResult {
        case compatible
        case insufficientItems(Int)
        case metadataUnavailable(VideoItem)
        case missingVideoTrack
        case videoCodecMismatch(VideoItem)
        case resolutionMismatch(VideoItem, expected: VideoMetadata.VideoStream)
        case pixelAspectMismatch(VideoItem)
        case frameRateMismatch(VideoItem)
        case audioPresenceMismatch(VideoItem)
        case audioChannelMismatch(VideoItem)
        case audioSampleRateMismatch(VideoItem)
        case audioCodecMismatch(VideoItem)
        case cancelled

        var tooltip: String {
            switch self {
            case .compatible:
                return "Enable to merge compatible clips into one export."
            case .insufficientItems(let count):
                return count == 0 ? "Add clips to enable merging." : "Need at least two queued clips to merge."
            case .metadataUnavailable(let item):
                return "Metadata is unavailable for \(item.name)."
            case .missingVideoTrack:
                return "All clips must contain a video track for merging."
            case .videoCodecMismatch:
                return "Video codec mismatch between clips."
            case .resolutionMismatch(let item, let expected):
                let expectedRes = "\(expected.width ?? 0)x\(expected.height ?? 0)"
                return "Resolution mismatch involving \(item.name). Expected \(expectedRes)."
            case .pixelAspectMismatch:
                return "Pixel aspect ratio mismatch between clips."
            case .frameRateMismatch:
                return "Frame rate mismatch between clips."
            case .audioPresenceMismatch:
                return "Some clips have audio while others do not."
            case .audioChannelMismatch:
                return "Audio channel count mismatch between clips."
            case .audioSampleRateMismatch:
                return "Audio sample rate mismatch between clips."
            case .audioCodecMismatch:
                return "Audio codec mismatch between clips."
            case .cancelled:
                return "Compatibility check cancelled."
            }
        }
    }

    /// Pure compatibility check that doesn't mutate actor state.
    /// Use this from UI code (e.g. card import dialog) where you already have metadata loaded.
    static func checkMergeCompatibility(
        items: [VideoItem],
        metadata: [UUID: VideoMetadata]
    ) -> MergeCompatibilityResult {
        let waitingItems = items.filter {
            $0.status == .waiting &&
            !$0.isDownloading &&
            $0.scheduledDownloadTime == nil &&
            !$0.isImageSequence
        }
        guard waitingItems.count >= 2 else {
            return .insufficientItems(waitingItems.count)
        }

        guard let firstItem = waitingItems.first else {
            return .insufficientItems(0)
        }
        guard let referenceMetadata = metadata[firstItem.id] else {
            return .metadataUnavailable(firstItem)
        }
        guard !referenceMetadata.videoStreams.isEmpty else {
            return .missingVideoTrack
        }

        let referenceVideoStreams = referenceMetadata.videoStreams
        let referenceAudio = referenceMetadata.audioStreams.first

        for item in waitingItems {
            guard let meta = metadata[item.id] else {
                return .metadataUnavailable(item)
            }
            guard !meta.videoStreams.isEmpty else {
                return .missingVideoTrack
            }

            if meta.videoStreams.count != referenceVideoStreams.count {
                if meta.primaryVideoStream != nil && !referenceVideoStreams.isEmpty {
                    return .videoCodecMismatch(item)
                }
                return .missingVideoTrack
            }

            for (video, referenceVideo) in zip(meta.videoStreams, referenceVideoStreams) {
                if (video.codec?.lowercased() ?? "") != (referenceVideo.codec?.lowercased() ?? "") {
                    return .videoCodecMismatch(item)
                }
                if video.width != referenceVideo.width || video.height != referenceVideo.height {
                    return .resolutionMismatch(item, expected: referenceVideo)
                }
                // PAR check
                let parEqual: Bool = {
                    switch (video.pixelAspectRatio, referenceVideo.pixelAspectRatio) {
                    case (nil, nil): return true
                    case let (l?, r?):
                        if let lv = l.doubleValue, let rv = r.doubleValue { return abs(lv - rv) <= 0.001 }
                        return l.stringValue == r.stringValue
                    case (nil, let r?):
                        if let v = r.doubleValue { return abs(v - 1.0) <= 0.001 }
                        let n = r.stringValue.replacingOccurrences(of: " ", with: "").lowercased()
                        return n == "1:1" || n == "1" || n == "0:1"
                    case (let l?, nil):
                        if let v = l.doubleValue { return abs(v - 1.0) <= 0.001 }
                        let n = l.stringValue.replacingOccurrences(of: " ", with: "").lowercased()
                        return n == "1:1" || n == "1" || n == "0:1"
                    }
                }()
                if !parEqual { return .pixelAspectMismatch(item) }

                // Frame rate check
                let frEqual: Bool = {
                    switch (video.frameRate?.value, referenceVideo.frameRate?.value) {
                    case (nil, nil): return true
                    case let (l?, r?): return abs(l - r) <= 0.01
                    default: return video.frameRate?.stringValue == referenceVideo.frameRate?.stringValue
                    }
                }()
                if !frEqual { return .frameRateMismatch(item) }
            }

            switch (referenceAudio, meta.audioStreams.first) {
            case (nil, nil): break
            case (nil, .some), (.some, nil):
                return .audioPresenceMismatch(item)
            case let (.some(refAudio), .some(audio)):
                if audio.channels != refAudio.channels { return .audioChannelMismatch(item) }
                if audio.sampleRate != refAudio.sampleRate { return .audioSampleRateMismatch(item) }
                if (audio.codec?.lowercased() ?? "") != (refAudio.codec?.lowercased() ?? "") {
                    return .audioCodecMismatch(item)
                }
            }
        }

        return .compatible
    }

    /// Groups items into clusters where all items in a cluster are merge-compatible.
    static func groupByCompatibility(
        items: [VideoItem],
        metadata: [UUID: VideoMetadata]
    ) -> [[VideoItem]] {
        guard !items.isEmpty else { return [] }

        var groups: [[VideoItem]] = []

        for item in items {
            guard let itemMeta = metadata[item.id],
                  !itemMeta.videoStreams.isEmpty else {
                groups.append([item])
                continue
            }

            var placed = false
            for groupIndex in groups.indices {
                guard let first = groups[groupIndex].first,
                      let firstMeta = metadata[first.id] else { continue }

                let twoItems = [first, item]
                let twoMeta = [first.id: firstMeta, item.id: itemMeta]
                if case .compatible = checkMergeCompatibility(items: twoItems, metadata: twoMeta) {
                    groups[groupIndex].append(item)
                    placed = true
                    break
                }
            }

            if !placed {
                groups.append([item])
            }
        }

        return groups
    }

    /// Exposes the metadata gathered during the last merge compatibility check.
    /// Available even when clips are incompatible — used by conformance merge UI.
    func getLastMergeMetadata() -> [UUID: VideoMetadata] {
        return lastMergeMetadata
    }

    /// Analyzes what each clip needs to change to conform to a reference clip's format.
    static func analyzeConformance(
        items: [VideoItem],
        referenceItemID: UUID,
        metadata: [UUID: VideoMetadata]
    ) -> [ConformanceAnalysis] {
        guard let refMeta = metadata[referenceItemID],
              let refVideo = refMeta.primaryVideoStream else { return [] }
        let refAudio = refMeta.audioStreams.first

        return items.map { item in
            guard let itemMeta = metadata[item.id],
                  let itemVideo = itemMeta.primaryVideoStream else {
                return ConformanceAnalysis(
                    id: item.id, itemName: item.name,
                    needsVideoReencode: true, needsAudioReencode: true,
                    videoMismatches: ["No video metadata"], audioMismatches: []
                )
            }
            let itemAudio = itemMeta.audioStreams.first

            var videoMismatches: [String] = []
            if (itemVideo.codec?.lowercased() ?? "") != (refVideo.codec?.lowercased() ?? "") {
                videoMismatches.append("Codec: \(itemVideo.codec ?? "?") → \(refVideo.codec ?? "?")")
            }
            if itemVideo.width != refVideo.width || itemVideo.height != refVideo.height {
                videoMismatches.append("Resolution: \(itemVideo.width ?? 0)x\(itemVideo.height ?? 0) → \(refVideo.width ?? 0)x\(refVideo.height ?? 0)")
            }
            let itemFR = itemVideo.frameRate?.value
            let refFR = refVideo.frameRate?.value
            if let i = itemFR, let r = refFR, abs(i - r) > 0.01 {
                videoMismatches.append("Frame rate: \(String(format: "%.2f", i)) → \(String(format: "%.2f", r))")
            } else if (itemFR == nil) != (refFR == nil) {
                videoMismatches.append("Frame rate mismatch")
            }

            var audioMismatches: [String] = []
            switch (itemAudio, refAudio) {
            case (nil, .some(let r)):
                audioMismatches.append("No audio → \(r.codec ?? "?") \(r.channels ?? 0)ch")
            case (.some, nil):
                audioMismatches.append("Audio will be removed")
            case let (.some(a), .some(r)):
                if (a.codec?.lowercased() ?? "") != (r.codec?.lowercased() ?? "") {
                    audioMismatches.append("Codec: \(a.codec ?? "?") → \(r.codec ?? "?")")
                }
                if a.channels != r.channels {
                    audioMismatches.append("Channels: \(a.channels ?? 0) → \(r.channels ?? 0)")
                }
                if a.sampleRate != r.sampleRate {
                    audioMismatches.append("Sample rate: \(a.sampleRate ?? 0) → \(r.sampleRate ?? 0)")
                }
            case (nil, nil):
                break
            }

            return ConformanceAnalysis(
                id: item.id,
                itemName: item.name,
                needsVideoReencode: !videoMismatches.isEmpty,
                needsAudioReencode: !audioMismatches.isEmpty,
                videoMismatches: videoMismatches,
                audioMismatches: audioMismatches
            )
        }
    }

    private func stringsEqual(_ lhs: String?, _ rhs: String?) -> Bool {
        (lhs?.lowercased() ?? "") == (rhs?.lowercased() ?? "")
    }

    private func ratiosEqual(_ lhs: VideoMetadata.Ratio?, _ rhs: VideoMetadata.Ratio?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            if let lhsValue = lhs.doubleValue, let rhsValue = rhs.doubleValue {
                return abs(lhsValue - rhsValue) <= 0.001
            }
            return lhs.stringValue == rhs.stringValue
        case let (nil, rhs?):
            return isUnityRatio(rhs)
        case let (lhs?, nil):
            return isUnityRatio(lhs)
        }
    }

    private func isUnityRatio(_ ratio: VideoMetadata.Ratio) -> Bool {
        if let value = ratio.doubleValue {
            return abs(value - 1.0) <= 0.001
        }
        let normalized = ratio.stringValue.replacingOccurrences(of: " ", with: "").lowercased()
        return normalized == "1:1" || normalized == "1" || normalized == "0:1"
    }

    private func frameRatesEqual(_ lhs: VideoMetadata.FrameRate?, _ rhs: VideoMetadata.FrameRate?) -> Bool {
        switch (lhs?.value, rhs?.value) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return abs(lhs - rhs) <= 0.01
        default: return lhs?.stringValue == rhs?.stringValue
        }
    }

    /// Converts all items in an encoding group using the group's own settings.
    /// Caller must provide the items binding and resolved group settings as plain values.
    func convertGroup(
        items: Binding<[VideoItem]>,
        outputFolder: String,
        preset: ExportPreset,
        concatEnabled: Bool,
        groupName: String? = nil,
        transcriptionEnabled: Bool,
        uploadEnabled: Bool,
        analyticsEnabled: Bool,
        conformanceMergeEnabled: Bool = false,
        conformanceReferenceItemID: UUID? = nil,
        conformanceMetadata: [UUID: VideoMetadata]? = nil
    ) async {
        let batchID = UUID()
        activeBatchID = batchID
        self.isConverting = true
        self.currentDroppedFiles = items
        self.currentOutputFolder = outputFolder
        self.currentPreset = preset

        // Apply group-level settings to individual items
        if transcriptionEnabled || uploadEnabled || analyticsEnabled {
            await MainActor.run {
                for i in items.wrappedValue.indices {
                    if transcriptionEnabled {
                        items.wrappedValue[i].subtitleEnabled = true
                    }
                    if uploadEnabled {
                        items.wrappedValue[i].uploadEnabled = true
                    }
                    if analyticsEnabled {
                        items.wrappedValue[i].analyticsEnabled = true
                    }
                }
                if uploadEnabled {
                    UploadManager.shared.videoItems = items
                }
            }
        }

        if conformanceMergeEnabled,
           let refID = conformanceReferenceItemID,
           let meta = conformanceMetadata,
           items.wrappedValue.filter({ $0.status == .waiting }).count >= 2 {
            // Two-pass conformance merge: re-encode mismatched clips, then stream-copy concat
            beginMergePreparation(batchID: batchID, items: items.wrappedValue)
            let preparedPlan = await buildConformanceMergePlan(
                from: items.wrappedValue,
                metadata: meta,
                referenceItemID: refID,
                outputFolder: outputFolder,
                groupName: groupName,
                batchID: batchID,
                statusUpdate: { message in
                    // Could update UI status here in future
                    self.mergeLogger.info("\(message, privacy: .public)")
                }
            )
            let preparationIsActive = isMergePreparationActive(batchID)
            finishMergePreparation(batchID: batchID)
            if preparationIsActive {
                self.mergePlan = preparedPlan
            } else {
                if let preparedPlan { cleanupMergeArtifacts(for: preparedPlan) }
                guard isBatchActive(batchID) else { return }
                self.mergePlan = nil
            }
        } else if concatEnabled && items.wrappedValue.filter({ $0.status == .waiting }).count >= 2 {
            beginMergePreparation(batchID: batchID, items: items.wrappedValue)
            let preparedPlan = await buildMergePlan(
                from: items.wrappedValue,
                preset: preset,
                outputFolder: outputFolder,
                groupName: groupName,
                batchID: batchID
            )
            let preparationIsActive = isMergePreparationActive(batchID)
            finishMergePreparation(batchID: batchID)
            if preparationIsActive {
                self.mergePlan = preparedPlan
            } else {
                if let preparedPlan { cleanupMergeArtifacts(for: preparedPlan) }
                guard isBatchActive(batchID) else { return }
                self.mergePlan = nil
            }
        } else {
            self.mergePlan = nil
        }

        startProgressTimer(droppedFiles: items)
        guard isBatchActive(batchID) else { return }
        // Install the completion continuation before starting work. The actor can
        // be re-entered while convertNextFile awaits process launch, so cancellation
        // must never be able to arrive before the waiter exists.
        await withCheckedContinuation { continuation in
            self.batchCompletionContinuation = (batchID, continuation)
            Task {
                await self.convertNextFile(
                    droppedFiles: items,
                    outputFolder: outputFolder,
                    preset: preset,
                    batchID: batchID
                )
            }
        }
    }

    func startConversion(
        droppedFiles: Binding<[VideoItem]>,
        outputFolder: String,
        preset: ExportPreset = .videoLoop,
        mergeClipsEnabled: Bool = false,
        limitToIDs: Set<UUID>? = nil
    ) async {
        guard !self.isConverting else { return }
        let batchID = UUID()
        activeBatchID = batchID
        self.isConverting = true
        self.allowedItemIDs = limitToIDs
        self.currentDroppedFiles = droppedFiles
        self.currentOutputFolder = outputFolder
        self.currentPreset = preset
        if mergeClipsEnabled {
            beginMergePreparation(batchID: batchID, items: droppedFiles.wrappedValue)
            let preparedPlan = await buildMergePlan(
                from: droppedFiles.wrappedValue,
                preset: preset,
                outputFolder: outputFolder,
                batchID: batchID
            )
            let preparationIsActive = isMergePreparationActive(batchID)
            finishMergePreparation(batchID: batchID)
            if preparationIsActive {
                self.mergePlan = preparedPlan
            } else {
                if let preparedPlan { cleanupMergeArtifacts(for: preparedPlan) }
                guard isBatchActive(batchID) else { return }
                self.mergePlan = nil
            }
        } else {
            self.mergePlan = nil
        }
        progressContinuation?.yield(0.0)
        // Start periodic updates so dock appears immediately
        startProgressTimer(droppedFiles: droppedFiles)
        guard isBatchActive(batchID) else { return }
        // Install the completion continuation before starting work. The actor can
        // be re-entered while convertNextFile awaits process launch, so cancellation
        // must never be able to arrive before the waiter exists.
        await withCheckedContinuation { continuation in
            self.batchCompletionContinuation = (batchID, continuation)
            Task {
                await self.convertNextFile(
                    droppedFiles: droppedFiles,
                    outputFolder: outputFolder,
                    preset: preset,
                    batchID: batchID
                )
            }
        }
    }

    private func convertNextFile(
        droppedFiles: Binding<[VideoItem]>,
        outputFolder: String,
        preset: ExportPreset,
        batchID: UUID
    ) async {
        guard isConverting, activeBatchID == batchID else { return }

        // Update overall progress before starting next file
        await updateOverallProgress(droppedFiles: droppedFiles)
        guard isConverting, activeBatchID == batchID else { return }

        if let plan = mergePlan, !plan.hasExecuted {
            mergePlan?.hasExecuted = true
            await executeMergePlan(droppedFiles: droppedFiles, batchID: batchID)
            return
        }

        guard let nextFile = ConversionQueueState.nextItem(
            in: droppedFiles.wrappedValue,
            allowedItemIDs: allowedItemIDs
        ) else {
            self.isConverting = false
            self.activeBatchID = nil
            self.allowedItemIDs = nil
            progressContinuation?.yield(1.0)
            stopProgressTimer()
            releaseAllSecurityScopedAccess()
            // Signal batch completion so startConversion/convertGroup can return
            finishBatch(batchID)
            return
        }
        
        let fileId = nextFile.id
        guard let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == fileId }) else {
            await convertNextFile(
                droppedFiles: droppedFiles,
                outputFolder: outputFolder,
                preset: preset,
                batchID: batchID
            )
            return
        }
        
        // Ensure the metadata an encode actually needs (duration, video-stream presence,
        // output URL, full metadata) is loaded before conversion. We deliberately pass
        // `generateRowThumbnailIfMissing: false` so encode start NEVER blocks on row-thumbnail
        // generation: for non-native card formats (MKV/MXF/MTS) the row thumbnail is produced by
        // an FFmpeg seek+decode that can take several seconds, and it is not needed to start
        // encoding. The row thumbnail is populated independently on the import background task
        // (`loadGroupItemDetails` / the per-item detail load). A thumbnail already cached on disk
        // is still picked up cheaply here.
        if !droppedFiles.wrappedValue[idx].detailsLoaded {
            let details = await VideoFileUtils.loadDetails(
                for: droppedFiles.wrappedValue[idx].url,
                outputFolder: outputFolder,
                preset: preset,
                generateRowThumbnailIfMissing: false
            )
            droppedFiles.wrappedValue[idx].apply(details: details)
            droppedFiles.wrappedValue[idx].detailsLoaded = true
        }
        guard isConverting, activeBatchID == batchID else { return }
        
        // Update status to converting
        droppedFiles.wrappedValue[idx].status = .converting

        let currentItem = droppedFiles.wrappedValue[idx]
        let inputURL = currentItem.url

        // Ensure input file is accessible with security-scoped access
        if !ensureInputFileAccessible(at: inputURL) {
            logger.error("Failed to access input file: \(inputURL.path, privacy: .public)")
            await MainActor.run {
                droppedFiles.wrappedValue[idx].status = .failed
                droppedFiles.wrappedValue[idx].progress = 0
                droppedFiles.wrappedValue[idx].conversionError = "Cannot access input file"
                droppedFiles.wrappedValue[idx].eta = nil
                droppedFiles.wrappedValue[idx].statusMessage = nil
                SoundManager.shared.playError()
            }
            await convertNextFile(
                droppedFiles: droppedFiles,
                outputFolder: outputFolder,
                preset: preset,
                batchID: batchID
            )
            return
        }

        let outputFileName = outputBaseName(for: currentItem, inputURL: inputURL, preset: preset)
        let resolvedOutputFolder = VideoFileUtils.resolveOutputFolder(for: inputURL, defaultOutputFolder: outputFolder, preset: preset) ?? outputFolder

        // Ensure the output directory exists with proper security-scoped access
        let resolvedOutputFolderURL = URL(fileURLWithPath: resolvedOutputFolder)
        guard ensureDirectoryAccessible(at: resolvedOutputFolderURL) else {
            logger.error("Failed to access output directory: \(resolvedOutputFolder, privacy: .public)")
            await MainActor.run {
                droppedFiles.wrappedValue[idx].status = .failed
                droppedFiles.wrappedValue[idx].progress = 0
                droppedFiles.wrappedValue[idx].conversionError = "Cannot access output directory"
                droppedFiles.wrappedValue[idx].eta = nil
                droppedFiles.wrappedValue[idx].statusMessage = nil
                SoundManager.shared.playError()
            }
            await convertNextFile(
                droppedFiles: droppedFiles,
                outputFolder: outputFolder,
                preset: preset,
                batchID: batchID
            )
            return
        }

        let outputURL = URL(fileURLWithPath: resolvedOutputFolder).appendingPathComponent(outputFileName)

        let waveformPreferences = AudioWaveformPreferences.loadConfig()
        let resolvedWaveformResolution = preset.resolvedWaveformResolution(defaultResolution: waveformPreferences.resolution)

        // Check if waveform generation is compatible with audio routing
        let canGenerateWaveform = {
            guard preset != .streamCopy && currentItem.requiresWaveformVideo else { return false }
            // splitToMono is incompatible with waveform video (needs 2 separate audio outputs)
            if case .splitToMono = currentItem.audioRoutingConfig?.channelOperation {
                return false
            }
            return true
        }()

        let waveformRequest: WaveformVideoRequest? = canGenerateWaveform ? {
            return WaveformVideoRequest(
                width: Int(resolvedWaveformResolution.width),
                height: Int(resolvedWaveformResolution.height),
                backgroundHex: waveformPreferences.backgroundHex,
                foregroundHex: waveformPreferences.foregroundHex,
                normalizeAudio: waveformPreferences.normalizeAudio,
                style: waveformPreferences.style,
                frameRate: waveformPreferences.frameRate,
                renderingEngine: waveformPreferences.renderingEngine,
                swiftStyle: waveformPreferences.swiftStyle,
                bandCount: waveformPreferences.bandCount,
                frequencyDistribution: waveformPreferences.frequencyDistribution,
                foregroundGradientEnabled: waveformPreferences.foregroundGradientEnabled,
                foregroundGradientEndHex: waveformPreferences.foregroundGradientEndHex,
                backgroundGradientEnabled: waveformPreferences.backgroundGradientEnabled,
                backgroundGradientEndHex: waveformPreferences.backgroundGradientEndHex,
                waveformOpacity: waveformPreferences.waveformOpacity
            )
        }() : nil

        let synthesizedVideoRequest: SynthesizedVideoRequest? = {
            guard waveformRequest == nil else { return nil }
            guard preset.outputsVideoTrack else { return nil }
            guard !currentItem.hasVideoStream else { return nil }
            // splitToMono is incompatible with video generation (needs 2 separate audio outputs)
            if case .splitToMono = currentItem.audioRoutingConfig?.channelOperation {
                return nil
            }
            return SynthesizedVideoRequest(
                width: Int(resolvedWaveformResolution.width),
                height: Int(resolvedWaveformResolution.height),
                backgroundHex: waveformPreferences.backgroundHex,
                frameRate: waveformPreferences.frameRate,
                includeAudio: true
            )
        }()

        // For image sequence input, pass the FFMPEG input arguments and expected duration
        var customInputArguments = currentItem.imageSequenceConfig?.ffmpegInputArguments
#if DEBUG
        // Keep the real process/cancellation path under UI test while ensuring a
        // tiny fixture cannot finish before automation has a chance to cancel it.
        if customInputArguments == nil,
           ProcessInfo.processInfo.environment["AMC_UI_TEST_REALTIME_INPUT"] == "1" {
            customInputArguments = ["-re", "-i", inputURL.path]
        }
#endif
        let imageSeqExpectedDuration = currentItem.imageSequenceConfig?.durationSeconds

        // Auto-populate DCP/IMF metadata when the user never opened the editor.
        // The CPL/PKL embed `ContentTitleText` literally, so handing FFMPEGConverter
        // the raw filename would put the source extension into the cinema package.
        // Default the title to the filename minus extension and pick up the user's
        // last-used contentKind so batches of trailers don't have to be re-edited.
        let resolvedDCPMetadata = resolveDCPMetadata(for: currentItem, preset: preset, inputURL: inputURL)
        let resolvedIMFMetadata = resolveIMFMetadata(for: currentItem, preset: preset, inputURL: inputURL)

        let conversionRequest = ConversionRequest(
            inputURL: inputURL,
            outputURL: outputURL,
            preset: preset,
            comment: currentItem.comment,
            includeDateTag: currentItem.includeDateTag,
            sourceMetadata: currentItem.metadata,
            sourceCameraMetadata: currentItem.cameraMetadata,
            dcpMetadata: resolvedDCPMetadata,
            imfMetadata: resolvedIMFMetadata,
            trimStart: currentItem.trimStart,
            trimEnd: currentItem.trimEnd,
            expectedDuration: imageSeqExpectedDuration,
            videoFrameRate: currentItem.metadata?.primaryVideoStream?.frameRate?.value,
            audioRoutingConfig: currentItem.audioRoutingConfig,
            cropConfig: currentItem.cropConfig,
            timecodeConfig: currentItem.timecodeConfig,
            isMuted: currentItem.isMuted,
            waveformRequest: waveformRequest,
            synthesizedVideoRequest: synthesizedVideoRequest,
            waveformBackgroundImageURL: currentItem.waveformBackgroundImageURL,
            visualSourceURL: currentItem.imageSequenceConfig?.firstFrameURL,
            customInputArguments: customInputArguments
        )

        // Throttle UI updates to ~4 Hz to avoid SwiftUI re-render storms during encoding
        let singleUIThrottle = OSAllocatedUnfairLock(initialState: Date.distantPast)
        let av2Settings = preset == .av2 ? AV2Settings() : nil
        let outputExtension = av2Settings?.container.fileExtension ?? preset.outputExtension(for: inputURL)
        await ffmpegConverter.convert(
            request: conversionRequest,
            av2Settings: av2Settings,
            progressUpdate: { progress, status in
                let now = Date()
                let shouldUpdate = singleUIThrottle.withLock { last -> Bool in
                    guard progress < 1.0 else { return true }
                    guard now.timeIntervalSince(last) >= 0.25 else { return false }
                    last = now
                    return true
                }
                guard shouldUpdate else { return }
                let isDuration = progressIsDuration(status)
                Task { @MainActor in
                    if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == fileId }) {
                        droppedFiles.wrappedValue[idx].progress = progress
                        if isDuration {
                            droppedFiles.wrappedValue[idx].eta = status
                            droppedFiles.wrappedValue[idx].statusMessage = nil
                        } else {
                            droppedFiles.wrappedValue[idx].statusMessage = status
                        }
                    }
                }
            }
        ) { success, errorReason in
            Task { @MainActor in
                // A cancelled batch may finish after the user has reset and started
                // another one. Never let that stale callback mutate the new batch.
                guard await self.isBatchActive(batchID) else { return }

                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == fileId }) {
                    // Capture file size FIRST (before setting status to .done)
                    // This ensures all data is ready before SwiftUI re-renders
                    var capturedSize: Int64?
                    var outputFileURL: URL?

                    if success {
                        if preset == .imageSequence || preset == .dcp || preset == .imfJ2K || preset == .imfProRes {
                            // For image sequence / DCP / IMF export, the output is a subfolder
                            // Point outputURL to the subfolder (same name as outputBaseName)
                            let subfolderName = outputURL.lastPathComponent
                            let subfolderURL = outputURL.deletingLastPathComponent().appendingPathComponent(subfolderName, isDirectory: true)
                            outputFileURL = subfolderURL

                            // Compute total size of all files in the subfolder
                            if let contents = try? FileManager.default.contentsOfDirectory(at: subfolderURL, includingPropertiesForKeys: [.fileSizeKey]) {
                                capturedSize = contents.reduce(Int64(0)) { total, fileURL in
                                    let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
                                    return total + size
                                }
                            }
                        } else {
                            outputFileURL = outputURL.appendingPathExtension(outputExtension)
                        }

                        // Capture file size - try multiple approaches
                        if let url = outputFileURL, capturedSize == nil {
                            // First try: direct file access (may work if app created the file)
                            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                               let fileSize = attrs[.size] as? Int64 {
                                capturedSize = fileSize
                                self.logger.debug("Captured file size (direct): \(fileSize) bytes")
                            }

                            // Second try: with security-scoped access on file
                            if capturedSize == nil {
                                let hasFileAccess = url.startAccessingSecurityScopedResource()
                                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                                   let fileSize = attrs[.size] as? Int64 {
                                    capturedSize = fileSize
                                    self.logger.debug("Captured file size (file scope): \(fileSize) bytes")
                                }
                                if hasFileAccess {
                                    url.stopAccessingSecurityScopedResource()
                                }
                            }

                            // Third try: with security-scoped access on folder via bookmark
                            if capturedSize == nil {
                                let outputFolderURL = url.deletingLastPathComponent()
                                let hasFolderAccess = SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: outputFolderURL)
                                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                                   let fileSize = attrs[.size] as? Int64 {
                                    capturedSize = fileSize
                                    self.logger.debug("Captured file size (folder bookmark): \(fileSize) bytes")
                                }
                                if hasFolderAccess {
                                    SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: outputFolderURL)
                                }
                            }

                            if capturedSize == nil {
                                self.logger.warning("Failed to capture file size for: \(url.path, privacy: .public)")
                                self.logger.warning("File exists: \(FileManager.default.fileExists(atPath: url.path))")
                            }
                        }
                    }

                    // Update all properties by replacing the entire item
                    // This ensures SwiftUI detects the change
                    var updatedItem = droppedFiles.wrappedValue[idx]

                    if success, let url = outputFileURL {
                        updatedItem.outputURL = url
                        updatedItem.outputFileSizeBytes = capturedSize
                    }

                    // If user previously cancelled this item, keep it as .cancelled
                    if updatedItem.status != .cancelled {
                        updatedItem.status = success ? .done : .failed
                        updatedItem.progress = success ? 1.0 : 0
                        updatedItem.conversionError = success ? nil : errorReason
                        updatedItem.eta = nil
                        updatedItem.statusMessage = nil
                    }

                    // Replace the entire item to ensure SwiftUI detects the change
                    droppedFiles.wrappedValue[idx] = updatedItem

                    // Debug: verify the values
                    self.logger.debug("Final state - outputFileSizeBytes: \(droppedFiles.wrappedValue[idx].outputFileSizeBytes ?? -1)")
                    self.logger.debug("Final state - formattedOutputSize: \(droppedFiles.wrappedValue[idx].formattedOutputSize ?? "nil", privacy: .public)")
                    self.logger.debug("Final state - status: \(String(describing: droppedFiles.wrappedValue[idx].status), privacy: .public)")

                    // Trigger upload if enabled for this item
                    if let itemID = ConversionUploadFollowUp.itemID(
                        afterSuccess: success, item: droppedFiles.wrappedValue[idx]
                    ) {
                        Task {
                            UploadManager.shared.startUpload(itemID: itemID)
                        }
                    }

                    // Trigger subtitle generation if enabled for this item
                    if success && droppedFiles.wrappedValue[idx].subtitleEnabled {
                        let method = droppedFiles.wrappedValue[idx].subtitleMethod
                        switch method {
                        case .ocr:
                            if let outputURL = droppedFiles.wrappedValue[idx].outputURL {
                                // OCR reads from the original source file (PGS lives in the MKV, not the re-encode)
                                // but saves the SRT alongside the encoded output
                                let sourceURL = droppedFiles.wrappedValue[idx].url
                                let metadata  = droppedFiles.wrappedValue[idx].metadata
                                Task {
                                    await self.generateOCRSubtitles(
                                        for: fileId,
                                        sourceURL: sourceURL,
                                        outputURL: outputURL,
                                        metadata: metadata,
                                        droppedFiles: droppedFiles
                                    )
                                }
                            }
                        case .whisper:
                            if let outputURL = droppedFiles.wrappedValue[idx].outputURL {
                                Task {
                                    await self.generateSubtitles(
                                        for: fileId,
                                        inputURL: outputURL,
                                        droppedFiles: droppedFiles
                                    )
                                }
                            }
                        case .parakeet:
                            if let outputURL = droppedFiles.wrappedValue[idx].outputURL {
                                Task {
                                    await self.generateParakeetSubtitles(
                                        for: fileId,
                                        inputURL: outputURL,
                                        droppedFiles: droppedFiles
                                    )
                                }
                            }
                        }
                    }

                    // Trigger quality analytics if enabled for this item
                    if success && droppedFiles.wrappedValue[idx].analyticsEnabled {
                        if let outputURL = droppedFiles.wrappedValue[idx].outputURL {
                            let sourceURL = droppedFiles.wrappedValue[idx].url
                            if let analyticsURL = self.resolveAnalyticsSourceURL(for: outputURL, preset: preset) {
                                Task {
                                    await self.runAnalytics(
                                        for: fileId,
                                        sourceURL: sourceURL,
                                        encodedURL: analyticsURL,
                                        droppedFiles: droppedFiles
                                    )
                                }
                            } else {
                                droppedFiles.wrappedValue[idx].analyticsStatus = .failed("Could not locate wrapped video essence in package")
                            }
                        }
                    }
                }

                // Only continue if conversion has not been cancelled
                if await self.isBatchActive(batchID) {
                    await self.convertNextFile(
                        droppedFiles: droppedFiles,
                        outputFolder: outputFolder,
                        preset: preset,
                        batchID: batchID
                    )
                }
                
                Task { @MainActor in
                    if !success {
                        SoundManager.shared.playError()
                    }
                }
            }
        }
    }

    func cancelConversion() async {
        let cancelledBatchID = activeBatchID
        self.isConverting = false
        self.activeBatchID = nil
        cancelMergePreparation()
        cancelAllSubtitleEmbeddings()
        await ffmpegConverter.cancelConversion()
        currentProcess = nil

        // Clean up merge temp files if a merge was in progress
        if let plan = mergePlan {
            cleanupMergeArtifacts(for: plan)
            mergePlan = nil
        }

        // Update UI-bound items to cancelled
        if let droppedFiles = currentDroppedFiles {
            ConversionQueueState.cancel(&droppedFiles.wrappedValue, scope: .converting)
        }

        // Update internal queue
        for idx in conversionQueue.indices where conversionQueue[idx].status == .converting {
            conversionQueue[idx].status = .cancelled
        }
        stopProgressTimer()
        releaseAllSecurityScopedAccess()
        // Signal batch completion so the caller's await returns
        finishBatch(cancelledBatchID)
    }

    /// Cancels a single video item without aborting the entire queue
    func cancelItem(with id: UUID) async {
        cancelMergePreparation(for: id)
        cancelSubtitleEmbedding(itemID: id, operationID: nil)
        if let plan = mergePlan, !plan.hasExecuted, plan.itemIDs.contains(id) {
            cleanupMergeArtifacts(for: plan)
            mergePlan = nil
        }
        guard let droppedFiles = currentDroppedFiles else { return }
        
        // If the item is currently converting
        if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == id && $0.status == .converting }) {
            await ffmpegConverter.cancelConversion()
            currentProcess = nil
            droppedFiles.wrappedValue[idx].status = .cancelled
        #if DEBUG
        logger.debug("Item \(droppedFiles.wrappedValue[idx].name, privacy: .public) cancelled (was converting)")
        #endif
            droppedFiles.wrappedValue[idx].progress = 0.0
            droppedFiles.wrappedValue[idx].eta = nil
            droppedFiles.wrappedValue[idx].statusMessage = nil
            
            // Re-compute overall progress; the existing convertNextFile call in the
            // original conversion's completion handler will continue the queue, so
            // we must NOT start a new one here to avoid parallel encodes.
            await updateOverallProgress(droppedFiles: droppedFiles)
            return
        }
        
        // If the item is still waiting, simply mark as cancelled
        if let waitingIdx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == id && $0.status == .waiting }) {
            droppedFiles.wrappedValue[waitingIdx].status = .cancelled
            #if DEBUG
            logger.debug("Item \(droppedFiles.wrappedValue[waitingIdx].name, privacy: .public) cancelled (was waiting)")
            #endif
            await updateOverallProgress(droppedFiles: droppedFiles)
        }
    }
    func cancelAllConversions() async {
        let cancelledBatchID = activeBatchID
        self.isConverting = false
        self.activeBatchID = nil
        cancelMergePreparation()
        cancelAllSubtitleEmbeddings()
        await ffmpegConverter.cancelConversion()

        // Clean up merge temp files if a merge was in progress
        if let plan = mergePlan {
            cleanupMergeArtifacts(for: plan)
            mergePlan = nil
        }

        // Update UI-bound items to cancelled
        if let droppedFiles = currentDroppedFiles {
            ConversionQueueState.cancel(&droppedFiles.wrappedValue, scope: .waitingAndConverting)
        }

        // Clear internal queue
        conversionQueue.removeAll()
        progressContinuation?.yield(0.0)
        stopProgressTimer()
        releaseAllSecurityScopedAccess()
        finishBatch(cancelledBatchID)
    }

    private func isBatchActive(_ batchID: UUID) -> Bool {
        isConverting && activeBatchID == batchID
    }

    private func finishBatch(_ batchID: UUID?) {
        guard let batchID,
              let waiter = batchCompletionContinuation,
              waiter.batchID == batchID else { return }
        batchCompletionContinuation = nil
        waiter.continuation.resume()
    }
    
    // Convert duration string ("hh:mm:ss" or "mm:ss" or "ss") to seconds
    private func timeStringToSeconds(_ str: String) -> Double {
        let components = str.split(separator: ":").map { Double($0) ?? 0 }
        switch components.count {
        case 3:
            return components[0] * 3600 + components[1] * 60 + components[2]
        case 2:
            return components[0] * 60 + components[1]
        case 1:
            return components[0]
        default:
            return 0
        }
    }
    
    private func updateOverallProgress(droppedFiles: Binding<[VideoItem]>) async {
        #if DEBUG
        logger.debug("updateOverallProgress called")
        #endif
        let files = droppedFiles.wrappedValue
        
        let progress = ConversionQueueState.overallProgress(for: files)
        #if DEBUG
        logger.debug("overallProgress: \(progress * 100)%")
        #endif
        progressContinuation?.yield(progress)
    }

    // MARK: - Subtitle Generation

    /// Generates subtitles for a completed conversion
    private func generateSubtitles(
        for itemID: UUID,
        inputURL: URL,
        droppedFiles: Binding<[VideoItem]>
    ) async {
        logger.info("[subtitle-trigger] post-encode Whisper for item \(itemID, privacy: .public) inputURL=\(inputURL.lastPathComponent, privacy: .public)")
        let settings = transcriptionSettings.transcriptionSnapshot()
        let model = settings.whisperModel
        let language = settings.whisperLanguage

        let operationID = UUID()
        // Publish the attempt token before dispatching work so an immediate cancel is routable.
        await MainActor.run {
            if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                droppedFiles.wrappedValue[idx].subtitleStatus = .pending
                droppedFiles.wrappedValue[idx].subtitleOperationID = operationID
            }
        }

        // Verify model is downloaded
        guard WhisperModelManager.shared.isModelDownloaded(model) else {
            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .failed("Model not downloaded")
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }
            return
        }

        do {
            let outputDir = inputURL.deletingLastPathComponent()

            let audioStreamIndex = droppedFiles.wrappedValue.first(where: { $0.id == itemID })?.selectedAudioStreamIndex
            let srtURL = try await WhisperService.shared.generateSubtitles(
                inputFile: inputURL,
                outputDirectory: outputDir,
                model: model,
                language: language,
                operationID: operationID,
                audioStreamIndex: audioStreamIndex
            ) { [weak self] whisperProgress in
                Task { @MainActor in
                    guard let _ = self else { return }
                    if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }),
                       droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                        switch whisperProgress.stage {
                        case .extractingAudio:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .extractingAudio
                        case .transcribing:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .generating(progress: whisperProgress.percentage)
                        case .complete:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .completed
                        case .failed(let error):
                            droppedFiles.wrappedValue[idx].subtitleStatus = .failed(error)
                        default:
                            break
                        }
                        droppedFiles.wrappedValue[idx].subtitleProgress = whisperProgress.percentage
                    }
                }
            }

            let isCurrentAttempt = await MainActor.run { () -> Bool in
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .completed
                    droppedFiles.wrappedValue[idx].subtitleFilePath = srtURL
                    droppedFiles.wrappedValue[idx].subtitleProgress = 1.0
                    return true
                }
                return false
            }
            guard isCurrentAttempt else { return }

            logger.info("Subtitles generated: \(srtURL.lastPathComponent, privacy: .public)")

            // Embed SRT into the output file if enabled
            if settings.embedSubtitles {
                await embedSubtitles(
                    srtURL: srtURL,
                    into: inputURL,
                    itemID: itemID,
                    operationID: operationID,
                    droppedFiles: droppedFiles
                )
            }

            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }

        } catch WhisperServiceError.cancelled {
            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .notQueued
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }
        } catch {
            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .failed(error.localizedDescription)
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }
            logger.error("Subtitle generation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Parakeet Subtitle Generation

    /// Generates subtitles for a completed conversion using parakeet-mlx
    private func generateParakeetSubtitles(
        for itemID: UUID,
        inputURL: URL,
        droppedFiles: Binding<[VideoItem]>
    ) async {
        logger.info("[subtitle-trigger] post-encode Parakeet for item \(itemID, privacy: .public) inputURL=\(inputURL.lastPathComponent, privacy: .public)")
        let settings = transcriptionSettings.transcriptionSnapshot()
        let model = settings.parakeetModel
        let language = settings.parakeetLanguage

        let operationID = UUID()
        // Publish the attempt token before dispatching work so an immediate cancel is routable.
        await MainActor.run {
            if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                droppedFiles.wrappedValue[idx].subtitleStatus = .pending
                droppedFiles.wrappedValue[idx].subtitleOperationID = operationID
            }
        }

        do {
            let outputDir = inputURL.deletingLastPathComponent()

            let audioStreamIndex = droppedFiles.wrappedValue.first(where: { $0.id == itemID })?.selectedAudioStreamIndex
            let srtURL = try await ParakeetService.shared.generateSubtitles(
                inputFile: inputURL,
                outputDirectory: outputDir,
                model: model,
                language: language,
                operationID: operationID,
                audioStreamIndex: audioStreamIndex
            ) { [weak self] parakeetProgress in
                Task { @MainActor in
                    guard let _ = self else { return }
                    if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }),
                       droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                        switch parakeetProgress.stage {
                        case .extractingAudio:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .extractingAudio
                        case .transcribing:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .generating(progress: parakeetProgress.percentage)
                        case .complete:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .completed
                        case .failed(let error):
                            droppedFiles.wrappedValue[idx].subtitleStatus = .failed(error)
                        }
                        droppedFiles.wrappedValue[idx].subtitleProgress = parakeetProgress.percentage
                    }
                }
            }

            let isCurrentAttempt = await MainActor.run { () -> Bool in
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .completed
                    droppedFiles.wrappedValue[idx].subtitleFilePath = srtURL
                    droppedFiles.wrappedValue[idx].subtitleProgress = 1.0
                    return true
                }
                return false
            }
            guard isCurrentAttempt else { return }

            logger.info("Parakeet subtitles generated: \(srtURL.lastPathComponent, privacy: .public)")

            // Embed SRT into the output file if enabled
            if settings.embedSubtitles {
                await embedSubtitles(
                    srtURL: srtURL,
                    into: inputURL,
                    itemID: itemID,
                    operationID: operationID,
                    droppedFiles: droppedFiles
                )
            }

            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }

        } catch ParakeetServiceError.cancelled {
            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .notQueued
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }
        } catch {
            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .failed(error.localizedDescription)
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }
            logger.error("Parakeet subtitle generation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - OCR Subtitle Generation

    /// Converts bitmap subtitle stream in the source MKV to SRT using Tesseract OCR.
    /// Saves the SRT alongside the encoded output file.
    private func generateOCRSubtitles(
        for itemID: UUID,
        sourceURL: URL,
        outputURL: URL,
        metadata: VideoMetadata?,
        droppedFiles: Binding<[VideoItem]>
    ) async {
        logger.info("[subtitle-trigger] post-encode OCR for item \(itemID, privacy: .public) sourceURL=\(sourceURL.lastPathComponent, privacy: .public)")
        let settings = ocrSettings.ocrSnapshot()
        // Identify the chosen (or first) bitmap subtitle stream
        let chosenStreamIndex = droppedFiles.wrappedValue.first(where: { $0.id == itemID })?.selectedBitmapSubtitleStreamIndex
        // FFprobe-style + Matroska container IDs (SwiftExif's MKV reader surfaces the latter).
        let bitmapCodecs: Set<String> = ["pgssub", "hdmv_pgs_subtitle", "dvd_subtitle", "dvdsub", "s_hdmv/pgs", "s_vobsub"]
        guard let stream = metadata?.subtitleStreams.first(where: {
            if let chosen = chosenStreamIndex { return $0.index == chosen }
            return bitmapCodecs.contains($0.codec?.lowercased() ?? "")
        }) else {
            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .failed("No bitmap subtitle stream found")
                }
            }
            return
        }

        let streamIndex = stream.index ?? 0
        let codec = stream.codec ?? "pgssub"

        // Language: stream language wins (ISO 639-2; both engines accept it).
        // Otherwise fall back to the engine-specific user preference.
        let language = settings.language(forStreamLanguage: stream.languageCode)

        let operationID = UUID()
        await MainActor.run {
            if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                droppedFiles.wrappedValue[idx].subtitleStatus = .pending
                droppedFiles.wrappedValue[idx].subtitleOperationID = operationID
            }
        }

        do {
            // Save SRT alongside the encoded output (mirrors Whisper behaviour)
            let outputDir = outputURL.deletingLastPathComponent()
            let srtURL = try await TesseractService.shared.generateSubtitles(
                sourceFile: sourceURL,
                outputDirectory: outputDir,
                operationID: operationID,
                subtitleStreamIndex: streamIndex,
                codec: codec,
                language: language,
                engineKind: settings.engine
            ) { [weak self] ocrProgress in
                Task { @MainActor in
                    guard let _ = self else { return }
                    if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }),
                       droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                        switch ocrProgress.stage {
                        case .extractingTrack:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .extractingAudio
                        case .parsingFrames:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .extractingAudio
                        case .recognizing:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .generating(progress: ocrProgress.percentage)
                        case .complete:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .completed
                        case .failed(let error):
                            droppedFiles.wrappedValue[idx].subtitleStatus = .failed(error)
                        case .writingSRT:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .generating(progress: ocrProgress.percentage)
                        }
                        droppedFiles.wrappedValue[idx].subtitleProgress = ocrProgress.percentage
                    }
                }
            }

            let isCurrentAttempt = await MainActor.run { () -> Bool in
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .completed
                    droppedFiles.wrappedValue[idx].subtitleFilePath = srtURL
                    droppedFiles.wrappedValue[idx].subtitleProgress = 1.0
                    return true
                }
                return false
            }
            guard isCurrentAttempt else { return }

            logger.info("OCR subtitles generated: \(srtURL.lastPathComponent, privacy: .public)")

            // Embed SRT into the output file if enabled
            if settings.embedSubtitles {
                await embedSubtitles(
                    srtURL: srtURL,
                    into: outputURL,
                    itemID: itemID,
                    operationID: operationID,
                    droppedFiles: droppedFiles
                )
            }

            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }

        } catch TesseractServiceError.cancelled {
            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .notQueued
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }
        } catch {
            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .failed(error.localizedDescription)
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }
            logger.error("OCR subtitle generation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Subtitle Embedding

    /// Muxes a generated SRT file into the output video as a subtitle track using FFmpeg.
    /// The original output file is replaced in-place; the external SRT is kept.
    private func embedSubtitles(
        srtURL: URL,
        into videoURL: URL,
        itemID: UUID,
        operationID: UUID?,
        droppedFiles: Binding<[VideoItem]>
    ) async {
        guard let ffmpegPath = ffmpegPathProvider() else {
            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }),
                   operationID == nil || droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .failed("FFmpeg is unavailable")
                }
            }
            logger.error("FFmpeg binary not found for subtitle embedding")
            return
        }

        let beganCurrentAttempt = await MainActor.run { () -> Bool in
            if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }),
               operationID == nil || droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                droppedFiles.wrappedValue[idx].subtitleStatus = .embedding
                return true
            }
            return false
        }
        guard beganCurrentAttempt else { return }

        let attempt = startSubtitleEmbedding(
            ffmpegPath: ffmpegPath,
            srtURL: srtURL,
            videoURL: videoURL,
            itemID: itemID,
            operationID: operationID
        )
        defer { finishSubtitleEmbedding(itemID: itemID, attemptID: attempt.id) }

        do {
            try await withTaskCancellationHandler {
                try await attempt.task.value
            } onCancel: {
                attempt.task.cancel()
            }
            guard subtitleEmbeddingAttempts[itemID]?.id == attempt.id else {
                try? FileManager.default.removeItem(at: attempt.stagedURL)
                return
            }

            let didPublish = try await MainActor.run { () throws -> Bool in
                try attempt.ownership.whileCurrent {
                    try SubtitleEmbeddingCommit.publishIfCurrent(
                        temporaryURL: attempt.stagedURL,
                        destinationURL: videoURL,
                        isCurrent: {
                            guard let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) else {
                                return false
                            }
                            return operationID == nil ||
                                droppedFiles.wrappedValue[idx].subtitleOperationID == operationID
                        },
                        didPublish: {
                            if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                                droppedFiles.wrappedValue[idx].subtitleStatus = .completed
                            }
                        }
                    )
                } ?? false
            }
            guard didPublish else {
                try? FileManager.default.removeItem(at: attempt.stagedURL)
                return
            }
            logger.info("Subtitles embedded into \(videoURL.lastPathComponent, privacy: .public)")
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: attempt.stagedURL)
            guard subtitleEmbeddingAttempts[itemID]?.id == attempt.id else { return }
            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }),
                   operationID == nil || droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .notQueued
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: attempt.stagedURL)
            guard subtitleEmbeddingAttempts[itemID]?.id == attempt.id else { return }
            let message = subtitleEmbeddingErrorMessage(error)
            logger.error("Subtitle embedding error: \(message, privacy: .public)")

            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }),
                   operationID == nil || droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .failed(message)
                }
            }
        }
    }

    /// Standalone subtitle embedding for manually attached files (no queue binding needed).
    /// Called from the context menu "Attach Subtitle File" action when the item is already done.
    func embedSubtitlesForAttachedFile(
        srtURL: URL,
        videoURL: URL,
        itemID: UUID
    ) async {
        guard let ffmpegPath = ffmpegPathProvider() else {
            logger.error("FFmpeg binary not found for subtitle embedding")
            return
        }

        let attempt = startSubtitleEmbedding(
            ffmpegPath: ffmpegPath,
            srtURL: srtURL,
            videoURL: videoURL,
            itemID: itemID,
            operationID: nil
        )
        defer { finishSubtitleEmbedding(itemID: itemID, attemptID: attempt.id) }

        do {
            try await withTaskCancellationHandler {
                try await attempt.task.value
            } onCancel: {
                attempt.task.cancel()
            }
            guard subtitleEmbeddingAttempts[itemID]?.id == attempt.id else {
                try? FileManager.default.removeItem(at: attempt.stagedURL)
                return
            }

            let didPublish = try attempt.ownership.whileCurrent {
                _ = try FileManager.default.replaceItemAt(videoURL, withItemAt: attempt.stagedURL)
            } != nil
            guard didPublish else {
                try? FileManager.default.removeItem(at: attempt.stagedURL)
                return
            }
            logger.info("Subtitles embedded (attached) into \(videoURL.lastPathComponent, privacy: .public)")
        } catch {
            try? FileManager.default.removeItem(at: attempt.stagedURL)
            if error is CancellationError { return }
            let message = subtitleEmbeddingErrorMessage(error)
            logger.error("Subtitle embedding (attached) error: \(message, privacy: .public)")
        }
    }

    func cancelSubtitleEmbedding(itemID: UUID, operationID: UUID?) {
        guard let attempt = subtitleEmbeddingAttempts[itemID],
              operationID == nil || attempt.operationID == operationID else { return }
        attempt.ownership.invalidate()
        subtitleEmbeddingAttempts.removeValue(forKey: itemID)
        attempt.task.cancel()
    }

    private func startSubtitleEmbedding(
        ffmpegPath: String,
        srtURL: URL,
        videoURL: URL,
        itemID: UUID,
        operationID: UUID?
    ) -> (id: UUID, stagedURL: URL, ownership: SubtitleEmbeddingOwnership, task: Task<Void, Error>) {
        if let previousAttempt = subtitleEmbeddingAttempts[itemID] {
            previousAttempt.ownership.invalidate()
            previousAttempt.task.cancel()
        }

        let attemptID = UUID()
        let ownership = SubtitleEmbeddingOwnership()
        let ext = videoURL.pathExtension.lowercased()
        let stagedURL = videoURL.deletingLastPathComponent()
            .appendingPathComponent(".subtitle-embed-\(attemptID.uuidString).\(ext)")
        let subtitleCodec = ext == "mkv" || ext == "mka" ? "srt" : "mov_text"
        let srtStem = srtURL.deletingPathExtension().pathExtension
        let languageCode = !srtStem.isEmpty && srtStem.count <= 3 ? srtStem : nil
        let subprocess = subtitleEmbeddingSubprocess
        let task = Task {
            try await subprocess.run(
                ffmpegPath: ffmpegPath,
                srtURL: srtURL,
                videoURL: videoURL,
                stagedURL: stagedURL,
                subtitleCodec: subtitleCodec,
                languageCode: languageCode
            )
        }
        subtitleEmbeddingAttempts[itemID] = SubtitleEmbeddingAttempt(
            id: attemptID,
            operationID: operationID,
            ownership: ownership,
            task: task
        )
        return (attemptID, stagedURL, ownership, task)
    }

    private func finishSubtitleEmbedding(itemID: UUID, attemptID: UUID) {
        guard subtitleEmbeddingAttempts[itemID]?.id == attemptID else { return }
        subtitleEmbeddingAttempts.removeValue(forKey: itemID)
    }

    func cancelAllSubtitleEmbeddings() {
        let attempts = Array(subtitleEmbeddingAttempts.values)
        subtitleEmbeddingAttempts.removeAll()
        for attempt in attempts {
            attempt.ownership.invalidate()
            attempt.task.cancel()
        }
    }

    private func subtitleEmbeddingErrorMessage(_ error: Error) -> String {
        if let subprocessError = error as? SubtitleEmbeddingSubprocessError {
            return subprocessError.localizedDescription
        }
        return "Subtitle embedding could not replace the output file."
    }

    // MARK: - Quality Analytics

    /// Runs quality analytics for a completed conversion
    private func runAnalytics(
        for itemID: UUID,
        sourceURL: URL,
        encodedURL: URL,
        droppedFiles: Binding<[VideoItem]>
    ) async {
        let settings = analyticsSettings.analyticsSnapshot()
        let enabledMetrics = settings.enabledMetrics
        let vmafModel = settings.vmafModel

        guard !enabledMetrics.isEmpty else { return }

        // Update status to pending
        await MainActor.run {
            if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                droppedFiles.wrappedValue[idx].analyticsStatus = .pending
            }
        }

        do {
            let results = try await AnalyticsService.shared.runAnalytics(
                sourceFile: sourceURL,
                encodedFile: encodedURL,
                enabledMetrics: enabledMetrics,
                vmafModel: vmafModel,
                ssimulacra2MaxFrames: settings.ssimulacra2MaxFrames
            ) { metric, progressValue in
                Task { @MainActor in
                    if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                        // Drop in-flight progress updates that arrive after cancellation.
                        guard droppedFiles.wrappedValue[idx].analyticsStatus.isInProgress else { return }
                        droppedFiles.wrappedValue[idx].analyticsStatus = .running(metric: metric, progress: progressValue)
                        droppedFiles.wrappedValue[idx].analyticsProgress = progressValue
                    }
                }
            }

            let durationSeconds = await MainActor.run {
                droppedFiles.wrappedValue.first(where: { $0.id == itemID })?.durationSeconds ?? 0
            }

            let analyticsResults = AnalyticsResults(
                sourceFileName: sourceURL.lastPathComponent,
                encodedFileName: encodedURL.lastPathComponent,
                metrics: results,
                timestamp: Date(),
                durationSeconds: durationSeconds
            )

            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                    droppedFiles.wrappedValue[idx].analyticsStatus = .completed
                    droppedFiles.wrappedValue[idx].analyticsResults = analyticsResults
                    droppedFiles.wrappedValue[idx].analyticsProgress = 1.0
                }
                AnalyticsExporter.autoExportIfEnabled(results: analyticsResults, encodedFileURL: encodedURL, settings: settings.autoExport)
            }

            logger.info("Quality analytics completed for \(encodedURL.lastPathComponent, privacy: .public)")

        } catch {
            await MainActor.run {
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == itemID }) {
                    if case AnalyticsError.cancelled = error {
                        // User-initiated cancel already set status to .notQueued; don't overwrite.
                        return
                    }
                    droppedFiles.wrappedValue[idx].analyticsStatus = .failed(error.localizedDescription)
                }
            }
            logger.error("Quality analytics failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Resolves an item's reported `outputURL` to the file Quality Analytics should ingest.
    /// DCP / IMF presets store the package working folder as `outputURL` (so the queue UI
    /// can show package size and Reveal-in-Finder lands in the right place), but FFmpeg
    /// can't read a folder. For those presets, return the wrapped video essence MXF inside
    /// the package. Returns `nil` if the package is missing the expected MXF.
    nonisolated private func resolveAnalyticsSourceURL(for outputURL: URL, preset: ExportPreset) -> URL? {
        let fm = FileManager.default
        switch preset {
        case .dcp:
            // DCP: <packageFolder>/<isdcfFolder>/j2c_<UUID>.mxf
            guard let entries = try? fm.contentsOfDirectory(
                at: outputURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return nil }
            let subfolders = entries.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            for folder in subfolders {
                if let inner = try? fm.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ), let videoMXF = inner.first(where: {
                    $0.lastPathComponent.hasPrefix("j2c_") && $0.pathExtension.lowercased() == "mxf"
                }) {
                    return videoMXF
                }
            }
            return nil
        case .imfJ2K, .imfProRes:
            // IMF: <packageFolder>/video_<UUID>.mxf
            guard let entries = try? fm.contentsOfDirectory(
                at: outputURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return nil }
            return entries.first(where: {
                $0.lastPathComponent.hasPrefix("video_") && $0.pathExtension.lowercased() == "mxf"
            })
        default:
            return outputURL
        }
    }

    /// Returns the DCP metadata to embed in the request. When the user has saved
    /// metadata via the editor we pass it through unchanged. When the preset is
    /// DCP but no metadata exists yet, we materialize a sensible default so the
    /// CPL ContentTitleText is the source filename without extension (the editor
    /// uses the same fallback when the user opens it). Last-used contentKind is
    /// applied so a batch of trailers doesn't have to be re-edited per item.
    /// Logs advisory warnings when the chosen kind looks wrong for the filename
    /// or audio language is empty.
    private func resolveDCPMetadata(for item: VideoItem, preset: ExportPreset, inputURL: URL) -> DCPItemMetadata? {
        guard preset == .dcp else { return item.dcpMetadata }
        let stripped = inputURL.deletingPathExtension().lastPathComponent
        let resolved: DCPItemMetadata = {
            if let stored = item.dcpMetadata {
                if stored.contentTitleText.isEmpty {
                    var copy = stored
                    copy.contentTitleText = stripped
                    return copy
                }
                return stored
            }
            var fresh = DCPItemMetadata()
            fresh.contentTitleText = stripped
            if let raw = UserDefaults.standard.string(forKey: AppConstants.lastDCPContentKindKey),
               let remembered = DCPContentKind(rawValue: raw) {
                fresh.contentKind = remembered
            }
            return fresh
        }()
        emitDCPAdvisoryWarnings(metadata: resolved, sourceName: stripped)
        return resolved
    }

    private func resolveIMFMetadata(for item: VideoItem, preset: ExportPreset, inputURL: URL) -> IMFItemMetadata? {
        guard preset == .imfJ2K || preset == .imfProRes else { return item.imfMetadata }
        let stripped = inputURL.deletingPathExtension().lastPathComponent
        let resolved: IMFItemMetadata = {
            if let stored = item.imfMetadata {
                if stored.contentTitleText.isEmpty {
                    var copy = stored
                    copy.contentTitleText = stripped
                    return copy
                }
                return stored
            }
            var fresh = IMFItemMetadata()
            fresh.contentTitleText = stripped
            if let raw = UserDefaults.standard.string(forKey: AppConstants.lastIMFContentKindKey),
               let remembered = IMFContentKind(rawValue: raw) {
                fresh.contentKind = remembered
            }
            return fresh
        }()
        emitIMFAdvisoryWarnings(metadata: resolved, sourceName: stripped)
        return resolved
    }

    private func emitDCPAdvisoryWarnings(metadata: DCPItemMetadata, sourceName: String) {
        let lowered = sourceName.lowercased()
        if metadata.contentKind == .feature, lowered.contains("trailer") || lowered.contains("_tlr") {
            logger.warning("DCP metadata advisory for \(sourceName, privacy: .public): filename suggests a trailer but contentKind is set to 'feature'. Open the DCP metadata editor to confirm.")
        }
        if metadata.audioLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.warning("DCP metadata advisory for \(sourceName, privacy: .public): audioLanguage is empty. Defaulting to 'en' in the manifest.")
        }
    }

    private func emitIMFAdvisoryWarnings(metadata: IMFItemMetadata, sourceName: String) {
        let lowered = sourceName.lowercased()
        if metadata.contentKind == .feature, lowered.contains("trailer") || lowered.contains("_tlr") {
            logger.warning("IMF metadata advisory for \(sourceName, privacy: .public): filename suggests a trailer but contentKind is set to 'feature'. Open the IMF metadata editor to confirm.")
        }
        if metadata.audioLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logger.warning("IMF metadata advisory for \(sourceName, privacy: .public): audioLanguage is empty. Defaulting to 'en' in the manifest.")
        }
    }

    private func outputBaseName(for item: VideoItem, inputURL: URL, preset: ExportPreset) -> String {
        if let override = item.outputFileNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let baseName = (override as NSString).deletingPathExtension
            return FileNameProcessor.processFileName(baseName)
        }

        let sanitizedBaseName = FileNameProcessor.processFileName(inputURL.deletingPathExtension().lastPathComponent)
        let templatedBaseName = FileNameProcessor.applyCustomTemplate(sourceName: sanitizedBaseName, counter: item.customCounterValue, preset: preset)
        // Suppress the auto-appended suffix when the template already injected it via {presetSuffix},
        // otherwise users would see "_h264_h264".
        let suppressAutoSuffix = FileNameProcessor.customTemplateUsesPresetSuffix
        let suffixPart = (FileNameProcessor.includePresetSuffix && !suppressAutoSuffix) ? preset.fileSuffix : ""
        return templatedBaseName + suffixPart
    }
}
