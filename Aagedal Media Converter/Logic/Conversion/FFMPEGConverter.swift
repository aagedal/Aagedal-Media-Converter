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

/// Rejects progress callbacks admitted after cancellation or supersession. An already
/// admitted callback may finish after invalidation; the manager's attempt ownership
/// checks still govern UI publication. Invoke callers outside the lock so callbacks
/// can synchronously request cancellation without blocking gate invalidation.
final class ConversionProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    func run(_ action: @Sendable () -> Void) {
        guard lock.withLock({ active }) else { return }
        action()
    }

    func invalidate() {
        lock.withLock { active = false }
    }
}

/// Atomically reserves ordinary output paths across converter instances. A cancelled
/// attempt keeps its reservation until its completion path runs, preventing a retry
/// from publishing to a path that the older attempt may still clean up or write.
final class ConversionOutputReservations: @unchecked Sendable {
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

    func reserveExact(_ url: URL, notOverwriting inputURL: URL, owner: UUID) -> Bool {
        lock.withLock {
            let standardizedURL = url.standardizedFileURL
            guard standardizedURL != inputURL.standardizedFileURL,
                  !FileManager.default.fileExists(atPath: url.path),
                  owners[standardizedURL] == nil else { return false }
            owners[standardizedURL] = owner
            return true
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
    private var recursiveOperationID: UUID?

    @TaskLocal static var runningSubprocessID: UUID?
    var currentSubprocessTask: Task<Void, Never>?
    var joinableSubprocessID: UUID?
    var currentWaveformEncodingTask: Task<SubprocessResult, Error>?
    var currentWaveformEncodingID: UUID?
    private var currentDependencyPreflightTask: Task<String?, Error>?
    var currentWaveformAnalysisTask: Task<FrequencyBandData, Error>?
    var currentWaveformAnalysisID: UUID?
    var currentImageSequenceAudioTask: Task<ImageSequenceAudioStagingResult, Never>?
    var currentImageSequenceAudioTaskID: UUID?
    var currentPackageAudioTask: Task<AudioExtractionResult, Never>?
    var currentPackageAudioTaskID: UUID?
    var currentPackagePreparationTask: Task<Int64, Error>?
    var currentPackagePreparationTaskID: UUID?
    var currentPackageWrapperTask: Task<PackageWrapperResult, Never>?
    var currentPackageWrapperTaskID: UUID?
    var currentAVCIntraPreprocessingTask: Task<AVCIntraAudioPreprocessingResult, Never>?
    var currentAVCIntraPreprocessingTaskID: UUID?
    var currentEndCutListingTask: Task<PackageWrapperResult, Never>?
    var currentLoudnessMeasurementTask: Task<SubprocessResult?, Never>?
    var currentAV2HelperTask: Task<AV2HelperRunResult, Never>?
    var currentAV2HelperTaskID: UUID?
    var currentMCALabelTask: Task<URL?, Never>?
    var currentMCALabelTaskID: UUID?
    var currentAV2PipelineTasks: [UUID: Task<SubprocessPipelineResult, Error>] = [:]
    struct AV2FileTask {
        let cancel: @Sendable () -> Void
        let drain: Task<Void, Never>
    }
    var currentAV2FileTasks: [UUID: AV2FileTask] = [:]
    var av2CancellationToken = UUID()

    var currentProgressGate: ConversionProgressGate?
    var activeConversionID: UUID?
    var postProcessingConversionID: UUID?
    private var activeBMXOperationID: UUID?
    let subprocessRunner: any SubprocessRunning
    let bmxService: BMXService
    private let ffmpegPathProvider: @Sendable () -> String?
    private let avmdecPathProvider: @Sendable () -> String?
    let av2MemorySnapshot: @Sendable () -> AV2MemorySnapshot
    let av2RecoveryRoot: @Sendable () -> URL
    private let dependencyPreflight: ConversionDependencyPreflight
    let mcaAudioStreamProvider: @Sendable (URL) async -> [FFMPEGProbeService.AudioStreamInfo]?
    private let preflightAudioStreamProvider: @Sendable (URL) async -> [FFMPEGProbeService.AudioStreamInfo]?

    static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "FFMPEGConverter")
    static let outputReservations = ConversionOutputReservations()
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

    enum PostProcessingStepResult: Sendable, Equatable {
        case success
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
        bmxService: BMXService = .shared,
        ffmpegPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.ffmpegPath },
        avmdecPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.avmdecPath },
        av2MemorySnapshot: @escaping @Sendable () -> AV2MemorySnapshot = { AV2MemoryMonitor.shared.snapshot() },
        av2RecoveryRoot: @escaping @Sendable () -> URL = { AV2RecoveryStore.defaultRoot },
        dependencyPreflight: ConversionDependencyPreflight = ConversionDependencyPreflight(),
        mcaAudioStreamProvider: @escaping @Sendable (URL) async -> [FFMPEGProbeService.AudioStreamInfo]? = {
            await FFMPEGProbeService.fetchAudioStreams(for: $0)
        },
        preflightAudioStreamProvider: @escaping @Sendable (URL) async -> [FFMPEGProbeService.AudioStreamInfo]? = {
            await FFMPEGProbeService.fetchAudioStreams(for: $0)
        }
    ) {
        self.av2MemorySnapshot = av2MemorySnapshot
        self.av2RecoveryRoot = av2RecoveryRoot
        self.subprocessRunner = subprocessRunner
        self.bmxService = bmxService
        self.ffmpegPathProvider = ffmpegPathProvider
        self.avmdecPathProvider = avmdecPathProvider
        self.dependencyPreflight = dependencyPreflight
        self.preflightAudioStreamProvider = preflightAudioStreamProvider
        self.mcaAudioStreamProvider = mcaAudioStreamProvider
    }

    /// Converts a video file using the specified export preset
    /// - Parameters:
    ///   - request: All conversion parameters bundled in a ConversionRequest
    ///   - progressUpdate: Callback for progress updates (progress: Double, status: String?)
    ///   - completion: Callback for completion (success: Bool, errorReason: String?)
    func convert(
        request: ConversionRequest,
        recursiveGenerations: Int? = nil,
        av2Settings: AV2Settings? = nil,
        dcpSettings: DCPSettings? = nil,
        imfSettings: IMFSettings? = nil,
        audioOnlySettings: AudioOnlySettings? = nil,
        imageSequenceSettings: ImageSequenceSettings? = nil,
        codecSettings: CodecExportSettings? = nil,
        subtitleSettings: SubtitleExportSettings? = nil,
        commentSettings: CommentSettings? = nil,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void,
        completion: @escaping @Sendable (Bool, String?) -> Void
    ) async {
        let request = request.applyingMetadataEditor(
            outputExtension: av2Settings?.container.fileExtension ?? audioOnlySettings?.format.fileExtension ?? codecSettings?.outputExtension(for: request.inputURL)
        )
        if let generations = recursiveGenerations {
            guard !Task.isCancelled else {
                completion(false, "Recursive encoding cancelled")
                return
            }
            guard request.preset.supportsRecursiveEncoding, (2...100).contains(generations) else {
                completion(false, "Recursive encoding requires a supported encoding preset and 2–100 generations.")
                return
            }
            let operationID = UUID()
            recursiveOperationID = operationID
            defer {
                if recursiveOperationID == operationID { recursiveOperationID = nil }
            }
            // A unique run folder keeps reruns together without overwriting earlier experiments.
            let folderBase = request.outputURL.deletingLastPathComponent().appendingPathComponent(
                request.outputURL.lastPathComponent + "_generations", isDirectory: true
            )
            var folder = folderBase
            var run = 1
            while true {
                // mkdir reserves a new directory atomically; Foundation also succeeds
                // for existing directories, which would mix generations from reruns.
                if mkdir(folder.path, 0o755) == 0 { break }
                let failure = errno
                guard failure == EEXIST else {
                    completion(false, "Cannot create recursive encoding folder: \(String(cString: strerror(failure)))")
                    return
                }
                run += 1
                folder = folderBase.deletingLastPathComponent().appendingPathComponent(
                    folderBase.lastPathComponent + "_\(run)", isDirectory: true
                )
            }
            var previousOutput = request.inputURL
            for generation in 1...generations {
                guard recursiveOperationID == operationID, !Task.isCancelled else {
                    completion(false, "Recursive encoding cancelled")
                    return
                }
                var pass = request
                pass.inputURL = previousOutput
                pass.outputURL = folder.appendingPathComponent(
                    request.outputURL.lastPathComponent + String(format: "_gen%03d", generation)
                )
                pass.requiredOutputURL = nil
                let resolvedOutput = OSAllocatedUnfairLock<URL?>(initialState: nil)
                pass.outputURLResolved = { url in resolvedOutput.withLock { $0 = url } }
                if generation > 1 {
                    // Source edits belong to the original timeline, not every generation.
                    pass.trimStart = nil
                    pass.trimEnd = nil
                    pass.cropConfig = nil
                    pass.audioRoutingConfig = nil
                    pass.timecodeConfig = nil
                    pass.sourceMetadata = nil
                    pass.sourceCameraMetadata = nil
                    pass.customInputArguments = nil
                    pass.expectedDuration = nil
                    pass.waveformRequest = nil
                    pass.synthesizedVideoRequest = nil
                    pass.waveformBackgroundImageURL = nil
                    pass.visualSourceURL = nil
                    pass.chapterMetadataURL = nil
                    pass.chapterMetadataTitles = []
                }
                let result: (Bool, String?) = await withTaskCancellationHandler(operation: {
                    await withCheckedContinuation { continuation in
                        Task {
                            guard self.recursiveOperationID == operationID else {
                                continuation.resume(returning: (false, "Recursive encoding cancelled"))
                                return
                            }
                            await self.convert(
                                request: pass,
                                av2Settings: av2Settings, dcpSettings: dcpSettings, imfSettings: imfSettings,
                                audioOnlySettings: audioOnlySettings, imageSequenceSettings: imageSequenceSettings,
                                codecSettings: codecSettings, subtitleSettings: subtitleSettings, commentSettings: commentSettings,
                                progressUpdate: { progress, status in
                                    let update = RecursiveEncodingProgress(progress: progress, status: status,
                                                                           generation: generation, total: generations)
                                    request.etaUpdate?(update.eta)
                                    progressUpdate(update.fraction, update.message)
                                },
                                completion: { success, error in continuation.resume(returning: (success, error)) }
                            )
                        }
                    }
                }, onCancel: {
                    Task { await self.cancelRecursiveConversion(operationID: operationID) }
                }, isolation: self)
                guard result.0, let output = resolvedOutput.withLock({ $0 }) else {
                    completion(false, result.1 ?? "Generation \(generation) failed")
                    return
                }
                previousOutput = output
            }
            guard recursiveOperationID == operationID, !Task.isCancelled else {
                completion(false, "Recursive encoding cancelled")
                return
            }
            request.outputURLResolved?(previousOutput)
            completion(true, nil)
            return
        }
        // Destructure frequently-used fields for readability
        let inputURL = request.inputURL
        let outputURL = request.outputURL
        let preset = request.preset
        let trimPreparationError = preset == .av2
            ? AV2TrimPlan(start: request.trimStart, end: request.trimEnd).preparationError
            : FFMPEGTrimPlan(start: request.trimStart, end: request.trimEnd).preparationError
        if let preparationError = trimPreparationError {
            completion(false, preparationError)
            return
        }
        // Capture encoding and packaging preferences before cancellation or metadata work can suspend.
        let capturedAV2Settings = preset == .av2 ? (av2Settings ?? AV2Settings()) : nil
        let capturedDCPSettings = preset == .dcp ? (dcpSettings ?? DCPSettings()) : nil
        let capturedIMFSettings = (preset == .imfJ2K || preset == .imfProRes) ? (imfSettings ?? IMFSettings()) : nil
        let capturedAudioOnlySettings = preset == .audioOnly ? (audioOnlySettings ?? AudioOnlySettings()) : nil
        let capturedImageSequenceSettings = preset == .imageSequence ? (imageSequenceSettings ?? ImageSequenceSettings()) : nil
        let capturedCodecSettings = codecSettings ?? CodecExportSettings(preset: preset)
        let capturedSubtitleSettings = subtitleSettings ?? SubtitleExportSettings()
        let sourceCommentSettings = commentSettings ?? CommentSettings()
        let capturedCommentSettings = request.metadataEditorSettings?.writesComment == false
            ? sourceCommentSettings.withoutAffixes : sourceCommentSettings
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
        currentWaveformEncodingTask?.cancel()
        currentWaveformEncodingTask = nil
        currentWaveformEncodingID = nil
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
        currentEndCutListingTask?.cancel()
        currentEndCutListingTask = nil
        currentLoudnessMeasurementTask?.cancel()
        currentLoudnessMeasurementTask = nil
        currentAV2HelperTask?.cancel()
        currentAV2HelperTask = nil
        currentAV2HelperTaskID = nil
        currentMCALabelTask?.cancel()
        currentMCALabelTask = nil
        currentMCALabelTaskID = nil
        for task in currentAV2PipelineTasks.values { task.cancel() }
        currentAV2PipelineTasks.removeAll()
        av2CancellationToken = UUID()
        for work in currentAV2FileTasks.values { work.cancel() }
        currentAV2FileTasks.removeAll()
        let supersededBMXOperationID = activeBMXOperationID
        activeConversionID = nil
        postProcessingConversionID = nil
        activeBMXOperationID = nil
        if let supersededBMXOperationID {
            await bmxService.cancel(operationID: supersededBMXOperationID)
        }
        let conversionID = UUID()
        activeConversionID = conversionID

        if let nativeMerge = request.nativeMXFMerge,
           await runNativeMXFMerge(
               nativeMerge, request: request, conversionID: conversionID,
               progressUpdate: progressUpdate, completion: completion
           ) {
            return
        }

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
            if let requiredOutputURL = request.requiredOutputURL {
                guard subfolderURL.standardizedFileURL == requiredOutputURL.standardizedFileURL,
                      !fileManager.fileExists(atPath: subfolderURL.path) else {
                    activeConversionID = nil
                    completion(false, ApplicationJobErrorCode.outputCollision.rawValue)
                    return
                }
            }

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
            // IMF RDD 45: FFmpeg writes an intermediate MXF for bmxtranswrap.
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
            outputFileURL = finalSubfolderURL.appendingPathComponent("imf_prores_temp.mxf")
            Self.logger.info("IMF RDD 45: FFmpeg will output intermediate ProRes MXF")
        } else if let imageSequenceSettings = capturedImageSequenceSettings {
            // Create subfolder: outputDir/basename_seq/
            let subfolderName = outputURL.lastPathComponent
            let subfolderURL = outputDir.appendingPathComponent(subfolderName, isDirectory: true)
            if let requiredOutputURL = request.requiredOutputURL {
                guard subfolderURL.standardizedFileURL == requiredOutputURL.standardizedFileURL,
                      !fileManager.fileExists(atPath: subfolderURL.path) else {
                    activeConversionID = nil
                    completion(false, ApplicationJobErrorCode.outputCollision.rawValue)
                    return
                }
            }

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
            let patternFileName = imageSequenceSettings.outputPattern(baseName: baseName)
            outputFileURL = finalSubfolderURL.appendingPathComponent(patternFileName)
        } else {
            // Use the captured container for naming and encoding.
            let outputExtension = capturedAV2Settings?.container.fileExtension
                ?? capturedAudioOnlySettings?.format.fileExtension
                ?? capturedCodecSettings?.outputExtension(for: inputURL)
                ?? preset.outputExtension(for: inputURL)
            outputFileURL = outputURL.appendingPathExtension(outputExtension)

            if let requiredOutputURL = request.requiredOutputURL {
                guard outputFileURL.standardizedFileURL == requiredOutputURL.standardizedFileURL,
                      Self.outputReservations.reserveExact(
                        outputFileURL, notOverwriting: inputURL, owner: conversionID
                      ) else {
                    activeConversionID = nil
                    completion(false, ApplicationJobErrorCode.outputCollision.rawValue)
                    return
                }
            } else {
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
            }

            // Register this file as created by the app (for safe deletion later if needed)
            FileSafetyUtils.registerCreatedFile(outputFileURL)
        }

        request.outputURLResolved?(outputFileURL)
        let completionGate = ConversionCompletionGate()
        let cleanupOutputURL = outputFileURL
        let isOrdinaryFileExport = !isImageSequenceExport && !isDCPExport && !isIMFExport
        let matteSidecar = MatteSidecarBox()
        let finish: @Sendable (Bool, String?) -> Void = { success, errorReason in
            completionGate.run {
                if let matteURL = matteSidecar.url {
                    let ownsMatte = Self.outputReservations.release(matteURL, owner: conversionID)
                    if success && matteSidecar.isWritten && ownsMatte {
                        FileSafetyUtils.markCompletedOutput(matteURL)
                    } else if ownsMatte {
                        Self.cleanupFailedOutput(at: matteURL)
                    }
                }
                let ownsOutput = !isOrdinaryFileExport || Self.outputReservations.release(
                    cleanupOutputURL,
                    owner: conversionID
                )
                if success && isOrdinaryFileExport && ownsOutput {
                    FileSafetyUtils.markCompletedOutput(cleanupOutputURL)
                }
                if !success && isOrdinaryFileExport && ownsOutput {
                    Self.cleanupFailedOutput(at: cleanupOutputURL)
                }
                completion(success, errorReason)
            }
        }

        // For AVC-Intra MXF, FFmpeg outputs to temp file, then bmxtranswrap rewraps to OP1a.
        // Stream Copy of H.264 into MXF also needs a valid index: bmx rewraps a single
        // clip, and a merge's offsets are read from its inputs (see MXFIndexTemporalOffsets).
        // A merge's input is its first clip, whose rate and codec the merge shares.
        var avcStreamCopyPicture: NativeMXFMerge.PictureTrack?
        if request.waveformRequest == nil, request.synthesizedVideoRequest == nil,
           AVCMXFStreamCopy.applies(preset: preset, outputExtension: outputFileURL.pathExtension, sourceURL: inputURL) {
            avcStreamCopyPicture = await bmxService.getMXFInfo(url: inputURL).flatMap(AVCMXFStreamCopy.avcPicture(fromMXFInfo:))
        }
        let isAVCMXFStreamCopy = avcStreamCopyPicture != nil
        var avcIndexConcatInput: [String]?
        if isAVCMXFStreamCopy,
           case .concat(let path, let safe) = FFMPEGInputPlan(inputURL: inputURL, customArguments: request.customInputArguments) {
            avcIndexConcatInput = ["-f", "concat", "-safe", safe, "-i", path]
        }
        let needsBMXRewrap = preset == .tvAVCIntra || (isAVCMXFStreamCopy && avcIndexConcatInput == nil)
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
                conversionID: conversionID,
                targetChannelCount: capturedCodecSettings?.avcIntraAudioChannels?.count ?? 8
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
                dcpSettings: capturedDCPSettings,
                imfSettings: capturedIMFSettings,
                audioOnlySettings: capturedAudioOnlySettings,
                imageSequenceSettings: capturedImageSequenceSettings,
                codecSettings: capturedCodecSettings,
                waveformRequest: waveformRequest,
                audioRoutingConfig: request.audioRoutingConfig,
                trimStart: request.trimStart,
                trimEnd: request.trimEnd,
                comment: request.comment,
                writeEmptyComment: request.metadataEditorSettings?.writesComment == true,
                includeDateTag: request.includeDateTag,
                commentSettings: capturedCommentSettings,
                isMuted: request.isMuted,
                additionalOutputArguments: request.additionalOutputArguments,
                expectedDuration: request.expectedDuration,
                videoFrameRate: request.videoFrameRate,
                needsBMXRewrap: needsBMXRewrap,
                tempMXFURL: tempMXFURL,
                outputFileURL: outputFileURL,
                waveformBackgroundImageURL: request.waveformBackgroundImageURL,
                matteSidecar: request.exportsMatteSidecar && preset.supportsMatteSidecar ? matteSidecar : nil,
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
                    metadataEditorSettings: request.metadataEditorSettings,
                    includeDateTag: request.includeDateTag,
                    commentSettings: capturedCommentSettings,
                    timecodeConfig: request.timecodeConfig,
                    timecodeTrimStart: request.timecodeTrimStart,
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
                if ok {
                    if let directory = encodeResult.recoveryDirectory { AV2RecoveryStore.discard(directory) }
                    progressUpdate(1.0, nil)
                }
                finish(ok, reason)
                return
            }

            if let directory = encodeResult.recoveryDirectory { AV2RecoveryStore.discard(directory) }
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

        // FFmpeg ends a Stream Copy cut by decode time, which can keep a picture from
        // after the end and drop B-frames before it (see `StreamCopyEndCut`).
        var trimEnd = tempAudioURL != nil ? nil : request.trimEnd
        var additionalOutputArguments = request.additionalOutputArguments
        if preset == .streamCopy, tempAudioURL == nil, trimEnd != nil,
           request.waveformRequest == nil, request.synthesizedVideoRequest == nil,
           case .file = FFMPEGInputPlan(inputURL: effectiveInputURL, customArguments: effectiveCustomInputArguments) {
            let trimPlan = FFMPEGTrimPlan(start: request.trimStart, end: trimEnd)
            if trimPlan.preparationError == nil, let end = trimPlan.end {
                let start = trimPlan.start ?? 0
                // Reads the source up to the end before the export starts, which takes a
                // while for an end-only trim of a long file.
                progressUpdate(0, "Finding the trim's end frame…")
                guard let cut = await findStreamCopyEndCut(
                    conversionID: conversionID, ffmpegPath: ffmpegPath, inputURL: effectiveInputURL,
                    seek: trimPlan.seekArguments, end: end - start
                ) else {
                    finish(false, "Conversion cancelled")
                    return
                }
                trimEnd = cut.duration(requested: end - start).map { start + $0 }
                if let drop = cut.droppedVideo {
                    additionalOutputArguments = (additionalOutputArguments ?? [])
                        + ["-bsf:v", "noise=amount=0:drop='\(drop)'"]
                }
            }
        }

        // Build FFmpeg arguments
        let buildCommand: ([LoudnormMeasurement]?) async -> FFMPEGCommand = { loudnessMeasurements in await FFMPEGCommandBuilder.buildCommand(
            inputURL: effectiveInputURL,
            outputFileURL: ffmpegOutputURL,  // Use temp file for AVC-Intra, final file otherwise
            preset: preset,
            dcpSettings: capturedDCPSettings,
            imfSettings: capturedIMFSettings,
            audioOnlySettings: capturedAudioOnlySettings,
            imageSequenceSettings: capturedImageSequenceSettings,
            codecSettings: capturedCodecSettings,
            commentSettings: capturedCommentSettings,
            subtitleSettings: capturedSubtitleSettings,
            comment: request.comment,
            writeEmptyComment: request.metadataEditorSettings?.writesComment == true,
            includeDateTag: request.includeDateTag,
            trimStart: tempAudioURL != nil ? nil : request.trimStart,  // Trim already applied in pre-processing
            trimEnd: trimEnd,
            audioRoutingConfig: tempAudioURL != nil ? nil : request.audioRoutingConfig,  // Audio already processed
            cropConfig: request.cropConfig,
            timecodeConfig: request.timecodeConfig,
            timecodeTrimStart: request.timecodeTrimStart,
            sourceMetadata: request.sourceMetadata,
            waveformRequest: request.waveformRequest,
            synthesizedVideoRequest: request.synthesizedVideoRequest,
            synthesizedVideoDuration: tempAudioURL != nil
                ? FFMPEGCommandBuilder.calculateEffectiveDuration(trimStart: request.trimStart, trimEnd: request.trimEnd)
                : (request.trimStart == nil && request.trimEnd == nil ? request.expectedDuration : nil),
            synthesizedVideoUsesSourceMetadataDuration: tempAudioURL == nil,
            visualSourceURL: request.visualSourceURL,
            customInputArguments: effectiveCustomInputArguments,
            additionalOutputArguments: avcStreamCopyPicture.map {
                (additionalOutputArguments ?? []) + AVCMXFStreamCopy.frameRateArguments(editRate: $0.editRate)
            } ?? additionalOutputArguments,
            chapterMetadataURL: request.chapterMetadataURL,
            chapterMetadataTitles: request.chapterMetadataTitles,
            isMuted: request.isMuted,
            adjustments: tempAudioURL != nil ? nil : request.adjustments,
            loudnessMeasurements: loudnessMeasurements
        ) }
        var command = await buildCommand(nil)

        // Two-pass loudness: measure every normalized track, then rebuild with the results.
        if command.preparationError == nil, let measurementArguments = command.loudnessMeasurementArguments {
            progressUpdate(0, String(localized: "Measuring loudness…", comment: "Conversion status during the first loudness normalization pass."))
            switch await measureLoudness(conversionID: conversionID, ffmpegPath: ffmpegPath, arguments: measurementArguments) {
            case .cancelled:
                // The preparation-failure path below owns the cleanup of unstarted outputs.
                command.preparationError = "Conversion cancelled"
            case .measured(let measurements) where measurements.count == command.loudnessTrackCount:
                command = await buildCommand(measurements)
            case .measured, .failed:
                command.preparationError = MediaAdjustmentsPlan.AdjustmentError.measurementFailed.message
            }
        }

        if let preparationError = command.preparationError {
            if let tempAudioURL { Self.cleanupTempFile(at: tempAudioURL, label: "Preprocessed audio") }
            if let tempMXFURL { Self.cleanupTempFile(at: tempMXFURL, label: "Intermediate MXF") }
            if let dcpSubfolderURL { Self.cleanupTempFile(at: dcpSubfolderURL, label: "Unstarted DCP package") }
            if let imfSubfolderURL { Self.cleanupTempFile(at: imfSubfolderURL, label: "Unstarted IMF package") }
            if isImageSequenceExport {
                Self.cleanupTempFile(at: outputFileURL.deletingLastPathComponent(), label: "Unstarted image sequence")
            }
            _ = await finishTrackedConversion(conversionID)
            finish(false, preparationError)
            return
        }

        // For an AV2 Matroska source the decoded video arrives on input 0 (the avmdec pipe) and the
        // audio lives on input 1 (the original file). Redirect the preset's audio/subtitle maps,
        // which default to input 0, over to input 1.
        var finalArguments = command.arguments
        if av2MatroskaAudioFromInput1 {
            finalArguments = Self.redirectAudioSubtitleMapsToSecondInput(finalArguments)
        }

        // Matte sidecar for sources with alpha whose output format drops it. Runs as a
        // second FFmpeg pass after the main encode, reusing its inputs, trim and filters.
        var matteArguments: [String]? = nil
        if request.exportsMatteSidecar, preset.supportsMatteSidecar, isOrdinaryFileExport,
           request.waveformRequest == nil, request.synthesizedVideoRequest == nil,
           request.visualSourceURL == nil, av2DecodeRequest == nil,
           request.sourceMetadata?.videoStreams.first?.hasAlpha == true
               || FFMPEGInputPlan(inputURL: inputURL, customArguments: effectiveCustomInputArguments).imageSequenceHasAlpha,
           !FFMPEGCommandBuilder.outputKeepsAlpha(finalArguments) {
            let matteURL = matteSidecar.reserve(for: outputFileURL, notOverwriting: inputURL, owner: conversionID)
            matteArguments = FFMPEGCommandBuilder.sourceMatteArguments(
                fromMainArguments: finalArguments, matteOutputURL: matteURL
            )
            if matteArguments == nil {
                Self.logger.warning("Matte sidecar skipped: the video is built by a complex filter graph")
                matteSidecar.cancelReservation(owner: conversionID)
            }
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
        let bmxService = self.bmxService
        let capturedRequest = request
        let capturedTempAudioURL = tempAudioURL
        let capturedTempMXFURL = tempMXFURL
        let capturedFinalOutputURL = outputFileURL
        let capturedNeedsBMXRewrap = needsBMXRewrap
        let capturedIsAVCMXFStreamCopy = isAVCMXFStreamCopy
        let capturedAVCIndexConcatInput = avcIndexConcatInput
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
        let capturedMatteArguments = matteArguments

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
                // For IMF RDD 45 we validate the intermediate MXF before rewrapping it.
                if success && !capturedIsImageSequenceExport && !capturedIsDCPExport && !capturedIsIMFJ2KExport {
                    let fileToValidate = capturedNeedsBMXRewrap ? (capturedTempMXFURL ?? capturedFinalOutputURL) : capturedFinalOutputURL
                    if let validationError = Self.validateOutputFile(at: fileToValidate) {
                        Self.logger.error("Output validation failed: \(validationError, privacy: .public)")
                        errorReason = validationError
                        success = false
                    }
                }

                // Matte sidecar pass. A failed matte is logged but does not fail the main export.
                if success, let matteArguments = capturedMatteArguments, let matteURL = matteSidecar.url {
                    progressUpdate(1.0, "Writing matte…")
                    let matteResult = await self?.runTrackedPackageWrapper(
                        conversionID: conversionID,
                        executablePath: capturedFfmpegPath,
                        arguments: matteArguments,
                        outputURL: matteURL
                    )
                    switch matteResult {
                    case .success?:
                        matteSidecar.markWritten()
                        Self.logger.info("Wrote matte sidecar: \(matteURL.lastPathComponent, privacy: .public)")
                    case .failed(_, let reason, let diagnostic)?:
                        Self.logger.warning("Matte sidecar failed (\(reason, privacy: .public)):\n\(diagnostic, privacy: .public)")
                    case .cancelled?, nil:
                        success = false
                        errorReason = "Conversion cancelled"
                    }
                }

                if success, let concatInput = capturedAVCIndexConcatInput {
                    progressUpdate(0.97, "Indexing H.264 MXF...")
                    switch await self?.writeAVCMXFIndexTemporalOffsets(
                        conversionID: conversionID, ffmpegPath: capturedFfmpegPath,
                        concatInput: concatInput, outputURL: capturedFinalOutputURL
                    ) {
                    case .success?:
                        break
                    case .failed(let reason)?:
                        // The file is still complete; only its frame order is unreliable.
                        Self.logger.error("Could not index the H.264 MXF merge: \(reason, privacy: .public)")
                    case .cancelled?, nil:
                        success = false
                        errorReason = "Conversion cancelled"
                    }
                }

                // Run bmxtranswrap for AVC-Intra to ensure OP1a compliance, and to index
                // Stream Copied H.264 MXF.
                if success && capturedNeedsBMXRewrap, let tempMXF = capturedTempMXFURL {
                    Self.logger.info("Running bmxtranswrap to rewrap MXF to OP1a format")
                    progressUpdate(0.95, "Rewrapping to OP1a...")

                    // Stream Copy keeps the source's audio layout; labels are an AVC-Intra preset setting.
                    let mcaLabelsFile = capturedIsAVCMXFStreamCopy ? nil : await self?.prepareTrackedAVCIntraMCALabelsFile(
                        conversionID: conversionID,
                        inputURL: capturedInputURL,
                        audioRoutingConfig: capturedRequest.audioRoutingConfig,
                        targetChannelCount: capturedCodecSettings?.avcIntraAudioChannels?.count ?? 8,
                        mcaDefaults: capturedCodecSettings?.avcIntraMCADefaults ?? .none
                    )
                    let bmxResult: BMXRewrapResult
                    if await self?.isPostProcessing(conversionID) == true {
                        bmxResult = await bmxService.rewrapToOP1a(
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
                    } else {
                        bmxResult = BMXRewrapResult(success: false, stderr: "", cancelled: true)
                    }
                    let lateCancellation = await bmxService.finishCancellationTracking(
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
                if success && capturedIsDCPExport, let dcpFolder = capturedDCPSubfolderURL,
                   let dcpSettings = capturedDCPSettings {
                    Self.logger.info("Starting DCP assembly...")

                    let resolution = dcpSettings.resolution
                    let frameRate = dcpSettings.frameRate

                    let fm = FileManager.default
                    let jp2Dir = capturedFinalOutputURL.deletingLastPathComponent()
                    var videoMXFURL: URL? = nil
                    var pictureFrameCount = 0
                    // The CPL/PKL/ASSETMAP ids must equal the AssetUUID asdcp-wrap stores in each
                    // MXF, or servers report the asset as missing. Generate them up front.
                    let videoAssetID = SMPTEPackageUtils.urnUUID()
                    let audioAssetID = SMPTEPackageUtils.urnUUID()

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

                        pictureFrameCount = jp2Files.count
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
                                    "-a", SMPTEPackageUtils.uuidString(from: videoAssetID),
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
                    if !dcpSettings.keepJP2Images {
                        Self.cleanupTempFile(at: jp2Dir, label: "DCP JP2 images")
                    }

                    var finalAudioMXF: URL? = nil
                    var sourceAudioChannels: Int? = nil
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
                            audioRoutingConfig: capturedRequest.audioRoutingConfig,
                            dcpCarrier: DCPAudioCarrier(frameCount: pictureFrameCount, frameRate: frameRate)
                        ) ?? .failed(reason: "Conversion cancelled")
                        let audioWavURL: URL?
                        switch audioExtractionResult {
                        case .extracted(let url, let sourceChannels):
                            audioWavURL = url
                            sourceAudioChannels = sourceChannels
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

                            let audioLanguage = capturedRequest.dcpMetadata?.audioLanguage ?? "en"
                            var audioWrapArgs: [String] = [
                                "-p", frameRate.ffmpegValue,
                                "-L",                          // SMPTE Universal Labels
                                "-a", SMPTEPackageUtils.uuidString(from: audioAssetID),
                                "-d", String(pictureFrameCount), // Same edit-unit count as the picture
                                "-m", DCPAudioCarrier.mcaExpression, // ST 377-4 MCA labels (Bv2.1)
                            ]
                            if DCPValidator.isValidLanguageTag(audioLanguage) {
                                audioWrapArgs += ["-g", audioLanguage]
                            }
                            audioWrapArgs += [wavURL.path, audioMXFURL.path]

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

                        // The CPL must state exactly the edit units asdcp-wrap wrote, so count
                        // the encoded frames rather than estimating from the source duration.
                        let frameCount = pictureFrameCount

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
                            audioLanguage: audioLanguage,
                            audioCode: finalAudioMXF == nil ? "MOS" : DCPAudioCarrier.isdcfAudioCode(sourceChannels: sourceAudioChannels)
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
                                videoAssetID: videoAssetID,
                                audioMXFURL: finalAudioMXF,
                                audioAssetID: audioAssetID,
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
                            } else {
                                // Hashes were just computed during assembly; skip re-reading the essence.
                                progressUpdate(0.99, "Validating DCP...")
                                let report = await DCPValidator.validate(
                                    directory: dcpOutputDir,
                                    options: DCPValidator.Options(verifyHashes: false)
                                )
                                for issue in report.issues where issue.severity != .info {
                                    Self.logger.warning("DCP validation \(issue.severity.label, privacy: .public) \(issue.code, privacy: .public): \(issue.message, privacy: .public)")
                                }
                                Self.logger.info("DCP validation: \(report.summaryLine, privacy: .public)")
                                // Errors break playback or ingest. Keep the package for inspection,
                                // but don't report it as a finished export.
                                if let firstError = report.issues.first(where: { $0.severity == .error }) {
                                    let format = String(
                                        localized: "The DCP failed validation: %@ Check it with File › Validate DCP… for all findings.",
                                        comment: "Shown when a just-exported DCP fails the built-in validator. The argument is the first error message."
                                    )
                                    errorReason = String(format: format, firstError.message)
                                    success = false
                                }
                            }
                        }

                    }
                }

                // IMF assembly: produce video MXF + audio MXF essences and emit CPL/PKL/ASSETMAP.
                if success && capturedIsIMFExport, let imfFolder = capturedIMFSubfolderURL,
                   let imfSettings = capturedIMFSettings {
                    Self.logger.info("Starting IMF assembly...")
                    print("[IMF] starting assembly, imfFolder=\(imfFolder.path)")

                    let resolution = imfSettings.resolution
                    let frameRate = imfSettings.frameRate
                    let color = imfSettings.color
                    let application: IMFApplication = capturedIsIMFJ2KExport ? .app2e : .rdd45

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
                        let keepIntermediates = imfSettings.keepIntermediates
                        if !keepIntermediates {
                            Self.cleanupTempFile(at: jp2Dir, label: "IMF JP2 images")
                        }
                    } else if capturedIsIMFProResExport {
                        // ProRes MXF → bmxtranswrap → IMF OP1a MXF
                        progressUpdate(0.78, "Creating IMF video essence")
                        print("[IMF] RDD 45 branch — input MXF: \(capturedFinalOutputURL.lastPathComponent)")
                        let tmpVideoMXF = FileManager.default.temporaryDirectory
                            .appendingPathComponent("imf_video_\(UUID().uuidString).mxf")

                        let bmxFlags = color.bmxFlags

                        let bmxResult = await bmxService.rewrapToIMFOP1a(
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
                        let lateCancellation = await bmxService.finishCancellationTracking(
                            operationID: conversionID
                        )
                        await self?.clearActiveBMXOperation(if: conversionID)
                        let stillOwnsPostProcessing = await self?.isPostProcessing(conversionID) ?? false
                        if bmxResult.cancelled || lateCancellation || !stillOwnsPostProcessing {
                            errorReason = "Conversion cancelled"
                            success = false
                        } else if bmxResult.success {
                            imfVideoMXF = tmpVideoMXF
                            Self.logger.info("IMF video essence created (RDD 45)")
                        } else {
                            Self.logger.error("bmxtranswrap failed for IMF ProRes video essence")
                            errorReason = Self.dcpIMFErrorReason(
                                base: String(localized: "IMF video wrap failed: bmxtranswrap rejected ProRes essence", comment: "Shown when bmxtranswrap cannot rewrap the intermediate ProRes MXF into an IMF RDD 45 OP1a MXF."),
                                stderr: bmxResult.stderr
                            )
                            success = false
                        }
                        // Remove the intermediate MXF unless requested for debugging.
                        let keepIntermediates = imfSettings.keepIntermediates
                        if !keepIntermediates {
                            Self.cleanupTempFile(at: capturedFinalOutputURL, label: "IMF ProRes temp MXF")
                        }
                    }

                    // Use the wrapped MXF's exact duration for audio padding and the CPL.
                    // Source container duration can round up by a frame on short clips.
                    if success, let videoMXF = imfVideoMXF {
                        if let wrappedFrameCount = await IMFManifestWriter.shared.pictureFrameCount(for: videoMXF) {
                            exactPictureFrameCount = wrappedFrameCount
                        } else {
                            errorReason = String(localized: "IMF video wrap failed: could not read the wrapped MXF duration", comment: "Shown when the app cannot inspect the finished IMF picture track file.")
                            success = false
                        }
                    }

                    // ----- Audio essence wrap (shared between App #2e and RDD 45) -----
                    var imfAudioMXF: URL? = nil
                    var imfAudioLabels: IMFAudioLabels? = nil
                    let imfTitle: String
                    if let metaTitle = capturedRequest.imfMetadata?.contentTitleText, !metaTitle.isEmpty {
                        imfTitle = metaTitle
                    } else {
                        imfTitle = capturedInputBaseName
                    }
                    let audioLanguage = capturedRequest.imfMetadata?.audioLanguage ?? "en"
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
                        case .extracted(let url, _):
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

                            // Fit the WAV to the picture frame count. Every CPL sequence must
                            // last as long as the picture, so a short track file is invalid and
                            // a long one only carries samples the composition never plays.
                            let duration = effectiveDurationBox.value ?? totalDurationBox.value
                            let pictureFrameCount = Self.resolvedIMFPictureFrameCount(
                                exactFrameCount: exactPictureFrameCount,
                                duration: duration,
                                editRateNumerator: frameRate.editRateNumerator,
                                editRateDenominator: frameRate.editRateDenominator
                            )
                            let wavURL: URL
                            if pictureFrameCount > 0,
                               let fitted = await self?.fitWAVToFrameCount(
                                   conversionID: conversionID,
                                   inputWAV: originalWavURL,
                                   frameCount: pictureFrameCount,
                                   editRateNumerator: frameRate.editRateNumerator,
                                   editRateDenominator: frameRate.editRateDenominator,
                                   ffmpegPath: capturedFfmpegPath
                               ) {
                                wavURL = fitted
                                Self.cleanupTempFile(at: originalWavURL, label: "IMF audio WAV (pre-fit)")
                            } else {
                                wavURL = originalWavURL
                                errorReason = String(localized: "IMF audio wrap failed: could not fit the audio to the picture duration", comment: "Shown when ffmpeg cannot pad or trim the extracted IMF audio to the exact picture length.")
                                success = false
                            }

                            // IMF audio track files must carry an MCA soundfield group with the
                            // spoken language. Layouts other than mono/stereo/5.1/7.1 stay unlabelled.
                            var mcaLabelsURL: URL? = nil
                            if success, let channelCount = Self.wavChannelCount(at: wavURL) {
                                let soundfieldOverride = capturedRequest.audioRoutingConfig?.outputTracks
                                    .lazy.compactMap { $0.mcaOverride?.soundfield }
                                    .first { $0.channelCount == channelCount }
                                if let labels = IMFAudioLabels(
                                    channelCount: channelCount,
                                    soundfieldOverride: soundfieldOverride,
                                    language: audioLanguage,
                                    title: imfTitle
                                ) {
                                    let labelsURL = FileManager.default.temporaryDirectory
                                        .appendingPathComponent("imf_mca_labels_\(UUID().uuidString).txt")
                                    do {
                                        try labels.bmxLabelsFile.write(to: labelsURL, atomically: true, encoding: .utf8)
                                        mcaLabelsURL = labelsURL
                                        imfAudioLabels = labels
                                    } catch {
                                        Self.logger.error("Failed to write IMF MCA labels: \(error.localizedDescription, privacy: .public)")
                                    }
                                } else {
                                    Self.logger.warning("IMF audio has \(channelCount) channels; no standard MCA layout, leaving it unlabelled")
                                }
                            }

                            // raw2bmx's IMF writer produces clip-wrapped OP1a PCM with a
                            // 48 kHz edit rate. asdcp-wrap produces a DCP-style OPAtom
                            // track with a picture edit rate, unsuitable for an IMF CPL.
                            if success, let raw2bmxPath = BinaryPathResolver.raw2bmxPath {
                                var audioWrapArgs: [String] = [
                                    "-t", "imf", "-o", tmpAudioMXF.path,
                                    "--track-map", "singlemca",
                                ]
                                if let mcaLabelsURL {
                                    audioWrapArgs.append(contentsOf: ["--track-mca-labels", "x", mcaLabelsURL.path])
                                }
                                audioWrapArgs.append(contentsOf: ["--wave", wavURL.path])
                                Self.logger.info("Launching raw2bmx for IMF audio")
                                let wrapResult = await self?.runTrackedPackageWrapper(
                                    conversionID: conversionID,
                                    executablePath: raw2bmxPath,
                                    arguments: audioWrapArgs,
                                    outputURL: tmpAudioMXF
                                ) ?? .cancelled
                                switch wrapResult {
                                case .success(let diagnostic):
                                    if !diagnostic.isEmpty {
                                        Self.logger.info("raw2bmx IMF audio output: \(diagnostic.prefix(500), privacy: .public)")
                                    }
                                    imfAudioMXF = tmpAudioMXF
                                    Self.logger.info("IMF audio essence created (raw2bmx)")
                                    progressUpdate(0.94, "Wrapping audio essence")
                                case .failed(_, let reason, let diagnostic):
                                    Self.logger.error("raw2bmx failed for IMF audio: \(diagnostic.prefix(300), privacy: .public)")
                                    errorReason = Self.dcpIMFErrorReason(
                                        base: String(localized: "IMF audio wrap failed: \(reason)", comment: "Shown when raw2bmx cannot create the IMF audio essence."),
                                        stderr: diagnostic
                                    )
                                    success = false
                                case .cancelled:
                                    errorReason = "Conversion cancelled"
                                    success = false
                                }
                            } else if success {
                                Self.logger.error("raw2bmx not found — cannot create IMF audio essence")
                                errorReason = String(localized: "IMF audio wrap failed: raw2bmx not found", comment: "Shown when the bundled raw2bmx binary cannot be located, blocking IMF audio essence creation.")
                                success = false
                            }
                            Self.cleanupTempFile(at: wavURL, label: "IMF audio WAV")
                            if let mcaLabelsURL {
                                Self.cleanupTempFile(at: mcaLabelsURL, label: "IMF MCA labels")
                            }
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
                                color: color,
                                itemMetadata: capturedRequest.imfMetadata,
                                audioLabels: imfAudioLabels,
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

                    if success, let imageSequenceSettings = capturedImageSequenceSettings {
                        let stillOwnsPostProcessing = await self?.generateImageSequenceMetadataSidecarIfOwned(
                            conversionID: conversionID,
                            originalFileName: capturedInputBaseName,
                            outputFolder: outputFolder,
                            metadata: capturedRequest.sourceMetadata,
                            cameraMetadata: capturedRequest.sourceCameraMetadata,
                            settings: imageSequenceSettings
                        ) ?? false
                        if !stillOwnsPostProcessing {
                            success = false
                            errorReason = "Conversion cancelled"
                        }
                    }
                }

                let stillOwned: Bool
                if let self {
                    stillOwned = await self.finishPostProcessing(if: conversionID)
                } else {
                    _ = await bmxService.finishCancellationTracking(operationID: conversionID)
                    stillOwned = false
                }
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
            currentSubprocessTask = makeJoinableSubprocessTask(conversionID: conversionID) {
                do {
                    let pipelineResult = try await runner.runPipeline(
                        producer: decoderRequest,
                        consumer: subprocessRequest,
                        consumerOutputHandler: { chunk in
                            Self.$runningSubprocessID.withValue(conversionID) {
                                guard case .standardError = chunk.stream else { return }
                                progressStreamParser.consume(chunk.data)
                            }
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
        currentSubprocessTask = makeJoinableSubprocessTask(conversionID: conversionID) {
            do {
                let result = try await runner.run(subprocessRequest) { chunk in
                    Self.$runningSubprocessID.withValue(conversionID) {
                        guard case .standardError = chunk.stream else { return }
                        progressStreamParser.consume(chunk.data)
                    }
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

    /// Ordinary FFmpeg and decoder tasks only own bounded runner execution; their
    /// post-processing is dispatched separately. Native waveform tasks still own
    /// framework/probe post-processing and deliberately remain outside this join.
    private func makeJoinableSubprocessTask(
        conversionID: UUID,
        operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        joinableSubprocessID = conversionID
        return Task {
            await Self.$runningSubprocessID.withValue(conversionID) {
                await operation()
            }
        }
    }

    private func cancelRecursiveConversion(operationID: UUID) async {
        // A late cancellation handler must never stop a replacement operation.
        guard recursiveOperationID == operationID else { return }
        await cancelConversion()
    }

    func cancelConversion() async {
        recursiveOperationID = nil
        let imageSequenceAudioTask = currentImageSequenceAudioTask
        let imageSequenceAudioID = currentImageSequenceAudioTaskID
        let packageAudioTask = currentPackageAudioTask
        let packageAudioID = currentPackageAudioTaskID
        let packagePreparationTask = currentPackagePreparationTask
        let packagePreparationID = currentPackagePreparationTaskID
        let packageWrapperTask = currentPackageWrapperTask
        let packageWrapperID = currentPackageWrapperTaskID
        let avcIntraPreprocessingTask = currentAVCIntraPreprocessingTask
        let avcIntraPreprocessingID = currentAVCIntraPreprocessingTaskID
        let av2HelperTask = currentAV2HelperTask
        let av2HelperID = currentAV2HelperTaskID
        let mcaLabelTask = currentMCALabelTask
        let mcaLabelTaskID = currentMCALabelTaskID
        let av2PipelineTasks = currentAV2PipelineTasks
        let av2FileTasks = currentAV2FileTasks
        let waveformAnalysisTask = currentWaveformAnalysisTask
        let waveformAnalysisID = currentWaveformAnalysisID
        let waveformEncodingTask = currentWaveformEncodingTask
        let waveformEncodingID = currentWaveformEncodingID
        let subprocessTask = currentSubprocessTask
        let subprocessID = joinableSubprocessID
        joinableSubprocessID = nil
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
        currentWaveformEncodingTask?.cancel()
        currentWaveformEncodingTask = nil
        currentWaveformEncodingID = nil
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
        currentEndCutListingTask?.cancel()
        currentEndCutListingTask = nil
        currentLoudnessMeasurementTask?.cancel()
        currentLoudnessMeasurementTask = nil
        currentAV2HelperTask?.cancel()
        currentAV2HelperTask = nil
        currentAV2HelperTaskID = nil
        currentMCALabelTask?.cancel()
        currentMCALabelTask = nil
        currentMCALabelTaskID = nil
        for task in currentAV2PipelineTasks.values { task.cancel() }
        currentAV2PipelineTasks.removeAll()
        av2CancellationToken = UUID()
        for work in currentAV2FileTasks.values { work.cancel() }
        currentAV2FileTasks.removeAll()
        // Tracking belongs to the post-processing callback, which may still be
        // between its ownership check and entering the BMX actor.
        if let bmxOperationID {
            await bmxService.cancel(operationID: bmxOperationID)
        }
        // Capture and detach before suspending: a replacement conversion may be
        // installed while the old runner drains. Never join from inside that same
        // runner (including injected runners that synchronously request cancellation).
        if let subprocessID, Self.runningSubprocessID != subprocessID {
            await subprocessTask?.value
        }
        // Native analysis owns a bounded decoder plus cancellation-aware FFT work.
        if let waveformAnalysisID, Self.runningSubprocessID != waveformAnalysisID {
            _ = await waveformAnalysisTask?.result
        }
        // Join only the native encoder, not its later framework/MCA post-processing.
        if let waveformEncodingID, Self.runningSubprocessID != waveformEncodingID {
            _ = await waveformEncodingTask?.result
        }
        // Helper probes use non-joining deadlines; the task still owns its runner
        // and bounded file work. Detach every handle before waiting so late completion
        // cannot clear a replacement conversion.
        if let imageSequenceAudioID, Self.runningSubprocessID != imageSequenceAudioID {
            _ = await imageSequenceAudioTask?.result
        }
        if let packageAudioID, Self.runningSubprocessID != packageAudioID {
            _ = await packageAudioTask?.result
        }
        if let packagePreparationID, Self.runningSubprocessID != packagePreparationID {
            _ = await packagePreparationTask?.result
        }
        if let packageWrapperID, Self.runningSubprocessID != packageWrapperID {
            _ = await packageWrapperTask?.result
        }
        if let avcIntraPreprocessingID, Self.runningSubprocessID != avcIntraPreprocessingID {
            _ = await avcIntraPreprocessingTask?.result
        }
        if let av2HelperID, Self.runningSubprocessID != av2HelperID {
            _ = await av2HelperTask?.result
        }
        if let mcaLabelTaskID, Self.runningSubprocessID != mcaLabelTaskID {
            _ = await mcaLabelTask?.result
        }
        for (id, work) in av2FileTasks where Self.runningSubprocessID != id { await work.drain.value }
        for (pipelineID, task) in av2PipelineTasks where Self.runningSubprocessID != pipelineID {
            _ = await task.result
        }
    }

    func clearWaveformEncoding(if encodingID: UUID) {
        guard currentWaveformEncodingID == encodingID else { return }
        currentWaveformEncodingTask = nil
        currentWaveformEncodingID = nil
    }

    @discardableResult
    func finishTrackedConversion(_ conversionID: UUID) async -> Bool {
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
            await bmxService.prepareCancellationTracking(operationID: conversionID)
            guard activeConversionID == conversionID else {
                _ = await bmxService.finishCancellationTracking(operationID: conversionID)
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
        // The callback owns tracking until its last possible BMX handoff. A stop
        // must leave the cancellation tombstone intact across that actor hop.
        _ = await bmxService.finishCancellationTracking(operationID: conversionID)
        guard postProcessingConversionID == conversionID else { return false }
        postProcessingConversionID = nil
        if activeBMXOperationID == conversionID {
            activeBMXOperationID = nil
        }
        return true
    }

    func activateBMXOperationIfActiveConversion(_ conversionID: UUID) async -> Bool {
        guard activeConversionID == conversionID else { return false }
        await bmxService.prepareCancellationTracking(operationID: conversionID)
        guard activeConversionID == conversionID else {
            _ = await bmxService.finishCancellationTracking(operationID: conversionID)
            return false
        }
        activeBMXOperationID = conversionID
        return true
    }

    func clearActiveBMXOperation(if conversionID: UUID) {
        if activeBMXOperationID == conversionID {
            activeBMXOperationID = nil
        }
    }

    private func isPostProcessing(_ conversionID: UUID) -> Bool {
        postProcessingConversionID == conversionID
    }

    func clearWaveformAnalysis(if analysisID: UUID) {
        guard currentWaveformAnalysisID == analysisID else { return }
        currentWaveformAnalysisTask = nil
        currentWaveformAnalysisID = nil
    }

    func isActiveConversion(_ conversionID: UUID) -> Bool {
        activeConversionID == conversionID
    }

    /// Tracks the optional matte sidecar so `finish` can release, keep or remove it.
    final class MatteSidecarBox: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: (url: URL?.none, isWritten: false))

        var url: URL? { state.withLock { $0.url } }
        var isWritten: Bool { state.withLock { $0.isWritten } }

        /// Reserves a unique `_matte` path next to the main output and registers it as app-created.
        func reserve(for outputURL: URL, notOverwriting inputURL: URL, owner: UUID) -> URL {
            let matteURL = FFMPEGConverter.outputReservations.reserveUnique(
                FFMPEGCommandBuilder.matteSidecarURL(for: outputURL),
                notOverwriting: inputURL,
                owner: owner
            )
            FileSafetyUtils.registerCreatedFile(matteURL)
            state.withLock { $0.url = matteURL }
            return matteURL
        }

        /// Gives the reservation back when the command will not write a matte after all.
        func cancelReservation(owner: UUID) {
            guard let matteURL = state.withLock({ state -> URL? in
                defer { state.url = nil }
                return state.url
            }) else { return }
            _ = FFMPEGConverter.outputReservations.release(matteURL, owner: owner)
            FileSafetyUtils.unregisterCreatedFile(matteURL)
        }

        func markWritten() { state.withLock { $0.isWritten = true } }
    }

    final class DurationBox: Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: Optional<Double>.none)

        var value: Double? {
            get { lock.withLock { $0 } }
            set { lock.withLock { $0 = newValue } }
        }
    }

    /// Counts avmenc's `POC:` progress markers across arbitrary stdout chunk boundaries without
    /// retaining the rest of its verbose per-frame output.
    final class AV2POCStreamParser: @unchecked Sendable {
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
    final class FFMPEGProgressStreamParser: @unchecked Sendable {
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

}
