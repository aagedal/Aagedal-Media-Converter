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

func progressIsDuration(_ s: String?) -> Bool {
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

final class SubtitleEmbeddingOwnership: @unchecked Sendable {
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
    @MainActor static let shared = ConversionManager(executionGate: .shared)
    let mergePreparationSubprocess: MergePreparationSubprocess
    let subtitleEmbeddingSubprocess: SubtitleEmbeddingSubprocess
    let ffmpegPathProvider: @Sendable () -> String?
    let transcriptionSettings: any TranscriptionSettingsProviding
    let ocrSettings: any OCRSettingsProviding
    let analyticsSettings: any AnalyticsSettingsProviding
    let analyticsService: AnalyticsService
    let preparationSettingsProvider: @Sendable (ExportPreset) -> ConversionPreparationSettings
    private let conversionDetailsLoader: @Sendable (URL, String, ExportPreset) async -> VideoFileUtils.VideoItemDetails
    private let executionGate: ApplicationConversionExecutionGate

    init(
        subprocessRunner: any SubprocessRunning = SubprocessRunner(),
        ffmpegConverter: FFMPEGConverter = FFMPEGConverter(),
        executionGate: ApplicationConversionExecutionGate = ApplicationConversionExecutionGate(),
        ffmpegPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.ffmpegPath },
        transcriptionSettings: any TranscriptionSettingsProviding = PostConversionSettings(),
        ocrSettings: any OCRSettingsProviding = PostConversionSettings(),
        analyticsSettings: any AnalyticsSettingsProviding = PostConversionSettings(),
        analyticsService: AnalyticsService = .shared,
        preparationSettingsProvider: @escaping @Sendable (ExportPreset) -> ConversionPreparationSettings = {
            ConversionPreparationSettings(preset: $0)
        },
        conversionDetailsLoader: @escaping @Sendable (URL, String, ExportPreset) async -> VideoFileUtils.VideoItemDetails = { url, folder, preset in
            await VideoFileUtils.loadDetails(
                for: url, outputFolder: folder, preset: preset, generateRowThumbnailIfMissing: false
            )
        }
    ) {
        self.mergePreparationSubprocess = MergePreparationSubprocess(subprocessRunner: subprocessRunner)
        self.ffmpegConverter = ffmpegConverter
        self.executionGate = executionGate
        self.subtitleEmbeddingSubprocess = SubtitleEmbeddingSubprocess(subprocessRunner: subprocessRunner)
        self.ffmpegPathProvider = ffmpegPathProvider
        self.transcriptionSettings = transcriptionSettings
        self.ocrSettings = ocrSettings
        self.analyticsSettings = analyticsSettings
        self.analyticsService = analyticsService
        self.conversionDetailsLoader = conversionDetailsLoader
        self.preparationSettingsProvider = preparationSettingsProvider
    }

    enum ConversionStatus {
        case waiting
        case converting
        case done
        case failed
        case cancelled
    }
    

    var isConverting = false
    private var pendingCancellationCount = 0
    private var cancellationGeneration = 0
    private var batchCancellationNeedsCleanup = false
    private var currentProcess: Process?
    let ffmpegConverter: FFMPEGConverter
    private var conversionQueue: [VideoItem] = []
    private var currentDroppedFiles: Binding<[VideoItem]>?
    private var currentOutputFolder: String?
    private var currentPreset: ExportPreset = .videoLoop
    private var allowedItemIDs: Set<UUID>? = nil
    var activeBatchID: UUID?
    var callbackOwnership = ConversionCallbackOwnership()
    struct WeakFollowUpOwnership {
        weak var value: ConversionCallbackOwnership?
    }
    // Running conversion/follow-up closures retain their own tokens. Weak entries
    // allow removed rows to be reclaimed without cancelling work in other groups.
    var followUpOwnership: [UUID: WeakFollowUpOwnership] = [:]

    func beginFollowUpOwnership(for itemID: UUID) -> ConversionCallbackOwnership {
        followUpOwnership = followUpOwnership.filter { $0.value.value != nil }
        followUpOwnership[itemID]?.value?.invalidate()
        let ownership = ConversionCallbackOwnership()
        followUpOwnership[itemID] = WeakFollowUpOwnership(value: ownership)
        return ownership
    }
    /// Await each service's cancellation fence before a replacement encode can
    /// reuse its output paths. Engine selection may have changed since the run.
    func cancelPreviousSubtitleOperation(itemID: UUID, operationID: UUID) async {
        cancelSubtitleEmbedding(itemID: itemID, operationID: operationID)
        async let whisper: Void = WhisperService.shared.cancelGeneration(operationID: operationID)
        async let parakeet: Void = ParakeetService.shared.cancelGeneration(operationID: operationID)
        async let ocr: Void = TesseractService.shared.cancelGeneration(operationID: operationID)
        async let nemotron: Void = NemotronService.shared.cancelGeneration(operationID: operationID)
        _ = await (whisper, parakeet, nemotron, ocr)
    }

    private var batchCompletionContinuation: (
        batchID: UUID,
        continuation: CheckedContinuation<Void, Never>
    )?
    struct SubtitleEmbeddingAttempt {
        let id: UUID
        let operationID: UUID?
        let ownership: SubtitleEmbeddingOwnership
        let task: Task<Void, Error>
    }
    var subtitleEmbeddingAttempts: [UUID: SubtitleEmbeddingAttempt] = [:]

    // Progress tracking with Swift Concurrency
    private var progressContinuation: AsyncStream<Double>.Continuation?
    private var progressSubscriberID: UUID?
    private var progressStream: AsyncStream<Double>?
    // Periodic task that yields overall progress every few seconds while converting
    private var progressTimerTask: Task<Void, Never>?
    // Track URLs that have active security-scoped access during conversion
    var activeSecurityScopedURLs: Set<URL> = []
    struct MergePlan {
        let itemIDs: [UUID]
        let listFileURL: URL
        let outputBaseURL: URL
        let outputFolder: String
        let preset: ExportPreset
        let settings: ConversionPreparationSettings
        let comment: String
        let metadataEditorSettings: MetadataEditorSettings?
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
        /// Stream Copy MXF merges rewrapped by bmxtranswrap (nil for the FFmpeg concat path)
        var nativeMXFMerge: NativeMXFMergeRequest? = nil
        /// Shown on the merged rows after success, e.g. why camera metadata was not kept.
        var mergeNotice: String? = nil
    }

    struct MergeSegment {
        let timelineMarkers: [StitchTimelineMarker]
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

    typealias ConformanceTarget = MergeCompatibilityPolicy.ConformanceTarget
    typealias ConformanceAnalysis = MergeCompatibilityPolicy.ConformanceAnalysis

    var mergePlan: MergePlan?
    var mergePreparationTask: (id: UUID, itemID: UUID, task: Task<Bool, Never>)?
    var mergePreparationScope: (batchID: UUID, itemIDs: Set<UUID>)?
    var invalidatedMergePreparationBatchIDs: Set<UUID> = []
    var lastMergeMetadata: [UUID: VideoMetadata] = [:]
    let mergeLogger = Logger(subsystem: "com.aagedal.MediaConverter", category: "MergeCompatibility")
    let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ConversionManager")
    
    func progressUpdates() -> AsyncStream<Double> {
        let subscriberID = UUID()
        let stream = AsyncStream(Double.self) { continuation in
            progressSubscriberID = subscriberID
            progressContinuation = continuation
            
            continuation.onTermination = { _ in
                Task {
                    await self.clearProgressContinuation(subscriberID: subscriberID)
                }
            }
        }
        progressStream = stream
        return stream
    }
    
    private func clearProgressContinuation(subscriberID: UUID) {
        guard progressSubscriberID == subscriberID else { return }
        progressSubscriberID = nil
        progressContinuation = nil
    }

    // MARK: - Periodic Progress Timer
    /// Starts a periodic task that emits overall progress every 3 s
    private func startProgressTimer(droppedFiles: Binding<[VideoItem]>) {
        progressTimerTask?.cancel()
        guard let batchID = activeBatchID else { return }
        
        progressTimerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, await self.updateBatchProgress(droppedFiles: droppedFiles, batchID: batchID) {
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            }
        }
    }

    private func updateBatchProgress(droppedFiles: Binding<[VideoItem]>, batchID: UUID) -> Bool {
        guard isBatchActive(batchID) else { return false }
        updateOverallProgress(droppedFiles: droppedFiles)
        return true
    }

    /// Starts an output upload that was held for subtitle generation, unless the row
    /// moved on (re-queued, upload cancelled or disabled) while subtitles were written.
    @MainActor
    private static func startUploadAfterSubtitles(followUp: ConversionFollowUp, droppedFiles: Binding<[VideoItem]>) {
        guard let index = followUp.index(in: droppedFiles.wrappedValue) else { return }
        let item = droppedFiles.wrappedValue[index]
        guard item.uploadStatus == .pending, item.uploadOperationID == nil,
              let itemID = ConversionUploadFollowUp.itemID(afterSuccess: item.status == .done, item: item) else { return }
        UploadManager.shared.startUpload(itemID: itemID)
    }

    private func stopProgressTimer() {
        progressTimerTask?.cancel()
        progressTimerTask = nil
    }

    func isConvertingStatus() -> Bool {
        return isConverting
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
        guard !isConverting, pendingCancellationCount == 0 else { return }
        let generation = cancellationGeneration
        let gateID = await executionGate.acquire()
        if generation == cancellationGeneration {
            await convertGroupHoldingGate(
                items: items,
                outputFolder: outputFolder,
                preset: preset,
                concatEnabled: concatEnabled,
                groupName: groupName,
                transcriptionEnabled: transcriptionEnabled,
                uploadEnabled: uploadEnabled,
                analyticsEnabled: analyticsEnabled,
                conformanceMergeEnabled: conformanceMergeEnabled,
                conformanceReferenceItemID: conformanceReferenceItemID,
                conformanceMetadata: conformanceMetadata
            )
        }
        await executionGate.release(gateID)
    }

    private func convertGroupHoldingGate(
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
        guard !isConverting, pendingCancellationCount == 0 else { return }
        if await rejectRecursiveMerge(items: items, mergeEnabled: concatEnabled || conformanceMergeEnabled) { return }
        allowedItemIDs = nil
        let batchID = UUID()
        activeBatchID = batchID
        callbackOwnership = ConversionCallbackOwnership()
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
        guard !isConverting, pendingCancellationCount == 0 else { return }
        let generation = cancellationGeneration
        let gateID = await executionGate.acquire()
        if generation == cancellationGeneration {
            await startConversionHoldingGate(
                droppedFiles: droppedFiles,
                outputFolder: outputFolder,
                preset: preset,
                mergeClipsEnabled: mergeClipsEnabled,
                limitToIDs: limitToIDs
            )
        }
        await executionGate.release(gateID)
    }

    private func startConversionHoldingGate(
        droppedFiles: Binding<[VideoItem]>,
        outputFolder: String,
        preset: ExportPreset = .videoLoop,
        mergeClipsEnabled: Bool = false,
        limitToIDs: Set<UUID>? = nil
    ) async {
        guard !self.isConverting, pendingCancellationCount == 0 else { return }
        if await rejectRecursiveMerge(items: droppedFiles, mergeEnabled: mergeClipsEnabled, allowedIDs: limitToIDs) { return }
        let batchID = UUID()
        activeBatchID = batchID
        callbackOwnership = ConversionCallbackOwnership()
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

    /// A merge consumes all sources at once, so a per-clip generation chain cannot be preserved.
    private func rejectRecursiveMerge(
        items: Binding<[VideoItem]>, mergeEnabled: Bool, allowedIDs: Set<UUID>? = nil
    ) async -> Bool {
        guard mergeEnabled else { return false }
        return await MainActor.run {
            let indices = items.wrappedValue.indices.filter {
                let item = items.wrappedValue[$0]
                return item.status == .waiting && item.recursiveEncodingGenerations != nil
                    && (allowedIDs?.contains(item.id) ?? true)
            }
            guard !indices.isEmpty else { return false }
            for index in indices {
                items.wrappedValue[index].status = .failed
                items.wrappedValue[index].conversionError = "Recursive encoding cannot merge clips. Disable merging or recursive encoding, then reset this clip."
            }
            SoundManager.shared.playError()
            return true
        }
    }

    func convertNextFile(
        droppedFiles: Binding<[VideoItem]>,
        outputFolder: String,
        preset: ExportPreset,
        batchID: UUID
    ) async {
        guard isConverting, activeBatchID == batchID else { return }

        // Update overall progress before starting next file
        updateOverallProgress(droppedFiles: droppedFiles)
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
            callbackOwnership.invalidate()
            self.allowedItemIDs = nil
            progressContinuation?.yield(1.0)
            stopProgressTimer()
            releaseAllSecurityScopedAccess()
            // Signal batch completion so startConversion/convertGroup can return
            finishBatch(batchID)
            return
        }
        
        let fileId = nextFile.id
        let settings = preparationSettingsProvider(preset)
        let packageMetadataSettings = settings.packageMetadata
        
        // Ensure the metadata an encode actually needs (duration, video-stream presence,
        // output URL, full metadata) is loaded before conversion. We deliberately pass
        // `generateRowThumbnailIfMissing: false` so encode start NEVER blocks on row-thumbnail
        // generation: for non-native card formats (MKV/MXF/MTS) the row thumbnail is produced by
        // an FFmpeg seek+decode that can take several seconds, and it is not needed to start
        // encoding. The row thumbnail is populated independently on the import background task
        // (`loadGroupItemDetails` / the per-item detail load). A thumbnail already cached on disk
        // is still picked up cheaply here.
        let preparedDetails: VideoFileUtils.VideoItemDetails?
        if !nextFile.detailsLoaded {
            preparedDetails = await conversionDetailsLoader(nextFile.url, outputFolder, preset)
        } else {
            preparedDetails = nil
        }
        guard isConverting, activeBatchID == batchID else { return }

        guard let idx = ConversionQueueState.beginPreparedItem(
            nextFile, details: preparedDetails, in: &droppedFiles.wrappedValue
        ) else {
            await convertNextFile(
                droppedFiles: droppedFiles,
                outputFolder: outputFolder,
                preset: preset,
                batchID: batchID
            )
            return
        }

        let currentItem = droppedFiles.wrappedValue[idx]
        let previousSubtitleOperationIDs = Set([
            followUpOwnership[currentItem.id]?.value?.id, currentItem.subtitleOperationID
        ].compactMap { $0 })
        let itemFollowUpOwnership = beginFollowUpOwnership(for: currentItem.id)
        let inputURL = currentItem.url
        let callbackOwnership = self.callbackOwnership
        await UploadManager.shared.cancelUploadBeforeConversion(itemID: currentItem.id)
        guard isBatchActive(batchID) else { return }
        guard !ConversionQueueState.callbackIndices(for: [currentItem], in: droppedFiles.wrappedValue).isEmpty else {
            await convertNextFile(droppedFiles: droppedFiles, outputFolder: outputFolder, preset: preset, batchID: batchID)
            return
        }
        for previousSubtitleOperationID in previousSubtitleOperationIDs {
            await cancelPreviousSubtitleOperation(itemID: currentItem.id, operationID: previousSubtitleOperationID)
            guard isBatchActive(batchID) else { return }
            guard !ConversionQueueState.callbackIndices(for: [currentItem], in: droppedFiles.wrappedValue).isEmpty else {
                await convertNextFile(droppedFiles: droppedFiles, outputFolder: outputFolder, preset: preset, batchID: batchID)
                return
            }
        }

        // Ensure input file is accessible with security-scoped access
        if !ensureInputFileAccessible(at: inputURL) {
            logger.error("Failed to access input file: \(inputURL.path, privacy: .public)")
            await MainActor.run {
                guard callbackOwnership.isActive,
                      let idx = ConversionQueueState.callbackIndices(
                          for: [currentItem], in: droppedFiles.wrappedValue
                      ).first else { return }
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

        let generatedVideoRequests = settings.generatedVideo.requests(for: [currentItem])
        let waveformRequest = generatedVideoRequests.waveform
        let synthesizedVideoRequest = generatedVideoRequests.synthesized

        // Naming and command preparation share the same export preferences, including
        // labels such as resolution and the animated-still/custom preset suffix.
        let av2Settings = settings.av2
        let dcpSettings = settings.dcp
        let imfSettings = settings.imf
        let audioOnlySettings = settings.audioOnly
        let codecSettings = settings.codec
        let fileNameSettings = settings.fileName
        let fileNameContext = settings.namingContext(
            preset: preset,
            imageSequenceFrameRate: waveformRequest?.frameRate ?? synthesizedVideoRequest?.frameRate
                ?? FileNameTemplateContext.imageSequenceFrameRate(for: currentItem)
        )
        let outputFileName = outputBaseName(
            for: currentItem, inputURL: inputURL, preset: preset,
            settings: fileNameSettings, context: fileNameContext
        )
        let resolvedOutputFolder = settings.outputDestination.resolveFolder(
            for: inputURL, defaultOutputFolder: outputFolder, presetSuffix: fileNameContext.presetSuffix
        ) ?? outputFolder

        // Ensure the output directory exists with proper security-scoped access
        let resolvedOutputFolderURL = URL(fileURLWithPath: resolvedOutputFolder)
        guard ensureDirectoryAccessible(at: resolvedOutputFolderURL) else {
            logger.error("Failed to access output directory: \(resolvedOutputFolder, privacy: .public)")
            await MainActor.run {
                guard callbackOwnership.isActive,
                      let idx = ConversionQueueState.callbackIndices(
                          for: [currentItem], in: droppedFiles.wrappedValue
                      ).first else { return }
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
        let resolvedDCPMetadata = resolveDCPMetadata(for: currentItem, preset: preset, inputURL: inputURL, settings: packageMetadataSettings)
        let resolvedIMFMetadata = resolveIMFMetadata(for: currentItem, preset: preset, inputURL: inputURL, settings: packageMetadataSettings)

        let resolvedSingleOutput = OSAllocatedUnfairLock<URL?>(initialState: nil)
        var conversionRequest = ConversionRequest(
            inputURL: inputURL,
            outputURL: outputURL,
            preset: preset,
            comment: currentItem.comment,
            metadataEditorSettings: currentItem.metadataEditorSettings,
            includeDateTag: currentItem.includeDateTag,
            sourceMetadata: currentItem.metadata,
            sourceCameraMetadata: currentItem.cameraMetadata,
            dcpMetadata: resolvedDCPMetadata,
            imfMetadata: resolvedIMFMetadata,
            trimStart: currentItem.trimStart,
            trimEnd: currentItem.trimEnd,
            expectedDuration: imageSeqExpectedDuration,
            videoFrameRate: FileNameTemplateContext.imageSequenceFrameRate(for: currentItem),
            audioRoutingConfig: currentItem.audioRoutingConfig,
            cropConfig: currentItem.cropConfig,
            adjustments: ResolvedMediaAdjustments(adjustments: currentItem.adjustments, globalLoudness: settings.loudness),
            timecodeConfig: currentItem.timecodeConfig,
            isMuted: currentItem.isMuted,
            waveformRequest: waveformRequest,
            synthesizedVideoRequest: synthesizedVideoRequest,
            waveformBackgroundImageURL: currentItem.waveformBackgroundImageURL,
            visualSourceURL: currentItem.imageSequenceConfig?.firstFrameURL,
            customInputArguments: customInputArguments
        )

        conversionRequest.exportsMatteSidecar = preset.exportsMatteSidecar()
        conversionRequest.outputURLResolved = { url in resolvedSingleOutput.withLock { $0 = url } }
        conversionRequest.etaUpdate = { eta in
            Task { @MainActor in
                ConversionQueueState.applyETA(eta, for: [currentItem], ownership: callbackOwnership,
                                              in: &droppedFiles.wrappedValue)
            }
        }

        // Throttle UI updates to ~4 Hz to avoid SwiftUI re-render storms during encoding
        let singleUIThrottle = OSAllocatedUnfairLock(initialState: Date.distantPast)
        let outputExtension = av2Settings?.container.fileExtension
            ?? audioOnlySettings?.format.fileExtension
            ?? codecSettings?.outputExtension(for: inputURL)
            ?? preset.outputExtension(for: inputURL)
        await ffmpegConverter.convert(
            request: conversionRequest,
            recursiveGenerations: currentItem.recursiveEncodingGenerations,
            av2Settings: av2Settings,
            dcpSettings: dcpSettings,
            imfSettings: imfSettings,
            audioOnlySettings: audioOnlySettings,
            imageSequenceSettings: settings.imageSequence,
            codecSettings: codecSettings,
            subtitleSettings: settings.subtitles,
            commentSettings: settings.comment,
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
                    ConversionQueueState.applyProgress(
                        progress, message: status, isDuration: isDuration,
                        for: [currentItem], ownership: callbackOwnership,
                        in: &droppedFiles.wrappedValue
                    )
                }
            }
        ) { success, errorReason in
            Task { @MainActor in
                // A cancelled batch may finish after the user has reset and started
                // another one. Never let that stale callback mutate the new batch.
                guard await self.isBatchActive(batchID), callbackOwnership.isActive else { return }

                if let idx = ConversionQueueState.callbackIndices(
                    for: [currentItem], in: droppedFiles.wrappedValue
                ).first {
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
                            outputFileURL = resolvedSingleOutput.withLock { $0 } ?? outputURL.appendingPathExtension(outputExtension)
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
                        updatedItem.analyticsSourceRange = AnalyticsSourceRange(start: currentItem.trimStart, end: currentItem.trimEnd)
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

                    let followUp = ConversionFollowUp(item: updatedItem, ownership: itemFollowUpOwnership)
                    followUp.reserveSubtitles(in: &droppedFiles.wrappedValue)
                    followUp.reserveAnalytics(in: &droppedFiles.wrappedValue)

                    // Trigger upload if enabled for this item. When subtitles will be
                    // uploaded or embedded, the upload starts after they are written.
                    let uploadWaitsForSubtitles = droppedFiles.wrappedValue[idx].outputURL != nil
                        && UploadSidecars.outputUploadWaitsForSubtitles(
                            item: droppedFiles.wrappedValue[idx],
                            settings: UploadSidecarSettings(),
                            embedSubtitles: UserDefaults.standard.bool(forKey: AppConstants.embedSubtitlesKey)
                        )
                    if let itemID = ConversionUploadFollowUp.itemID(
                        afterSuccess: success, item: droppedFiles.wrappedValue[idx]
                    ) {
                        if uploadWaitsForSubtitles {
                            droppedFiles.wrappedValue[idx].uploadStatus = .pending
                            droppedFiles.wrappedValue[idx].uploadOperationID = nil
                        } else {
                            // Already on the main actor: install the upload task now so
                            // an immediate cancel cannot race a deferred start wrapper.
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
                                        followUp: followUp,
                                        droppedFiles: droppedFiles
                                    )
                                    if uploadWaitsForSubtitles {
                                        await Self.startUploadAfterSubtitles(followUp: followUp, droppedFiles: droppedFiles)
                                    }
                                }
                            }
                        case .whisper:
                            if let outputURL = droppedFiles.wrappedValue[idx].outputURL {
                                Task {
                                    await self.generateSubtitles(
                                        for: fileId,
                                        inputURL: outputURL,
                                        followUp: followUp,
                                        droppedFiles: droppedFiles
                                    )
                                    if uploadWaitsForSubtitles {
                                        await Self.startUploadAfterSubtitles(followUp: followUp, droppedFiles: droppedFiles)
                                    }
                                }
                            }
                        case .nemotron:
                            if let outputURL = droppedFiles.wrappedValue[idx].outputURL {
                                Task {
                                    await self.generateNemotronSubtitles(for: fileId, inputURL: outputURL, followUp: followUp, droppedFiles: droppedFiles)
                                    if uploadWaitsForSubtitles {
                                        await Self.startUploadAfterSubtitles(followUp: followUp, droppedFiles: droppedFiles)
                                    }
                                }
                            }
                        case .parakeet:
                            if let outputURL = droppedFiles.wrappedValue[idx].outputURL {
                                Task {
                                    await self.generateParakeetSubtitles(
                                        for: fileId,
                                        inputURL: outputURL,
                                        followUp: followUp,
                                        droppedFiles: droppedFiles
                                    )
                                    if uploadWaitsForSubtitles {
                                        await Self.startUploadAfterSubtitles(followUp: followUp, droppedFiles: droppedFiles)
                                    }
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
                                        followUp: followUp,
                                        droppedFiles: droppedFiles
                                    )
                                }
                            } else {
                                droppedFiles.wrappedValue[idx].analyticsStatus = .failed("Could not locate wrapped video essence in package")
                                droppedFiles.wrappedValue[idx].analyticsOperationID = nil
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
        await cancelConversions(scope: .converting)
    }

    private func cancelConversions(scope: ConversionQueueState.CancellationScope) async {
        cancellationGeneration &+= 1
        pendingCancellationCount += 1
        batchCancellationNeedsCleanup = true
        isConverting = false
        activeBatchID = nil
        callbackOwnership.invalidate()
        cancelMergePreparation()
        cancelAllSubtitleEmbeddings()
        stopProgressTimer()

        // Publish cancellation before suspending so queued callbacks cannot revive rows.
        if let droppedFiles = currentDroppedFiles {
            ConversionQueueState.cancel(&droppedFiles.wrappedValue, scope: scope)
        }
        if scope == .waitingAndConverting {
            conversionQueue.removeAll()
            progressContinuation?.yield(0.0)
        } else {
            ConversionQueueState.cancel(&conversionQueue, scope: .converting)
        }

        await ffmpegConverter.cancelConversion()
        pendingCancellationCount -= 1
        finishPendingBatchCancellation()
    }

    private func finishPendingBatchCancellation() {
        guard pendingCancellationCount == 0, batchCancellationNeedsCleanup else { return }
        batchCancellationNeedsCleanup = false
        // Admission remains closed until every outstanding stop has acknowledged it.
        // Only then release resources the old process may still have been reading.
        currentProcess = nil
        if let plan = mergePlan {
            cleanupMergeArtifacts(for: plan)
            mergePlan = nil
        }
        releaseAllSecurityScopedAccess()
        finishBatch(batchCompletionContinuation?.batchID)
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
            updateOverallProgress(droppedFiles: droppedFiles)
            pendingCancellationCount += 1
            await ffmpegConverter.cancelConversion()
            pendingCancellationCount -= 1
            finishPendingBatchCancellation()
            return
        }
        
        // If the item is still waiting, simply mark as cancelled
        if let waitingIdx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == id && $0.status == .waiting }) {
            droppedFiles.wrappedValue[waitingIdx].status = .cancelled
            #if DEBUG
            logger.debug("Item \(droppedFiles.wrappedValue[waitingIdx].name, privacy: .public) cancelled (was waiting)")
            #endif
            updateOverallProgress(droppedFiles: droppedFiles)
        }
    }
    func cancelAllConversions() async {
        await cancelConversions(scope: .waitingAndConverting)
    }

    func isBatchActive(_ batchID: UUID) -> Bool {
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
    
    private func updateOverallProgress(droppedFiles: Binding<[VideoItem]>) {
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

    /// Returns the DCP metadata to embed in the request. When the user has saved
    /// metadata via the editor we pass it through unchanged. When the preset is
    /// DCP but no metadata exists yet, we materialize a sensible default so the
    /// CPL ContentTitleText is the source filename without extension (the editor
    /// uses the same fallback when the user opens it). Last-used contentKind is
    /// applied so a batch of trailers doesn't have to be re-edited per item.
    /// Logs advisory warnings when the chosen kind looks wrong for the filename
    /// or audio language is empty.
    private func resolveDCPMetadata(for item: VideoItem, preset: ExportPreset, inputURL: URL, settings: PackageMetadataSettings) -> DCPItemMetadata? {
        guard preset == .dcp else { return item.dcpMetadata }
        let stripped = inputURL.deletingPathExtension().lastPathComponent
        let resolved = settings.resolveDCPMetadata(item.dcpMetadata, inputURL: inputURL)
        emitDCPAdvisoryWarnings(metadata: resolved, sourceName: stripped)
        return resolved
    }

    private func resolveIMFMetadata(for item: VideoItem, preset: ExportPreset, inputURL: URL, settings: PackageMetadataSettings) -> IMFItemMetadata? {
        guard preset == .imfJ2K || preset == .imfProRes else { return item.imfMetadata }
        let stripped = inputURL.deletingPathExtension().lastPathComponent
        let resolved = settings.resolveIMFMetadata(item.imfMetadata, inputURL: inputURL)
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

    private func outputBaseName(
        for item: VideoItem, inputURL: URL, preset: ExportPreset,
        settings: FileNamePreferences, context: FileNameTemplateContext
    ) -> String {
        FileNameProcessor.outputBaseName(
            inputURL: inputURL, override: item.outputFileNameOverride,
            counter: item.customCounterValue, preset: preset,
            settings: settings, context: context
        )
    }
}
