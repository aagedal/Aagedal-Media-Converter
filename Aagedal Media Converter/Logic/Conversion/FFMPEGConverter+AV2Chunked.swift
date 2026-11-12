// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Experimental AV2 export: the chunked, parallel avmenc encode.

import Foundation
import OSLog

extension FFMPEGConverter {
    // MARK: - Chunked (parallel) AV2 Conversion

    /// Result of an AV2 encode (single-process or chunked). `keyframeIndices` are global frame
    /// indices known to be key frames — used by the `.mkv` muxer to place Cue points.
    struct AV2EncodeResult: Sendable {
        let success: Bool
        let errorReason: String?
        let keyframeIndices: [Int]
        var recoveryDirectory: URL? = nil
    }

    private struct AV2SegmentOutcome: Sendable {
        let index: Int
        let success: Bool
        let errorReason: String?
    }

    /// Keep hashing, copying and muxing off this actor, but retain cancellation and
    /// ownership until file work has drained. Stop remains responsive on large files.
    func runAV2FileWork<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let id = UUID()
        let task = Task.detached(priority: .utility) {
            try Self.$runningSubprocessID.withValue(id) { try operation() }
        }
        let drain = Task { _ = await task.result }
        currentAV2FileTasks[id] = AV2FileTask(cancel: { task.cancel() }, drain: drain)
        defer { currentAV2FileTasks.removeValue(forKey: id) }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            await drain.value
            guard !task.isCancelled else { throw CancellationError() }
            try Task.checkCancellation()
            return result
        } catch {
            await drain.value
            throw error
        }
    }

    /// Runs a chunked AV2 encode in a memory-limited pool of ffmpeg│avmenc pipelines, with
    /// `POC:` progress aggregated across workers. When every chunk succeeds the segment `.ivf`
    /// files are joined (in order) by ``IVFConcatenator`` into the final video-only `.ivf`. A single
    /// failing chunk aborts the rest. Each chunk is an independent AV2 sequence (key frame at its
    /// first frame), which is what makes the bitstream-level concatenation valid.
    func runAV2ChunkedConversion(
        plan: AV2CommandBuilder.AV2SegmentPlan,
        outputFileURL: URL,
        ffmpegPath: String,
        avmencPath: String,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void
    ) async -> AV2EncodeResult {
        let cancellationToken = av2CancellationToken
        guard !Task.isCancelled, av2CancellationToken == cancellationToken else {
            return AV2EncodeResult(success: false, errorReason: "Conversion cancelled", keyframeIndices: [])
        }

        // mkdir is exclusive: an existing file, directory, or symlink is never adopted as
        // scratch space. Cleanup is installed only after this execution creates the directory.
        let preparationError: Int32? = plan.segmentDirectory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return EINVAL }
            return Darwin.mkdir(path, mode_t(0o700)) == 0 ? nil : errno
        }
        if let preparationError {
            let reason = NSError(domain: NSPOSIXErrorDomain, code: Int(preparationError)).localizedDescription
            Self.logger.error("Could not prepare AV2 chunk scratch directory: \(reason, privacy: .public)")
            return AV2EncodeResult(
                success: false,
                errorReason: String(localized: "Could not create temporary storage for AV2 chunks: \(reason). Check available disk space and temporary-folder permissions, then try again."),
                keyframeIndices: []
            )
        }
        defer { Self.cleanupDirectory(plan.segmentDirectory) }

        guard !Task.isCancelled, av2CancellationToken == cancellationToken else {
            return AV2EncodeResult(success: false, errorReason: "Conversion cancelled", keyframeIndices: [])
        }
        let totalFrames = plan.totalFrames
        let chunkCount = plan.segments.count
        Self.logger.info("AV2 chunked encode: \(chunkCount) chunks in a memory-limited pool, \(totalFrames) frames → \(outputFileURL.lastPathComponent, privacy: .public)")

        // Aggregate per-worker "POC:" frame counts into one progress value, throttled to per-mille
        // steps so N workers don't flood the main thread.
        let progressState = OSAllocatedUnfairLock<(total: Int, lastPermille: Int)>(initialState: (0, 0))
        let onFrames: @Sendable (Int) -> Void = { delta in
            let (total, emit) = progressState.withLock { st -> (Int, Bool) in
                st.total += delta
                let permille = totalFrames > 0 ? min(990, st.total * 1000 / totalFrames) : 0
                if permille != st.lastPermille { st.lastPermille = permille; return (st.total, true) }
                return (st.total, false)
            }
            if emit {
                let fraction = totalFrames > 0 ? min(0.99, Double(total) / Double(totalFrames)) : 0
                progressUpdate(fraction, "Encoding AV2 — \(chunkCount) chunks — frame \(min(total, totalFrames))/\(totalFrames)")
            }
        }

        progressUpdate(0.0, "Encoding AV2 — \(chunkCount) chunks — frame 0/\(totalFrames)")

        let recovery: AV2RecoveryStore?
        do {
            let root = av2RecoveryRoot()
            recovery = try await runAV2FileWork {
                try AV2RecoveryStore.open(plan: plan, ffmpeg: URL(fileURLWithPath: ffmpegPath),
                    encoder: URL(fileURLWithPath: avmencPath), root: root)
            }
        } catch is CancellationError {
            return AV2EncodeResult(success: false, errorReason: "Conversion cancelled", keyframeIndices: [])
        } catch let error as AV2RecoveryStore.RecoveryError {
            return AV2EncodeResult(success: false, errorReason: error.localizedDescription, keyframeIndices: [])
        } catch {
            // Recovery is best-effort. An unwritable cache must not prevent encoding.
            Self.logger.warning("AV2 recovery cache unavailable")
            recovery = nil
        }
        guard !Task.isCancelled, av2CancellationToken == cancellationToken else {
            return AV2EncodeResult(success: false, errorReason: "Conversion cancelled", keyframeIndices: [])
        }
        var pending: [AV2CommandBuilder.AV2SegmentCommand] = []
        var reused = 0
        for segment in plan.segments {
            do {
                if try await runAV2FileWork({ try recovery?.restore(segment) == true }) {
                    reused += 1
                    onFrames(segment.frameCount)
                    continue
                }
            } catch is CancellationError {
                return AV2EncodeResult(success: false, errorReason: "Conversion cancelled", keyframeIndices: [])
            } catch let error as AV2RecoveryStore.RecoveryError {
                return AV2EncodeResult(success: false, errorReason: error.localizedDescription, keyframeIndices: [])
            } catch {
                Self.cleanupAV2SegmentIfPresent(segment.outputURL, label: "unusable recovered AV2 chunk")
            }
            pending.append(segment)
        }
        guard !Task.isCancelled, av2CancellationToken == cancellationToken else {
            return AV2EncodeResult(success: false, errorReason: "Conversion cancelled", keyframeIndices: [])
        }
        if reused > 0 { progressUpdate(min(0.99, Double(plan.totalFrames - pending.reduce(0) { $0 + $1.frameCount }) / Double(max(1, totalFrames))), "Resumed \(reused) completed AV2 chunks") }
        var outcomes: [AV2SegmentOutcome] = []
        var firstFailure: AV2SegmentOutcome?
        await withTaskGroup(of: AV2SegmentOutcome.self) { group in
            var next = 0
            var running = 0
            while next < pending.count || running > 0 {
                if Task.isCancelled || av2CancellationToken != cancellationToken { group.cancelAll() }
                let limit = av2MemorySnapshot().workerLimit(width: plan.outputWidth, height: plan.outputHeight,
                    bitDepth: plan.bitDepth, planned: chunkCount, running: running)
                while firstFailure == nil, !Task.isCancelled, av2CancellationToken == cancellationToken, next < pending.count, running < limit {
                    let segment = pending[next]
                    next += 1
                    running += 1
                    group.addTask {
                        await self.encodeAV2Segment(segment, ffmpegPath: ffmpegPath, avmencPath: avmencPath, onFrames: onFrames)
                    }
                }
                if running == 0 {
                    if firstFailure != nil || Task.isCancelled || av2CancellationToken != cancellationToken { break }
                    progressUpdate(progressState.withLock { min(0.99, Double($0.total) / Double(max(1, totalFrames))) },
                        "Waiting for memory — completed AV2 chunks are saved")
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                guard let outcome = await group.next() else { break }
                running -= 1
                outcomes.append(outcome)
                if outcome.success, let segment = plan.segments.first(where: { $0.index == outcome.index }) {
                    do { try await runAV2FileWork { try recovery?.store(segment) } }
                    catch let error as AV2RecoveryStore.RecoveryError {
                        firstFailure = AV2SegmentOutcome(index: segment.index, success: false, errorReason: error.localizedDescription)
                        group.cancelAll()
                    } catch { Self.logger.warning("Could not checkpoint completed AV2 chunk") }
                } else if !outcome.success, firstFailure == nil {
                    firstFailure = outcome
                    group.cancelAll()
                }
            }
        }
        guard !Task.isCancelled, av2CancellationToken == cancellationToken else {
            return AV2EncodeResult(success: false, errorReason: "Conversion cancelled", keyframeIndices: [])
        }

        // All workers have exited (the task group is the 2N-of-2N termination barrier).
        if let failed = firstFailure ?? outcomes.first(where: { !$0.success }) {
            Self.logger.error("AV2 chunked failed at chunk \(failed.index): \(failed.errorReason ?? "unknown", privacy: .public)")
            return AV2EncodeResult(success: false, errorReason: failed.errorReason ?? "AV2 chunked encode failed", keyframeIndices: [])
        }

        // Join the chunk bitstreams in order.
        let ordered = plan.segments.sorted { $0.index < $1.index }.map { $0.outputURL }
        do {
            let result = try await runAV2FileWork {
                try recovery?.validateSource()
                return try IVFConcatenator.concatenate(segmentURLs: ordered, into: outputFileURL)
            }
            guard !Task.isCancelled, av2CancellationToken == cancellationToken else { throw CancellationError() }
            if let validationError = Self.validateOutputFile(at: outputFileURL) {
                Self.cleanupTempFile(at: outputFileURL, label: "invalid AV2 .ivf")
                return AV2EncodeResult(success: false, errorReason: validationError, keyframeIndices: [])
            }
            progressUpdate(1.0, nil)
            Self.logger.info("AV2 chunked encode complete: \(result.totalFrames) frames → \(outputFileURL.lastPathComponent, privacy: .public)")
            return AV2EncodeResult(success: true, errorReason: nil, keyframeIndices: result.keyframeIndices, recoveryDirectory: recovery?.directory)
        } catch {
            if FileManager.default.fileExists(atPath: outputFileURL.path) {
                Self.cleanupTempFile(at: outputFileURL, label: "partial AV2 .ivf")
            }
            return AV2EncodeResult(success: false, errorReason: "Failed to assemble AV2 chunks: \(error.localizedDescription)", keyframeIndices: [])
        }
    }

    /// Encodes one chunk through the shared coordinated ffmpeg→avmenc pipeline. The runner drains
    /// and bounds both tools' output, terminates their process trees on cancellation or timeout, and
    /// returns only after the consumer plus the producer's terminal state have been collected.
    private func encodeAV2Segment(
        _ seg: AV2CommandBuilder.AV2SegmentCommand,
        ffmpegPath: String,
        avmencPath: String,
        onFrames: @escaping @Sendable (Int) -> Void
    ) async -> AV2SegmentOutcome {
        let privatePaths = Set(
            (seg.ffmpegArguments + seg.avmencArguments)
                .filter { $0.hasPrefix("/") }
                + [seg.outputURL.path, ffmpegPath, avmencPath]
        )
        let ffmpegRequest = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: seg.ffmpegArguments,
            timeout: Self.av2PipelineTimeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: Self.av2PipelineDiagnosticCaptureLimit,
            sensitiveValues: privatePaths
        )
        let avmencRequest = SubprocessRequest(
            executableURL: URL(fileURLWithPath: avmencPath),
            arguments: seg.avmencArguments,
            timeout: Self.av2PipelineTimeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: Self.av2PipelineDiagnosticCaptureLimit,
            sensitiveValues: privatePaths
        )
        Self.logger.info("AV2 chunk \(seg.index) ffmpeg: \(ffmpegRequest.redactedCommandDescription, privacy: .public)")
        Self.logger.info("AV2 chunk \(seg.index) avmenc: \(avmencRequest.redactedCommandDescription, privacy: .public)")

        let progressParser = AV2POCStreamParser(onFrames: onFrames)
        let pipelineID = UUID()
        let runner = subprocessRunner
        let pipelineTask = Task {
            try await Self.$runningSubprocessID.withValue(pipelineID) {
                let result = try await runner.runPipeline(
                    producer: ffmpegRequest,
                    consumer: avmencRequest,
                    consumerOutputHandler: { chunk in
                        Self.$runningSubprocessID.withValue(pipelineID) {
                            guard case .standardOutput = chunk.stream else { return }
                            progressParser.consume(chunk.data)
                        }
                    },
                    drainProducer: true
                )
                try Task.checkCancellation()
                return result
            }
        }
        currentAV2PipelineTasks[pipelineID] = pipelineTask

        let pipelineResult: SubprocessPipelineResult
        do {
            pipelineResult = try await withTaskCancellationHandler {
                try await pipelineTask.value
            } onCancel: {
                pipelineTask.cancel()
            }
        } catch is CancellationError {
            currentAV2PipelineTasks.removeValue(forKey: pipelineID)
            Self.cleanupAV2SegmentIfPresent(seg.outputURL, label: "cancelled AV2 chunk")
            return AV2SegmentOutcome(index: seg.index, success: false, errorReason: "Conversion cancelled")
        } catch SubprocessRunnerError.timedOut {
            currentAV2PipelineTasks.removeValue(forKey: pipelineID)
            Self.cleanupAV2SegmentIfPresent(seg.outputURL, label: "timed-out AV2 chunk")
            return AV2SegmentOutcome(index: seg.index, success: false, errorReason: "AV2 chunk \(seg.index) timed out after 7 days")
        } catch SubprocessRunnerError.failedToStart(_, let underlying) {
            currentAV2PipelineTasks.removeValue(forKey: pipelineID)
            Self.cleanupAV2SegmentIfPresent(seg.outputURL, label: "failed AV2 chunk")
            let diagnostic = avmencRequest.redactedDiagnostic(underlying)
            return AV2SegmentOutcome(index: seg.index, success: false, errorReason: "Failed to start AV2 encoder: \(diagnostic)")
        } catch {
            currentAV2PipelineTasks.removeValue(forKey: pipelineID)
            Self.cleanupAV2SegmentIfPresent(seg.outputURL, label: "failed AV2 chunk")
            let diagnostic = avmencRequest.redactedDiagnostic(error.localizedDescription)
            return AV2SegmentOutcome(index: seg.index, success: false, errorReason: "Failed to run AV2 chunk \(seg.index): \(diagnostic)")
        }
        currentAV2PipelineTasks.removeValue(forKey: pipelineID)

        let avmencResult = pipelineResult.consumer
        let ffmpegResult: SubprocessResult?
        var failureReason: String?
        switch pipelineResult.producer {
        case .completed(let result):
            ffmpegResult = result
        case .failed(.cancelled):
            ffmpegResult = nil
            failureReason = "Conversion cancelled"
        case .failed(.timedOut):
            ffmpegResult = nil
            failureReason = "FFmpeg input preparation for AV2 chunk \(seg.index) timed out after 7 days"
        case .failed(.failedToStart(let reason)):
            ffmpegResult = nil
            failureReason = "Failed to start FFmpeg: \(reason)"
        case .failed(.connectionClosed(let reason)):
            ffmpegResult = nil
            if avmencResult.succeeded {
                failureReason = "AV2 chunk \(seg.index) closed before all frames were delivered: \(reason)"
            }
        case .failed(.failed(let reason)):
            ffmpegResult = nil
            failureReason = "FFmpeg input preparation for AV2 chunk \(seg.index) failed: \(reason)"
        case .unfinished:
            ffmpegResult = nil
            if avmencResult.succeeded {
                failureReason = "FFmpeg input preparation for AV2 chunk \(seg.index) did not finish"
            }
        }

        let ffmpegStatus = ffmpegResult?.terminationStatus ?? -1
        let avmencStatus = avmencResult.terminationStatus
        let success = ffmpegResult?.succeeded == true
            && avmencResult.succeeded
            && failureReason == nil
            && Self.fileHasContent(at: seg.outputURL)
        if success {
            return AV2SegmentOutcome(index: seg.index, success: true, errorReason: nil)
        }

        if failureReason == nil, avmencStatus != 0, ffmpegResult?.succeeded != false {
            let diagnostic = avmencRequest.redactedDiagnostic(avmencResult.standardErrorText)
            failureReason = Self.extractAvmencErrorReason(from: diagnostic, exitCode: avmencStatus)
        } else if failureReason == nil, let ffmpegResult, !ffmpegResult.succeeded {
            let diagnostic = ffmpegRequest.redactedDiagnostic(ffmpegResult.standardErrorText)
            failureReason = Self.extractErrorReason(from: diagnostic, exitCode: ffmpegStatus)
        } else if failureReason == nil {
            failureReason = Self.fileHasContent(at: seg.outputURL)
                ? "AV2 chunk \(seg.index) failed (ffmpeg=\(ffmpegStatus), avmenc=\(avmencStatus))"
                : "AV2 chunk \(seg.index) did not produce an output file"
        }
        Self.cleanupAV2SegmentIfPresent(seg.outputURL, label: "partial AV2 chunk")
        return AV2SegmentOutcome(index: seg.index, success: false, errorReason: failureReason)
    }

    static func fileHasContent(at url: URL) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return size > 0
    }

    private static func cleanupAV2SegmentIfPresent(_ url: URL, label: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        cleanupTempFile(at: url, label: label)
    }

    private static func cleanupDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
