// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Audio extraction for image-sequence exports and SMPTE packages (DCP, IMF),
// including the IMF WAV channel count and frame-count fitting.

import Foundation
import OSLog

extension FFMPEGConverter {
    // MARK: - Audio Extraction for Image Sequence Export

    /// Extracts the audio track from a video file as a WAV file alongside the image sequence output.
    /// Only runs if the input has audio streams. The WAV file is placed in the same subfolder as the images.
    func extractImageSequenceAudioAsWAV(
        conversionID: UUID,
        inputURL: URL,
        outputFolder: URL,
        baseName: String,
        ffmpegPath: String,
        trimStart: Double?,
        trimEnd: Double?
    ) async -> ImageSequenceAudioExtractionResult {
        guard postProcessingConversionID == conversionID else { return .cancelled }

        let taskID = UUID()
        let runner = subprocessRunner
        let task = Task {
            await Self.$runningSubprocessID.withValue(taskID) {
                await Self.stageAudioAsWAV(
                    inputURL: inputURL,
                    outputFolder: outputFolder,
                    baseName: baseName,
                    ffmpegPath: ffmpegPath,
                    trimStart: trimStart,
                    trimEnd: trimEnd,
                    subprocessRunner: runner
                )
            }
        }
        currentImageSequenceAudioTask?.cancel()
        currentImageSequenceAudioTask = task
        currentImageSequenceAudioTaskID = taskID

        let result = await task.value
        if currentImageSequenceAudioTaskID == taskID {
            currentImageSequenceAudioTask = nil
            currentImageSequenceAudioTaskID = nil
        }

        guard postProcessingConversionID == conversionID else {
            if case .staged(let stagedURL, _, _) = result {
                Self.cleanupTempFile(at: stagedURL, label: "superseded image-sequence audio WAV")
            }
            return .cancelled
        }

        switch result {
        case .staged(let stagedURL, let outputURL, let request):
            // This actor-isolated ownership check and synchronous rename form one publication
            // boundary: cancellation or a replacement conversion cannot interleave here.
            return Self.publishStagedAudioWAV(
                stagedURL: stagedURL,
                outputURL: outputURL,
                request: request
            )
        case .noAudioInSource:
            return .noAudioInSource
        case .failed(let reason):
            return .failed(reason: reason)
        case .cancelled:
            return .cancelled
        }
    }

    static func extractAudioAsWAV(
        inputURL: URL,
        outputFolder: URL,
        baseName: String,
        ffmpegPath: String,
        trimStart: Double?,
        trimEnd: Double?,
        subprocessRunner: any SubprocessRunning = SubprocessRunner(),
        audioStreamProvider: @escaping @Sendable (URL) async -> [FFMPEGProbeService.AudioStreamInfo]? = {
            await FFMPEGProbeService.fetchAudioStreams(for: $0)
        }
    ) async -> ImageSequenceAudioExtractionResult {
        let result = await stageAudioAsWAV(
            inputURL: inputURL,
            outputFolder: outputFolder,
            baseName: baseName,
            ffmpegPath: ffmpegPath,
            trimStart: trimStart,
            trimEnd: trimEnd,
            subprocessRunner: subprocessRunner,
            audioStreamProvider: audioStreamProvider
        )

        switch result {
        case .staged(let stagedURL, let outputURL, let request):
            guard !Task.isCancelled else {
                cleanupTempFile(at: stagedURL, label: "cancelled image-sequence audio WAV")
                return .cancelled
            }
            return publishStagedAudioWAV(
                stagedURL: stagedURL,
                outputURL: outputURL,
                request: request
            )
        case .noAudioInSource:
            return .noAudioInSource
        case .failed(let reason):
            return .failed(reason: reason)
        case .cancelled:
            return .cancelled
        }
    }

    private static func stageAudioAsWAV(
        inputURL: URL,
        outputFolder: URL,
        baseName: String,
        ffmpegPath: String,
        trimStart: Double?,
        trimEnd: Double?,
        subprocessRunner: any SubprocessRunning,
        audioStreamProvider: @escaping @Sendable (URL) async -> [FFMPEGProbeService.AudioStreamInfo]? = {
            await FFMPEGProbeService.fetchAudioStreams(for: $0)
        }
    ) async -> ImageSequenceAudioStagingResult {
        // Check if source has audio streams
        guard let audioStreams = await audioStreamProvider(inputURL),
              !audioStreams.isEmpty else {
            logger.debug("No audio streams in source, skipping WAV extraction")
            return .noAudioInSource
        }
        guard !Task.isCancelled else { return .cancelled }

        let wavOutputURL = outputFolder.appendingPathComponent("\(baseName).wav")
        let stagedWAVURL = outputFolder.appendingPathComponent(
            ".\(baseName)-\(UUID().uuidString).wav"
        )

        var args: [String] = ["-y", "-nostdin"]

        // Apply trim start (input seeking)
        let normalizedStart = FFMPEGCommandBuilder.normalizedTrimPoint(trimStart)
        if let start = normalizedStart {
            args.append(contentsOf: ["-ss", FFMPEGCommandBuilder.ffmpegTimeString(from: start)])
        }

        args.append(contentsOf: ["-i", inputURL.path])

        // Apply trim duration
        if let durationArgs = FFMPEGCommandBuilder.trimDurationArgument(start: normalizedStart, end: FFMPEGCommandBuilder.normalizedTrimPoint(trimEnd)) {
            args.append(contentsOf: durationArgs)
        }

        args.append(contentsOf: [
            "-vn",           // No video
            "-c:a", "pcm_s24le",  // 24-bit WAV
            "-rf64", "auto", // Use RF64 for files >4GB
            stagedWAVURL.path
        ])

        logger.info("Extracting audio as WAV: \(wavOutputURL.lastPathComponent)")

        let sensitiveValues = Set(
            args.filter { $0.hasPrefix("/") } + [
                ffmpegPath,
                inputURL.path,
                outputFolder.path,
                wavOutputURL.path,
                stagedWAVURL.path,
            ]
        )
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: args,
            timeout: imageSequenceAudioExtractionTimeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: imageSequenceAudioDiagnosticCaptureLimit,
            sensitiveValues: sensitiveValues
        )

        func cleanupPartialOutput() {
            guard FileManager.default.fileExists(atPath: stagedWAVURL.path) else { return }
            Self.cleanupTempFile(at: stagedWAVURL, label: "partial image-sequence audio WAV")
        }

        func failureReason(_ base: String, diagnostic: String = "") -> String {
            let trimmed = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? base : "\(base): \(trimmed)"
        }

        do {
            let result = try await subprocessRunner.run(request)
            guard result.succeeded else {
                let reason = failureReason(
                    "FFmpeg audio extraction exited with status \(result.terminationStatus)",
                    diagnostic: request.redactedDiagnostic(result.standardErrorText)
                )
                logger.warning("Image-sequence audio extraction failed: \(reason, privacy: .public)")
                cleanupPartialOutput()
                return .failed(reason: reason)
            }
            if let validationError = Self.validateOutputFile(at: stagedWAVURL) {
                let reason = request.redactedDiagnostic(validationError)
                logger.warning("Image-sequence audio extraction output validation failed: \(reason, privacy: .public)")
                cleanupPartialOutput()
                return .failed(reason: reason)
            }
            try Task.checkCancellation()
            return .staged(stagedWAVURL, wavOutputURL, request)
        } catch is CancellationError {
            cleanupPartialOutput()
            return .cancelled
        } catch SubprocessRunnerError.timedOut(_, let result) {
            let reason = failureReason(
                "FFmpeg audio extraction timed out after 12 hours",
                diagnostic: request.redactedDiagnostic(result.standardErrorText)
            )
            logger.warning("Image-sequence audio extraction timed out: \(reason, privacy: .public)")
            cleanupPartialOutput()
            return .failed(reason: reason)
        } catch {
            let diagnostic = request.redactedDiagnostic(error.localizedDescription)
            let reason = failureReason("Failed to start FFmpeg audio extraction", diagnostic: diagnostic)
            logger.error("Image-sequence audio extraction launch failed: \(reason, privacy: .public)")
            cleanupPartialOutput()
            return .failed(reason: reason)
        }
    }

    private static func publishStagedAudioWAV(
        stagedURL: URL,
        outputURL: URL,
        request: SubprocessRequest
    ) -> ImageSequenceAudioExtractionResult {
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: stagedURL)
            } else {
                try FileManager.default.moveItem(at: stagedURL, to: outputURL)
            }
            logger.info("Audio WAV extraction complete: \(outputURL.lastPathComponent)")
            return .extracted(outputURL)
        } catch {
            if FileManager.default.fileExists(atPath: stagedURL.path) {
                cleanupTempFile(at: stagedURL, label: "unpublished image-sequence audio WAV")
            }
            let diagnostic = request.redactedDiagnostic(error.localizedDescription)
            let reason = diagnostic.isEmpty
                ? "Failed to publish extracted audio"
                : "Failed to publish extracted audio: \(diagnostic)"
            logger.error("Image-sequence audio publication failed: \(reason, privacy: .public)")
            return .failed(reason: reason)
        }
    }

    /// Checks conversion ownership and writes the optional metadata sidecar without an actor
    /// suspension between those operations, so cancellation cannot interleave before publication.
    func generateImageSequenceMetadataSidecarIfOwned(
        conversionID: UUID,
        originalFileName: String,
        outputFolder: URL,
        metadata: VideoMetadata?,
        cameraMetadata: CameraMetadata?,
        settings: ImageSequenceSettings
    ) -> Bool {
        guard postProcessingConversionID == conversionID else { return false }

        if settings.metadataSidecarEnabled, let metadata {
            MetadataSidecarGenerator.generateSidecar(
                originalFileName: originalFileName,
                outputFolder: outputFolder,
                metadata: metadata,
                cameraMetadata: cameraMetadata,
                format: settings.metadataSidecarFormat
            )
        }
        return true
    }

    /// Extracts audio from source as 24-bit PCM 48 kHz WAV for SMPTE-package exports (DCP, IMF).
    /// FFmpeg's MXF muxer cannot create audio-only MXF files, so we extract to WAV first,
    /// then asdcp-wrap (DCP) or bmxtranswrap (IMF) takes over to produce the MXF essence.
    /// - Returns: URL of the audio WAV file, or nil if source has no audio or extraction failed
    /// Result of `extractAudioAsPCMWAV`. Distinguishes "source has no audio" (a legitimate
    /// silent DCP/IMF) from "extraction failed" (the user had audio but we lost it), so
    /// callers can surface the failure case to the UI instead of silently producing a
    /// package with no audio.
    enum AudioExtractionResult: Sendable {
        /// `sourceChannels` is the channel count before any DCP carrier mapping (0 = generated silence).
        case extracted(URL, sourceChannels: Int?)
        case noAudioInSource
        case failed(reason: String)
    }

    enum ImageSequenceAudioExtractionResult: Sendable {
        case extracted(URL)
        case noAudioInSource
        case failed(reason: String)
        case cancelled
    }

    enum ImageSequenceAudioStagingResult: Sendable {
        case staged(URL, URL, SubprocessRequest)
        case noAudioInSource
        case failed(reason: String)
        case cancelled
    }

    struct PackageAudioInput: Equatable, Sendable {
        let arguments: [String]
        let probeURL: URL?
        let ffmpegInputIndex: Int
        let assumesSingleAudioStreamIfProbeUnavailable: Bool
    }

    private static let packageAudioOnlyExtensions: Set<String> = [
        "wav", "aif", "aiff", "caf", "mp3", "aac", "m4a", "flac", "ogg", "oga", "opus", "wma"
    ]

    /// Resolves the audio source used by the DCP/IMF post-processing pass. The picture encode may
    /// receive a virtual source through `customInputArguments`, so reopening `inputURL` here would
    /// silently truncate concat groups to their first clip or lose image-sequence companion audio.
    static func packageAudioInput(
        inputURL: URL,
        customInputArguments: [String]?
    ) -> PackageAudioInput {
        let plan = FFMPEGInputPlan(inputURL: inputURL, customArguments: customInputArguments)
        let isAudioFile = packageAudioOnlyExtensions.contains(inputURL.pathExtension.lowercased())
        switch plan {
        case .imageSequence:
            guard let audioPath = plan.companionAudioPath else {
                return PackageAudioInput(arguments: [], probeURL: nil, ffmpegInputIndex: 0,
                                         assumesSingleAudioStreamIfProbeUnavailable: false)
            }
            let audioURL = URL(fileURLWithPath: audioPath)
            return PackageAudioInput(arguments: FFMPEGInputPlan.file(audioURL).arguments(),
                                     probeURL: audioURL, ffmpegInputIndex: 0,
                                     assumesSingleAudioStreamIfProbeUnavailable: true)
        case .file, .concat:
            return PackageAudioInput(arguments: plan.arguments(), probeURL: inputURL, ffmpegInputIndex: 0,
                                     assumesSingleAudioStreamIfProbeUnavailable: isAudioFile)
        case .custom:
            return PackageAudioInput(arguments: plan.arguments(), probeURL: inputURL, ffmpegInputIndex: 0,
                                     assumesSingleAudioStreamIfProbeUnavailable: false)
        }
    }

    func extractPackageAudioAsPCMWAV(
        conversionID: UUID,
        inputURL: URL,
        customInputArguments: [String]?,
        outputFolder: URL,
        ffmpegPath: String,
        trimStart: Double?,
        trimEnd: Double?,
        audioRoutingConfig: AudioRoutingConfig?,
        dcpCarrier: DCPAudioCarrier? = nil
    ) async -> AudioExtractionResult {
        guard postProcessingConversionID == conversionID else {
            return .failed(reason: "Conversion cancelled")
        }

        let taskID = UUID()
        let runner = subprocessRunner
        let task = Task {
            await Self.$runningSubprocessID.withValue(taskID) {
                await Self.extractAudioAsPCMWAV(
                    inputURL: inputURL,
                    customInputArguments: customInputArguments,
                    outputFolder: outputFolder,
                    ffmpegPath: ffmpegPath,
                    trimStart: trimStart,
                    trimEnd: trimEnd,
                    audioRoutingConfig: audioRoutingConfig,
                    dcpCarrier: dcpCarrier,
                    subprocessRunner: runner
                )
            }
        }
        currentPackageAudioTask?.cancel()
        currentPackageAudioTask = task
        currentPackageAudioTaskID = taskID

        let result = await task.value
        if currentPackageAudioTaskID == taskID {
            currentPackageAudioTask = nil
            currentPackageAudioTaskID = nil
        }

        guard postProcessingConversionID == conversionID else {
            if case .extracted(let outputURL, _) = result,
               FileManager.default.fileExists(atPath: outputURL.path) {
                Self.cleanupTempFile(at: outputURL, label: "cancelled package audio WAV")
            }
            return .failed(reason: "Conversion cancelled")
        }
        return result
    }

    static func extractAudioAsPCMWAV(
        inputURL: URL,
        customInputArguments: [String]? = nil,
        outputFolder: URL,
        ffmpegPath: String,
        trimStart: Double?,
        trimEnd: Double?,
        audioRoutingConfig: AudioRoutingConfig? = nil,
        dcpCarrier: DCPAudioCarrier? = nil,
        subprocessRunner: any SubprocessRunning = SubprocessRunner()
    ) async -> AudioExtractionResult {
        let audioWavURL = outputFolder.appendingPathComponent("audio_temp_\(UUID().uuidString).wav")

        // DCP-o-matic always writes a sound track; a picture-only DCP trips up some servers.
        func silentOrNoAudio() async -> AudioExtractionResult {
            guard let dcpCarrier else { return .noAudioInSource }
            logger.info("DCP audio: source has no audio, writing a silent 5.1 track")
            let args = ["-y", "-nostdin",
                        "-f", "lavfi", "-i", "anullsrc=r=48000:cl=5.1",
                        "-af", dcpCarrier.lengthFilter,
                        "-c:a", "pcm_s24le", audioWavURL.path]
            return await runPCMWAVExtraction(
                args: args, ffmpegPath: ffmpegPath, inputURL: inputURL, outputFolder: outputFolder,
                audioWavURL: audioWavURL, sourceChannels: 0, subprocessRunner: subprocessRunner
            )
        }

        let audioInput = packageAudioInput(
            inputURL: inputURL,
            customInputArguments: customInputArguments
        )

        // A sequence without companion audio has no probe URL and is a legitimate silent input.
        guard let probeURL = audioInput.probeURL else {
            logger.debug("No audio streams in resolved source, skipping package audio extraction")
            return await silentOrNoAudio()
        }
        let probedAudioStreams = await FFMPEGProbeService.fetchAudioStreams(for: probeURL) ?? []
        let audioStreams: [FFMPEGProbeService.AudioStreamInfo]
        if !probedAudioStreams.isEmpty {
            audioStreams = probedAudioStreams
        } else if audioInput.assumesSingleAudioStreamIfProbeUnavailable {
            // SwiftExif intentionally delegates WAV/AIFF and a few other raw audio containers to
            // AVFoundation for duration only, so it cannot report their stream topology. These are
            // explicit audio-only sources; FFmpeg can safely address their sole stream as 0:a:0.
            audioStreams = [FFMPEGProbeService.AudioStreamInfo(
                index: 0,
                channels: nil,
                channelLayout: nil,
                codecName: nil
            )]
        } else {
            logger.debug("No audio streams in resolved source, skipping package audio extraction")
            return await silentOrNoAudio()
        }

        var args: [String] = ["-y", "-nostdin"]

        // Apply trim start (input seeking)
        let normalizedStart = FFMPEGCommandBuilder.normalizedTrimPoint(trimStart)
        if let start = normalizedStart {
            args.append(contentsOf: ["-ss", FFMPEGCommandBuilder.ffmpegTimeString(from: start)])
        }

        args.append(contentsOf: audioInput.arguments)

        // Apply trim duration. DCP audio instead runs exactly as long as the picture,
        // which its sample-exact length filter enforces.
        if dcpCarrier == nil, let durationArgs = FFMPEGCommandBuilder.trimDurationArgument(start: normalizedStart, end: FFMPEGCommandBuilder.normalizedTrimPoint(trimEnd)) {
            args.append(contentsOf: durationArgs)
        }

        // Always suppress video output
        args.append(contentsOf: ["-vn"])

        // Determine which audio streams to use based on routing config
        // If audio routing is configured, use the selected output tracks.
        // Otherwise, only amerge when ALL streams are mono (e.g. separate mono tracks
        // that should be combined). For multi-channel streams (5.1, 7.1, etc.),
        // just use the first stream.
        let selectedStreamIndices: [Int]
        if let routing = audioRoutingConfig, routing.isCustomized {
            selectedStreamIndices = routing.outputTrackIndices
            if selectedStreamIndices.count > 1 {
                logger.info("DCP audio: using \(selectedStreamIndices.count) streams from audio routing config")
            }
        } else {
            // Check if all streams are mono — if so, merge them all
            let allMono = audioStreams.allSatisfy { ($0.channels ?? 0) == 1 }
            if allMono && audioStreams.count > 1 {
                selectedStreamIndices = audioStreams.enumerated().map { $0.offset }
                logger.info("DCP audio: merging \(audioStreams.count) mono streams into one multi-channel output")
            } else {
                // Multiple non-mono streams (e.g. 10x 5.1 surround) — use only the first
                selectedStreamIndices = [0]
                if audioStreams.count > 1 {
                    logger.warning("DCP audio: source has \(audioStreams.count) multi-channel audio streams — using only the first stream. Configure audio routing to select a different track.")
                }
            }
        }

        // An empty customized route means the user intentionally removed every audio track.
        // Treat that the same as a silent source instead of indexing the empty selection below.
        guard !selectedStreamIndices.isEmpty else {
            logger.info("Package audio: all audio tracks were removed by routing configuration")
            return await silentOrNoAudio()
        }

        // For multiple selected streams that are all mono, amerge them.
        // Otherwise, map a single stream.
        let selectedAllMono = selectedStreamIndices.allSatisfy { idx in
            let channels = audioStreams.indices.contains(idx) ? (audioStreams[idx].channels ?? 0) : 0
            return channels == 1
        }
        let merged = selectedStreamIndices.count > 1 && selectedAllMono
        let sourceChannels: Int? = merged
            ? selectedStreamIndices.count
            : (audioStreams.indices.contains(selectedStreamIndices[0]) ? audioStreams[selectedStreamIndices[0]].channels : nil)
        // DCP: place the source in the 5.1 carrier and pad short audio to the picture length.
        let dcpFilter = dcpCarrier.map {
            "\(DCPAudioCarrier.channelMapFilter(sourceChannels: sourceChannels)),\($0.lengthFilter)"
        }
        if merged {
            var filterInputs = ""
            for idx in selectedStreamIndices {
                filterInputs += "[\(audioInput.ffmpegInputIndex):a:\(idx)]"
            }
            let carrierSuffix = dcpFilter.map { ",\($0)" } ?? ""
            args.append(contentsOf: [
                "-filter_complex", "\(filterInputs)amerge=inputs=\(selectedStreamIndices.count)\(carrierSuffix)[aout]",
                "-map", "[aout]",
            ])
        } else {
            // Map a single audio stream
            args.append(contentsOf: ["-map", "\(audioInput.ffmpegInputIndex):a:\(selectedStreamIndices[0])"])
            if let dcpFilter {
                args.append(contentsOf: ["-af", dcpFilter])
            }
        }

        args.append(contentsOf: [
            "-c:a", "pcm_s24le",     // 24-bit PCM
            "-ar", "48000",          // 48 kHz (DCI standard)
            audioWavURL.path
        ])

        logger.info("Extracting audio as WAV for DCP: \(audioWavURL.lastPathComponent) (streams: \(selectedStreamIndices))")
        return await runPCMWAVExtraction(
            args: args, ffmpegPath: ffmpegPath, inputURL: inputURL, outputFolder: outputFolder,
            audioWavURL: audioWavURL, sourceChannels: sourceChannels, subprocessRunner: subprocessRunner
        )
    }

    private static func runPCMWAVExtraction(
        args: [String],
        ffmpegPath: String,
        inputURL: URL,
        outputFolder: URL,
        audioWavURL: URL,
        sourceChannels: Int?,
        subprocessRunner: any SubprocessRunning
    ) async -> AudioExtractionResult {
        let sensitiveValues = Set(
            args.filter { $0.hasPrefix("/") } + [
                ffmpegPath,
                inputURL.path,
                outputFolder.path,
                audioWavURL.path,
            ]
        )
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: args,
            timeout: packageAudioExtractionTimeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: packageAudioDiagnosticCaptureLimit,
            sensitiveValues: sensitiveValues
        )

        func cleanupPartialOutput() {
            guard FileManager.default.fileExists(atPath: audioWavURL.path) else { return }
            Self.cleanupTempFile(at: audioWavURL, label: "partial package audio WAV")
        }

        do {
            let result = try await subprocessRunner.run(request)
            try Task.checkCancellation()
            guard result.succeeded else {
                let diagnostic = request.redactedDiagnostic(result.standardErrorText)
                let reason = Self.dcpIMFErrorReason(
                    base: "ffmpeg exit \(result.terminationStatus)",
                    stderr: diagnostic
                )
                logger.error("Package audio extraction failed: \(reason, privacy: .public)")
                cleanupPartialOutput()
                return .failed(reason: reason)
            }
            if let validationError = Self.validateOutputFile(at: audioWavURL) {
                logger.error("Package audio extraction output validation failed: \(validationError, privacy: .public)")
                cleanupPartialOutput()
                return .failed(reason: validationError)
            }

            logger.info("Audio WAV extraction complete: \(audioWavURL.lastPathComponent)")
            return .extracted(audioWavURL, sourceChannels: sourceChannels)
        } catch is CancellationError {
            cleanupPartialOutput()
            return .failed(reason: "Conversion cancelled")
        } catch SubprocessRunnerError.timedOut {
            cleanupPartialOutput()
            return .failed(reason: "FFmpeg audio extraction timed out after 12 hours")
        } catch {
            cleanupPartialOutput()
            let diagnostic = request.redactedDiagnostic(error.localizedDescription)
            logger.error("Failed to start package audio extraction: \(diagnostic, privacy: .public)")
            return .failed(reason: "Failed to start FFmpeg: \(diagnostic)")
        }
    }

    /// Reads the channel count from a RIFF WAV's `fmt ` chunk. The metadata probe cannot
    /// report WAV stream topology, and the IMF MCA labels must match the extracted layout.
    static func wavChannelCount(at url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count == 12,
              header.prefix(4) == Data("RIFF".utf8),
              header.suffix(4) == Data("WAVE".utf8) else { return nil }
        // Chunks before `fmt ` are small (e.g. JUNK); stop after a bounded scan.
        for _ in 0..<16 {
            guard let chunkHeader = try? handle.read(upToCount: 8), chunkHeader.count == 8 else { return nil }
            let size = chunkHeader.suffix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            if chunkHeader.prefix(4) == Data("fmt ".utf8) {
                guard size >= 4, let format = try? handle.read(upToCount: 4), format.count == 4 else { return nil }
                let channels = Int(format[format.startIndex + 2]) | Int(format[format.startIndex + 3]) << 8
                return channels > 0 ? channels : nil
            }
            guard let offset = try? handle.offset(),
                  (try? handle.seek(toOffset: offset + UInt64(size + size % 2))) != nil else { return nil }
        }
        return nil
    }

    /// Uses the exact wrapped picture frame count when available so audio padding and the CPL
    /// agree with the MXF. Falls back to source duration before wrapping has completed.
    static func resolvedIMFPictureFrameCount(
        exactFrameCount: Int?,
        duration: Double?,
        editRateNumerator: Int,
        editRateDenominator: Int
    ) -> Int {
        if let exactFrameCount, exactFrameCount > 0 {
            return exactFrameCount
        }

        guard let duration,
              duration.isFinite,
              duration > 0,
              editRateNumerator > 0,
              editRateDenominator > 0 else {
            return 0
        }

        return Int(ceil(
            duration * Double(editRateNumerator) / Double(editRateDenominator)
        ))
    }

    /// Pads with silence or trims a 48 kHz PCM WAV so it holds exactly `frameCount`
    /// picture frames worth of samples. The IMF CPL plays the audio track file for
    /// the picture's duration, so a short file cannot cover the composition and
    /// surplus samples (e.g. a source audio tail) would only be dead weight.
    ///
    /// For non-integer rates (29.97, 59.94) the per-frame sample count is not an
    /// integer, so this uses the ceiling of `frameCount × 48000 × den / num`, the
    /// same rounding `IMFManifestWriter.resourceDuration` applies to the CPL.
    func fitWAVToFrameCount(
        conversionID: UUID,
        inputWAV: URL,
        frameCount: Int,
        editRateNumerator: Int,
        editRateDenominator: Int,
        ffmpegPath: String
    ) async -> URL? {
        guard frameCount > 0, editRateNumerator > 0, editRateDenominator > 0 else { return nil }
        guard let totalSamples = IMFManifestWriter.resourceDuration(
            compositionFrames: frameCount,
            compositionEditRate: (editRateNumerator, editRateDenominator),
            resourceEditRate: "48000/1"
        ) else { return nil }
        let outputWAV = inputWAV.deletingLastPathComponent()
            .appendingPathComponent("audio_fitted_\(UUID().uuidString).wav")

        let args: [String] = [
            "-y", "-nostdin",
            "-i", inputWAV.path,
            "-af", "apad=whole_len=\(totalSamples),atrim=end_sample=\(totalSamples)",
            "-c:a", "pcm_s24le",
            "-ar", "48000",
            outputWAV.path
        ]
        Self.logger.info("Fitting IMF WAV to \(totalSamples) samples")
        let result = await runTrackedPackageWrapper(
            conversionID: conversionID,
            executablePath: ffmpegPath,
            arguments: args,
            outputURL: outputWAV
        )
        switch result {
        case .success(let diagnostic):
            if !diagnostic.isEmpty {
                Self.logger.info("IMF WAV fitting output: \(diagnostic.prefix(500), privacy: .public)")
            }
            return outputWAV
        case .failed(_, let reason, let diagnostic):
            Self.logger.error("IMF WAV fitting failed (\(reason, privacy: .public)): \(diagnostic.prefix(300), privacy: .public)")
            return nil
        case .cancelled:
            return nil
        }
    }
}
