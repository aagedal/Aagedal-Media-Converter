// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import Darwin
import CoreGraphics
import os
import OSLog

/// Serializes the several asynchronous exit paths a conversion can have. In particular,
/// cancellation and subprocess completion may race while post-processing is handed off.
private final class ConversionCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didComplete = false

    func run(_ action: @Sendable () -> Void) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        lock.unlock()
        action()
    }
}

/// Prevents progress callbacks already queued on another executor from mutating a
/// cancelled or superseded conversion.
private final class ConversionProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    func run(_ action: @Sendable () -> Void) {
        lock.withLock {
            guard active else { return }
            action()
        }
    }

    func invalidate() {
        lock.withLock { active = false }
    }
}

/// Atomically reserves ordinary output paths across converter instances. A cancelled
/// attempt keeps its reservation until its completion path runs, preventing a retry
/// from publishing to a path that the older attempt may still clean up or write.
private final class ConversionOutputReservations: @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [URL: UUID] = [:]

    func reserveUnique(
        _ requestedURL: URL,
        notOverwriting inputURL: URL,
        owner: UUID
    ) -> URL {
        lock.withLock {
            let standardizedInput = inputURL.standardizedFileURL
            let fileManager = FileManager.default
            let baseName = requestedURL.deletingPathExtension().lastPathComponent
            let pathExtension = requestedURL.pathExtension
            let folder = requestedURL.deletingLastPathComponent()
            var candidate = requestedURL
            var counter = 1

            while fileManager.fileExists(atPath: candidate.path)
                || candidate.standardizedFileURL == standardizedInput
                || owners[candidate.standardizedFileURL] != nil {
                candidate = folder
                    .appendingPathComponent("\(baseName)_\(counter)")
                    .appendingPathExtension(pathExtension)
                counter += 1
            }

            owners[candidate.standardizedFileURL] = owner
            return candidate
        }
    }

    /// Returns true only when this attempt still owns the reservation.
    func release(_ url: URL, owner: UUID) -> Bool {
        lock.withLock {
            let standardizedURL = url.standardizedFileURL
            guard owners[standardizedURL] == owner else { return false }
            owners.removeValue(forKey: standardizedURL)
            return true
        }
    }
}

actor FFMPEGConverter {
    private var currentSubprocessTask: Task<Void, Never>?
    private var currentDependencyPreflightTask: Task<String?, Error>?
    private var currentWaveformAnalysisTask: Task<FrequencyBandData, Error>?
    private var currentWaveformAnalysisID: UUID?
    private var currentImageSequenceAudioTask: Task<ImageSequenceAudioStagingResult, Never>?
    private var currentImageSequenceAudioTaskID: UUID?
    private var currentPackageAudioTask: Task<AudioExtractionResult, Never>?
    private var currentPackageAudioTaskID: UUID?
    private var currentPackagePreparationTask: Task<Int64, Error>?
    private var currentPackagePreparationTaskID: UUID?
    private var currentPackageWrapperTask: Task<PackageWrapperResult, Never>?
    private var currentPackageWrapperTaskID: UUID?
    private var currentAVCIntraPreprocessingTask: Task<AVCIntraAudioPreprocessingResult, Never>?
    private var currentAVCIntraPreprocessingTaskID: UUID?
    private var currentAV2HelperTask: Task<AV2HelperRunResult, Never>?
    private var currentAV2HelperTaskID: UUID?
    private var currentAV2PipelineTasks: [UUID: Task<SubprocessPipelineResult, Error>] = [:]
    private var currentProgressGate: ConversionProgressGate?
    private var activeConversionID: UUID?
    private var postProcessingConversionID: UUID?
    private var activeBMXOperationID: UUID?
    private let subprocessRunner: any SubprocessRunning
    private let ffmpegPathProvider: @Sendable () -> String?
    private let avmdecPathProvider: @Sendable () -> String?
    private let dependencyPreflight: ConversionDependencyPreflight
    private let preflightAudioStreamProvider: @Sendable (URL) async -> [FFMPEGProbeService.AudioStreamInfo]?

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "FFMPEGConverter")
    private static let outputReservations = ConversionOutputReservations()
    static let packageAudioExtractionTimeout: Duration = .seconds(12 * 60 * 60)
    static let packageAudioDiagnosticCaptureLimit = 256 * 1024
    static let imageSequenceAudioExtractionTimeout: Duration = .seconds(12 * 60 * 60)
    static let imageSequenceAudioDiagnosticCaptureLimit = 256 * 1024
    static let packageWrapperTimeout: Duration = .seconds(12 * 60 * 60)
    static let packageWrapperDiagnosticCaptureLimit = 256 * 1024
    static let avcIntraAudioPreprocessingTimeout: Duration = .seconds(12 * 60 * 60)
    static let avcIntraAudioPreprocessingDiagnosticCaptureLimit = 256 * 1024
    static let av2ProbeHelperTimeout: Duration = .seconds(5 * 60)
    static let av2AudioHelperTimeout: Duration = .seconds(12 * 60 * 60)
    static let av2HelperDiagnosticCaptureLimit = 256 * 1024
    static let av2PipelineTimeout: Duration = .seconds(7 * 24 * 60 * 60)
    static let av2PipelineDiagnosticCaptureLimit = 512 * 1024
    static let nativeWaveformEncodingTimeout: Duration = .seconds(7 * 24 * 60 * 60)
    static let nativeWaveformDiagnosticCaptureLimit = 256 * 1024

    enum PackageWrapperResult: Sendable {
        case success(diagnostic: String)
        case failed(status: Int32?, reason: String, diagnostic: String)
        case cancelled
    }

    enum AVCIntraAudioPreprocessingResult: Sendable {
        case success(URL)
        case failed(reason: String)
        case cancelled
    }

    enum AV2HelperRunResult: Sendable, Equatable {
        case success
        case failed(reason: String)
        case cancelled
    }

    init(
        subprocessRunner: any SubprocessRunning = SubprocessRunner(),
        ffmpegPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.ffmpegPath },
        avmdecPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.avmdecPath },
        dependencyPreflight: ConversionDependencyPreflight = ConversionDependencyPreflight(),
        preflightAudioStreamProvider: @escaping @Sendable (URL) async -> [FFMPEGProbeService.AudioStreamInfo]? = {
            await FFMPEGProbeService.fetchAudioStreams(for: $0)
        }
    ) {
        self.subprocessRunner = subprocessRunner
        self.ffmpegPathProvider = ffmpegPathProvider
        self.avmdecPathProvider = avmdecPathProvider
        self.dependencyPreflight = dependencyPreflight
        self.preflightAudioStreamProvider = preflightAudioStreamProvider
    }

    // MARK: - Temp File Cleanup

    /// Removes a temporary file with proper error logging instead of silently swallowing failures.
    /// Silent `try?` on file removal can hide disk space leaks that accumulate over many conversions.
    private static func cleanupTempFile(at url: URL, label: String) {
        do {
            try FileManager.default.removeItem(at: url)
            logger.debug("Cleaned up temp file (\(label, privacy: .public)): \(url.lastPathComponent, privacy: .public)")
        } catch {
            logger.warning("Failed to clean up temp file (\(label, privacy: .public)): \(url.lastPathComponent, privacy: .public) — \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func cleanupWaveformTemporaryMXFIfPresent(_ url: URL?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        cleanupTempFile(at: url, label: "waveform BMX rewrap temp MXF")
    }

    // MARK: - AVC-Intra MCA Labels

    /// Builds an MCA labels temp file for the AVC-Intra OP1a rewrap.
    ///
    /// Returns nil if no useful labels can be derived (caller should rewrap without
    /// the labels flag in that case, preserving today's behavior). Mirrors the
    /// AVC-Intra mono-split layout in `FFMPEGCommandBuilder.adjustAVCIntraAudio`:
    /// each input audio channel becomes one mono output track in input order.
    private static func prepareAVCIntraMCALabelsFile(
        inputURL: URL,
        audioRoutingConfig: AudioRoutingConfig?
    ) async -> URL? {
        let allStreams = await FFMPEGProbeService.fetchAudioStreams(for: inputURL) ?? []
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
            mcaLabels = await BMXService.shared.getAudioTrackLabels(url: inputURL) ?? []
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

        let audioChannelsRaw = UserDefaults.standard.string(forKey: AppConstants.avcIntraAudioChannelsKey)
            ?? AppConstants.defaultAVCIntraAudioChannels
        let targetChannelCount = (AVCIntraAudioChannels(rawValue: audioChannelsRaw) ?? .ch8).count

        guard let content = MCALabelsBuilder.buildAVCIntraLabelsFile(
            inputStreams: inputInfos,
            inputMCALabels: mcaLabels,
            overrides: overrides,
            outputTrackCount: targetChannelCount
        ) else {
            return nil
        }

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

    // MARK: - Output Validation

    /// Validates that an output file exists and has a non-zero size after FFmpeg reports success.
    /// FFmpeg can exit with status 0 while producing empty or corrupt output (e.g., disk full,
    /// interrupted I/O, or edge-case codec errors that don't set a non-zero exit code).
    private static func validateOutputFile(at url: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return "Output file was not created"
        }
        do {
            let attrs = try fm.attributesOfItem(atPath: url.path)
            let fileSize = attrs[.size] as? UInt64 ?? 0
            if fileSize == 0 {
                return "Output file is empty (0 bytes)"
            }
            logger.info("Output validated: \(url.lastPathComponent, privacy: .public) (\(fileSize) bytes)")
        } catch {
            return "Cannot read output file attributes: \(error.localizedDescription)"
        }
        return nil
    }

    static func runPackageWrapper(
        executablePath: String,
        arguments: [String],
        outputURL: URL,
        subprocessRunner: any SubprocessRunning = SubprocessRunner()
    ) async -> PackageWrapperResult {
        let sensitiveValues = Set(
            arguments.filter { $0.hasPrefix("/") } + [executablePath, outputURL.path]
        )
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            timeout: packageWrapperTimeout,
            standardOutputCaptureLimit: packageWrapperDiagnosticCaptureLimit,
            standardErrorCaptureLimit: packageWrapperDiagnosticCaptureLimit,
            sensitiveValues: sensitiveValues
        )

        func cleanupPartialOutput() {
            guard FileManager.default.fileExists(atPath: outputURL.path) else { return }
            cleanupTempFile(at: outputURL, label: "partial package wrapper output")
        }

        func diagnostic(for result: SubprocessResult) -> String {
            request.redactedDiagnostic(
                [result.standardOutputText, result.standardErrorText]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            )
        }

        do {
            let result = try await subprocessRunner.run(request)
            let output = diagnostic(for: result)
            guard result.succeeded else {
                cleanupPartialOutput()
                return .failed(
                    status: result.terminationStatus,
                    reason: "tool exited with status \(result.terminationStatus)",
                    diagnostic: output
                )
            }
            if let validationError = validateOutputFile(at: outputURL) {
                cleanupPartialOutput()
                return .failed(
                    status: result.terminationStatus,
                    reason: request.redactedDiagnostic(validationError),
                    diagnostic: output
                )
            }
            return .success(diagnostic: output)
        } catch is CancellationError {
            cleanupPartialOutput()
            return .cancelled
        } catch SubprocessRunnerError.timedOut(_, let result) {
            let output = diagnostic(for: result)
            cleanupPartialOutput()
            return .failed(
                status: result.terminationStatus,
                reason: "tool timed out after 12 hours",
                diagnostic: output
            )
        } catch {
            let output = request.redactedDiagnostic(error.localizedDescription)
            cleanupPartialOutput()
            return .failed(status: nil, reason: "failed to start tool", diagnostic: output)
        }
    }

    private func runTrackedPackageWrapper(
        conversionID: UUID,
        executablePath: String,
        arguments: [String],
        outputURL: URL
    ) async -> PackageWrapperResult {
        guard postProcessingConversionID == conversionID else { return .cancelled }

        let taskID = UUID()
        let runner = subprocessRunner
        let task = Task {
            await Self.runPackageWrapper(
                executablePath: executablePath,
                arguments: arguments,
                outputURL: outputURL,
                subprocessRunner: runner
            )
        }
        currentPackageWrapperTask?.cancel()
        currentPackageWrapperTask = task
        currentPackageWrapperTaskID = taskID

        let result = await task.value
        if currentPackageWrapperTaskID == taskID {
            currentPackageWrapperTask = nil
            currentPackageWrapperTaskID = nil
        }

        guard postProcessingConversionID == conversionID else {
            if case .success = result,
               FileManager.default.fileExists(atPath: outputURL.path) {
                Self.cleanupTempFile(at: outputURL, label: "cancelled package wrapper output")
            }
            return .cancelled
        }
        return result
    }

    /// Runs blocking frame I/O off the converter actor so cancellation can reach it.
    private func prepareTrackedPackageCodestreams(
        conversionID: UUID,
        sourceDirectory: URL,
        frameNames: [String],
        destinationDirectory: URL,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> Int64 {
        guard postProcessingConversionID == conversionID else { throw CancellationError() }
        let taskID = UUID()
        let task = Task.detached {
            var lastEmit = Date.distantPast
            return try Self.preparePackageCodestreams(
                sourceDirectory: sourceDirectory,
                frameNames: frameNames,
                destinationDirectory: destinationDirectory
            ) { completed, total in
                let now = Date()
                if now.timeIntervalSince(lastEmit) >= 0.25 || completed == total {
                    lastEmit = now
                    progress(completed, total)
                }
            }
        }
        currentPackagePreparationTask?.cancel()
        currentPackagePreparationTask = task
        currentPackagePreparationTaskID = taskID
        defer {
            if currentPackagePreparationTaskID == taskID {
                currentPackagePreparationTask = nil
                currentPackagePreparationTaskID = nil
            }
        }
        let bytes = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        guard postProcessingConversionID == conversionID else { throw CancellationError() }
        return bytes
    }

    /// Removes an incomplete ordinary-file output and revokes its app-created trust record.
    /// A failed encode must not leave a stale registration that could authorize deleting an
    /// unrelated file created at the same path later.
    private static func cleanupFailedOutput(at url: URL) {
        guard FileSafetyUtils.isCreatedByApp(url) else { return }

        defer { FileSafetyUtils.unregisterCreatedFile(url) }
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            try FileManager.default.removeItem(at: url)
            logger.info("Removed incomplete conversion output: \(url.lastPathComponent, privacy: .public)")
        } catch {
            logger.warning("Failed to remove incomplete conversion output \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Converts a video file using the specified export preset
    /// - Parameters:
    ///   - request: All conversion parameters bundled in a ConversionRequest
    ///   - progressUpdate: Callback for progress updates (progress: Double, status: String?)
    ///   - completion: Callback for completion (success: Bool, errorReason: String?)
    func convert(
        request: ConversionRequest,
        av2Settings: AV2Settings? = nil,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void,
        completion: @escaping @Sendable (Bool, String?) -> Void
    ) async {
        // Destructure frequently-used fields for readability
        let inputURL = request.inputURL
        let outputURL = request.outputURL
        let preset = request.preset
        // Capture all AV2 preferences before cancellation or metadata work can suspend.
        let capturedAV2Settings = preset == .av2 ? (av2Settings ?? AV2Settings()) : nil
        guard let ffmpegPath = ffmpegPathProvider() else {
            Self.logger.error("FFMPEG binary not found")
            completion(false, "FFmpeg binary not found")
            return
        }
        guard preset != .av2 || request.additionalOutputArguments?.isEmpty != false else {
            completion(false, "AV2 export does not support additional FFmpeg output arguments")
            return
        }
        // Generated-video AV2 requests retain their specific unsupported-feature diagnostic.
        if !(preset == .av2 && (request.waveformRequest != nil || request.synthesizedVideoRequest != nil)),
           let failure = dependencyPreflight.failure(for: preset) {
            completion(false, failure)
            return
        }
        // Read the same bounded source headers used by the decoder path before output setup.
        let usesAV2SourceDecoder = preset != .av2
            && request.customInputArguments == nil
            && request.waveformRequest == nil
            && request.synthesizedVideoRequest == nil
        let av2SourceExt = inputURL.pathExtension.lowercased()
        let av2IsIVF = usesAV2SourceDecoder && av2SourceExt == "ivf"
            && (IVFHeaderParser.parse(url: inputURL)?.isAV2 ?? false)
        let av2IsMatroska = usesAV2SourceDecoder && (av2SourceExt == "mkv" || av2SourceExt == "webm")
            && Self.matroskaContainsAV2(url: inputURL)
        let av2SourceDecoderPath = (av2IsIVF || av2IsMatroska) ? avmdecPathProvider() : nil
        if (av2IsIVF || av2IsMatroska),
           let failure = ConversionDependencyPreflight.failure(for: .avmdec, path: av2SourceDecoderPath) {
            completion(false, failure)
            return
        }
        currentDependencyPreflightTask?.cancel()
        currentDependencyPreflightTask = nil
        currentProgressGate?.invalidate()
        currentSubprocessTask?.cancel()
        currentWaveformAnalysisTask?.cancel()
        currentWaveformAnalysisTask = nil
        currentWaveformAnalysisID = nil
        currentImageSequenceAudioTask?.cancel()
        currentImageSequenceAudioTask = nil
        currentImageSequenceAudioTaskID = nil
        currentPackageAudioTask?.cancel()
        currentPackageAudioTask = nil
        currentPackageAudioTaskID = nil
        currentPackagePreparationTask?.cancel()
        currentPackagePreparationTask = nil
        currentPackagePreparationTaskID = nil
        currentPackageWrapperTask?.cancel()
        currentPackageWrapperTask = nil
        currentPackageWrapperTaskID = nil
        currentAVCIntraPreprocessingTask?.cancel()
        currentAVCIntraPreprocessingTask = nil
        currentAVCIntraPreprocessingTaskID = nil
        currentAV2HelperTask?.cancel()
        currentAV2HelperTask = nil
        currentAV2HelperTaskID = nil
        for task in currentAV2PipelineTasks.values { task.cancel() }
        currentAV2PipelineTasks.removeAll()
        let supersededBMXOperationID = activeBMXOperationID
        activeConversionID = nil
        postProcessingConversionID = nil
        activeBMXOperationID = nil
        if let supersededBMXOperationID {
            await BMXService.shared.cancel(operationID: supersededBMXOperationID)
            _ = await BMXService.shared.finishCancellationTracking(operationID: supersededBMXOperationID)
        }
        let conversionID = UUID()
        activeConversionID = conversionID

        if preset == .imfJ2K || preset == .imfProRes {
            let preflight = dependencyPreflight
            let audioStreamProvider = preflightAudioStreamProvider
            let preflightTask = Task {
                try await preflight.audioFailure(for: request, audioStreamProvider: audioStreamProvider)
            }
            currentDependencyPreflightTask = preflightTask
            let audioDependencyFailure: String?
            do {
                audioDependencyFailure = try await withTaskCancellationHandler {
                    try await preflightTask.value
                } onCancel: {
                    preflightTask.cancel()
                }
            } catch {
                if activeConversionID == conversionID {
                    currentDependencyPreflightTask = nil
                    activeConversionID = nil
                }
                completion(false, "Conversion cancelled")
                return
            }
            guard activeConversionID == conversionID, !Task.isCancelled else {
                completion(false, "Conversion cancelled")
                return
            }
            currentDependencyPreflightTask = nil
            if let audioDependencyFailure {
                activeConversionID = nil
                completion(false, audioDependencyFailure)
                return
            }
        }

        // Ensure output directory exists
        let fileManager = FileManager.default
        let outputDir = outputURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            Self.logger.error("Failed to create output directory: \(error.localizedDescription, privacy: .public)")
            completion(false, "Failed to create output directory")
            return
        }

        // Image sequence / DCP / IMF export: create subfolder
        var outputFileURL: URL
        let isImageSequenceExport = preset == .imageSequence
        let isDCPExport = preset == .dcp
        let isIMFJ2KExport = preset == .imfJ2K
        let isIMFProResExport = preset == .imfProRes
        let isIMFExport = isIMFJ2KExport || isIMFProResExport
        var dcpSubfolderURL: URL? = nil
        var imfSubfolderURL: URL? = nil

        if isDCPExport || isIMFJ2KExport {
            // Create working directory for the package output
            let subfolderName = outputURL.lastPathComponent
            let subfolderURL = outputDir.appendingPathComponent(subfolderName, isDirectory: true)

            var finalSubfolderURL = subfolderURL
            var counter = 1
            while FileManager.default.fileExists(atPath: finalSubfolderURL.path) {
                finalSubfolderURL = outputDir.appendingPathComponent("\(subfolderName)_\(counter)", isDirectory: true)
                counter += 1
            }

            do {
                try fileManager.createDirectory(at: finalSubfolderURL, withIntermediateDirectories: true)
            } catch {
                Self.logger.error("Failed to create package working directory: \(error.localizedDescription, privacy: .public)")
                completion(false, "Failed to create package directory")
                return
            }

            if isDCPExport {
                dcpSubfolderURL = finalSubfolderURL
            } else {
                imfSubfolderURL = finalSubfolderURL
            }

            // DCP / IMF App #2e: FFmpeg outputs JP2 image sequence to a subdirectory in the working folder.
            // This allows the user to optionally keep the JP2 images for image sequence import.
            let jp2Dir = finalSubfolderURL.appendingPathComponent("jp2", isDirectory: true)
            do {
                try fileManager.createDirectory(at: jp2Dir, withIntermediateDirectories: true)
            } catch {
                Self.logger.error("Failed to create JP2 working directory: \(error.localizedDescription, privacy: .public)")
                completion(false, "Failed to create JP2 directory")
                return
            }
            outputFileURL = jp2Dir.appendingPathComponent("frame_%06d.jp2")
            Self.logger.info("\(isDCPExport ? "DCP" : "IMF App 2e"): FFmpeg will output JP2 image sequence")
        } else if isIMFProResExport {
            // IMF App #5: create package working directory; FFmpeg writes to a temp MOV that we
            // later rewrap to OP1a MXF and assemble into the package.
            let subfolderName = outputURL.lastPathComponent
            let subfolderURL = outputDir.appendingPathComponent(subfolderName, isDirectory: true)
            var finalSubfolderURL = subfolderURL
            var counter = 1
            while FileManager.default.fileExists(atPath: finalSubfolderURL.path) {
                finalSubfolderURL = outputDir.appendingPathComponent("\(subfolderName)_\(counter)", isDirectory: true)
                counter += 1
            }
            do {
                try fileManager.createDirectory(at: finalSubfolderURL, withIntermediateDirectories: true)
            } catch {
                Self.logger.error("Failed to create IMF package working directory: \(error.localizedDescription, privacy: .public)")
                completion(false, "Failed to create IMF directory")
                return
            }
            imfSubfolderURL = finalSubfolderURL
            // FFmpeg outputs to a temp MOV inside the working folder; bmxtranswrap will produce the OP1a MXF.
            outputFileURL = finalSubfolderURL.appendingPathComponent("imf_prores_temp.mov")
            Self.logger.info("IMF App 5: FFmpeg will output ProRes MOV for OP1a rewrap")
        } else if isImageSequenceExport {
            let formatRaw = UserDefaults.standard.string(forKey: AppConstants.imageSequenceExportFormatKey) ?? AppConstants.defaultImageSequenceExportFormat
            let format = ImageSequenceFormat(rawValue: formatRaw) ?? .png
            let padding = UserDefaults.standard.integer(forKey: AppConstants.imageSequenceNumberingPaddingKey)
            let effectivePadding = padding > 0 ? padding : AppConstants.defaultImageSequenceNumberingPadding

            // Create subfolder: outputDir/basename_seq/
            let subfolderName = outputURL.lastPathComponent
            let subfolderURL = outputDir.appendingPathComponent(subfolderName, isDirectory: true)

            // Ensure unique folder name
            var finalSubfolderURL = subfolderURL
            var counter = 1
            while FileManager.default.fileExists(atPath: finalSubfolderURL.path) {
                finalSubfolderURL = outputDir.appendingPathComponent("\(subfolderName)_\(counter)", isDirectory: true)
                counter += 1
            }

            do {
                try fileManager.createDirectory(at: finalSubfolderURL, withIntermediateDirectories: true)
            } catch {
                Self.logger.error("Failed to create image sequence output directory: \(error.localizedDescription, privacy: .public)")
                completion(false, "Failed to create image sequence directory")
                return
            }

            // Build the FFMPEG output pattern: subfolder/basename_%06d.png
            let baseName = outputURL.lastPathComponent
            let patternFileName = "\(baseName)_%0\(effectivePadding)d.\(format.primaryExtension)"
            outputFileURL = finalSubfolderURL.appendingPathComponent(patternFileName)
        } else {
            // Use the same captured container for AV2 naming and muxing.
            let outputExtension = capturedAV2Settings?.container.fileExtension ?? preset.outputExtension(for: inputURL)
            outputFileURL = outputURL.appendingPathExtension(outputExtension)

            // CRITICAL: Ensure we never overwrite the source file
            if outputFileURL.standardizedFileURL == inputURL.standardizedFileURL {
                // Add "_encoded" suffix to prevent overwriting source
                let baseName = outputURL.lastPathComponent
                let safeOutputURL = outputDir.appendingPathComponent(baseName + "_encoded")
                    .appendingPathExtension(outputExtension)
                Self.logger.warning("Safety check: would have overwritten input file. Changed output to: \(safeOutputURL.lastPathComponent, privacy: .public)")
                outputFileURL = safeOutputURL
            }

            // Ensure the output path is unique — prevents silently overwriting
            // a previous conversion output (FFmpeg runs with -y).
            outputFileURL = Self.outputReservations.reserveUnique(
                outputFileURL,
                notOverwriting: inputURL,
                owner: conversionID
            )

            // Register this file as created by the app (for safe deletion later if needed)
            FileSafetyUtils.registerCreatedFile(outputFileURL)
        }

        let completionGate = ConversionCompletionGate()
        let cleanupOutputURL = outputFileURL
        let isOrdinaryFileExport = !isImageSequenceExport && !isDCPExport && !isIMFExport
        let finish: @Sendable (Bool, String?) -> Void = { success, errorReason in
            completionGate.run {
                let ownsOutput = !isOrdinaryFileExport || Self.outputReservations.release(
                    cleanupOutputURL,
                    owner: conversionID
                )
                if !success && isOrdinaryFileExport && ownsOutput {
                    Self.cleanupFailedOutput(at: cleanupOutputURL)
                }
                completion(success, errorReason)
            }
        }

        // For AVC-Intra MXF, FFmpeg outputs to temp file, then bmxtranswrap rewraps to OP1a
        let needsBMXRewrap = preset == .tvAVCIntra
        var ffmpegOutputURL = outputFileURL
        var tempMXFURL: URL? = nil

        if needsBMXRewrap {
            // Create temp file for FFmpeg output
            let tempDir = FileManager.default.temporaryDirectory
            let tempURL = tempDir.appendingPathComponent("ffmpeg_mxf_\(UUID().uuidString).mxf")
            tempMXFURL = tempURL
            ffmpegOutputURL = tempURL
            Self.logger.info("AVC-Intra: FFmpeg will output to temp file for OP1a rewrap")
        }

        // Check if we need audio pre-processing for AVC-Intra with audio-only files
        // This creates a temp file with mono-split audio channels first
        var effectiveInputURL = inputURL
        var effectiveCustomInputArguments = request.customInputArguments
        var tempAudioURL: URL? = nil

        if needsAudioPreProcessing(preset: preset, waveformRequest: request.waveformRequest, synthesizedVideoRequest: request.synthesizedVideoRequest) {
            Self.logger.info("Audio-only file with AVC-Intra preset detected, running audio pre-processing pass")

            let preprocessingResult = await preProcessAudioForAVCIntra(
                inputURL: inputURL,
                ffmpegPath: ffmpegPath,
                trimStart: request.trimStart,
                trimEnd: request.trimEnd,
                conversionID: conversionID
            )
            switch preprocessingResult {
            case .success(let preProcessedURL):
                tempAudioURL = preProcessedURL
                effectiveInputURL = preProcessedURL
                // Use the pre-processed file as input
                effectiveCustomInputArguments = ["-i", preProcessedURL.path]
                Self.logger.info("Audio pre-processing complete: \(preProcessedURL.lastPathComponent)")
            case .failed(let reason):
                Self.logger.error("Audio pre-processing failed: \(reason, privacy: .public); falling back to standard conversion")
            case .cancelled:
                finish(false, "Conversion cancelled")
                return
            }
        }

        if preset == .av2,
           (request.waveformRequest != nil || request.synthesizedVideoRequest != nil) {
            finish(false, "AV2 export does not yet support generated video from audio-only sources")
            return
        }

        // MARK: Native waveform rendering branch (Swift engine)
        if let waveformRequest = request.waveformRequest, waveformRequest.renderingEngine == .swift {
            await runNativeWaveformConversion(
                conversionID: conversionID,
                inputURL: inputURL,
                ffmpegOutputURL: ffmpegOutputURL,
                ffmpegPath: ffmpegPath,
                preset: preset,
                waveformRequest: waveformRequest,
                audioRoutingConfig: request.audioRoutingConfig,
                trimStart: request.trimStart,
                trimEnd: request.trimEnd,
                comment: request.comment,
                includeDateTag: request.includeDateTag,
                isMuted: request.isMuted,
                additionalOutputArguments: request.additionalOutputArguments,
                expectedDuration: request.expectedDuration,
                videoFrameRate: request.videoFrameRate,
                needsBMXRewrap: needsBMXRewrap,
                tempMXFURL: tempMXFURL,
                outputFileURL: outputFileURL,
                waveformBackgroundImageURL: request.waveformBackgroundImageURL,
                progressUpdate: progressUpdate,
                completion: finish
            )
            return
        }

        // MARK: Experimental AV2 branch (ffmpeg decode → avmenc encode, two-process pipe)
        if let av2Settings = capturedAV2Settings {
            // Choose output container: a raw video-only `.ivf`, or `.mkv` (AV2 + audio) via the
            // in-app Matroska muxer (FFmpeg can't write AV2). For `.mkv` the encode targets a temp
            // intermediate `.ivf` that the muxer then wraps with the source audio.
            let muxToMKV = (av2Settings.container == .mkv && BinaryPathResolver.avmencPath != nil)
            let encodeURL: URL = muxToMKV
                ? FileManager.default.temporaryDirectory.appendingPathComponent("av2enc_\(UUID().uuidString).ivf")
                : outputFileURL

            // Resolve visual metadata once for the whole AV2 operation. Chunk planning may fall
            // back to the single-pipeline command, and Matroska setup also needs the chosen bit
            // depth; none of those stages should start another potentially stalled media read.
            let metadataURL = request.visualSourceURL ?? inputURL
            let av2PlanningMetadata: VideoMetadata?
            if request.visualSourceURL == nil, let sourceMetadata = request.sourceMetadata {
                av2PlanningMetadata = sourceMetadata
            } else {
                av2PlanningMetadata = try? await BoundedVideoMetadataProbe.metadata(for: metadataURL)
            }
            guard activeConversionID == conversionID else {
                if muxToMKV { Self.cleanupTempFile(at: encodeURL, label: "AV2 intermediate .ivf") }
                finish(false, "Conversion cancelled")
                return
            }

            // Prefer the parallel chunked path (one avmenc per core) when the source can be split;
            // buildSegments returns nil to fall back to the single-process pipe (chunking disabled,
            // VBR mode, unknown frame count, or a clip too short to usefully split).
            let encodeResult: AV2EncodeResult
            if let plan = await AV2CommandBuilder.buildSegments(
                inputURL: inputURL,
                trimStart: request.trimStart,
                trimEnd: request.trimEnd,
                cropConfig: request.cropConfig,
                visualSourceURL: request.visualSourceURL,
                customInputArguments: request.customInputArguments,
                expectedDuration: request.expectedDuration,
                videoFrameRate: request.videoFrameRate,
                metadataSource: .resolved(av2PlanningMetadata),
                settings: av2Settings
            ), let avmencPath = BinaryPathResolver.avmencPath {
                encodeResult = await runAV2ChunkedConversion(
                    plan: plan,
                    outputFileURL: encodeURL,
                    ffmpegPath: ffmpegPath,
                    avmencPath: avmencPath,
                    progressUpdate: progressUpdate
                )
            } else {
                encodeResult = await runAV2Conversion(
                    inputURL: inputURL,
                    outputFileURL: encodeURL,
                    ffmpegPath: ffmpegPath,
                    trimStart: request.trimStart,
                    trimEnd: request.trimEnd,
                    cropConfig: request.cropConfig,
                    visualSourceURL: request.visualSourceURL,
                    customInputArguments: request.customInputArguments,
                    expectedDuration: request.expectedDuration,
                    videoFrameRate: request.videoFrameRate,
                    sourceMetadata: av2PlanningMetadata,
                    settings: av2Settings,
                    progressUpdate: progressUpdate
                )
            }

            guard activeConversionID == conversionID else {
                if muxToMKV {
                    Self.cleanupTempFile(at: encodeURL, label: "superseded AV2 intermediate .ivf")
                }
                finish(false, "Conversion cancelled")
                return
            }

            guard encodeResult.success else {
                if muxToMKV { Self.cleanupTempFile(at: encodeURL, label: "AV2 intermediate .ivf") }
                finish(false, encodeResult.errorReason)
                return
            }

            if muxToMKV, let avmencPath = BinaryPathResolver.avmencPath {
                let bitDepth = await AV2CommandBuilder.resolvedBitDepth(
                    inputURL: inputURL,
                    trimStart: request.trimStart,
                    trimEnd: request.trimEnd,
                    cropConfig: request.cropConfig,
                    visualSourceURL: request.visualSourceURL,
                    metadataSource: .resolved(av2PlanningMetadata),
                    settings: av2Settings
                ) ?? 8
                let (ok, reason) = await muxAV2ToMatroska(
                    conversionID: conversionID,
                    videoIvfURL: encodeURL,
                    sourceURL: inputURL,
                    customInputArguments: request.customInputArguments,
                    isMuted: request.isMuted,
                    audioRoutingConfig: request.audioRoutingConfig,
                    comment: request.comment,
                    includeDateTag: request.includeDateTag,
                    timecodeConfig: request.timecodeConfig,
                    sourceMetadata: request.sourceMetadata ?? (request.visualSourceURL == nil ? av2PlanningMetadata : nil),
                    trimStart: request.trimStart,
                    trimEnd: request.trimEnd,
                    bitDepth: bitDepth,
                    keyframeIndices: encodeResult.keyframeIndices,
                    outputURL: outputFileURL,
                    ffmpegPath: ffmpegPath,
                    avmencPath: avmencPath,
                    settings: av2Settings,
                    progressUpdate: progressUpdate
                )
                Self.cleanupTempFile(at: encodeURL, label: "AV2 intermediate .ivf")
                if ok { progressUpdate(1.0, nil) }
                finish(ok, reason)
                return
            }

            finish(true, nil)
            return
        }

        // MARK: AV2 source decode front-end
        // FFmpeg can't decode AV2, so we run `avmdec` to produce raw frames and pipe them into
        // FFmpeg's stdin; FFmpeg then runs the normal preset command on the decoded frames.
        // avmdec reads both raw `.ivf` bitstreams and AV2-in-Matroska (`.mkv`/`.webm`) directly.
        // For Matroska sources the original file is added as a second FFmpeg input so its
        // (FFmpeg-readable) audio track can be mapped in. Skipped for merges / AVC-Intra / waveform.
        var av2DecodeRequest: SubprocessRequest? = nil
        var av2MatroskaAudioFromInput1 = false
        if (av2IsIVF || av2IsMatroska),
           tempAudioURL == nil,
           request.customInputArguments == nil,
           request.waveformRequest == nil,
           request.synthesizedVideoRequest == nil,
           let avmdecPath = av2SourceDecoderPath {
            // avmdec writes self-describing Y4M to stdout, so FFmpeg auto-detects the exact
            // chroma subsampling and bit depth (4:2:0/4:2:2/4:4:4, 8/10/12-bit) with no
            // assumptions — native depth is preserved (a 10-bit source stays 10-bit).
            if av2IsMatroska {
                var customArgs = ["-f", "yuv4mpegpipe", "-i", "pipe:0"]
                if let ts = request.trimStart, ts > 0 {
                    customArgs += ["-ss", String(format: "%.6f", ts)] // seek the audio input to match
                }
                customArgs += ["-i", inputURL.path]
                effectiveCustomInputArguments = customArgs
                av2MatroskaAudioFromInput1 = true
            } else {
                effectiveCustomInputArguments = ["-f", "yuv4mpegpipe", "-i", "pipe:0"]
            }
            av2DecodeRequest = SubprocessRequest(
                executableURL: URL(fileURLWithPath: avmdecPath),
                arguments: [inputURL.path, "-o", "-"],
                timeout: Self.av2PipelineTimeout,
                standardOutputCaptureLimit: 0,
                standardErrorCaptureLimit: Self.av2PipelineDiagnosticCaptureLimit,
                sensitiveValues: [inputURL.path, avmdecPath]
            )
            Self.logger.info("AV2 decode front-end: avmdec → ffmpeg for \(inputURL.lastPathComponent, privacy: .public)\(av2IsMatroska ? " (Matroska + audio)" : "")")
        }

        // Build FFmpeg arguments
        let command = await FFMPEGCommandBuilder.buildCommand(
            inputURL: effectiveInputURL,
            outputFileURL: ffmpegOutputURL,  // Use temp file for AVC-Intra, final file otherwise
            preset: preset,
            comment: request.comment,
            includeDateTag: request.includeDateTag,
            trimStart: tempAudioURL != nil ? nil : request.trimStart,  // Trim already applied in pre-processing
            trimEnd: tempAudioURL != nil ? nil : request.trimEnd,
            audioRoutingConfig: tempAudioURL != nil ? nil : request.audioRoutingConfig,  // Audio already processed
            cropConfig: request.cropConfig,
            timecodeConfig: request.timecodeConfig,
            sourceMetadata: request.sourceMetadata,
            waveformRequest: request.waveformRequest,
            synthesizedVideoRequest: request.synthesizedVideoRequest,
            visualSourceURL: request.visualSourceURL,
            customInputArguments: effectiveCustomInputArguments,
            additionalOutputArguments: request.additionalOutputArguments,
            isMuted: request.isMuted
        )

        // For an AV2 Matroska source the decoded video arrives on input 0 (the avmdec pipe) and the
        // audio lives on input 1 (the original file). Redirect the preset's audio/subtitle maps,
        // which default to input 0, over to input 1.
        var finalArguments = command.arguments
        if av2MatroskaAudioFromInput1 {
            finalArguments = Self.redirectAudioSubtitleMapsToSecondInput(finalArguments)
        }
        let explicitPrivatePaths = [
            request.visualSourceURL?.path,
            request.waveformBackgroundImageURL?.path,
            tempAudioURL?.path,
            tempMXFURL?.path,
            dcpSubfolderURL?.path,
            imfSubfolderURL?.path,
        ].compactMap { $0 }
        let privatePaths = Set(
            finalArguments.filter { $0.hasPrefix("/") } + explicitPrivatePaths + [
                inputURL.path,
                effectiveInputURL.path,
                outputFileURL.path,
                ffmpegOutputURL.path,
                outputDir.path,
            ]
        )
        let subprocessRequest = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: finalArguments,
            timeout: .seconds(7 * 24 * 60 * 60),
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 512 * 1024,
            sensitiveValues: privatePaths
        )
        Self.logger.info("FFmpeg command: \(subprocessRequest.redactedCommandDescription, privacy: .public)")

        let totalDurationBox = DurationBox()
        let effectiveDurationBox = DurationBox()
        effectiveDurationBox.value = command.effectiveDuration
        if let expectedDuration = request.expectedDuration {
            totalDurationBox.value = expectedDuration
            if effectiveDurationBox.value == nil {
                effectiveDurationBox.value = expectedDuration
            }
        }
        let frameStallTracker = FrameStallTracker()
        let progressThrottler = ProgressThrottler()
        let frameRate = request.videoFrameRate ?? 24.0  // Default to 24fps if not provided

        // For DCP / IMF exports, scale FFmpeg progress to 0-75% to leave room for post-processing steps
        let ffmpegProgressUpdate: @Sendable (Double, String?) -> Void
        if isDCPExport || isIMFExport {
            ffmpegProgressUpdate = { progress, eta in
                progressUpdate(progress * 0.75, eta)
            }
        } else {
            ffmpegProgressUpdate = progressUpdate
        }

        let progressGate = ConversionProgressGate()
        currentProgressGate?.invalidate()
        currentProgressGate = progressGate
        let gatedProgressUpdate: @Sendable (Double, String?) -> Void = { progress, status in
            progressGate.run {
                ffmpegProgressUpdate(progress, status)
            }
        }
        let progressStreamParser = FFMPEGProgressStreamParser(
            totalDuration: totalDurationBox,
            effectiveDuration: effectiveDurationBox,
            frameRate: frameRate,
            frameStallTracker: frameStallTracker,
            progressThrottler: progressThrottler,
            progressUpdate: gatedProgressUpdate
        )

        // Capture values for the closure
        let capturedRequest = request
        let capturedTempAudioURL = tempAudioURL
        let capturedTempMXFURL = tempMXFURL
        let capturedFinalOutputURL = outputFileURL
        let capturedNeedsBMXRewrap = needsBMXRewrap
        let capturedInputBaseName = inputURL.deletingPathExtension().lastPathComponent
        let capturedIsImageSequenceExport = isImageSequenceExport
        let capturedIsDCPExport = isDCPExport
        let capturedDCPSubfolderURL = dcpSubfolderURL
        let capturedIsIMFJ2KExport = isIMFJ2KExport
        let capturedIsIMFProResExport = isIMFProResExport
        let capturedIsIMFExport = isIMFExport
        let capturedIMFSubfolderURL = imfSubfolderURL
        let capturedInputURL = inputURL
        let capturedFfmpegPath = ffmpegPath

        let handleFFmpegTermination: @Sendable (Int32, Data, String?) -> Void = { [weak self] exitStatus, stderrData, forcedErrorReason in
            Task { [weak self] in
                let wasActive = await self?.beginPostProcessing(
                    conversionID,
                    usesBMX: capturedNeedsBMXRewrap || capturedIsIMFProResExport
                ) ?? false
                var success = exitStatus == 0 && wasActive && forcedErrorReason == nil
                if capturedIsIMFExport || capturedIsDCPExport {
                    print("[IMF/DCP] termination handler entered, ffmpeg exit=\(exitStatus), success=\(success), isIMF=\(capturedIsIMFExport), isDCP=\(capturedIsDCPExport)")
                }
                if success {
                    Self.logger.info("FFmpeg process terminated with status: \(exitStatus) (success: \(success))")
                } else {
                    Self.logger.error("FFmpeg process terminated with status: \(exitStatus) (success: \(success))")
                }
                var errorReason = forcedErrorReason ?? (wasActive ? nil : "Conversion cancelled")
                if !success && errorReason == nil {
                    let stderrString = subprocessRequest.redactedDiagnostic(
                        String(decoding: stderrData, as: UTF8.self),
                        limit: 64 * 1024
                    )
                    Self.logger.error("FFmpeg exited with code \(exitStatus). Output:\n\(stderrString, privacy: .public)\n-- end of ffmpeg log --")
                    errorReason = Self.extractErrorReason(from: stderrString, exitCode: exitStatus)
                }

                // Validate output file exists and has content.
                // FFmpeg can exit 0 while producing empty/corrupt output (disk full, I/O error, etc.)
                // Skip validation for image sequence and DCP / IMF App 2e exports (they produce directories).
                // For IMF App 5 we still validate the temp MOV here; the rewrap-to-MXF step is the IMF arm below.
                if success && !capturedIsImageSequenceExport && !capturedIsDCPExport && !capturedIsIMFJ2KExport {
                    let fileToValidate = capturedNeedsBMXRewrap ? (capturedTempMXFURL ?? capturedFinalOutputURL) : capturedFinalOutputURL
                    if let validationError = Self.validateOutputFile(at: fileToValidate) {
                        Self.logger.error("Output validation failed: \(validationError, privacy: .public)")
                        errorReason = validationError
                        success = false
                    }
                }

                // Run bmxtranswrap for AVC-Intra to ensure OP1a compliance
                if success && capturedNeedsBMXRewrap, let tempMXF = capturedTempMXFURL {
                    Self.logger.info("Running bmxtranswrap to rewrap MXF to OP1a format")
                    progressUpdate(0.95, "Rewrapping to OP1a...")

                    let mcaLabelsFile = await Self.prepareAVCIntraMCALabelsFile(
                        inputURL: capturedInputURL,
                        audioRoutingConfig: capturedRequest.audioRoutingConfig
                    )
                    let bmxResult = await BMXService.shared.rewrapToOP1a(
                        inputURL: tempMXF,
                        outputURL: capturedFinalOutputURL,
                        clipName: capturedInputBaseName,
                        mcaLabelsFile: mcaLabelsFile,
                        operationID: conversionID,
                        progress: { bmxProgress in
                            // Map bmx progress to 95-100% range
                            let overallProgress = 0.95 + (bmxProgress * 0.05)
                            Task { @MainActor in
                                progressUpdate(overallProgress, "Rewrapping to OP1a...")
                            }
                        }
                    )
                    let lateCancellation = await BMXService.shared.finishCancellationTracking(
                        operationID: conversionID
                    )
                    await self?.clearActiveBMXOperation(if: conversionID)
                    if let mcaLabelsFile {
                        Self.cleanupTempFile(at: mcaLabelsFile, label: "MCA labels")
                    }

                    let stillOwnsPostProcessing = await self?.isPostProcessing(conversionID) ?? false
                    if bmxResult.cancelled || lateCancellation || !stillOwnsPostProcessing {
                        success = false
                        errorReason = "Conversion cancelled"
                    } else if bmxResult.success {
                        Self.logger.info("bmxtranswrap completed: \(capturedFinalOutputURL.lastPathComponent)")
                    } else {
                        Self.logger.error("bmxtranswrap failed, keeping FFmpeg output as fallback")
                        // Copy temp file to final location as fallback
                        do {
                            try FileManager.default.copyItem(at: tempMXF, to: capturedFinalOutputURL)
                            Self.logger.warning("Used FFmpeg MXF output as fallback (not OP1a compliant)")
                        } catch {
                            Self.logger.error("Failed to copy fallback MXF: \(error.localizedDescription)")
                            success = false
                        }
                    }

                    // Clean up temp MXF file
                    Self.cleanupTempFile(at: tempMXF, label: "BMX rewrap temp MXF")
                }

                // Clean up temp audio file if it exists
                if let tempURL = capturedTempAudioURL {
                    Self.cleanupTempFile(at: tempURL, label: "AVC-Intra pre-processed audio")
                }

                if success {
                    let stillOwnsPostProcessing = await self?.isPostProcessing(conversionID) ?? false
                    if !stillOwnsPostProcessing {
                        success = false
                        errorReason = "Conversion cancelled"
                    }
                }

                // DCP assembly: wrap JP2 frames + audio WAV into DCP-compliant MXF using asdcp-wrap
                if success && capturedIsDCPExport, let dcpFolder = capturedDCPSubfolderURL {
                    Self.logger.info("Starting DCP assembly...")

                    let resolutionRaw = UserDefaults.standard.string(forKey: AppConstants.dcpResolutionKey) ?? AppConstants.defaultDCPResolution
                    let resolution = DCPResolution(rawValue: resolutionRaw) ?? .twoKFull
                    let frameRateRaw = UserDefaults.standard.string(forKey: AppConstants.dcpFrameRateKey) ?? AppConstants.defaultDCPFrameRate
                    let frameRate = DCPFrameRate(rawValue: frameRateRaw) ?? .fps24

                    let fm = FileManager.default
                    let jp2Dir = capturedFinalOutputURL.deletingLastPathComponent()
                    var videoMXFURL: URL? = nil

                    if let asdcpWrapPath = BinaryPathResolver.asdcpWrapPath {
                        // Step 1: Convert JP2 frames to raw J2C codestreams and wrap with asdcp-wrap
                        progressUpdate(0.75, "Creating video MXF for DCP...")
                        let tmpVideoMXF = FileManager.default.temporaryDirectory
                            .appendingPathComponent("dcp_video_\(UUID().uuidString).mxf")

                        // Strip JP2 container headers to get raw J2C codestreams
                        // JP2 files have a header before the raw JPEG 2000 codestream (SOC marker: FF 4F)
                        let jp2Files = (try? fm.contentsOfDirectory(atPath: jp2Dir.path))?
                            .filter { $0.hasSuffix(".jp2") }
                            .sorted() ?? []

                        if jp2Files.isEmpty {
                            Self.logger.error("No JP2 frames found in \(jp2Dir.path)")
                            errorReason = String(localized: "DCP video wrap failed: no JP2 frames produced", comment: "Shown when the JPEG 2000 frame export step produced no usable frames for DCP wrapping.")
                            success = false
                        } else {
                            // Create J2C directory for stripped codestreams
                            let j2cDir = FileManager.default.temporaryDirectory
                                .appendingPathComponent("dcp_j2c_\(UUID().uuidString)", isDirectory: true)
                            do {
                                guard let self else { throw CancellationError() }
                                _ = try await self.prepareTrackedPackageCodestreams(
                                    conversionID: conversionID,
                                    sourceDirectory: jp2Dir,
                                    frameNames: jp2Files,
                                    destinationDirectory: j2cDir
                                )

                                // Run asdcp-wrap on J2C directory
                                let videoWrapArgs: [String] = [
                                    "-v",                                // Verbose output
                                    "-p", frameRate.ffmpegValue,
                                    "-L",                                // SMPTE Universal Labels
                                    j2cDir.path + "/",                   // Directory of J2C frames
                                    tmpVideoMXF.path
                                ]

                                Self.logger.info("Running asdcp-wrap for DCP video")
                                let wrapResult = await self.runTrackedPackageWrapper(
                                    conversionID: conversionID,
                                    executablePath: asdcpWrapPath,
                                    arguments: videoWrapArgs,
                                    outputURL: tmpVideoMXF
                                )
                                switch wrapResult {
                                case .success(let diagnostic):
                                    if !diagnostic.isEmpty {
                                        Self.logger.info("asdcp-wrap video output: \(diagnostic.prefix(500), privacy: .public)")
                                    }
                                    videoMXFURL = tmpVideoMXF
                                    Self.logger.info("Video MXF created with asdcp-wrap")
                                case .failed(let status, let reason, let diagnostic):
                                    let statusText = status.map(String.init) ?? "launch"
                                    Self.logger.error("asdcp-wrap failed for video MXF (\(statusText, privacy: .public)): \(diagnostic.prefix(300), privacy: .public)")
                                    errorReason = Self.dcpIMFErrorReason(
                                        base: String(localized: "DCP video wrap failed: \(reason)", comment: "Shown when asdcp-wrap cannot create the DCP video essence."),
                                        stderr: diagnostic
                                    )
                                    success = false
                                case .cancelled:
                                    errorReason = "Conversion cancelled"
                                    success = false
                                }

                            } catch is CancellationError {
                                errorReason = "Conversion cancelled"
                                success = false
                            } catch {
                                Self.logger.error("DCP frame preparation failed: \(error.localizedDescription, privacy: .public)")
                                let reason = error.localizedDescription
                                errorReason = String(localized: "DCP video wrap failed: \(reason)", comment: "Shown when asdcp-wrap cannot create the DCP video essence.")
                                success = false
                            }

                            // Clean up J2C frames
                            Self.cleanupTempFile(at: j2cDir, label: "DCP J2C frames")
                        }
                    } else {
                        Self.logger.error("asdcp-wrap not found — cannot create DCP-compliant MXF files")
                        errorReason = String(localized: "DCP video wrap failed: asdcp-wrap not found", comment: "Shown when the bundled asdcp-wrap binary cannot be located, blocking the DCP export.")
                        success = false
                    }

                    // Clean up JP2 images unless user wants to keep them
                    let keepJP2 = UserDefaults.standard.bool(forKey: AppConstants.dcpKeepJP2ImagesKey)
                    if !keepJP2 {
                        Self.cleanupTempFile(at: jp2Dir, label: "DCP JP2 images")
                    }

                    var finalAudioMXF: URL? = nil
                    defer {
                        if let videoMXFURL, fm.fileExists(atPath: videoMXFURL.path) {
                            Self.cleanupTempFile(at: videoMXFURL, label: "DCP video MXF")
                        }
                        if let finalAudioMXF, fm.fileExists(atPath: finalAudioMXF.path) {
                            Self.cleanupTempFile(at: finalAudioMXF, label: "DCP audio MXF")
                        }
                    }
                    if success {
                        // Step 2: Extract audio as WAV
                        progressUpdate(0.82, "Extracting audio for DCP...")
                        let audioExtractionResult = await self?.extractPackageAudioAsPCMWAV(
                            conversionID: conversionID,
                            inputURL: capturedInputURL,
                            customInputArguments: capturedRequest.customInputArguments,
                            outputFolder: FileManager.default.temporaryDirectory,
                            ffmpegPath: capturedFfmpegPath,
                            trimStart: capturedRequest.trimStart,
                            trimEnd: capturedRequest.trimEnd,
                            audioRoutingConfig: capturedRequest.audioRoutingConfig
                        ) ?? .failed(reason: "Conversion cancelled")
                        let audioWavURL: URL?
                        switch audioExtractionResult {
                        case .extracted(let url):
                            audioWavURL = url
                        case .noAudioInSource:
                            audioWavURL = nil
                        case .failed(let reason):
                            audioWavURL = nil
                            errorReason = String(localized: "DCP audio extraction failed: \(reason)", comment: "Shown when ffmpeg cannot extract PCM audio from a source that has audio streams, blocking the DCP audio MXF.")
                            success = false
                        }

                        defer {
                            if let audioWavURL {
                                Self.cleanupTempFile(at: audioWavURL, label: "DCP audio WAV")
                            }
                        }

                        // Step 3: Wrap audio WAV to DCP MXF with asdcp-wrap
                        if let wavURL = audioWavURL, let asdcpPath = BinaryPathResolver.asdcpWrapPath {
                            progressUpdate(0.87, "Creating audio MXF for DCP...")
                            let audioMXFURL = FileManager.default.temporaryDirectory
                                .appendingPathComponent("dcp_audio_\(UUID().uuidString).mxf")

                            let audioWrapArgs: [String] = [
                                "-p", frameRate.ffmpegValue,
                                "-L",                          // SMPTE Universal Labels
                                wavURL.path,
                                audioMXFURL.path
                            ]

                            Self.logger.info("Running asdcp-wrap for DCP audio")
                            let wrapResult = await self?.runTrackedPackageWrapper(
                                conversionID: conversionID,
                                executablePath: asdcpPath,
                                arguments: audioWrapArgs,
                                outputURL: audioMXFURL
                            ) ?? .cancelled
                            switch wrapResult {
                            case .success(let diagnostic):
                                if !diagnostic.isEmpty {
                                    Self.logger.info("asdcp-wrap audio output: \(diagnostic.prefix(500), privacy: .public)")
                                }
                                finalAudioMXF = audioMXFURL
                                Self.logger.info("Audio MXF created with asdcp-wrap")
                            case .failed(_, let reason, let diagnostic):
                                Self.logger.error("asdcp-wrap failed for DCP audio: \(diagnostic.prefix(300), privacy: .public)")
                                errorReason = Self.dcpIMFErrorReason(
                                    base: String(localized: "DCP audio wrap failed: \(reason)", comment: "Shown when asdcp-wrap cannot create the DCP audio essence."),
                                    stderr: diagnostic
                                )
                                success = false
                            case .cancelled:
                                errorReason = "Conversion cancelled"
                                success = false
                            }

                        }

                    }

                    // Step 4: Assemble DCP XML metadata (only if video MXF was created)
                    if success, let videoMXF = videoMXFURL {
                        progressUpdate(0.91, "Generating DCP metadata...")

                        let duration = effectiveDurationBox.value ?? totalDurationBox.value ?? 0
                        let frameCount = Int(ceil(duration * Double(frameRate.editRateNumerator) / Double(frameRate.editRateDenominator)))

                        let dcpTitle: String
                        if let metadataTitle = capturedRequest.dcpMetadata?.contentTitleText, !metadataTitle.isEmpty {
                            dcpTitle = metadataTitle
                        } else {
                            dcpTitle = capturedInputBaseName
                        }

                        // Create ISDCF-named DCP folder inside the working folder
                        let contentKind = capturedRequest.dcpMetadata?.contentKind ?? .feature
                        let audioLanguage = capturedRequest.dcpMetadata?.audioLanguage ?? "en"
                        let isdcfName = await DCPService.shared.isdcfFolderName(
                            title: dcpTitle,
                            contentKind: contentKind,
                            frameRate: frameRate,
                            resolution: resolution,
                            audioLanguage: audioLanguage
                        )
                        let dcpOutputDir = dcpFolder.appendingPathComponent(
                            isdcfName,
                            isDirectory: true
                        )
                        do {
                            try fm.createDirectory(at: dcpOutputDir, withIntermediateDirectories: true)
                        } catch {
                            Self.logger.error("Failed to create DCP output folder: \(error.localizedDescription, privacy: .public)")
                            errorReason = String(localized: "Could not create the DCP output folder", comment: "Shown when the app cannot create the final DCP package directory.")
                            success = false
                        }

                        if success {
                            Self.logger.info("DCP output folder: \(dcpOutputDir.lastPathComponent)")

                            let dcpSuccess = await DCPService.shared.assembleDCP(
                                videoMXFURL: videoMXF,
                                audioMXFURL: finalAudioMXF,
                                outputDirectoryURL: dcpOutputDir,
                                title: dcpTitle,
                                resolution: resolution,
                                frameRate: frameRate,
                                frameCount: max(frameCount, 1),
                                itemMetadata: capturedRequest.dcpMetadata,
                                progress: { dcpProgress in
                                    let overall = 0.91 + dcpProgress * 0.09
                                    Task { @MainActor in
                                        progressUpdate(overall, "Generating DCP metadata...")
                                    }
                                }
                            )

                            if !dcpSuccess {
                                Self.logger.error("DCP assembly failed")
                                errorReason = String(localized: "DCP assembly failed", comment: "Shown when DCPService cannot assemble the final DCP package (CPL/PKL/ASSETMAP). Detailed cause is in the app log.")
                                success = false
                            }
                        }

                    }
                }

                // IMF assembly: produce video MXF + audio MXF essences and emit CPL/PKL/ASSETMAP.
                if success && capturedIsIMFExport, let imfFolder = capturedIMFSubfolderURL {
                    Self.logger.info("Starting IMF assembly...")
                    print("[IMF] starting assembly, imfFolder=\(imfFolder.path)")

                    let resolutionRaw = UserDefaults.standard.string(forKey: AppConstants.imfResolutionKey) ?? AppConstants.defaultIMFResolution
                    let resolution = IMFResolution(rawValue: resolutionRaw) ?? .hd1080
                    let frameRateRaw = UserDefaults.standard.string(forKey: AppConstants.imfFrameRateKey) ?? AppConstants.defaultIMFFrameRate
                    let frameRate = IMFFrameRate(rawValue: frameRateRaw) ?? .fps24
                    let colorRaw = UserDefaults.standard.string(forKey: AppConstants.imfJ2KColorEncodingKey) ?? AppConstants.defaultIMFJ2KColorEncoding
                    let color = IMFColorEncoding(rawValue: colorRaw) ?? .rec709
                    let application: IMFApplication = capturedIsIMFJ2KExport ? .app2e : .app5

                    let fm = FileManager.default
                    var imfVideoMXF: URL? = nil
                    var exactPictureFrameCount: Int? = nil

                    // ----- Video essence wrap -----
                    if capturedIsIMFJ2KExport {
                        // J2K → raw2bmx with `-t imf` writes a full ST 2067-21 CDCIPictureEssenceDescriptor
                        // including ColorPrimaries/TransferCharacteristic/CodingEquations/ChromaSubsampling
                        // ULs. asdcp-wrap (a DCP tool) cannot, and the resulting sparse descriptor caused
                        // Resolve to read the YCbCr essence as RGBA — see the colour-magenta bug.
                        let jp2Dir = capturedFinalOutputURL.deletingLastPathComponent()
                        let resolvedRaw2bmxPath = BinaryPathResolver.raw2bmxPath
                        print("[IMF] App 2e branch — raw2bmx path: \(resolvedRaw2bmxPath ?? "<nil>"), jp2Dir=\(jp2Dir.path)")
                        if let raw2bmxPath = resolvedRaw2bmxPath {
                            progressUpdate(0.78, "Creating IMF video essence")
                            let tmpVideoMXF = FileManager.default.temporaryDirectory
                                .appendingPathComponent("imf_video_\(UUID().uuidString).mxf")

                            let jp2Files = (try? fm.contentsOfDirectory(atPath: jp2Dir.path))?
                                .filter { $0.hasSuffix(".jp2") }
                                .sorted() ?? []
                            exactPictureFrameCount = jp2Files.count
                            print("[IMF] discovered \(jp2Files.count) JP2 frames in \(jp2Dir.path)")

                            if jp2Files.isEmpty {
                                Self.logger.error("No JP2 frames found for IMF in \(jp2Dir.path)")
                                errorReason = String(localized: "IMF video wrap failed: no JP2 frames produced", comment: "Shown when the JPEG 2000 frame export step produced no usable frames for IMF App 2e wrapping.")
                                success = false
                            } else {
                                let j2cDir = FileManager.default.temporaryDirectory
                                    .appendingPathComponent("imf_j2c_\(UUID().uuidString)", isDirectory: true)
                                do {
                                    guard let self else { throw CancellationError() }
                                    let totalFrames = jp2Files.count
                                    let expectedMXFBytes = try await self.prepareTrackedPackageCodestreams(
                                        conversionID: conversionID,
                                        sourceDirectory: jp2Dir,
                                        frameNames: jp2Files,
                                        destinationDirectory: j2cDir
                                    ) { completed, total in
                                        let fraction = Double(completed) / Double(total)
                                        progressUpdate(0.78 + fraction * 0.02, "Preparing J2C frames \(completed)/\(total)")
                                    }
                                    print("[IMF] J2C extraction complete (\(totalFrames) frames, \(ByteCountFormatter.string(fromByteCount: expectedMXFBytes, countStyle: .file)))")

                                    // raw2bmx accepts the same frame-rate syntax as ffmpeg ("24" / "24000/1001").
                                    // --j2c_cdci tells raw2bmx the codestream is YCbCr (CDCI descriptor); the
                                    // alternative --j2c_rgba would reproduce the original RGBA-mislabelling bug.
                                    // The input is a printf-style %d pattern matched against the J2C frames
                                    // (extracted above from frame_%06d.jp2 → frame_%06d.j2c).
                                    // Per-input flags (--color-prim/--transfer-ch/--coding-eq) bind to the
                                    // following --j2c_cdci input, so they must appear before it.
                                    let bmxFlags = color.bmxFlags
                                    let j2cPattern = j2cDir.appendingPathComponent("frame_%d.j2c").path
                                    var videoWrapArgs: [String] = [
                                        "-t", "imf",
                                        "-o", tmpVideoMXF.path,
                                        "-f", frameRate.ffmpegValue,
                                        "--clip", capturedInputBaseName,
                                        "--color-prim", bmxFlags.colorPrimaries,
                                    ]
                                    if let transfer = bmxFlags.transferCharacteristic {
                                        videoWrapArgs.append(contentsOf: ["--transfer-ch", transfer])
                                    }
                                    videoWrapArgs.append(contentsOf: [
                                        "--coding-eq", bmxFlags.codingEquations,
                                        "--j2c_cdci", j2cPattern
                                    ])
                                    progressUpdate(0.80, "Wrapping J2C → MXF")
                                    Self.logger.info("Launching raw2bmx for IMF video")
                                    // Poll the output MXF size while the runner owns process execution.
                                    let pollerTask = Task.detached { [tmpVideoMXF, expectedMXFBytes] in
                                        let pollFM = FileManager.default
                                        while !Task.isCancelled {
                                            try? await Task.sleep(for: .seconds(1))
                                            guard !Task.isCancelled else { break }
                                            let attrs = try? pollFM.attributesOfItem(atPath: tmpVideoMXF.path)
                                            let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                                            let formatted = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                                            let fraction = expectedMXFBytes > 0
                                                ? min(0.99, Double(bytes) / Double(expectedMXFBytes))
                                                : 0
                                            progressUpdate(
                                                0.80 + fraction * 0.06,
                                                "Wrapping J2C → MXF (\(formatted), \(Int(fraction * 100))%)"
                                            )
                                        }
                                    }
                                    let wrapResult = await self.runTrackedPackageWrapper(
                                        conversionID: conversionID,
                                        executablePath: raw2bmxPath,
                                        arguments: videoWrapArgs,
                                        outputURL: tmpVideoMXF
                                    )
                                    pollerTask.cancel()
                                    await pollerTask.value
                                    switch wrapResult {
                                    case .success(let diagnostic):
                                        if !diagnostic.isEmpty {
                                            Self.logger.info("raw2bmx output: \(diagnostic.prefix(500), privacy: .public)")
                                        }
                                        imfVideoMXF = tmpVideoMXF
                                        Self.logger.info("IMF video essence created (App #2e)")
                                    case .failed(_, let reason, let diagnostic):
                                        Self.logger.error("raw2bmx failed for IMF video: \(diagnostic.prefix(300), privacy: .public)")
                                        errorReason = Self.dcpIMFErrorReason(
                                            base: String(localized: "IMF video wrap failed: \(reason)", comment: "Shown when raw2bmx cannot create the IMF App 2e video essence."),
                                            stderr: diagnostic
                                        )
                                        success = false
                                    case .cancelled:
                                        errorReason = "Conversion cancelled"
                                        success = false
                                    }
                                } catch is CancellationError {
                                    errorReason = "Conversion cancelled"
                                    success = false
                                } catch {
                                    Self.logger.error("IMF frame preparation failed: \(error.localizedDescription, privacy: .public)")
                                    let reason = error.localizedDescription
                                    errorReason = String(localized: "IMF video wrap failed: \(reason)", comment: "Shown when raw2bmx cannot create the IMF App 2e video essence.")
                                    success = false
                                }
                                Self.cleanupTempFile(at: j2cDir, label: "IMF J2C frames")
                            }
                        } else {
                            Self.logger.error("raw2bmx not found — cannot create IMF App 2e essence")
                            errorReason = String(localized: "IMF video wrap failed: raw2bmx not found", comment: "Shown when the bundled raw2bmx binary cannot be located, blocking the IMF App 2e export.")
                            success = false
                        }

                        // Clean up JP2 working folder
                        let keepIntermediates = UserDefaults.standard.bool(forKey: AppConstants.imfKeepIntermediatesKey)
                        if !keepIntermediates {
                            Self.cleanupTempFile(at: jp2Dir, label: "IMF JP2 images")
                        }
                    } else if capturedIsIMFProResExport {
                        // ProRes MOV → bmxtranswrap → OP1a MXF
                        progressUpdate(0.78, "Creating IMF video essence")
                        print("[IMF] App 5 branch — input MOV: \(capturedFinalOutputURL.lastPathComponent)")
                        let tmpVideoMXF = FileManager.default.temporaryDirectory
                            .appendingPathComponent("imf_video_\(UUID().uuidString).mxf")

                        let bmxFlags = color.bmxFlags

                        let bmxResult = await BMXService.shared.rewrapToIMFOP1a(
                            inputURL: capturedFinalOutputURL,
                            outputURL: tmpVideoMXF,
                            colorPrimaries: bmxFlags.colorPrimaries,
                            transferCharacteristic: bmxFlags.transferCharacteristic,
                            codingEquations: bmxFlags.codingEquations,
                            clipName: capturedInputBaseName,
                            mcaLabelsFile: nil,
                            operationID: conversionID,
                            progress: { bmxProgress in
                                // Map bmx 0..1 onto the 0.78 → 0.84 sub-band of overall progress.
                                let overall = 0.78 + bmxProgress * 0.06
                                let pct = Int(bmxProgress * 100)
                                progressUpdate(overall, "Wrapping ProRes → MXF \(pct)%")
                            }
                        )
                        let lateCancellation = await BMXService.shared.finishCancellationTracking(
                            operationID: conversionID
                        )
                        await self?.clearActiveBMXOperation(if: conversionID)
                        let stillOwnsPostProcessing = await self?.isPostProcessing(conversionID) ?? false
                        if bmxResult.cancelled || lateCancellation || !stillOwnsPostProcessing {
                            errorReason = "Conversion cancelled"
                            success = false
                        } else if bmxResult.success {
                            imfVideoMXF = tmpVideoMXF
                            Self.logger.info("IMF video essence created (App #5)")
                        } else {
                            Self.logger.error("bmxtranswrap failed for IMF ProRes video essence")
                            errorReason = Self.dcpIMFErrorReason(
                                base: String(localized: "IMF video wrap failed: bmxtranswrap rejected ProRes essence", comment: "Shown when bmxtranswrap cannot rewrap the ProRes MOV into IMF App 5 OP1a MXF."),
                                stderr: bmxResult.stderr
                            )
                            success = false
                        }
                        // Remove the temporary MOV; if user wants to keep, they can use the .prores preset directly.
                        let keepIntermediates = UserDefaults.standard.bool(forKey: AppConstants.imfKeepIntermediatesKey)
                        if !keepIntermediates {
                            Self.cleanupTempFile(at: capturedFinalOutputURL, label: "IMF ProRes temp MOV")
                        }
                    }

                    // ----- Audio essence wrap (shared between App #2e and App #5) -----
                    var imfAudioMXF: URL? = nil
                    if success {
                        progressUpdate(0.86, "Extracting audio for IMF")
                        print("[IMF] extracting audio")
                        let audioExtractionResult = await self?.extractPackageAudioAsPCMWAV(
                            conversionID: conversionID,
                            inputURL: capturedInputURL,
                            customInputArguments: capturedRequest.customInputArguments,
                            outputFolder: FileManager.default.temporaryDirectory,
                            ffmpegPath: capturedFfmpegPath,
                            trimStart: capturedRequest.trimStart,
                            trimEnd: capturedRequest.trimEnd,
                            audioRoutingConfig: capturedRequest.audioRoutingConfig
                        ) ?? .failed(reason: "Conversion cancelled")
                        let audioWavURL: URL?
                        switch audioExtractionResult {
                        case .extracted(let url):
                            audioWavURL = url
                        case .noAudioInSource:
                            audioWavURL = nil
                        case .failed(let reason):
                            audioWavURL = nil
                            errorReason = String(localized: "IMF audio extraction failed: \(reason)", comment: "Shown when ffmpeg cannot extract PCM audio from a source that has audio streams, blocking the IMF audio essence.")
                            success = false
                        }

                        if let originalWavURL = audioWavURL {
                            progressUpdate(0.90, "Wrapping audio essence")
                            print("[IMF] wrapping audio essence")
                            let tmpAudioMXF = FileManager.default.temporaryDirectory
                                .appendingPathComponent("imf_audio_\(UUID().uuidString).mxf")

                            // Pad the WAV to match the picture frame count so asdcp-wrap's
                            // edit-unit index matches the actual essence length. Without this,
                            // sources whose duration doesn't quantise cleanly to picture frames
                            // (e.g. 156.36 s → 3754 frames @ 24 fps but only ~3752.6 audio
                            // frames worth of samples) produce a truncated MXF that Resolve
                            // refuses to play even though mpv tolerates it.
                            let duration = effectiveDurationBox.value ?? totalDurationBox.value
                            let pictureFrameCount = Self.resolvedIMFPictureFrameCount(
                                exactFrameCount: exactPictureFrameCount,
                                duration: duration,
                                editRateNumerator: frameRate.editRateNumerator,
                                editRateDenominator: frameRate.editRateDenominator
                            )
                            let wavURL: URL
                            if pictureFrameCount > 0,
                               let padded = await self?.padWAVToFrameCount(
                                   conversionID: conversionID,
                                   inputWAV: originalWavURL,
                                   frameCount: pictureFrameCount,
                                   editRateNumerator: frameRate.editRateNumerator,
                                   editRateDenominator: frameRate.editRateDenominator,
                                   ffmpegPath: capturedFfmpegPath
                               ) {
                                wavURL = padded
                                Self.cleanupTempFile(at: originalWavURL, label: "IMF audio WAV (pre-pad)")
                            } else {
                                wavURL = originalWavURL
                                print("[IMF] WAV padding skipped (frameCount=\(pictureFrameCount))")
                            }

                            // Wrap PCM WAV → IMF audio MXF using asdcp-wrap. bmxtranswrap is
                            // MXF-only (it cannot ingest WAV), so the prior call always failed
                            // with "Failed to open MXF file '…wav'". asdcp-wrap supports raw
                            // PCM input and produces a SMPTE-labelled audio essence — same
                            // tool the DCP path uses for its audio MXF.
                            if let asdcpPath = BinaryPathResolver.asdcpWrapPath {
                                let audioWrapArgs: [String] = [
                                    "-p", frameRate.ffmpegValue,
                                    "-L",                          // SMPTE Universal Labels
                                    wavURL.path,
                                    tmpAudioMXF.path
                                ]
                                Self.logger.info("Launching asdcp-wrap for IMF audio")
                                let wrapResult = await self?.runTrackedPackageWrapper(
                                    conversionID: conversionID,
                                    executablePath: asdcpPath,
                                    arguments: audioWrapArgs,
                                    outputURL: tmpAudioMXF
                                ) ?? .cancelled
                                switch wrapResult {
                                case .success(let diagnostic):
                                    if !diagnostic.isEmpty {
                                        Self.logger.info("asdcp-wrap IMF audio output: \(diagnostic.prefix(500), privacy: .public)")
                                    }
                                    imfAudioMXF = tmpAudioMXF
                                    Self.logger.info("IMF audio essence created (asdcp-wrap)")
                                    progressUpdate(0.94, "Wrapping audio essence")
                                case .failed(_, let reason, let diagnostic):
                                    Self.logger.error("asdcp-wrap failed for IMF audio: \(diagnostic.prefix(300), privacy: .public)")
                                    errorReason = Self.dcpIMFErrorReason(
                                        base: String(localized: "IMF audio wrap failed: \(reason)", comment: "Shown when asdcp-wrap cannot create the IMF audio essence."),
                                        stderr: diagnostic
                                    )
                                    success = false
                                case .cancelled:
                                    errorReason = "Conversion cancelled"
                                    success = false
                                }
                            } else {
                                Self.logger.error("asdcp-wrap not found — cannot create IMF audio essence")
                                errorReason = String(localized: "IMF audio wrap failed: asdcp-wrap not found", comment: "Shown when the bundled asdcp-wrap binary cannot be located, blocking IMF audio essence creation.")
                                success = false
                            }
                            Self.cleanupTempFile(at: wavURL, label: "IMF audio WAV")
                        }
                    }

                    // ----- Manifest assembly -----
                    if success, let videoMXF = imfVideoMXF {
                        progressUpdate(0.94, "Generating IMF manifests")
                        print("[IMF] generating manifests")

                        let duration = effectiveDurationBox.value ?? totalDurationBox.value
                        let frameCount = Self.resolvedIMFPictureFrameCount(
                            exactFrameCount: exactPictureFrameCount,
                            duration: duration,
                            editRateNumerator: frameRate.editRateNumerator,
                            editRateDenominator: frameRate.editRateDenominator
                        )

                        let imfTitle: String
                        if let metaTitle = capturedRequest.imfMetadata?.contentTitleText, !metaTitle.isEmpty {
                            imfTitle = metaTitle
                        } else {
                            imfTitle = capturedInputBaseName
                        }
                        let audioLanguage = capturedRequest.imfMetadata?.audioLanguage ?? "en"

                        let folderName = await IMFManifestWriter.shared.packageFolderName(
                            title: imfTitle,
                            application: application,
                            resolution: resolution,
                            frameRate: frameRate,
                            audioLanguage: audioLanguage
                        )
                        let imfOutputDir = imfFolder.appendingPathComponent(folderName, isDirectory: true)
                        do {
                            try fm.createDirectory(at: imfOutputDir, withIntermediateDirectories: true)
                        } catch {
                            Self.logger.error("Failed to create IMF output folder: \(error.localizedDescription, privacy: .public)")
                            errorReason = String(localized: "Could not create the IMF output folder", comment: "Shown when the app cannot create the final IMF package directory.")
                            success = false
                        }

                        if success {
                            Self.logger.info("IMF output folder: \(imfOutputDir.lastPathComponent)")

                            let imfSuccess = await IMFManifestWriter.shared.assembleIMP(
                                videoMXFURL: videoMXF,
                                audioMXFURL: imfAudioMXF,
                                outputDirectoryURL: imfOutputDir,
                                title: imfTitle,
                                application: application,
                                editRateNumerator: frameRate.editRateNumerator,
                                editRateDenominator: frameRate.editRateDenominator,
                                frameCount: max(frameCount, 1),
                                itemMetadata: capturedRequest.imfMetadata,
                                progress: { imfProgress in
                                    let overall = 0.94 + imfProgress * 0.06
                                    let pct = Int(imfProgress * 100)
                                    Task { @MainActor in
                                        progressUpdate(overall, "Generating IMF manifests \(pct)%")
                                    }
                                }
                            )
                            if !imfSuccess {
                                Self.logger.error("IMF assembly failed")
                                errorReason = String(localized: "IMF manifest assembly failed", comment: "Shown when IMFManifestWriter cannot assemble the IMP package (CPL/PKL/ASSETMAP). Detailed cause is in the app log.")
                                success = false
                            }
                        }
                        // IMFManifestWriter moves the essences into the package folder; clean up
                        // the temp paths only if they still exist (they shouldn't on success).
                        if fm.fileExists(atPath: videoMXF.path) {
                            Self.cleanupTempFile(at: videoMXF, label: "IMF video MXF")
                        }
                        if let audioMXF = imfAudioMXF, fm.fileExists(atPath: audioMXF.path) {
                            Self.cleanupTempFile(at: audioMXF, label: "IMF audio MXF")
                        }
                    }
                    _ = resolution // resolution captured for potential per-essence labelling; quiet "unused" warnings
                }

                // Extract audio as WAV for image sequence exports (if source has audio)
                // Use the output pattern's base name so the WAV matches the image filenames
                if success && capturedIsImageSequenceExport && capturedRequest.customInputArguments == nil {
                    let outputFolder = capturedFinalOutputURL.deletingLastPathComponent()
                    let outputBaseName = outputFolder.lastPathComponent
                    let audioResult = await self?.extractImageSequenceAudioAsWAV(
                        conversionID: conversionID,
                        inputURL: capturedInputURL,
                        outputFolder: outputFolder,
                        baseName: outputBaseName,
                        ffmpegPath: capturedFfmpegPath,
                        trimStart: capturedRequest.trimStart,
                        trimEnd: capturedRequest.trimEnd
                    )

                    if case .cancelled? = audioResult {
                        success = false
                        errorReason = "Conversion cancelled"
                    }

                    if success {
                        let stillOwnsPostProcessing = await self?.generateImageSequenceMetadataSidecarIfOwned(
                            conversionID: conversionID,
                            originalFileName: capturedInputBaseName,
                            outputFolder: outputFolder,
                            metadata: capturedRequest.sourceMetadata,
                            cameraMetadata: capturedRequest.sourceCameraMetadata
                        ) ?? false
                        if !stillOwnsPostProcessing {
                            success = false
                            errorReason = "Conversion cancelled"
                        }
                    }
                }

                let stillOwned = await self?.finishPostProcessing(if: conversionID) ?? false
                if !stillOwned {
                    success = false
                    errorReason = "Conversion cancelled"
                }
                finish(success, errorReason)
            }
        }

        guard activeConversionID == conversionID else {
            progressGate.invalidate()
            finish(false, "Conversion cancelled")
            return
        }

        if let decoderRequest = av2DecodeRequest {
            let runner = subprocessRunner
            currentSubprocessTask = Task {
                do {
                    let pipelineResult = try await runner.runPipeline(
                        producer: decoderRequest,
                        consumer: subprocessRequest,
                        consumerOutputHandler: { chunk in
                            guard case .standardError = chunk.stream else { return }
                            progressStreamParser.consume(chunk.data)
                        }
                    )
                    progressStreamParser.finish()

                    let ffmpegResult = pipelineResult.consumer
                    var forcedErrorReason: String?
                    switch pipelineResult.producer {
                    case .completed(let decoderResult):
                        if !decoderResult.succeeded {
                            let diagnostic = decoderRequest.redactedDiagnostic(
                                decoderResult.standardErrorText,
                                limit: 64 * 1024
                            )
                            forcedErrorReason = Self.av2DecoderErrorReason(
                                diagnostic: diagnostic,
                                exitCode: decoderResult.terminationStatus
                            )
                        }
                    case .failed(.cancelled):
                        forcedErrorReason = "Conversion cancelled"
                    case .failed(.timedOut):
                        forcedErrorReason = "AV2 decoding timed out after 7 days"
                    case .failed(.failedToStart(let reason)):
                        forcedErrorReason = "Failed to start AV2 decoder (avmdec): \(reason)"
                    case .failed(.connectionClosed(let reason)):
                        if ffmpegResult.succeeded {
                            forcedErrorReason = "AV2 decode pipeline closed before all frames were delivered: \(reason)"
                        }
                    case .failed(.failed(let reason)):
                        forcedErrorReason = "AV2 decoding failed: \(reason)"
                    case .unfinished:
                        if ffmpegResult.succeeded {
                            forcedErrorReason = "AV2 decoder did not finish"
                        }
                    }
                    handleFFmpegTermination(
                        ffmpegResult.terminationStatus,
                        ffmpegResult.standardError,
                        forcedErrorReason
                    )
                } catch is CancellationError {
                    progressStreamParser.finish()
                    handleFFmpegTermination(-SIGTERM, Data(), "Conversion cancelled")
                } catch SubprocessRunnerError.timedOut(_, let result) {
                    progressStreamParser.finish()
                    handleFFmpegTermination(
                        result.terminationStatus,
                        result.standardError,
                        "FFmpeg conversion timed out after 7 days"
                    )
                } catch {
                    progressStreamParser.finish()
                    let message = subprocessRequest.redactedDiagnostic(error.localizedDescription)
                    Self.logger.error("Failed to run AV2 decode pipeline: \(message, privacy: .public)")
                    handleFFmpegTermination(-1, Data(), "Failed to start FFmpeg: \(message)")
                }
            }
            return
        }

        let runner = subprocessRunner
        currentSubprocessTask = Task {
            do {
                let result = try await runner.run(subprocessRequest) { chunk in
                    guard case .standardError = chunk.stream else { return }
                    progressStreamParser.consume(chunk.data)
                }
                progressStreamParser.finish()
                handleFFmpegTermination(result.terminationStatus, result.standardError, nil)
            } catch is CancellationError {
                progressStreamParser.finish()
                handleFFmpegTermination(-SIGTERM, Data(), "Conversion cancelled")
            } catch SubprocessRunnerError.timedOut(_, let result) {
                progressStreamParser.finish()
                handleFFmpegTermination(
                    result.terminationStatus,
                    result.standardError,
                    "FFmpeg conversion timed out after 7 days"
                )
            } catch {
                progressStreamParser.finish()
                let message = subprocessRequest.redactedDiagnostic(error.localizedDescription)
                Self.logger.error("Failed to run FFmpeg: \(message, privacy: .public)")
                handleFFmpegTermination(-1, Data(), "Failed to start FFmpeg: \(message)")
            }
        }
    }

    // MARK: - Extract Error Reason

    /// Composes a user-facing reason for a DCP/IMF wrap-step failure. Appends a short,
    /// trimmed slice of the tool's stderr after the base message when present, so the
    /// queue capsule tooltip carries the diagnostic context without dumping the full log.
    private static func dcpIMFErrorReason(base: String, stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return base }
        // Use the last non-empty line — wrap tools tend to print the actionable cause last.
        let lastLine = trimmed.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? trimmed
        return truncateForDisplay("\(base): \(lastLine)")
    }

    /// Extracts a concise reason from avmdec stderr. The decoder's actionable message is
    /// generally its last non-empty line, but some launch failures have no captured output.
    private static func av2DecoderErrorReason(diagnostic: String, exitCode: Int32) -> String {
        let lastLine = diagnostic.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
        if let lastLine {
            return truncateForDisplay("AV2 decoder failed: \(lastLine)")
        }
        return "AV2 decoder failed (exit \(exitCode))"
    }

    /// Extracts a concise reason from avmenc stderr. The encoder's actionable message
    /// (e.g. "Fatal: …", "Error: …") is typically the last meaningful line it prints.
    private static func extractAvmencErrorReason(from stderr: String, exitCode: Int32) -> String {
        let lines = stderr.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let explicit = lines.last(where: {
            let lower = $0.lowercased()
            return lower.hasPrefix("fatal") || lower.contains("error") || lower.contains("unsupported")
        }) {
            return truncateForDisplay("AV2 encoder: \(explicit)")
        }
        if let last = lines.last {
            return truncateForDisplay("AV2 encoder failed: \(last)")
        }
        return "AV2 encoder failed (exit \(exitCode))"
    }

    /// Extracts a concise, user-facing error reason from FFmpeg stderr output.
    private static func extractErrorReason(from stderr: String, exitCode: Int32) -> String {
        let lines = stderr.components(separatedBy: .newlines).reversed()
        // FFmpeg typically outputs the most relevant error on the last non-empty lines.
        // Look for lines containing common error patterns.
        // Track the last FFmpeg internal error (e.g. "[libx264 @ 0x...] message") as a
        // fallback — these often carry the root cause when no high-level message matches.
        var lastInternalError: String? = nil

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Match common FFmpeg error patterns
            if trimmed.contains("No such file or directory") ||
               trimmed.contains("Permission denied") ||
               trimmed.contains("No space left on device") ||
               trimmed.contains("Invalid data found") ||
               (trimmed.contains("Decoder") && trimmed.contains("not found")) ||
               (trimmed.contains("Encoder") && trimmed.contains("not found")) ||
               trimmed.contains("Unknown encoder") ||
               trimmed.contains("Unknown decoder") ||
               (trimmed.contains("Codec") && trimmed.contains("not")) ||
               trimmed.contains("does not support") ||
               trimmed.contains("Invalid argument") ||
               (trimmed.contains("Error") && !trimmed.hasPrefix("frame=")) ||
               trimmed.contains("Cannot") ||
               trimmed.contains("Could not") ||
               trimmed.contains("Impossible") ||
               trimmed.contains("not found") ||
               trimmed.contains("Unrecognized option") ||
               trimmed.contains("already exists. Overwrite") ||
               (trimmed.contains("Discarded") && trimmed.contains("exceeded")) ||
               trimmed.contains("Conversion failed") ||
               trimmed.contains("Failed to") ||
               trimmed.contains("Unable to") ||
               trimmed.contains("Unsupported") ||
               trimmed.contains("Too many packets buffered") ||
               trimmed.contains("Output file is empty") {
                return truncateForDisplay(cleanUpErrorMessage(trimmed))
            }

            // Track FFmpeg internal error messages as fallback (e.g. "[libx264 @ 0x12345] ...")
            if lastInternalError == nil && trimmed.hasPrefix("[") && trimmed.contains(" @ 0x") {
                lastInternalError = trimmed
            }
        }

        // Use the last FFmpeg internal error if no high-level pattern matched
        if let internal_ = lastInternalError {
            return truncateForDisplay(cleanUpErrorMessage(internal_))
        }

        return "Encoding failed (exit code \(exitCode))"
    }

    /// Strips FFmpeg internal prefixes like "[libx264 @ 0x12345abcdef]" to produce
    /// cleaner user-facing error messages while keeping the component name.
    private static func cleanUpErrorMessage(_ message: String) -> String {
        // Pattern: [component @ 0xHEXADDR] rest of message
        // Extract "component: rest of message"
        guard message.hasPrefix("["),
              let closeBracket = message.firstIndex(of: "]") else {
            return message
        }
        let bracketContent = message[message.index(after: message.startIndex)..<closeBracket]
        let remainder = message[message.index(after: closeBracket)...].trimmingCharacters(in: .whitespaces)

        // Strip the " @ 0x..." part, keeping just the component name
        if let atRange = bracketContent.range(of: " @ 0x") {
            let component = bracketContent[bracketContent.startIndex..<atRange.lowerBound]
            if remainder.isEmpty {
                return "[\(component)] (no details)"
            }
            return "[\(component)] \(remainder)"
        }

        // No memory address — return as-is
        return message
    }

    /// Truncates a string for UI display, capping at 150 characters.
    private static func truncateForDisplay(_ text: String, maxLength: Int = 150) -> String {
        if text.count > maxLength {
            return String(text.prefix(maxLength)) + "…"
        }
        return text
    }

    // MARK: - AV2 Conversion

    /// Runs the experimental AV2 export as a two-process pipe: ffmpeg decodes/trims/scales
    /// the source to y4m on stdout, which is piped into avmenc's stdin; avmenc writes the
    /// final video-only `.ivf`. avmenc's `POC:` records drive frame progress when the total
    /// is known, with ffmpeg's stderr feeding the standard time-based fallback parser.
    private func runAV2Conversion(
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
            try await runner.runPipeline(
                producer: ffmpegRequest,
                consumer: avmencRequest,
                producerOutputHandler: { chunk in
                    guard totalFrames == 0, case .standardError = chunk.stream else { return }
                    ffmpegProgressParser.consume(chunk.data)
                },
                consumerOutputHandler: { chunk in
                    guard case .standardOutput = chunk.stream else { return }
                    avmencProgressParser.consume(chunk.data)
                }
            )
        }
        currentAV2PipelineTasks[pipelineID] = pipelineTask

        let pipelineResult: SubprocessPipelineResult
        do {
            pipelineResult = try await pipelineTask.value
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

    // MARK: - Chunked (parallel) AV2 Conversion

    /// Result of an AV2 encode (single-process or chunked). `keyframeIndices` are global frame
    /// indices known to be key frames — used by the `.mkv` muxer to place Cue points.
    struct AV2EncodeResult: Sendable {
        let success: Bool
        let errorReason: String?
        let keyframeIndices: [Int]
    }

    private struct AV2SegmentOutcome: Sendable {
        let index: Int
        let success: Bool
        let errorReason: String?
    }

    /// Runs a parallel chunked AV2 encode: one ffmpeg│avmenc pipe per chunk, all concurrent, with
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
        guard !Task.isCancelled else {
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

        guard !Task.isCancelled else {
            return AV2EncodeResult(success: false, errorReason: "Conversion cancelled", keyframeIndices: [])
        }
        let totalFrames = plan.totalFrames
        let chunkCount = plan.segments.count
        Self.logger.info("AV2 chunked encode: \(chunkCount) workers, \(totalFrames) frames → \(outputFileURL.lastPathComponent, privacy: .public)")

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

        var outcomes: [AV2SegmentOutcome] = []
        var firstFailure: AV2SegmentOutcome?
        await withTaskGroup(of: AV2SegmentOutcome.self) { group in
            for seg in plan.segments {
                group.addTask {
                    await self.encodeAV2Segment(seg, ffmpegPath: ffmpegPath, avmencPath: avmencPath, onFrames: onFrames)
                }
            }
            for await outcome in group {
                outcomes.append(outcome)
                // Preserve the root failure and cancel the remaining coordinated pipelines so we
                // don't burn cores on a doomed encode. Later sibling-cancellation outcomes must not
                // replace the actionable error from the worker that failed first.
                if !outcome.success, firstFailure == nil {
                    firstFailure = outcome
                    group.cancelAll()
                    self.cancelAV2PipelineTasks()
                }
            }
        }

        // All workers have exited (the task group is the 2N-of-2N termination barrier).
        if let failed = firstFailure ?? outcomes.first(where: { !$0.success }) {
            Self.logger.error("AV2 chunked failed at chunk \(failed.index): \(failed.errorReason ?? "unknown", privacy: .public)")
            return AV2EncodeResult(success: false, errorReason: failed.errorReason ?? "AV2 chunked encode failed", keyframeIndices: [])
        }

        // Join the chunk bitstreams in order.
        let ordered = plan.segments.sorted { $0.index < $1.index }.map { $0.outputURL }
        do {
            let result = try IVFConcatenator.concatenate(segmentURLs: ordered, into: outputFileURL)
            if let validationError = Self.validateOutputFile(at: outputFileURL) {
                Self.cleanupTempFile(at: outputFileURL, label: "invalid AV2 .ivf")
                return AV2EncodeResult(success: false, errorReason: validationError, keyframeIndices: [])
            }
            progressUpdate(1.0, nil)
            Self.logger.info("AV2 chunked encode complete: \(result.totalFrames) frames → \(outputFileURL.lastPathComponent, privacy: .public)")
            return AV2EncodeResult(success: true, errorReason: nil, keyframeIndices: result.keyframeIndices)
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
            try await runner.runPipeline(
                producer: ffmpegRequest,
                consumer: avmencRequest,
                consumerOutputHandler: { chunk in
                    guard case .standardOutput = chunk.stream else { return }
                    progressParser.consume(chunk.data)
                }
            )
        }
        currentAV2PipelineTasks[pipelineID] = pipelineTask

        let pipelineResult: SubprocessPipelineResult
        do {
            pipelineResult = try await pipelineTask.value
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

    private func cancelAV2PipelineTasks() {
        for task in currentAV2PipelineTasks.values {
            task.cancel()
        }
    }

    private static func fileHasContent(at url: URL) -> Bool {
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

    // MARK: - AV2 → Matroska (.mkv) muxing

    /// Wraps an already-encoded AV2 `.ivf` plus the source audio into a `.mkv` using the in-app
    /// ``MatroskaMuxer`` (FFmpeg cannot write AV2). The AV2 `CodecPrivate` is harvested from a tiny
    /// `avmenc --webm` probe; routed audio is re-encoded to AAC or Opus and packetised in-app.
    /// A source with no selected audio yields a valid video-only `.mkv`; failures while processing
    /// selected audio fail the conversion so routing choices are never silently discarded.
    private func muxAV2ToMatroska(
        conversionID: UUID,
        videoIvfURL: URL,
        sourceURL: URL,
        customInputArguments: [String]?,
        isMuted: Bool,
        audioRoutingConfig: AudioRoutingConfig?,
        comment: String,
        includeDateTag: Bool,
        timecodeConfig: TimecodeConfig?,
        sourceMetadata knownSourceMetadata: VideoMetadata?,
        trimStart: Double?,
        trimEnd: Double?,
        bitDepth: Int,
        keyframeIndices: [Int],
        outputURL: URL,
        ffmpegPath: String,
        avmencPath: String,
        settings: AV2Settings,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void
    ) async -> (Bool, String?) {
        guard activeConversionID == conversionID else {
            return (false, "Conversion cancelled")
        }
        guard let ivfHeader = IVFHeaderParser.parse(url: videoIvfURL), ivfHeader.isAV2 else {
            return (false, "AV2 muxing: the encoded bitstream is not a valid AV2 IVF")
        }
        let width = ivfHeader.width
        let height = ivfHeader.height
        let fpsNum = ivfHeader.fpsNumerator > 0 ? ivfHeader.fpsNumerator : 24
        let fpsDen = ivfHeader.fpsDenominator > 0 ? ivfHeader.fpsDenominator : 1

        progressUpdate(0.99, "Muxing AV2 + audio…")

        // 1. Harvest the authoritative V_AV2 CodecPrivate (level/bit-depth depend on the config).
        let codecPrivate = await harvestAV2CodecPrivate(
            width: width, height: height, bitDepth: bitDepth,
            fpsNum: fpsNum, fpsDen: fpsDen, ffmpegPath: ffmpegPath, avmencPath: avmencPath
        )
        if codecPrivate == nil {
            Self.logger.warning("AV2 muxing: failed to harvest CodecPrivate; writing track without it")
        }
        guard activeConversionID == conversionID else {
            return (false, "Conversion cancelled")
        }

        // 2. Read the video frames, flagging known key frames (chunk boundaries) for seeking.
        let keyset = Set(keyframeIndices)
        var videoFrames: [MatroskaMuxer.VideoFrame] = []
        do {
            var idx = 0
            try IVFConcatenator.forEachFrame(in: videoIvfURL) { payload, _ in
                videoFrames.append(MatroskaMuxer.VideoFrame(data: payload, isKeyframe: idx == 0 || keyset.contains(idx)))
                idx += 1
            }
        } catch {
            return (false, "AV2 muxing: \(error.localizedDescription)")
        }
        guard !videoFrames.isEmpty else { return (false, "AV2 muxing: no video frames in bitstream") }

        // 3. Extract + parse routed audio. A video-only .mkv is fine only when audio is absent,
        // muted, or explicitly removed by the routing configuration.
        var audioTracks: [MatroskaMuxer.AudioTrack] = []
        if let audioInput = Self.av2MuxAudioInput(
            inputURL: sourceURL,
            customInputArguments: customInputArguments,
            isMuted: isMuted
        ) {
            switch await extractAudioTracksForAV2Mux(
                conversionID: conversionID,
                source: audioInput,
                audioRoutingConfig: audioRoutingConfig,
                trimStart: trimStart,
                trimEnd: trimEnd,
                ffmpegPath: ffmpegPath,
                settings: settings
            ) {
            case .noAudio:
                break
            case .tracks(let extractedTracks):
                audioTracks = extractedTracks
            case .failed(let reason):
                return (false, "AV2 audio routing failed: \(reason)")
            case .cancelled:
                return (false, "Conversion cancelled")
            }
        }
        guard activeConversionID == conversionID else {
            return (false, "Conversion cancelled")
        }

        // 4. Resolve global/container metadata. Raw IVF cannot carry these tags;
        // the Matroska path keeps the same comment/date and timecode policy as
        // ordinary FFmpeg-backed exports.
        let sourceMetadata: VideoMetadata?
        if case .preserveSource? = timecodeConfig?.mode, knownSourceMetadata == nil {
            sourceMetadata = try? await BoundedVideoMetadataProbe.metadata(for: sourceURL)
        } else {
            sourceMetadata = knownSourceMetadata
        }
        guard activeConversionID == conversionID else {
            return (false, "Conversion cancelled")
        }
        let timecode = timecodeConfig.flatMap {
            FFMPEGCommandBuilder.resolvedTimecode(
                timecodeConfig: $0,
                sourceMetadata: sourceMetadata,
                trimStart: trimStart
            )
        }
        let metadata = MatroskaMuxer.Metadata(
            comment: FFMPEGCommandBuilder.commentMetadataValue(
                comment: comment,
                includeDateTag: includeDateTag
            ),
            timecode: timecode
        )

        // 5. Write the Matroska file.
        let video = MatroskaMuxer.VideoTrackInfo(
            codecID: "V_AV2", codecPrivate: codecPrivate,
            width: width, height: height, fpsNumerator: fpsNum, fpsDenominator: fpsDen
        )
        do {
            try MatroskaMuxer.write(
                to: outputURL,
                video: video,
                videoFrames: videoFrames,
                audioTracks: audioTracks,
                metadata: metadata
            )
        } catch {
            return (false, "AV2 muxing failed: \(error.localizedDescription)")
        }
        if let validationError = Self.validateOutputFile(at: outputURL) {
            return (false, validationError)
        }
        let audioFrameCount = audioTracks.reduce(0) { $0 + $1.frames.count }
        Self.logger.info("AV2 mux complete: \(videoFrames.count) video + \(audioFrameCount) audio frames across \(audioTracks.count) tracks → \(outputURL.lastPathComponent, privacy: .public)")
        return (true, nil)
    }

    /// Encodes a single black frame at the exact geometry/depth/fps to learn the authoritative
    /// AV2 `CodecPrivate` from `avmenc --webm` (the field is config-dependent, not content-dependent).
    private func harvestAV2CodecPrivate(
        width: Int, height: Int, bitDepth: Int, fpsNum: Int, fpsDen: Int,
        ffmpegPath: String, avmencPath: String
    ) async -> Data? {
        let dir = FileManager.default.temporaryDirectory
        let y4m = dir.appendingPathComponent("av2probe_\(UUID().uuidString).y4m")
        let webm = dir.appendingPathComponent("av2probe_\(UUID().uuidString).webm")
        defer {
            Self.cleanupTempFile(at: y4m, label: "AV2 probe y4m")
            Self.cleanupTempFile(at: webm, label: "AV2 probe webm")
        }
        let pix = bitDepth >= 10 ? "yuv420p10le" : "yuv420p"
        let ff = ["-y", "-nostdin", "-hide_banner", "-f", "lavfi",
                  "-i", "color=c=black:s=\(width)x\(height):r=\(fpsNum)/\(fpsDen)",
                  "-frames:v", "1", "-pix_fmt", pix, "-f", "yuv4mpegpipe", "-strict", "-1", y4m.path]
        guard case .success = await runTrackedAV2Helper(
            ffmpegPath,
            ff,
            timeout: Self.av2ProbeHelperTimeout
        ), Self.fileHasContent(at: y4m) else { return nil }
        let av = ["--webm", "-w", "\(width)", "-h", "\(height)", "-b", "\(bitDepth)",
                  "--input-bit-depth=\(bitDepth)", "--i420", "--fps=\(fpsNum)/\(fpsDen)",
                  "--end-usage=q", "--qp=110", "--cpu-used=9", "--limit=1", "-o", webm.path, y4m.path]
        guard case .success = await runTrackedAV2Helper(
            avmencPath,
            av,
            timeout: Self.av2ProbeHelperTimeout
        ), Self.fileHasContent(at: webm) else { return nil }
        return Self.extractMatroskaCodecPrivate(fromWebM: webm)
    }

    /// Re-encodes the routed source audio to the configured codec (AAC or Opus), preserving the
    /// selected order and duplicate tracks. FFmpeg first writes an audio-only Matroska file so a
    /// single filter graph can produce every requested stream; each stream is then copied to an
    /// elementary file for the existing AAC/Opus packet parsers.
    static func av2MuxAudioInput(
        inputURL: URL,
        customInputArguments: [String]?,
        isMuted: Bool
    ) -> PackageAudioInput? {
        guard !isMuted else { return nil }
        let source = packageAudioInput(inputURL: inputURL, customInputArguments: customInputArguments)
        return source.arguments.isEmpty ? nil : source
    }

    private static func av2HelperSensitiveValues(for source: PackageAudioInput) -> Set<String> {
        var values = Set(source.arguments.filter { $0.hasPrefix("/") })
        if let probeURL = source.probeURL {
            values.insert(probeURL.path)
        }

        guard source.arguments.contains("concat") else { return values }
        for index in source.arguments.indices where source.arguments[index] == "-i" {
            guard source.arguments.indices.contains(index + 1) else { continue }
            let listPath = source.arguments[index + 1]
            guard let contents = try? String(contentsOfFile: listPath, encoding: .utf8) else {
                continue
            }
            for line in contents.split(whereSeparator: \.isNewline) {
                guard line.hasPrefix("file '"), line.hasSuffix("'") else { continue }
                let encodedPath = line.dropFirst(6).dropLast()
                let path = encodedPath.replacingOccurrences(of: "'\\''", with: "'")
                if path.hasPrefix("/") {
                    values.insert(path)
                }
            }
        }
        return values
    }

    enum AV2MuxAudioExtractionResult: Sendable {
        case noAudio
        case tracks([MatroskaMuxer.AudioTrack])
        case failed(String)
        case cancelled
    }

    func extractAudioTracksForAV2Mux(
        conversionID: UUID? = nil,
        source: PackageAudioInput,
        audioRoutingConfig: AudioRoutingConfig?,
        trimStart: Double?,
        trimEnd: Double?,
        ffmpegPath: String,
        settings: AV2Settings = AV2Settings(),
        audioStreamProvider: @escaping @Sendable (URL) async -> [FFMPEGProbeService.AudioStreamInfo]? = {
            await FFMPEGProbeService.fetchAudioStreams(for: $0)
        }
    ) async -> AV2MuxAudioExtractionResult {
        func operationIsCurrent() -> Bool {
            guard !Task.isCancelled else { return false }
            guard let conversionID else { return true }
            return activeConversionID == conversionID
        }

        guard operationIsCurrent() else { return .cancelled }
        let codec = settings.audioCodec
        let bitrate = settings.audioBitrate.ffmpegValue
        let defaultAudioStreamIndices: [Int]
        if audioRoutingConfig != nil {
            defaultAudioStreamIndices = []
        } else if let probeURL = source.probeURL {
            guard let streams = await audioStreamProvider(probeURL) else {
                guard operationIsCurrent() else { return .cancelled }
                return .failed("Could not inspect the source audio streams")
            }
            guard operationIsCurrent() else { return .cancelled }
            if streams.isEmpty && source.assumesSingleAudioStreamIfProbeUnavailable {
                defaultAudioStreamIndices = [0]
            } else {
                defaultAudioStreamIndices = streams.enumerated().compactMap { offset, stream in
                    stream.isDecodable ? offset : nil
                }
            }
        } else {
            defaultAudioStreamIndices = []
        }
        let routingArguments = Self.av2MuxAudioRoutingArguments(
            inputIndex: source.ffmpegInputIndex,
            audioRoutingConfig: audioRoutingConfig,
            defaultAudioStreamIndices: defaultAudioStreamIndices
        )
        let plannedTrackCount = routingArguments.indices.reduce(into: 0) { count, index in
            if routingArguments[index] == "-map", routingArguments.indices.contains(index + 1) {
                count += 1
            }
        }
        guard plannedTrackCount > 0 else { return .noAudio }
        guard operationIsCurrent() else { return .cancelled }

        let sourceSensitiveValues = Self.av2HelperSensitiveValues(for: source)

        let routedAudioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("av2audio_routed_\(UUID().uuidString).mkv")
        defer { Self.cleanupTempFile(at: routedAudioURL, label: "AV2 routed audio") }

        var args = ["-y", "-nostdin", "-hide_banner"]
        if let trimStart, trimStart > 0 { args += ["-ss", String(format: "%.6f", trimStart)] }
        args += source.arguments
        if let trimStart, let trimEnd, trimEnd > trimStart {
            args += ["-t", String(format: "%.6f", trimEnd - trimStart)]
        } else if let trimEnd, trimEnd > 0, trimStart == nil {
            args += ["-t", String(format: "%.6f", trimEnd)]
        }
        args += ["-vn"]
        args += routingArguments
        args += ["-c:a", codec.ffmpegEncoder, "-b:a", bitrate, "-f", "matroska", routedAudioURL.path]
        switch await runTrackedAV2Helper(
            ffmpegPath,
            args,
            timeout: Self.av2AudioHelperTimeout,
            additionalSensitiveValues: sourceSensitiveValues
        ) {
        case .success:
            guard Self.fileHasContent(at: routedAudioURL) else {
                return .failed("FFmpeg did not produce the routed audio output")
            }
        case .failed(let reason):
            return .failed("FFmpeg could not encode the selected audio tracks: \(reason)")
        case .cancelled:
            return .cancelled
        }
        guard operationIsCurrent() else { return .cancelled }
        guard let routedStreams = await audioStreamProvider(routedAudioURL),
              !routedStreams.isEmpty else {
            guard operationIsCurrent() else { return .cancelled }
            return .failed("Could not inspect the routed audio output")
        }
        guard operationIsCurrent() else { return .cancelled }
        guard routedStreams.count == plannedTrackCount else {
            return .failed("Expected \(plannedTrackCount) routed audio tracks, but FFmpeg produced \(routedStreams.count)")
        }

        var tracks: [MatroskaMuxer.AudioTrack] = []
        for trackIndex in routedStreams.indices {
            guard operationIsCurrent() else { return .cancelled }
            let elementaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("av2audio_\(UUID().uuidString).\(codec.intermediateExtension)")
            defer { Self.cleanupTempFile(at: elementaryURL, label: "AV2 mux audio track") }
            var extractionArguments = [
                "-y", "-nostdin", "-hide_banner", "-i", routedAudioURL.path,
                "-map", "0:a:\(trackIndex)", "-vn", "-c:a", "copy"
            ]
            extractionArguments += codec == .opus ? ["-f", "ogg"] : ["-f", "adts"]
            extractionArguments += [elementaryURL.path]
            let extractionResult = await runTrackedAV2Helper(
                ffmpegPath,
                extractionArguments,
                timeout: Self.av2AudioHelperTimeout,
                additionalSensitiveValues: sourceSensitiveValues
            )
            if case .cancelled = extractionResult {
                return .cancelled
            }
            guard case .success = extractionResult,
                  Self.fileHasContent(at: elementaryURL),
                  let track = Self.parseAV2MuxAudioTrack(elementaryURL, codec: codec) else {
                if case .failed(let reason) = extractionResult {
                    return .failed("Could not packetize routed audio track \(trackIndex + 1): \(reason)")
                }
                return .failed("Could not packetize routed audio track \(trackIndex + 1)")
            }
            tracks.append(track)
        }
        return .tracks(tracks)
    }

    static func av2MuxAudioRoutingArguments(
        inputIndex: Int,
        audioRoutingConfig: AudioRoutingConfig?,
        defaultAudioStreamIndices: [Int]
    ) -> [String] {
        guard let audioRoutingConfig else {
            return defaultAudioStreamIndices.flatMap { ["-map", "\(inputIndex):a:\($0)"] }
        }

        let arguments = AudioRoutingService.buildFFmpegMapArguments(config: audioRoutingConfig)
        let inputPlaceholder = "{av2-audio-input}"
        return arguments.map { argument in
            argument
                .replacingOccurrences(of: "[0:a:", with: "[\(inputPlaceholder):a:")
                .replacingOccurrences(of: "0:a:", with: "\(inputIndex):a:")
                .replacingOccurrences(of: inputPlaceholder, with: String(inputIndex))
        }
    }

    private static func parseAV2MuxAudioTrack(
        _ url: URL,
        codec: AV2AudioCodec
    ) -> MatroskaMuxer.AudioTrack? {
        switch codec {
        case .aac:
            guard let parsed = parseADTS(url) else { return nil }
            let info = MatroskaMuxer.AudioTrackInfo(codecID: "A_AAC", codecPrivate: parsed.asc, sampleRate: parsed.sampleRate, channels: parsed.channels)
            return MatroskaMuxer.AudioTrack(
                info: info,
                frames: parsed.frames.map { MatroskaMuxer.AudioFrame(data: $0, durationSamples: 1024) }
            )
        case .opus:
            guard let parsed = parseOggOpus(url) else { return nil }
            // Opus always runs on a 48 kHz timestamp clock in Matroska. CodecDelay carries the
            // encoder pre-skip; SeekPreRoll is the standard 80 ms.
            let codecDelayNs = Int64((Double(parsed.preSkip) * 1_000_000_000.0 / 48000.0).rounded())
            let info = MatroskaMuxer.AudioTrackInfo(
                codecID: "A_OPUS", codecPrivate: parsed.codecPrivate, sampleRate: 48000, channels: parsed.channels,
                codecDelayNs: codecDelayNs, seekPreRollNs: 80_000_000
            )
            return MatroskaMuxer.AudioTrack(info: info, frames: parsed.frames)
        }
    }

    /// Parses an Ogg-Opus stream into Opus packets (with per-packet sample durations from each TOC
    /// byte), plus the `OpusHead` CodecPrivate, pre-skip and channel count from the identification
    /// header. Reassembles packets across Ogg segment/page boundaries.
    private static func parseOggOpus(_ url: URL) -> (frames: [MatroskaMuxer.AudioFrame], codecPrivate: Data, preSkip: Int, channels: Int)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)
        var packets: [[UInt8]] = []
        var partial: [UInt8] = []
        var off = 0
        while off + 27 <= bytes.count {
            guard bytes[off] == 0x4F, bytes[off + 1] == 0x67, bytes[off + 2] == 0x67, bytes[off + 3] == 0x53 else { break } // "OggS"
            let nsegs = Int(bytes[off + 26])
            let segStart = off + 27
            guard segStart + nsegs <= bytes.count else { break }
            let segTable = Array(bytes[segStart..<(segStart + nsegs)])
            var bi = segStart + nsegs
            let bodyLen = segTable.reduce(0) { $0 + Int($1) }
            guard bi + bodyLen <= bytes.count else { break }
            for lace in segTable {
                let len = Int(lace)
                partial.append(contentsOf: bytes[bi..<(bi + len)])
                bi += len
                if lace < 255 { packets.append(partial); partial = [] } // packet boundary
            }
            off = bi
        }
        // packet 0 = OpusHead, packet 1 = OpusTags, packets 2… = audio
        guard packets.count >= 3, packets[0].starts(with: Array("OpusHead".utf8)) else { return nil }
        let head = packets[0]
        let channels = head.count > 9 ? Int(head[9]) : 2
        let preSkip = head.count > 11 ? Int(head[10]) | (Int(head[11]) << 8) : 0
        let frames = packets[2...].map { MatroskaMuxer.AudioFrame(data: Data($0), durationSamples: opusPacketSamples($0)) }
        guard !frames.isEmpty else { return nil }
        return (frames, Data(head), preSkip, channels)
    }

    /// Number of 48 kHz samples a single Opus packet decodes to, from its TOC byte (and, for
    /// code 3, the following frame-count byte).
    private static func opusPacketSamples(_ packet: [UInt8]) -> Int {
        guard let toc = packet.first else { return 960 }
        // Frame size (samples @ 48 kHz) indexed by the 5-bit config (TOC >> 3).
        let frameSizes = [
            480, 960, 1920, 2880,   // 0–3   SILK NB  10/20/40/60 ms
            480, 960, 1920, 2880,   // 4–7   SILK MB
            480, 960, 1920, 2880,   // 8–11  SILK WB
            480, 960,               // 12–13 Hybrid SWB 10/20 ms
            480, 960,               // 14–15 Hybrid FB  10/20 ms
            120, 240, 480, 960,     // 16–19 CELT NB  2.5/5/10/20 ms
            120, 240, 480, 960,     // 20–23 CELT WB
            120, 240, 480, 960,     // 24–27 CELT SWB
            120, 240, 480, 960,     // 28–31 CELT FB
        ]
        let config = Int(toc >> 3)
        let frameSize = config < frameSizes.count ? frameSizes[config] : 960
        let code = Int(toc & 0x03)
        var frameCount = 1
        switch code {
        case 0: frameCount = 1
        case 1, 2: frameCount = 2
        case 3: frameCount = packet.count > 1 ? Int(packet[1] & 0x3F) : 1
        default: frameCount = 1
        }
        return frameSize * max(1, frameCount)
    }

    /// Runs a one-shot AV2 helper through the shared subprocess boundary. The actor-owned task
    /// keeps row cancellation and conversion supersession connected to the runner even though
    /// the outer conversion task itself is not cancelled by `ConversionManager`.
    private func runTrackedAV2Helper(
        _ path: String,
        _ arguments: [String],
        timeout: Duration,
        additionalSensitiveValues: Set<String> = []
    ) async -> AV2HelperRunResult {
        let taskID = UUID()
        let runner = subprocessRunner
        let task = Task {
            await Self.runAV2Helper(
                executablePath: path,
                arguments: arguments,
                timeout: timeout,
                additionalSensitiveValues: additionalSensitiveValues,
                subprocessRunner: runner
            )
        }
        currentAV2HelperTask?.cancel()
        currentAV2HelperTask = task
        currentAV2HelperTaskID = taskID

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        let resolvedResult: AV2HelperRunResult = if task.isCancelled || Task.isCancelled {
            .cancelled
        } else {
            result
        }
        if currentAV2HelperTaskID == taskID {
            currentAV2HelperTask = nil
            currentAV2HelperTaskID = nil
        }
        return resolvedResult
    }

    static func runAV2Helper(
        executablePath: String,
        arguments: [String],
        timeout: Duration,
        additionalSensitiveValues: Set<String> = [],
        subprocessRunner: any SubprocessRunning = SubprocessRunner()
    ) async -> AV2HelperRunResult {
        let privateValues = Set(
            arguments.filter { $0.hasPrefix("/") } + [executablePath]
        ).union(additionalSensitiveValues)
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            timeout: timeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: av2HelperDiagnosticCaptureLimit,
            sensitiveValues: privateValues
        )

        func failureReason(_ base: String, diagnostic: String = "") -> String {
            let safeDiagnostic = request.redactedDiagnostic(diagnostic)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return safeDiagnostic.isEmpty ? base : "\(base): \(safeDiagnostic)"
        }

        do {
            let result = try await subprocessRunner.run(request)
            guard result.succeeded else {
                return .failed(reason: failureReason(
                    "tool exited with status \(result.terminationStatus)",
                    diagnostic: result.standardErrorText
                ))
            }
            return .success
        } catch is CancellationError {
            return .cancelled
        } catch SubprocessRunnerError.timedOut(_, let result) {
            return .failed(reason: failureReason(
                "tool timed out",
                diagnostic: result.standardErrorText
            ))
        } catch {
            return .failed(reason: failureReason(
                "failed to start tool",
                diagnostic: error.localizedDescription
            ))
        }
    }

    /// Scans an avmenc-written WebM for the `V_AV2` track's `CodecPrivate` (`0x63A2`) payload.
    private static func extractMatroskaCodecPrivate(fromWebM url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let needle = Data("V_AV2".utf8)
        guard let r = data.range(of: needle) else { return nil }
        // Find the CodecPrivate element id (0x63 0xA2) shortly after the CodecID value.
        var i = r.upperBound
        let limit = min(data.count - 1, i + 16)
        var found = -1
        while i < limit {
            if data[i] == 0x63 && data[i + 1] == 0xA2 { found = i; break }
            i += 1
        }
        guard found >= 0 else { return nil }
        let sizeIdx = found + 2
        guard sizeIdx < data.count else { return nil }
        // Decode the size VINT (CodecPrivate is tiny, but parse it properly).
        let first = data[sizeIdx]
        var marker: UInt8 = 0x80
        var len = 1
        while marker != 0 && (first & marker) == 0 { marker >>= 1; len += 1 }
        guard marker != 0, sizeIdx + len <= data.count else { return nil }
        var value = UInt64(first & (marker &- 1))
        for k in 1..<len { value = (value << 8) | UInt64(data[sizeIdx + k]) }
        let payloadStart = sizeIdx + len
        guard value > 0, value < 256, payloadStart + Int(value) <= data.count else { return nil }
        return data.subdata(in: payloadStart..<(payloadStart + Int(value)))
    }

    /// Parses an ADTS AAC stream into raw AAC access units plus the derived AudioSpecificConfig,
    /// sample rate and channel count (read from the first frame's header).
    static func adtsChannelCount(forConfiguration configuration: UInt8) -> Int? {
        switch configuration {
        case 1...6: Int(configuration)
        case 7: 8
        default: nil
        }
    }

    private static func parseADTS(_ url: URL) -> (frames: [Data], asc: Data, sampleRate: Double, channels: Int)? {
        guard let data = try? Data(contentsOf: url), data.count > 7 else { return nil }
        let bytes = [UInt8](data)
        let rateTable: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        var frames: [Data] = []
        var asc: Data? = nil
        var sampleRate: Double = 48000
        var channels = 2
        var i = 0
        while i + 7 <= bytes.count {
            guard bytes[i] == 0xFF, (bytes[i + 1] & 0xF0) == 0xF0 else { break } // syncword
            let protectionAbsent = bytes[i + 1] & 0x01
            let headerLen = protectionAbsent == 1 ? 7 : 9
            let profile = (bytes[i + 2] >> 6) & 0x03
            let freqIdx = (bytes[i + 2] >> 2) & 0x0F
            let chanCfg = ((bytes[i + 2] & 0x01) << 2) | ((bytes[i + 3] >> 6) & 0x03)
            let frameLen = (Int(bytes[i + 3] & 0x03) << 11) | (Int(bytes[i + 4]) << 3) | (Int(bytes[i + 5] >> 5) & 0x07)
            guard frameLen >= headerLen, i + frameLen <= bytes.count else { break }
            if asc == nil {
                guard let parsedChannels = adtsChannelCount(forConfiguration: chanCfg) else {
                    // Configuration zero requires parsing the AAC Program Config Element. Reject it
                    // until that is supported rather than silently describing multichannel audio as stereo.
                    return nil
                }
                let aot = UInt8(profile + 1) // ADTS profile = audioObjectType − 1
                let b0 = (aot << 3) | (freqIdx >> 1)
                let b1 = ((freqIdx & 0x01) << 7) | (chanCfg << 3)
                asc = Data([b0, b1])
                if Int(freqIdx) < rateTable.count { sampleRate = rateTable[Int(freqIdx)] }
                channels = parsedChannels
            }
            let payloadStart = i + headerLen
            frames.append(data.subdata(in: payloadStart..<(i + frameLen)))
            i += frameLen
        }
        guard let asc, !frames.isEmpty else { return nil }
        return (frames, asc, sampleRate, channels)
    }

    /// Returns true if a Matroska/WebM file carries an AV2 video track (CodecID `V_AV2`). Scans the
    /// file head, where the Tracks element lives, so it's cheap and won't false-positive on normal
    /// `.mkv` files. Used to route AV2-in-Matroska sources through the avmdec decode front-end.
    static func matroskaContainsAV2(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_000_000) else { return false }
        return data.range(of: Data("V_AV2".utf8)) != nil
    }

    /// Rewrites `-map 0:a…` / `-map 0:s…` to input 1 (leaving `-map 0:v…` on input 0). Used when an
    /// AV2 Matroska source is decoded via avmdec on input 0 (video) with the original file added as
    /// input 1 (audio/subtitles).
    private static func redirectAudioSubtitleMapsToSecondInput(_ args: [String]) -> [String] {
        var out = args
        var i = 0
        while i + 1 < out.count {
            if out[i] == "-map" {
                let value = out[i + 1]
                if value.hasPrefix("0:a") || value.hasPrefix("0:s") {
                    out[i + 1] = "1:" + value.dropFirst(2)
                }
            }
            i += 1
        }
        return out
    }

    private func runNativeWaveformConversion(
        conversionID: UUID,
        inputURL: URL,
        ffmpegOutputURL: URL,
        ffmpegPath: String,
        preset: ExportPreset,
        waveformRequest: WaveformVideoRequest,
        audioRoutingConfig: AudioRoutingConfig?,
        trimStart: Double?,
        trimEnd: Double?,
        comment: String,
        includeDateTag: Bool,
        isMuted: Bool,
        additionalOutputArguments: [String]?,
        expectedDuration: Double?,
        videoFrameRate: Double?,
        needsBMXRewrap: Bool,
        tempMXFURL: URL?,
        outputFileURL: URL,
        waveformBackgroundImageURL: URL? = nil,
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

        // Phase 2: Build FFmpeg encoding command with rawvideo pipe input
        let command = await FFMPEGCommandBuilder.nativeWaveformEncodingCommand(
            audioInputURL: inputURL,
            outputFileURL: ffmpegOutputURL,
            preset: preset,
            width: waveformRequest.width,
            height: waveformRequest.height,
            frameRate: waveformRequest.frameRate,
            audioRoutingConfig: audioRoutingConfig,
            trimStart: trimStart,
            trimEnd: trimEnd,
            isMuted: isMuted,
            comment: comment,
            includeDateTag: includeDateTag,
            additionalOutputArguments: additionalOutputArguments
        )
        guard activeConversionID == conversionID else {
            await complete(false, "Conversion cancelled")
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

        currentSubprocessTask?.cancel()
        currentSubprocessTask = Task { [weak self] in
            defer {
                Self.cleanupWaveformTemporaryMXFIfPresent(capturedTempMXFURL)
            }
            let result: SubprocessResult
            do {
                result = try await runner.runWithStreamingStandardInput(
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
                            progressUpdate: { renderProgress in
                                let overall = 0.10 + renderProgress * 0.85
                                gatedProgressUpdate(overall, "Rendering waveform…")
                            }
                        )
                    },
                    outputHandler: nil
                )
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

                let mcaLabelsFile = await Self.prepareAVCIntraMCALabelsFile(
                    inputURL: capturedInputURL,
                    audioRoutingConfig: capturedAudioRoutingConfig
                )
                if await self?.activateBMXOperationIfActiveConversion(conversionID) == true {
                    let bmxResult = await BMXService.shared.rewrapToOP1a(
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
                    let lateCancellation = await BMXService.shared.finishCancellationTracking(
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

            Self.cleanupWaveformTemporaryMXFIfPresent(capturedTempMXFURL)
            await complete(success, errorReason)
        }
    }

    // MARK: - Audio Extraction for Image Sequence Export

    /// Extracts the audio track from a video file as a WAV file alongside the image sequence output.
    /// Only runs if the input has audio streams. The WAV file is placed in the same subfolder as the images.
    private func extractImageSequenceAudioAsWAV(
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
    private func generateImageSequenceMetadataSidecarIfOwned(
        conversionID: UUID,
        originalFileName: String,
        outputFolder: URL,
        metadata: VideoMetadata?,
        cameraMetadata: CameraMetadata?
    ) -> Bool {
        guard postProcessingConversionID == conversionID else { return false }

        let sidecarEnabled = UserDefaults.standard.object(
            forKey: AppConstants.imageSequenceMetadataSidecarEnabledKey
        ) != nil
            ? UserDefaults.standard.bool(forKey: AppConstants.imageSequenceMetadataSidecarEnabledKey)
            : AppConstants.defaultImageSequenceMetadataSidecarEnabled

        if sidecarEnabled, let metadata {
            let formatRaw = UserDefaults.standard.string(
                forKey: AppConstants.imageSequenceMetadataSidecarFormatKey
            ) ?? AppConstants.defaultImageSequenceMetadataSidecarFormat
            let format = MetadataSidecarGenerator.SidecarFormat(rawValue: formatRaw) ?? .markdown
            MetadataSidecarGenerator.generateSidecar(
                originalFileName: originalFileName,
                outputFolder: outputFolder,
                metadata: metadata,
                cameraMetadata: cameraMetadata,
                format: format
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
        case extracted(URL)
        case noAudioInSource
        case failed(reason: String)
    }

    enum ImageSequenceAudioExtractionResult: Sendable {
        case extracted(URL)
        case noAudioInSource
        case failed(reason: String)
        case cancelled
    }

    private enum ImageSequenceAudioStagingResult: Sendable {
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
        guard let customInputArguments else {
            return PackageAudioInput(
                arguments: ["-i", inputURL.path],
                probeURL: inputURL,
                ffmpegInputIndex: 0,
                assumesSingleAudioStreamIfProbeUnavailable: packageAudioOnlyExtensions.contains(
                    inputURL.pathExtension.lowercased()
                )
            )
        }

        let inputPaths = customInputArguments.indices.compactMap { index -> String? in
            guard customInputArguments[index] == "-i",
                  customInputArguments.indices.contains(index + 1) else {
                return nil
            }
            return customInputArguments[index + 1]
        }

        if customInputArguments.contains("-framerate") {
            // Image sequences carry audio as their second input. The frames are unnecessary for
            // PCM extraction, so open the associated audio directly and keep map indices simple.
            guard inputPaths.count >= 2 else {
                return PackageAudioInput(
                    arguments: [],
                    probeURL: nil,
                    ffmpegInputIndex: 0,
                    assumesSingleAudioStreamIfProbeUnavailable: false
                )
            }
            let audioURL = URL(fileURLWithPath: inputPaths[1])
            return PackageAudioInput(
                arguments: ["-i", audioURL.path],
                probeURL: audioURL,
                ffmpegInputIndex: 0,
                assumesSingleAudioStreamIfProbeUnavailable: true
            )
        }

        if customInputArguments.contains("concat") {
            // The concat demuxer exposes the merged stream as input 0. Probe the representative
            // first clip for its stream layout, but extract from the full concat list.
            return PackageAudioInput(
                arguments: customInputArguments,
                probeURL: inputURL,
                ffmpegInputIndex: 0,
                assumesSingleAudioStreamIfProbeUnavailable: packageAudioOnlyExtensions.contains(
                    inputURL.pathExtension.lowercased()
                )
            )
        }

        // Preserve future custom input forms. `inputURL` remains the best available source for
        // stream-layout probing; the custom arguments still control what FFmpeg actually reads.
        return PackageAudioInput(
            arguments: customInputArguments,
            probeURL: inputURL,
            ffmpegInputIndex: 0,
            assumesSingleAudioStreamIfProbeUnavailable: false
        )
    }

    private func extractPackageAudioAsPCMWAV(
        conversionID: UUID,
        inputURL: URL,
        customInputArguments: [String]?,
        outputFolder: URL,
        ffmpegPath: String,
        trimStart: Double?,
        trimEnd: Double?,
        audioRoutingConfig: AudioRoutingConfig?
    ) async -> AudioExtractionResult {
        guard postProcessingConversionID == conversionID else {
            return .failed(reason: "Conversion cancelled")
        }

        let taskID = UUID()
        let runner = subprocessRunner
        let task = Task {
            await Self.extractAudioAsPCMWAV(
                inputURL: inputURL,
                customInputArguments: customInputArguments,
                outputFolder: outputFolder,
                ffmpegPath: ffmpegPath,
                trimStart: trimStart,
                trimEnd: trimEnd,
                audioRoutingConfig: audioRoutingConfig,
                subprocessRunner: runner
            )
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
            if case .extracted(let outputURL) = result,
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
        subprocessRunner: any SubprocessRunning = SubprocessRunner()
    ) async -> AudioExtractionResult {
        let audioInput = packageAudioInput(
            inputURL: inputURL,
            customInputArguments: customInputArguments
        )

        // A sequence without companion audio has no probe URL and is a legitimate silent input.
        guard let probeURL = audioInput.probeURL else {
            logger.debug("No audio streams in resolved source, skipping package audio extraction")
            return .noAudioInSource
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
            return .noAudioInSource
        }

        let audioWavURL = outputFolder.appendingPathComponent("audio_temp_\(UUID().uuidString).wav")

        var args: [String] = ["-y", "-nostdin"]

        // Apply trim start (input seeking)
        let normalizedStart = FFMPEGCommandBuilder.normalizedTrimPoint(trimStart)
        if let start = normalizedStart {
            args.append(contentsOf: ["-ss", FFMPEGCommandBuilder.ffmpegTimeString(from: start)])
        }

        args.append(contentsOf: audioInput.arguments)

        // Apply trim duration
        if let durationArgs = FFMPEGCommandBuilder.trimDurationArgument(start: normalizedStart, end: FFMPEGCommandBuilder.normalizedTrimPoint(trimEnd)) {
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
            return .noAudioInSource
        }

        // For multiple selected streams that are all mono, amerge them.
        // Otherwise, map a single stream.
        let selectedAllMono = selectedStreamIndices.allSatisfy { idx in
            let channels = audioStreams.indices.contains(idx) ? (audioStreams[idx].channels ?? 0) : 0
            return channels == 1
        }
        if selectedStreamIndices.count > 1 && selectedAllMono {
            var filterInputs = ""
            for idx in selectedStreamIndices {
                filterInputs += "[\(audioInput.ffmpegInputIndex):a:\(idx)]"
            }
            args.append(contentsOf: [
                "-filter_complex", "\(filterInputs)amerge=inputs=\(selectedStreamIndices.count)[aout]",
                "-map", "[aout]",
            ])
        } else {
            // Map a single audio stream
            args.append(contentsOf: ["-map", "\(audioInput.ffmpegInputIndex):a:\(selectedStreamIndices[0])"])
        }

        args.append(contentsOf: [
            "-c:a", "pcm_s24le",     // 24-bit PCM
            "-ar", "48000",          // 48 kHz (DCI standard)
            audioWavURL.path
        ])

        logger.info("Extracting audio as WAV for DCP: \(audioWavURL.lastPathComponent) (streams: \(selectedStreamIndices))")

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
            return .extracted(audioWavURL)
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

    func cancelConversion() async {
        let bmxOperationID = activeBMXOperationID
        activeConversionID = nil
        postProcessingConversionID = nil
        activeBMXOperationID = nil
        currentDependencyPreflightTask?.cancel()
        currentDependencyPreflightTask = nil
        currentProgressGate?.invalidate()
        currentProgressGate = nil
        currentSubprocessTask?.cancel()
        currentSubprocessTask = nil
        currentWaveformAnalysisTask?.cancel()
        currentWaveformAnalysisTask = nil
        currentWaveformAnalysisID = nil
        currentImageSequenceAudioTask?.cancel()
        currentImageSequenceAudioTask = nil
        currentImageSequenceAudioTaskID = nil
        currentPackageAudioTask?.cancel()
        currentPackageAudioTask = nil
        currentPackageAudioTaskID = nil
        currentPackagePreparationTask?.cancel()
        currentPackagePreparationTask = nil
        currentPackagePreparationTaskID = nil
        currentPackageWrapperTask?.cancel()
        currentPackageWrapperTask = nil
        currentPackageWrapperTaskID = nil
        currentAVCIntraPreprocessingTask?.cancel()
        currentAVCIntraPreprocessingTask = nil
        currentAVCIntraPreprocessingTaskID = nil
        currentAV2HelperTask?.cancel()
        currentAV2HelperTask = nil
        currentAV2HelperTaskID = nil
        for task in currentAV2PipelineTasks.values { task.cancel() }
        currentAV2PipelineTasks.removeAll()
        if let bmxOperationID {
            await BMXService.shared.cancel(operationID: bmxOperationID)
            _ = await BMXService.shared.finishCancellationTracking(operationID: bmxOperationID)
        }
    }

    @discardableResult
    private func finishTrackedConversion(_ conversionID: UUID) async -> Bool {
        guard activeConversionID == conversionID else { return false }
        activeConversionID = nil
        currentProgressGate?.invalidate()
        currentProgressGate = nil
        currentSubprocessTask = nil
        currentWaveformAnalysisTask = nil
        currentWaveformAnalysisID = nil
        currentAVCIntraPreprocessingTask = nil
        currentAVCIntraPreprocessingTaskID = nil
        currentAV2HelperTask = nil
        currentAV2HelperTaskID = nil
        currentAV2PipelineTasks.removeAll()
        return true
    }

    @discardableResult
    private func beginPostProcessing(_ conversionID: UUID, usesBMX: Bool) async -> Bool {
        guard activeConversionID == conversionID else { return false }
        if usesBMX {
            await BMXService.shared.prepareCancellationTracking(operationID: conversionID)
            guard activeConversionID == conversionID else {
                _ = await BMXService.shared.finishCancellationTracking(operationID: conversionID)
                return false
            }
        }
        activeConversionID = nil
        postProcessingConversionID = conversionID
        activeBMXOperationID = usesBMX ? conversionID : nil
        currentProgressGate?.invalidate()
        currentProgressGate = nil
        currentSubprocessTask = nil
        currentWaveformAnalysisTask = nil
        currentWaveformAnalysisID = nil
        currentAVCIntraPreprocessingTask = nil
        currentAVCIntraPreprocessingTaskID = nil
        currentAV2HelperTask = nil
        currentAV2HelperTaskID = nil
        currentAV2PipelineTasks.removeAll()
        return true
    }

    private func finishPostProcessing(if conversionID: UUID) async -> Bool {
        guard postProcessingConversionID == conversionID else { return false }
        postProcessingConversionID = nil
        if activeBMXOperationID == conversionID {
            activeBMXOperationID = nil
            _ = await BMXService.shared.finishCancellationTracking(operationID: conversionID)
        }
        return true
    }

    private func activateBMXOperationIfActiveConversion(_ conversionID: UUID) async -> Bool {
        guard activeConversionID == conversionID else { return false }
        await BMXService.shared.prepareCancellationTracking(operationID: conversionID)
        guard activeConversionID == conversionID else {
            _ = await BMXService.shared.finishCancellationTracking(operationID: conversionID)
            return false
        }
        activeBMXOperationID = conversionID
        return true
    }

    private func clearActiveBMXOperation(if conversionID: UUID) {
        if activeBMXOperationID == conversionID {
            activeBMXOperationID = nil
        }
    }

    private func isPostProcessing(_ conversionID: UUID) -> Bool {
        postProcessingConversionID == conversionID
    }

    private func clearWaveformAnalysis(if analysisID: UUID) {
        guard currentWaveformAnalysisID == analysisID else { return }
        currentWaveformAnalysisTask = nil
        currentWaveformAnalysisID = nil
    }

    private func isActiveConversion(_ conversionID: UUID) -> Bool {
        activeConversionID == conversionID
    }

    private final class DurationBox: Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: Optional<Double>.none)

        var value: Double? {
            get { lock.withLock { $0 } }
            set { lock.withLock { $0 = newValue } }
        }
    }

    /// Counts avmenc's `POC:` progress markers across arbitrary stdout chunk boundaries without
    /// retaining the rest of its verbose per-frame output.
    private final class AV2POCStreamParser: @unchecked Sendable {
        private let lock = NSLock()
        private let onFrames: @Sendable (Int) -> Void
        private var pending = ""

        init(onFrames: @escaping @Sendable (Int) -> Void) {
            self.onFrames = onFrames
        }

        func consume(_ data: Data) {
            guard !data.isEmpty else { return }
            let frameCount = lock.withLock { () -> Int in
                pending += String(decoding: data, as: UTF8.self)
                var count = 0
                while let range = pending.range(of: "POC:") {
                    count += 1
                    pending.removeSubrange(pending.startIndex..<range.upperBound)
                }
                if pending.count > 3 {
                    pending = String(pending.suffix(3))
                }
                return count
            }
            if frameCount > 0 {
                onFrames(frameCount)
            }
        }
    }

    /// Reassembles FFmpeg's CR/LF-delimited status records so arbitrary pipe chunk
    /// boundaries cannot split a duration, timestamp, or frame token.
    private final class FFMPEGProgressStreamParser: @unchecked Sendable {
        private let lock = NSLock()
        private let totalDuration: DurationBox
        private let effectiveDuration: DurationBox
        private let frameRate: Double
        private let frameStallTracker: FrameStallTracker
        private let progressThrottler: ProgressThrottler
        private let progressUpdate: @Sendable (Double, String?) -> Void
        private var pendingText = ""

        init(
            totalDuration: DurationBox,
            effectiveDuration: DurationBox,
            frameRate: Double,
            frameStallTracker: FrameStallTracker,
            progressThrottler: ProgressThrottler,
            progressUpdate: @escaping @Sendable (Double, String?) -> Void
        ) {
            self.totalDuration = totalDuration
            self.effectiveDuration = effectiveDuration
            self.frameRate = frameRate
            self.frameStallTracker = frameStallTracker
            self.progressThrottler = progressThrottler
            self.progressUpdate = progressUpdate
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
                if pendingText.count > 64 * 1024 {
                    pendingText = String(pendingText.suffix(64 * 1024))
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

        private func parse(_ output: String) {
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let (newTotalDuration, _) = FFMPEGProgressParser.handleOutput(
                output,
                totalDuration: totalDuration.value,
                effectiveDuration: effectiveDuration.value,
                frameRate: frameRate,
                frameStallTracker: frameStallTracker,
                progressThrottler: progressThrottler,
                progressUpdate: progressUpdate
            )
            if let newTotalDuration {
                totalDuration.value = newTotalDuration
                if effectiveDuration.value == nil {
                    effectiveDuration.value = newTotalDuration
                }
            }
        }
    }

    static func getVideoDuration(url: URL) async -> Double? {
        await FFMPEGProbeService.getVideoDuration(for: url)
    }

    /// Uses the produced App 2e image count when available so audio padding and the CPL agree
    /// exactly with the wrapped picture essence. App 5 has no intermediate frame sequence, so it
    /// retains the duration-based calculation.
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

    /// Pads (or, if already long enough, leaves alone) a 48 kHz PCM WAV so it has
    /// at least `frameCount` picture frames worth of samples. Required by the
    /// IMF audio path: asdcp-wrap writes a frame-rate-keyed edit-unit index
    /// claiming one entry per picture frame, but the index is computed from the
    /// expected duration — if the WAV is short of that by even a fractional
    /// frame, the resulting MXF has an index entry pointing past the end of the
    /// essence and Resolve refuses to play it (mxf2raw also reports the file as
    /// "general error" with a "last edit unit not available" message).
    ///
    /// For non-integer rates (29.97, 59.94) the per-frame sample count is not
    /// integer, so we use a ceiling on `frameCount × 48000 × den / num` — a
    /// slight overshoot is fine, asdcp-wrap takes only what it needs.
    private func padWAVToFrameCount(
        conversionID: UUID,
        inputWAV: URL,
        frameCount: Int,
        editRateNumerator: Int,
        editRateDenominator: Int,
        ffmpegPath: String
    ) async -> URL? {
        guard frameCount > 0, editRateNumerator > 0, editRateDenominator > 0 else { return nil }
        let totalSamples = Int(ceil(Double(frameCount) * 48000.0 * Double(editRateDenominator) / Double(editRateNumerator)))
        let outputWAV = inputWAV.deletingLastPathComponent()
            .appendingPathComponent("audio_padded_\(UUID().uuidString).wav")

        let args: [String] = [
            "-y", "-nostdin",
            "-i", inputWAV.path,
            "-af", "apad=whole_len=\(totalSamples)",
            "-c:a", "pcm_s24le",
            "-ar", "48000",
            outputWAV.path
        ]
        Self.logger.info("Padding IMF WAV to \(totalSamples) samples")
        let result = await runTrackedPackageWrapper(
            conversionID: conversionID,
            executablePath: ffmpegPath,
            arguments: args,
            outputURL: outputWAV
        )
        switch result {
        case .success(let diagnostic):
            if !diagnostic.isEmpty {
                Self.logger.info("IMF WAV padding output: \(diagnostic.prefix(500), privacy: .public)")
            }
            return outputWAV
        case .failed(_, let reason, let diagnostic):
            Self.logger.error("IMF WAV padding failed (\(reason, privacy: .public)): \(diagnostic.prefix(300), privacy: .public)")
            return nil
        case .cancelled:
            return nil
        }
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
    private func needsAudioPreProcessing(
        preset: ExportPreset,
        waveformRequest: WaveformVideoRequest?,
        synthesizedVideoRequest: SynthesizedVideoRequest?
    ) -> Bool {
        guard preset == .tvAVCIntra else { return false }
        // Only needed for audio-only files (which use waveform or synthesized video)
        return waveformRequest != nil || synthesizedVideoRequest != nil
    }

    /// Pre-processes audio for AVC-Intra by splitting stereo to mono channels.
    /// Creates a temp MKA file with the target number of mono audio streams.
    /// - Returns: URL of the temp file, or nil if pre-processing failed
    private func preProcessAudioForAVCIntra(
        inputURL: URL,
        ffmpegPath: String,
        trimStart: Double?,
        trimEnd: Double?,
        conversionID: UUID
    ) async -> AVCIntraAudioPreprocessingResult {
        // Get target channel count from settings
        let audioChannelsRaw = UserDefaults.standard.string(forKey: AppConstants.avcIntraAudioChannelsKey)
            ?? AppConstants.defaultAVCIntraAudioChannels
        let audioChannels = AVCIntraAudioChannels(rawValue: audioChannelsRaw) ?? .ch8
        let targetChannelCount = audioChannels.count

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
                    // Multi-channel stream - split to mono
                    let splitLayout: String
                    if channels == 2 {
                        splitLayout = "stereo"
                    } else if channels == 6 {
                        splitLayout = "5.1"
                    } else if channels == 8 {
                        splitLayout = "7.1"
                    } else {
                        splitLayout = stream.channelLayout ?? "stereo"
                    }

                    var channelLabels: [String] = []
                    for ch in 0..<channels {
                        channelLabels.append("s\(audioPosition)c\(ch)")
                    }
                    let outputLabelsStr = channelLabels.map { "[\($0)]" }.joined()

                    filterParts.append("[0:a:\(audioPosition)]channelsplit=channel_layout=\(splitLayout)\(outputLabelsStr)")

                    // Format each split channel
                    for label in channelLabels {
                        let formattedLabel = "mono\(outputIndex)"
                        filterParts.append("[\(label)]aformat=sample_fmts=s32:sample_rates=48000:channel_layouts=mono[\(formattedLabel)]")
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
            await Self.runAVCIntraAudioPreprocessing(
                executablePath: ffmpegPath,
                arguments: args,
                outputURL: tempURL,
                subprocessRunner: runner
            )
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


extension FFMPEGConverter {
    /// Every selected picture must be prepared successfully before a package wrapper starts.
    /// The caller owns the private scratch directory and removes it on success or failure.
    nonisolated static func preparePackageCodestreams(
        sourceDirectory: URL,
        frameNames: [String],
        destinationDirectory: URL,
        progress: (_ completed: Int, _ total: Int) -> Void = { _, _ in }
    ) throws -> Int64 {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let socMarker = Data([0xFF, 0x4F])
        var totalBytes: Int64 = 0
        for (index, frameName) in frameNames.enumerated() {
            try Task.checkCancellation()
            let source = sourceDirectory.appendingPathComponent(frameName)
            let data = try Data(contentsOf: source)
            guard let marker = data.range(of: socMarker) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: source.path])
            }
            let destination = destinationDirectory.appendingPathComponent(frameName)
                .deletingPathExtension().appendingPathExtension("j2c")
            let codestream = data[marker.lowerBound...]
            try Task.checkCancellation()
            try codestream.write(to: destination, options: .atomic)
            totalBytes += Int64(codestream.count)
            progress(index + 1, frameNames.count)
        }
        try Task.checkCancellation()
        return totalBytes
    }
}
