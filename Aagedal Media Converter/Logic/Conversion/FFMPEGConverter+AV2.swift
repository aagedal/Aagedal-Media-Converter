// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Experimental AV2 export: the single-process ffmpeg → avmenc pipe.

import Foundation
import OSLog

extension FFMPEGConverter {
    // MARK: - AV2 Conversion

    /// Runs the experimental AV2 export as a two-process pipe: ffmpeg decodes/trims/scales
    /// the source to y4m on stdout, which is piped into avmenc's stdin; avmenc writes the
    /// final video-only `.ivf`. avmenc's `POC:` records drive frame progress when the total
    /// is known, with ffmpeg's stderr feeding the standard time-based fallback parser.
    func runAV2Conversion(
        inputURL: URL,
        outputFileURL: URL,
        ffmpegPath: String,
        trimStart: Double?,
        trimEnd: Double?,
        cropConfig: CropConfig?,
        visualSourceURL: URL?,
        customInputArguments: [String]?,
        expectedDuration: Double?,
        videoFrameRate: Double?,
        sourceMetadata: VideoMetadata?,
        settings: AV2Settings,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void
    ) async -> AV2EncodeResult {
        guard let avmencPath = BinaryPathResolver.avmencPath else {
            Self.logger.error("avmenc binary not found in app bundle")
            return AV2EncodeResult(success: false, errorReason: "AV2 encoder (avmenc) not found in the app bundle", keyframeIndices: [])
        }

        guard let command = await AV2CommandBuilder.build(
            inputURL: inputURL,
            outputURL: outputFileURL,
            trimStart: trimStart,
            trimEnd: trimEnd,
            cropConfig: cropConfig,
            visualSourceURL: visualSourceURL,
            customInputArguments: customInputArguments,
            expectedDuration: expectedDuration,
            videoFrameRate: videoFrameRate,
            metadataSource: .resolved(sourceMetadata),
            settings: settings
        ) else {
            return AV2EncodeResult(success: false, errorReason: "Could not determine source video dimensions for AV2 encoding", keyframeIndices: [])
        }

        let privatePaths = Set(
            (command.ffmpegArguments + command.avmencArguments)
                .filter { $0.hasPrefix("/") }
                + [inputURL.path, outputFileURL.path, ffmpegPath, avmencPath]
                + [visualSourceURL?.path].compactMap { $0 }
        )
        let ffmpegRequest = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: command.ffmpegArguments,
            timeout: Self.av2PipelineTimeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: Self.av2PipelineDiagnosticCaptureLimit,
            sensitiveValues: privatePaths
        )
        let avmencRequest = SubprocessRequest(
            executableURL: URL(fileURLWithPath: avmencPath),
            arguments: command.avmencArguments,
            timeout: Self.av2PipelineTimeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: Self.av2PipelineDiagnosticCaptureLimit,
            sensitiveValues: privatePaths
        )
        Self.logger.info("AV2 ffmpeg: \(ffmpegRequest.redactedCommandDescription, privacy: .public)")
        Self.logger.info("AV2 avmenc: \(avmencRequest.redactedCommandDescription, privacy: .public)")

        // Progress is driven by AVMENC, not ffmpeg. ffmpeg only decodes the source and feeds y4m
        // (fast — it finishes and exits within seconds), while avmenc does the slow encoding and
        // buffers frames via lag-in-frames, so ffmpeg never back-pressures on short clips. Tracking
        // ffmpeg would pin the bar at 100% for the entire real encode (the "stuck at 100%" report).
        // avmenc prints one "POC:" line per encoded frame to stderr, so we count those against the
        // known frame count. (A few extra hidden alt-ref frames may appear; we cap the bar at 99%
        // until the 2-of-2 barrier confirms completion.)
        let totalFrames: Int = {
            guard let dur = command.effectiveDuration, let fps = command.frameRate, dur > 0, fps > 0 else { return 0 }
            return max(1, Int((dur * fps).rounded()))
        }()
        let encodedFrames = OSAllocatedUnfairLock<Int>(initialState: 0)

        // Fallback time-based progress (only used when we can't determine a frame count).
        let totalDurationBox = DurationBox()
        let effectiveDurationBox = DurationBox()
        totalDurationBox.value = command.effectiveDuration
        effectiveDurationBox.value = command.effectiveDuration
        let frameStallTracker = FrameStallTracker()
        let progressThrottler = ProgressThrottler()
        let frameRate = command.frameRate ?? 24.0

        let ffmpegProgressParser = FFMPEGProgressStreamParser(
            totalDuration: totalDurationBox,
            effectiveDuration: effectiveDurationBox,
            frameRate: frameRate,
            frameStallTracker: frameStallTracker,
            progressThrottler: progressThrottler,
            progressUpdate: progressUpdate
        )
        defer { ffmpegProgressParser.finish() }
        let avmencProgressParser = AV2POCStreamParser { newFrames in
            guard totalFrames > 0 else { return }
            let count = encodedFrames.withLock { state -> Int in
                state += newFrames
                return state
            }
            let shown = min(count, totalFrames)
            let fraction = min(0.99, Double(count) / Double(totalFrames))
            progressUpdate(fraction, "Encoding AV2 — frame \(shown)/\(totalFrames)")
        }

        // Show an immediate status: avmenc buffers frames (lag-in-frames) before emitting the
        // first "POC:" line, so there's a gap before frame-based progress starts climbing.
        progressUpdate(0.0, totalFrames > 0 ? "Encoding AV2 — frame 0/\(totalFrames)" : "Encoding AV2…")

        let pipelineID = UUID()
        let runner = subprocessRunner
        let pipelineTask = Task {
            try await Self.$runningSubprocessID.withValue(pipelineID) {
                let result = try await runner.runPipeline(
                    producer: ffmpegRequest,
                    consumer: avmencRequest,
                    producerOutputHandler: { chunk in
                        Self.$runningSubprocessID.withValue(pipelineID) {
                            guard totalFrames == 0, case .standardError = chunk.stream else { return }
                            ffmpegProgressParser.consume(chunk.data)
                        }
                    },
                    consumerOutputHandler: { chunk in
                        Self.$runningSubprocessID.withValue(pipelineID) {
                            guard case .standardOutput = chunk.stream else { return }
                            avmencProgressParser.consume(chunk.data)
                        }
                    }
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
            if FileManager.default.fileExists(atPath: outputFileURL.path) {
                Self.cleanupTempFile(at: outputFileURL, label: "cancelled AV2 .ivf")
            }
            return AV2EncodeResult(success: false, errorReason: "Conversion cancelled", keyframeIndices: [])
        } catch SubprocessRunnerError.timedOut {
            currentAV2PipelineTasks.removeValue(forKey: pipelineID)
            if FileManager.default.fileExists(atPath: outputFileURL.path) {
                Self.cleanupTempFile(at: outputFileURL, label: "timed-out AV2 .ivf")
            }
            return AV2EncodeResult(success: false, errorReason: "AV2 encoding timed out after 7 days", keyframeIndices: [])
        } catch SubprocessRunnerError.failedToStart(_, let underlying) {
            currentAV2PipelineTasks.removeValue(forKey: pipelineID)
            if FileManager.default.fileExists(atPath: outputFileURL.path) {
                Self.cleanupTempFile(at: outputFileURL, label: "failed AV2 .ivf")
            }
            let reason = avmencRequest.redactedDiagnostic(underlying)
            return AV2EncodeResult(success: false, errorReason: "Failed to start AV2 encoder: \(reason)", keyframeIndices: [])
        } catch {
            currentAV2PipelineTasks.removeValue(forKey: pipelineID)
            if FileManager.default.fileExists(atPath: outputFileURL.path) {
                Self.cleanupTempFile(at: outputFileURL, label: "failed AV2 .ivf")
            }
            let reason = avmencRequest.redactedDiagnostic(error.localizedDescription)
            return AV2EncodeResult(success: false, errorReason: "Failed to run AV2 pipeline: \(reason)", keyframeIndices: [])
        }
        currentAV2PipelineTasks.removeValue(forKey: pipelineID)

        let avmencResult = pipelineResult.consumer
        let ffmpegResult: SubprocessResult?
        var pipelineFailureReason: String?
        switch pipelineResult.producer {
        case .completed(let result):
            ffmpegResult = result
        case .failed(.cancelled):
            ffmpegResult = nil
            pipelineFailureReason = "Conversion cancelled"
        case .failed(.timedOut(let result)):
            ffmpegResult = result
            pipelineFailureReason = "FFmpeg input preparation timed out after 7 days"
        case .failed(.failedToStart(let reason)):
            ffmpegResult = nil
            pipelineFailureReason = "Failed to start FFmpeg: \(reason)"
        case .failed(.connectionClosed(let reason)):
            ffmpegResult = nil
            if avmencResult.succeeded {
                pipelineFailureReason = "AV2 pipeline closed before all frames were delivered: \(reason)"
            }
        case .failed(.failed(let reason)):
            ffmpegResult = nil
            pipelineFailureReason = "FFmpeg input preparation failed: \(reason)"
        case .unfinished:
            ffmpegResult = nil
            if avmencResult.succeeded {
                pipelineFailureReason = "FFmpeg input preparation did not finish"
            }
        }

        let ffmpegStatus = ffmpegResult?.terminationStatus ?? -1
        let avmencStatus = avmencResult.terminationStatus
        var success = ffmpegResult?.succeeded == true
            && avmencResult.succeeded
            && pipelineFailureReason == nil
        var errorReason = pipelineFailureReason

        if success, let validationError = Self.validateOutputFile(at: outputFileURL) {
            success = false
            errorReason = validationError
        }

        if !success {
            // Prefer avmenc's stderr when avmenc failed: if avmenc dies first, ffmpeg exits via
            // SIGPIPE (141) — a symptom, not the root cause. An independently failed producer,
            // however, is the root cause of avmenc subsequently rejecting empty/truncated Y4M.
            if avmencStatus != 0, errorReason == nil, ffmpegResult?.succeeded != false {
                let stderrString = avmencRequest.redactedDiagnostic(avmencResult.standardErrorText)
                errorReason = Self.extractAvmencErrorReason(from: stderrString, exitCode: avmencStatus)
            } else if errorReason == nil, let ffmpegResult {
                let stderrString = ffmpegRequest.redactedDiagnostic(ffmpegResult.standardErrorText)
                errorReason = Self.extractErrorReason(from: stderrString, exitCode: ffmpegStatus)
            }
            if FileManager.default.fileExists(atPath: outputFileURL.path) {
                Self.cleanupTempFile(at: outputFileURL, label: "partial AV2 .ivf")
            }
            Self.logger.error("AV2 failed (ffmpeg=\(ffmpegStatus), avmenc=\(avmencStatus)): \(errorReason ?? "unknown", privacy: .public)")
        } else {
            progressUpdate(1.0, nil)
            Self.logger.info("AV2 encode complete: \(outputFileURL.lastPathComponent, privacy: .public)")
        }

        // The single-process encode forces a key frame only at frame 0; that is the lone guaranteed
        // seek point we surface to the muxer (avmenc inserts more, but their positions aren't known
        // here without parsing the bitstream).
        return AV2EncodeResult(success: success, errorReason: errorReason, keyframeIndices: success ? [0] : [])
    }
}
