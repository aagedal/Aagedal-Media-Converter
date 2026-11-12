// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Native (Swift-rendered) waveform video conversion.

import Foundation
import OSLog

extension FFMPEGConverter {
    func runNativeWaveformConversion(
        conversionID: UUID,
        inputURL: URL,
        ffmpegOutputURL: URL,
        ffmpegPath: String,
        preset: ExportPreset,
        dcpSettings: DCPSettings?,
        imfSettings: IMFSettings?,
        audioOnlySettings: AudioOnlySettings?,
        imageSequenceSettings: ImageSequenceSettings?,
        codecSettings: CodecExportSettings?,
        waveformRequest: WaveformVideoRequest,
        audioRoutingConfig: AudioRoutingConfig?,
        trimStart: Double?,
        trimEnd: Double?,
        comment: String,
        writeEmptyComment: Bool,
        includeDateTag: Bool,
        commentSettings: CommentSettings,
        isMuted: Bool,
        additionalOutputArguments: [String]?,
        expectedDuration: Double?,
        videoFrameRate: Double?,
        needsBMXRewrap: Bool,
        tempMXFURL: URL?,
        outputFileURL: URL,
        waveformBackgroundImageURL: URL? = nil,
        matteSidecar: MatteSidecarBox? = nil,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void,
        completion: @escaping @Sendable (Bool, String?) -> Void
    ) async {
        Self.logger.info("Starting native waveform conversion (Swift engine)")

        let progressGate = ConversionProgressGate()
        currentProgressGate?.invalidate()
        currentProgressGate = progressGate
        let gatedProgressUpdate: @Sendable (Double, String?) -> Void = { progress, status in
            progressGate.run {
                progressUpdate(progress, status)
            }
        }
        let complete: @Sendable (Bool, String?) async -> Void = { [weak self] success, errorReason in
            guard let self else {
                completion(false, errorReason ?? "Conversion cancelled")
                return
            }
            let wasActive = await self.finishTrackedConversion(conversionID)
            completion(success && wasActive, wasActive ? errorReason : "Conversion cancelled")
        }

        if let preparationError = FFMPEGTrimPlan(start: trimStart, end: trimEnd).preparationError {
            await complete(false, preparationError)
            return
        }

        // Compute effective duration for the render
        let effectiveDuration: Double
        if let trimStart, let trimEnd, trimEnd > trimStart {
            effectiveDuration = trimEnd - trimStart
        } else if let expected = expectedDuration {
            effectiveDuration = expected
        } else if let duration = await FFMPEGProbeService.getVideoDuration(for: inputURL) {
            effectiveDuration = duration
        } else {
            Self.logger.error("Cannot determine audio duration for native waveform")
            await complete(false, "Cannot determine audio duration")
            return
        }
        guard activeConversionID == conversionID else {
            await complete(false, "Conversion cancelled")
            return
        }

        // Phase 1: Decode audio and compute frequency bands (~10% of progress)
        gatedProgressUpdate(0.02, "Analyzing audio…")
        let frequencyData: FrequencyBandData
        let analysisID = UUID()
        let runner = subprocessRunner
        let analysisTask = Task {
            try await Self.$runningSubprocessID.withValue(analysisID) {
                try await WaveformPCMDecoder.decode(
                    url: inputURL,
                    ffmpegPath: ffmpegPath,
                    frameRate: waveformRequest.frameRate,
                    duration: effectiveDuration,
                    bandCount: waveformRequest.bandCount,
                    frequencyDistribution: waveformRequest.frequencyDistribution,
                    normalizeAudio: waveformRequest.normalizeAudio,
                    audioRoutingConfig: audioRoutingConfig,
                    trimStart: trimStart,
                    trimEnd: trimEnd,
                    subprocessRunner: runner
                )
            }
        }
        currentWaveformEncodingTask?.cancel()
        currentWaveformEncodingTask = nil
        currentWaveformEncodingID = nil
        currentWaveformAnalysisTask?.cancel()
        currentWaveformAnalysisTask = analysisTask
        currentWaveformAnalysisID = analysisID
        do {
            frequencyData = try await analysisTask.value
        } catch {
            clearWaveformAnalysis(if: analysisID)
            if error is CancellationError {
                await complete(false, "Conversion cancelled")
                return
            }
            Self.logger.error("PCM decode/FFT failed: \(error.localizedDescription)")
            await complete(false, "Audio analysis failed: \(error.localizedDescription)")
            return
        }
        clearWaveformAnalysis(if: analysisID)
        guard activeConversionID == conversionID else {
            await complete(false, "Conversion cancelled")
            return
        }

        gatedProgressUpdate(0.10, "Rendering waveform…")

        // A transparent waveform without a background image has alpha; when the format
        // cannot keep it, the command can split it into a matte sidecar instead.
        let matteOutputURL: URL? = if let matteSidecar, waveformRequest.transparentBackground,
                                      waveformBackgroundImageURL == nil {
            matteSidecar.reserve(for: outputFileURL, notOverwriting: inputURL, owner: conversionID)
        } else {
            nil
        }

        // Phase 2: Build FFmpeg encoding command with rawvideo pipe input
        let command = await FFMPEGCommandBuilder.nativeWaveformEncodingCommand(
            audioInputURL: inputURL,
            outputFileURL: ffmpegOutputURL,
            preset: preset,
            dcpSettings: dcpSettings,
            imfSettings: imfSettings,
            audioOnlySettings: audioOnlySettings,
            imageSequenceSettings: imageSequenceSettings,
            codecSettings: codecSettings,
            commentSettings: commentSettings,
            width: waveformRequest.width,
            height: waveformRequest.height,
            frameRate: waveformRequest.frameRate,
            audioRoutingConfig: audioRoutingConfig,
            trimStart: trimStart,
            trimEnd: trimEnd,
            isMuted: isMuted,
            comment: comment,
            writeEmptyComment: writeEmptyComment,
            includeDateTag: includeDateTag,
            additionalOutputArguments: additionalOutputArguments,
            transparentBackground: waveformRequest.transparentBackground,
            matteOutputURL: matteOutputURL
        )
        if matteOutputURL != nil && command.matteOutputURL == nil {
            // The format keeps alpha (or cannot take a matte): no sidecar needed.
            matteSidecar?.cancelReservation(owner: conversionID)
        }
        // Fill + matte: the fill keeps straight colors with black where fully transparent.
        let rendersTransparent = command.preservesAlpha || command.matteOutputURL != nil
        guard activeConversionID == conversionID else {
            await complete(false, "Conversion cancelled")
            return
        }

        if let preparationError = command.preparationError {
            await complete(false, preparationError)
            return
        }

        // Phase 3: Stream rendered video frames into FFmpeg through the shared runner.
        let privateCommandValues = Set(
            command.arguments.filter { $0.hasPrefix("/") } + [
                ffmpegPath,
                inputURL.path,
                ffmpegOutputURL.path,
                outputFileURL.path,
            ]
        )
        let subprocessRequest = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: command.arguments,
            timeout: Self.nativeWaveformEncodingTimeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: Self.nativeWaveformDiagnosticCaptureLimit,
            sensitiveValues: privateCommandValues
        )
        Self.logger.info("FFmpeg native waveform command: \(subprocessRequest.redactedCommandDescription, privacy: .public)")

        let bmxService = self.bmxService
        let capturedNeedsBMXRewrap = needsBMXRewrap
        let capturedTempMXFURL = tempMXFURL
        let capturedFinalOutputURL = outputFileURL
        let capturedInputBaseName = inputURL.deletingPathExtension().lastPathComponent
        let capturedInputURL = inputURL
        let capturedAudioRoutingConfig = audioRoutingConfig

        // Pre-load and scale background image (if set) once before render loop
        if let imageURL = waveformBackgroundImageURL {
            Self.logger.info("Loading waveform background image: \(imageURL.path)")
        } else {
            Self.logger.info("No waveform background image set")
        }
        let backgroundCGImage: CGImage? = if let imageURL = waveformBackgroundImageURL {
            NativeWaveformVideoRenderer.loadBackgroundImage(from: imageURL, width: waveformRequest.width, height: waveformRequest.height)
        } else {
            nil
        }

        let encodingID = UUID()
        let encodingTask = Task {
            try await Self.$runningSubprocessID.withValue(encodingID) {
                try await runner.runWithStreamingStandardInput(
                    subprocessRequest,
                    inputProducer: { standardInput in
                        await WaveformFramePipeWriter.writeFrames(
                            to: standardInput,
                            frequencyData: frequencyData,
                            style: waveformRequest.swiftStyle,
                            width: waveformRequest.width,
                            height: waveformRequest.height,
                            foregroundHex: waveformRequest.foregroundHex,
                            backgroundHex: waveformRequest.backgroundHex,
                            foregroundGradientEnabled: waveformRequest.foregroundGradientEnabled,
                            foregroundGradientEndHex: waveformRequest.foregroundGradientEndHex,
                            backgroundGradientEnabled: waveformRequest.backgroundGradientEnabled,
                            backgroundGradientEndHex: waveformRequest.backgroundGradientEndHex,
                            backgroundImage: backgroundCGImage,
                            waveformOpacity: waveformRequest.waveformOpacity,
                            transparentBackground: rendersTransparent,
                            progressUpdate: { renderProgress in
                                Self.$runningSubprocessID.withValue(encodingID) {
                                    let overall = 0.10 + renderProgress * 0.85
                                    gatedProgressUpdate(overall, "Rendering waveform…")
                                }
                            }
                        )
                    },
                    outputHandler: nil
                )
            }
        }
        currentWaveformEncodingTask?.cancel()
        currentWaveformEncodingTask = encodingTask
        currentWaveformEncodingID = encodingID

        currentSubprocessTask?.cancel()
        joinableSubprocessID = nil
        currentSubprocessTask = Task { [weak self] in
            defer {
                Self.cleanupWaveformTemporaryMXFIfPresent(capturedTempMXFURL)
            }
            let result: SubprocessResult
            do {
                let encodingResult = await encodingTask.result
                await self?.clearWaveformEncoding(if: encodingID)
                result = try encodingResult.get()
            } catch is CancellationError {
                Self.cleanupWaveformTemporaryMXFIfPresent(capturedTempMXFURL)
                await complete(false, "Conversion cancelled")
                return
            } catch SubprocessRunnerError.timedOut(_, let timedOutResult) {
                let diagnostic = subprocessRequest.redactedDiagnostic(
                    timedOutResult.standardErrorText,
                    limit: 64 * 1024
                )
                if !diagnostic.isEmpty {
                    Self.logger.error("Native waveform FFmpeg timed out:\n\(diagnostic, privacy: .public)")
                }
                Self.cleanupWaveformTemporaryMXFIfPresent(capturedTempMXFURL)
                await complete(false, "Native waveform encoding timed out")
                return
            } catch {
                let safeError = subprocessRequest.redactedDiagnostic(
                    error.localizedDescription,
                    limit: 1_000
                )
                Self.logger.error("Failed to run native waveform FFmpeg: \(safeError, privacy: .public)")
                Self.cleanupWaveformTemporaryMXFIfPresent(capturedTempMXFURL)
                await complete(false, "Failed to start FFmpeg: \(safeError)")
                return
            }

            let isActive = await self?.isActiveConversion(conversionID) ?? false
            var success = result.succeeded && isActive
            var errorReason: String? = isActive ? nil : "Conversion cancelled"
            Self.logger.info("Native waveform FFmpeg terminated with status: \(result.terminationStatus)")

            if !success && isActive {
                let stderrString = subprocessRequest.redactedDiagnostic(
                    result.standardErrorText,
                    limit: 64 * 1024
                )
                Self.logger.error("FFmpeg native waveform stderr:\n\(stderrString, privacy: .public)\n-- end --")
                errorReason = Self.extractErrorReason(
                    from: stderrString,
                    exitCode: result.terminationStatus
                )
            }

            if success {
                let fileToValidate = capturedNeedsBMXRewrap
                    ? (capturedTempMXFURL ?? capturedFinalOutputURL)
                    : capturedFinalOutputURL
                if let validationError = Self.validateOutputFile(at: fileToValidate) {
                    success = false
                    errorReason = validationError
                }
            }

            if success && capturedNeedsBMXRewrap, let tempMXF = capturedTempMXFURL {
                Self.logger.info("Running bmxtranswrap for native waveform output")
                gatedProgressUpdate(0.95, "Rewrapping to OP1a...")

                let mcaLabelsFile = await self?.prepareTrackedAVCIntraMCALabelsFile(
                    conversionID: conversionID,
                    inputURL: capturedInputURL,
                    audioRoutingConfig: capturedAudioRoutingConfig,
                    targetChannelCount: codecSettings?.avcIntraAudioChannels?.count ?? 8,
                    mcaDefaults: codecSettings?.avcIntraMCADefaults ?? .none
                )
                if await self?.activateBMXOperationIfActiveConversion(conversionID) == true {
                    let bmxResult = await bmxService.rewrapToOP1a(
                        inputURL: tempMXF,
                        outputURL: capturedFinalOutputURL,
                        clipName: capturedInputBaseName,
                        mcaLabelsFile: mcaLabelsFile,
                        operationID: conversionID,
                        progress: { bmxProgress in
                            let overallProgress = 0.95 + (bmxProgress * 0.05)
                            Task { @MainActor in
                                gatedProgressUpdate(overallProgress, "Rewrapping to OP1a...")
                            }
                        }
                    )
                    let lateCancellation = await bmxService.finishCancellationTracking(
                        operationID: conversionID
                    )
                    await self?.clearActiveBMXOperation(if: conversionID)
                    let stillOwnsConversion = await self?.isActiveConversion(conversionID) ?? false
                    if bmxResult.cancelled || lateCancellation || !stillOwnsConversion {
                        success = false
                        errorReason = "Conversion cancelled"
                    } else if !bmxResult.success {
                        Self.logger.error("bmxtranswrap failed for native waveform")
                        do {
                            try FileManager.default.copyItem(
                                at: tempMXF,
                                to: capturedFinalOutputURL
                            )
                        } catch {
                            success = false
                        }
                    }
                } else {
                    success = false
                    errorReason = "Conversion cancelled"
                }
                if let mcaLabelsFile {
                    Self.cleanupTempFile(at: mcaLabelsFile, label: "MCA labels")
                }
                Self.cleanupTempFile(at: tempMXF, label: "waveform BMX rewrap temp MXF")
            }

            if success, let writtenMatte = command.matteOutputURL {
                if let matteError = Self.validateOutputFile(at: writtenMatte) {
                    Self.logger.warning("Waveform matte sidecar missing or empty: \(matteError, privacy: .public)")
                } else {
                    matteSidecar?.markWritten()
                    Self.logger.info("Wrote waveform matte sidecar: \(writtenMatte.lastPathComponent, privacy: .public)")
                }
            }

            Self.cleanupWaveformTemporaryMXFIfPresent(capturedTempMXFURL)
            await complete(success, errorReason)
        }
    }
}
