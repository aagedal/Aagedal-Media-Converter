// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// AVC-Intra OP1a support for FFMPEGConverter: MCA labels for the rewrap and
// the mono-split audio pre-processing pass.

import Foundation
import OSLog

extension FFMPEGConverter {
    // MARK: - AVC-Intra MCA Labels

    /// Builds an MCA labels temp file for the AVC-Intra OP1a rewrap.
    ///
    /// Returns nil if no useful labels can be derived (caller should rewrap without
    /// the labels flag in that case, preserving today's behavior). Mirrors the
    /// AVC-Intra mono-split layout in `FFMPEGCommandBuilder.adjustAVCIntraAudio`:
    /// each input audio channel becomes one mono output track in input order.
    static func prepareAVCIntraMCALabelsFile(
        inputURL: URL,
        audioRoutingConfig: AudioRoutingConfig?,
        targetChannelCount: Int,
        mcaDefaults: AVCIntraMCADefaults,
        audioStreamProvider: @Sendable (URL) async -> [FFMPEGProbeService.AudioStreamInfo]? = { url in
            await FFMPEGProbeService.fetchAudioStreams(for: url)
        },
        mcaLabelProvider: @Sendable (URL) async -> [AudioTrackMCALabels]? = { url in
            await BMXService.shared.getAudioTrackLabels(url: url)
        }
    ) async -> URL? {
        guard !Task.isCancelled else { return nil }
        let allStreams = await audioStreamProvider(inputURL) ?? []
        guard !Task.isCancelled else { return nil }
        // Walk the unfiltered list so audio-relative indices match the routing UI
        // (which sees every audio stream, decodable or not). Only decodable streams
        // produce output tracks, but the override key must use the original index.
        let inputInfos = allStreams.enumerated().compactMap { (audioRelIdx, stream) -> MCALabelsBuilder.InputStreamInfo? in
            guard stream.isDecodable else { return nil }
            return MCALabelsBuilder.InputStreamInfo(
                audioRelativeIndex: audioRelIdx,
                channelCount: stream.channels ?? 0,
                channelLayout: stream.channelLayout,
                sampleRate: nil  // FFprobe basic info doesn't expose sampleRate; positional matching is reliable here
            )
        }
        guard !inputInfos.isEmpty else { return nil }

        // Read input MCA labels via mxf2raw only when the input is itself MXF.
        let mcaLabels: [AudioTrackMCALabels]
        if inputURL.pathExtension.lowercased() == "mxf" {
            mcaLabels = await mcaLabelProvider(inputURL) ?? []
            guard !Task.isCancelled else { return nil }
        } else {
            mcaLabels = []
        }

        // Collect manual overrides from the routing UI's output tracks. When more than
        // one output track points at the same input stream, the FIRST non-empty override
        // wins so the result is deterministic.
        var overrides: [Int: MCALabelOverride] = [:]
        if let routing = audioRoutingConfig {
            for outputTrack in routing.outputTracks {
                guard let override = outputTrack.mcaOverride, !override.isEmpty else { continue }
                if overrides[outputTrack.streamIndex] == nil {
                    overrides[outputTrack.streamIndex] = override
                }
            }
        }

        guard let content = MCALabelsBuilder.buildAVCIntraLabelsFile(
            inputStreams: inputInfos,
            inputMCALabels: mcaLabels,
            overrides: overrides,
            outputTrackCount: targetChannelCount,
            mcaDefaults: mcaDefaults
        ) else {
            return nil
        }

        guard !Task.isCancelled else { return nil }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mca-labels-\(UUID().uuidString).txt")
        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            logger.info("Wrote MCA labels file for \(inputURL.lastPathComponent, privacy: .public) at \(tempURL.path, privacy: .public)")
            return tempURL
        } catch {
            logger.error("Failed to write MCA labels file: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Own both probes independently of the callback task that performs post-processing.
    /// Queue cancellation can then stop and drain MCA work without joining that callback.
    func prepareTrackedAVCIntraMCALabelsFile(
        conversionID: UUID,
        inputURL: URL,
        audioRoutingConfig: AudioRoutingConfig?,
        targetChannelCount: Int,
        mcaDefaults: AVCIntraMCADefaults
    ) async -> URL? {
        guard activeConversionID == conversionID || postProcessingConversionID == conversionID else {
            return nil
        }
        let taskID = UUID()
        let audioStreamProvider = mcaAudioStreamProvider
        let task = Task {
            await Self.$runningSubprocessID.withValue(taskID) {
                await Self.prepareAVCIntraMCALabelsFile(
                    inputURL: inputURL,
                    audioRoutingConfig: audioRoutingConfig,
                    targetChannelCount: targetChannelCount,
                    mcaDefaults: mcaDefaults,
                    audioStreamProvider: audioStreamProvider
                )
            }
        }
        currentMCALabelTask?.cancel()
        currentMCALabelTask = task
        currentMCALabelTaskID = taskID
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        let ownsTask = currentMCALabelTaskID == taskID
        if ownsTask {
            currentMCALabelTask = nil
            currentMCALabelTaskID = nil
        }
        guard ownsTask, !task.isCancelled, !Task.isCancelled,
              activeConversionID == conversionID || postProcessingConversionID == conversionID else {
            if let result { Self.cleanupTempFile(at: result, label: "cancelled MCA labels") }
            return nil
        }
        return result
    }

    // MARK: - Audio Pre-Processing for AVC-Intra

    static func runAVCIntraAudioPreprocessing(
        executablePath: String,
        arguments: [String],
        outputURL: URL,
        subprocessRunner: any SubprocessRunning = SubprocessRunner()
    ) async -> AVCIntraAudioPreprocessingResult {
        let sensitiveValues = Set(
            arguments.filter { $0.hasPrefix("/") } + [executablePath, outputURL.path]
        )
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            timeout: avcIntraAudioPreprocessingTimeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: avcIntraAudioPreprocessingDiagnosticCaptureLimit,
            sensitiveValues: sensitiveValues
        )

        func cleanupPartialOutput() {
            guard FileManager.default.fileExists(atPath: outputURL.path) else { return }
            cleanupTempFile(at: outputURL, label: "partial AVC-Intra pre-processed audio")
        }

        func diagnostic(for result: SubprocessResult) -> String {
            request.redactedDiagnostic(result.standardErrorText)
        }

        func failureReason(_ base: String, diagnostic: String = "") -> String {
            let trimmed = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? base : "\(base): \(trimmed)"
        }

        do {
            let result = try await subprocessRunner.run(request)
            try Task.checkCancellation()
            let output = diagnostic(for: result)
            guard result.succeeded else {
                cleanupPartialOutput()
                return .failed(
                    reason: failureReason(
                        "FFmpeg audio pre-processing exited with status \(result.terminationStatus)",
                        diagnostic: output
                    )
                )
            }
            if let validationError = validateOutputFile(at: outputURL) {
                cleanupPartialOutput()
                return .failed(reason: request.redactedDiagnostic(validationError))
            }
            return .success(outputURL)
        } catch is CancellationError {
            cleanupPartialOutput()
            return .cancelled
        } catch SubprocessRunnerError.timedOut(_, let result) {
            let output = diagnostic(for: result)
            cleanupPartialOutput()
            return .failed(
                reason: failureReason(
                    "FFmpeg audio pre-processing timed out after 12 hours",
                    diagnostic: output
                )
            )
        } catch {
            cleanupPartialOutput()
            let output = request.redactedDiagnostic(error.localizedDescription)
            return .failed(reason: failureReason("Failed to start FFmpeg audio pre-processing", diagnostic: output))
        }
    }

    /// Checks if audio pre-processing is needed for AVC-Intra with audio-only files.
    /// This is required because the waveform/synthesized video pipeline's filter_complex
    /// conflicts with AVC-Intra's mono channel splitting filter_complex.
    func needsAudioPreProcessing(
        preset: ExportPreset,
        waveformRequest: WaveformVideoRequest?,
        synthesizedVideoRequest: SynthesizedVideoRequest?
    ) -> Bool {
        guard preset.splitsAudioIntoMonoTracks else { return false }
        // Only needed for audio-only files (which use waveform or synthesized video)
        return waveformRequest != nil || synthesizedVideoRequest != nil
    }

    /// Pre-processes audio for AVC-Intra by splitting stereo to mono channels.
    /// Creates a temp MKA file with the target number of mono audio streams.
    /// - Returns: URL of the temp file, or nil if pre-processing failed
    func preProcessAudioForAVCIntra(
        inputURL: URL,
        ffmpegPath: String,
        trimStart: Double?,
        trimEnd: Double?,
        conversionID: UUID,
        targetChannelCount: Int
    ) async -> AVCIntraAudioPreprocessingResult {
        // Create temp file
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent("avc_audio_\(UUID().uuidString)").appendingPathExtension("mka")

        // Get audio stream info
        let audioStreams = await FFMPEGProbeService.fetchAudioStreams(for: inputURL) ?? []
        guard activeConversionID == conversionID else { return .cancelled }
        let decodableStreams = audioStreams.filter { $0.isDecodable }

        // Build FFmpeg command for audio pre-processing
        var args: [String] = ["-y", "-nostdin"]

        // Add trim if specified
        if let start = trimStart, start > 0 {
            args.append(contentsOf: ["-ss", String(format: "%.3f", start)])
        }

        args.append(contentsOf: ["-i", inputURL.path])

        // Add duration if trim end specified
        if let start = trimStart, let end = trimEnd, end > start {
            args.append(contentsOf: ["-t", String(format: "%.3f", end - start)])
        } else if let end = trimEnd, end > 0 {
            args.append(contentsOf: ["-to", String(format: "%.3f", end)])
        }

        // Build filter graph for mono splitting
        var filterParts: [String] = []
        var monoOutputs: [String] = []
        var outputIndex = 0

        if decodableStreams.isEmpty {
            // No audio streams - create silent mono channels
            // Use aevalsrc for silence generation
            filterParts.append("aevalsrc=0:c=mono:s=48000:d=3600[silentsrc]")

            if targetChannelCount == 1 {
                monoOutputs.append("silentsrc")
            } else {
                var silentLabels: [String] = []
                for i in 0..<targetChannelCount {
                    silentLabels.append("silent\(i)")
                }
                filterParts.append("[silentsrc]asplit=\(targetChannelCount)\(silentLabels.map { "[\($0)]" }.joined())")
                monoOutputs.append(contentsOf: silentLabels)
            }
        } else {
            // Process each audio stream
            for (audioPosition, stream) in audioStreams.enumerated() {
                guard stream.isDecodable else { continue }

                let channels = stream.channels ?? 2

                if channels == 1 {
                    // Mono stream - use directly
                    let outputLabel = "mono\(outputIndex)"
                    filterParts.append("[0:a:\(audioPosition)]aformat=sample_fmts=s32:sample_rates=48000:channel_layouts=mono[\(outputLabel)]")
                    monoOutputs.append(outputLabel)
                    outputIndex += 1
                } else {
                    // Preserve decoded channel order without assuming speaker positions.
                    var channelLabels: [String] = []
                    for ch in 0..<channels {
                        channelLabels.append("s\(audioPosition)c\(ch)")
                    }
                    let outputLabelsStr = channelLabels.map { "[\($0)]" }.joined()

                    filterParts.append("[0:a:\(audioPosition)]asplit=\(channels)\(outputLabelsStr)")

                    // Format each split channel
                    for (channel, label) in channelLabels.enumerated() {
                        let formattedLabel = "mono\(outputIndex)"
                        filterParts.append("[\(label)]pan=mono|c0=c\(channel),aformat=sample_fmts=s32:sample_rates=48000:channel_layouts=mono[\(formattedLabel)]")
                        monoOutputs.append(formattedLabel)
                        outputIndex += 1
                    }
                }
            }

            // Pad with silent channels if needed
            let availableChannels = monoOutputs.count
            if availableChannels < targetChannelCount && availableChannels > 0 {
                let silentChannelsNeeded = targetChannelCount - availableChannels

                // Use first channel as template for silence
                let templateLabel = monoOutputs[0]
                let templateForOutput = "\(templateLabel)_out"
                let templateForSilent = "\(templateLabel)_silent"

                filterParts.append("[\(templateLabel)]asplit=2[\(templateForOutput)][\(templateForSilent)]")
                monoOutputs[0] = templateForOutput

                var silentLabels: [String] = []
                for i in 0..<silentChannelsNeeded {
                    silentLabels.append("silent\(availableChannels + i)")
                }

                if silentChannelsNeeded == 1 {
                    filterParts.append("[\(templateForSilent)]volume=0[\(silentLabels[0])]")
                } else {
                    let silentBaseLabel = "silentbase"
                    filterParts.append("[\(templateForSilent)]volume=0[\(silentBaseLabel)]")
                    let splitOutputs = silentLabels.map { "[\($0)]" }.joined()
                    filterParts.append("[\(silentBaseLabel)]asplit=\(silentChannelsNeeded)\(splitOutputs)")
                }

                monoOutputs.append(contentsOf: silentLabels)
            }
        }

        // Truncate if we have more channels than needed
        let finalOutputs = Array(monoOutputs.prefix(targetChannelCount))

        // Build the command
        let filterGraph = filterParts.joined(separator: ";")
        args.append(contentsOf: ["-filter_complex", filterGraph])

        // Map each mono output
        for output in finalOutputs {
            args.append(contentsOf: ["-map", "[\(output)]"])
        }

        // Audio codec settings
        args.append(contentsOf: ["-c:a", "pcm_s24le"])
        args.append(tempURL.path)

        let taskID = UUID()
        let runner = subprocessRunner
        let task = Task {
            await Self.$runningSubprocessID.withValue(taskID) {
                await Self.runAVCIntraAudioPreprocessing(
                    executablePath: ffmpegPath,
                    arguments: args,
                    outputURL: tempURL,
                    subprocessRunner: runner
                )
            }
        }
        currentAVCIntraPreprocessingTask?.cancel()
        currentAVCIntraPreprocessingTask = task
        currentAVCIntraPreprocessingTaskID = taskID

        let result = await task.value
        if currentAVCIntraPreprocessingTaskID == taskID {
            currentAVCIntraPreprocessingTask = nil
            currentAVCIntraPreprocessingTaskID = nil
        }

        guard activeConversionID == conversionID else {
            if case .success = result,
               FileManager.default.fileExists(atPath: tempURL.path) {
                Self.cleanupTempFile(at: tempURL, label: "cancelled AVC-Intra audio pre-processing")
            }
            return .cancelled
        }

        if case .success = result {
            Self.logger.info("Audio pre-processing succeeded: \(targetChannelCount) mono channels created")
        }
        return result
    }
}
