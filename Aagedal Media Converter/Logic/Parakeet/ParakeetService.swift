// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Service for generating subtitles using parakeet-mlx CLI.
actor ParakeetService {
    static let shared = ParakeetService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ParakeetService")
    private let transcriber: ParakeetCLITranscriber
    private let audioExtractor: ParakeetAudioExtractor
    private let parakeetPathProvider: @Sendable () -> String?
    private let ffmpegPathProvider: @Sendable () -> String?
    private let chunkDurationProvider: @Sendable () -> Int
    private let overlapDurationProvider: @Sendable () -> Int

    private var activeRunIDs: Set<UUID> = []
    private var cancelledRunIDs: Set<UUID> = []
    private var cancelledOperationIDs: Set<UUID> = []
    private var runIDsByOperationID: [UUID: Set<UUID>] = [:]
    private var currentGenerationTasks: [UUID: Task<Void, Error>] = [:]
    private var reservedOutputPaths: Set<String> = []

    init(
        subprocessRunner: any SubprocessRunning = SubprocessRunner(),
        parakeetPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.parakeetMlxPath },
        ffmpegPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.ffmpegPath },
        chunkDurationProvider: @escaping @Sendable () -> Int = {
            UserDefaults.standard.integer(forKey: AppConstants.parakeetChunkDurationKey)
        },
        overlapDurationProvider: @escaping @Sendable () -> Int = {
            UserDefaults.standard.integer(forKey: AppConstants.parakeetOverlapDurationKey)
        }
    ) {
        transcriber = ParakeetCLITranscriber(subprocessRunner: subprocessRunner)
        audioExtractor = ParakeetAudioExtractor(subprocessRunner: subprocessRunner)
        self.parakeetPathProvider = parakeetPathProvider
        self.ffmpegPathProvider = ffmpegPathProvider
        self.chunkDurationProvider = chunkDurationProvider
        self.overlapDurationProvider = overlapDurationProvider
    }

    func generateSubtitles(
        inputFile: URL,
        outputDirectory: URL,
        model: ParakeetModel,
        language: String?,
        operationID: UUID,
        audioStreamIndex: Int? = nil,
        progress: @escaping @Sendable (ParakeetProgress) -> Void
    ) async throws -> URL {
        let runID = UUID()
        registerRun(runID, operationID: operationID)
        defer { finishRun(runID, operationID: operationID) }
        guard !cancelledRunIDs.contains(runID) else { throw ParakeetServiceError.cancelled }

        guard let parakeetPath = parakeetPathProvider() else {
            throw ParakeetServiceError.binaryNotFound
        }
        let ffmpegPath: String?
        if audioStreamIndex != nil {
            guard let resolved = ffmpegPathProvider() else {
                throw ParakeetServiceError.ffmpegNotFound
            }
            ffmpegPath = resolved
        } else {
            ffmpegPath = ffmpegPathProvider()
        }

        let baseName = inputFile.deletingPathExtension().lastPathComponent
        let finalSRT = reserveOutputURL(directory: outputDirectory, baseName: baseName)
        defer { reservedOutputPaths.remove(finalSRT.path) }

        let stagingDirectory = outputDirectory.appendingPathComponent(
            ".parakeet-\(runID.uuidString)", isDirectory: true
        )
        let temporaryAudio = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-\(runID.uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: temporaryAudio)
            try? FileManager.default.removeItem(at: stagingDirectory)
        }

        logger.info("Starting Parakeet transcription with \(model.displayName, privacy: .public), language setting: \(language ?? "default", privacy: .public)")
        progress(ParakeetProgress(stage: .transcribing, percentage: 0, message: "Starting transcription..."))

        let chunkDuration = chunkDurationProvider()
        let overlapDuration = overlapDurationProvider()
        let transcriber = self.transcriber
        let audioExtractor = self.audioExtractor
        let generationTask = Task {
            try Task.checkCancellation()
            var transcriptionInput = inputFile
            if let audioStreamIndex, let ffmpegPath {
                progress(ParakeetProgress(stage: .extractingAudio, percentage: 0, message: "Extracting audio track..."))
                try await audioExtractor.extract(
                    inputFile: inputFile,
                    outputFile: temporaryAudio,
                    ffmpegPath: ffmpegPath,
                    audioStreamIndex: audioStreamIndex
                )
                transcriptionInput = temporaryAudio
            }

            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)

            // parakeet-mlx derives the SRT name from the input basename. A short run-local
            // symlink gives it a deterministic staging name without copying large media.
            let extensionSuffix = transcriptionInput.pathExtension.isEmpty
                ? "" : ".\(transcriptionInput.pathExtension)"
            let stagedInput = stagingDirectory.appendingPathComponent("input" + extensionSuffix)
            try FileManager.default.createSymbolicLink(at: stagedInput, withDestinationURL: transcriptionInput)

            progress(ParakeetProgress(stage: .transcribing, percentage: 0.01, message: "Transcribing..."))
            try await transcriber.transcribe(
                inputFile: stagedInput,
                outputDirectory: stagingDirectory,
                parakeetPath: parakeetPath,
                ffmpegPath: ffmpegPath,
                modelID: model.id,
                chunkDuration: chunkDuration,
                overlapDuration: overlapDuration,
                progress: progress
            )
        }
        currentGenerationTasks[runID] = generationTask

        do {
            try await withTaskCancellationHandler {
                try await generationTask.value
            } onCancel: {
                generationTask.cancel()
            }
        } catch is CancellationError {
            throw ParakeetServiceError.cancelled
        } catch let error as ParakeetServiceError {
            throw error
        } catch {
            throw ParakeetServiceError.transcriptionFailed(
                "Could not prepare transcription staging"
            )
        }

        guard !cancelledRunIDs.contains(runID) else { throw ParakeetServiceError.cancelled }
        do { try Task.checkCancellation() } catch { throw ParakeetServiceError.cancelled }

        let stagedSRT = stagingDirectory.appendingPathComponent("input.srt")
        guard FileManager.default.fileExists(atPath: stagedSRT.path) else {
            throw ParakeetServiceError.srtGenerationFailed
        }
        do {
            try publish(stagedSRT, to: finalSRT)
        } catch {
            throw ParakeetServiceError.transcriptionFailed("Could not publish subtitle output")
        }

        progress(ParakeetProgress(stage: .complete, percentage: 1, message: nil))
        logger.info("Subtitles generated: \(finalSRT.lastPathComponent, privacy: .public)")
        return finalSRT
    }

    func generateSubtitlesOnly(
        inputFile: URL,
        model: ParakeetModel,
        language: String?,
        operationID: UUID,
        audioStreamIndex: Int? = nil,
        progress: @escaping @Sendable (ParakeetProgress) -> Void
    ) async throws -> URL {
        try await generateSubtitles(
            inputFile: inputFile,
            outputDirectory: inputFile.deletingLastPathComponent(),
            model: model,
            language: language,
            operationID: operationID,
            audioStreamIndex: audioStreamIndex,
            progress: progress
        )
    }

    func cancelGeneration(operationID: UUID) {
        cancelledOperationIDs.insert(operationID)
        let runIDs = runIDsByOperationID[operationID] ?? []
        cancelledRunIDs.formUnion(runIDs)
        for runID in runIDs { currentGenerationTasks[runID]?.cancel() }
        logger.info("Parakeet subtitle generation cancelled")
    }

    func cancelAllGeneration() {
        cancelledRunIDs.formUnion(activeRunIDs)
        for task in currentGenerationTasks.values { task.cancel() }
        logger.info("All Parakeet subtitle generation cancelled")
    }

    private static let cachedIsAvailable = BinaryPathResolver.parakeetMlxPath != nil

    nonisolated func getInstallationStatus() -> ParakeetInstallationStatus {
        guard Self.cachedIsAvailable else { return .notInstalled }
        return .installed(version: "parakeet-mlx")
    }

    private func registerRun(_ runID: UUID, operationID: UUID) {
        activeRunIDs.insert(runID)
        runIDsByOperationID[operationID, default: []].insert(runID)
        if cancelledOperationIDs.contains(operationID) { cancelledRunIDs.insert(runID) }
    }

    private func finishRun(_ runID: UUID, operationID: UUID) {
        currentGenerationTasks.removeValue(forKey: runID)?.cancel()
        activeRunIDs.remove(runID)
        cancelledRunIDs.remove(runID)
        runIDsByOperationID[operationID]?.remove(runID)
        if runIDsByOperationID[operationID]?.isEmpty == true {
            runIDsByOperationID.removeValue(forKey: operationID)
            cancelledOperationIDs.remove(operationID)
        }
    }

    private func reserveOutputURL(directory: URL, baseName: String) -> URL {
        let preferred = SubtitleSRTNaming.outputURL(directory: directory, baseName: baseName, method: .parakeet)
        if !reservedOutputPaths.contains(preferred.path) {
            reservedOutputPaths.insert(preferred.path)
            return preferred
        }

        let methodSpecific = outputCandidate(directory: directory, baseName: baseName, suffix: ".parakeet")
        if !reservedOutputPaths.contains(methodSpecific.path),
           !FileManager.default.fileExists(atPath: methodSpecific.path) {
            reservedOutputPaths.insert(methodSpecific.path)
            return methodSpecific
        }

        var suffix = 2
        while true {
            let candidate = outputCandidate(directory: directory, baseName: baseName, suffix: ".parakeet-\(suffix)")
            if !reservedOutputPaths.contains(candidate.path),
               !FileManager.default.fileExists(atPath: candidate.path) {
                reservedOutputPaths.insert(candidate.path)
                return candidate
            }
            suffix += 1
        }
    }

    private func outputCandidate(directory: URL, baseName: String, suffix: String) -> URL {
        let ending = suffix + ".srt"
        let maximumBaseBytes = max(255 - ending.utf8.count, 1)
        var shortenedBase = baseName
        while shortenedBase.utf8.count > maximumBaseBytes { shortenedBase.removeLast() }
        return directory.appendingPathComponent(shortenedBase + ending)
    }

    private func publish(_ stagedURL: URL, to destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagedURL)
        } else {
            try FileManager.default.moveItem(at: stagedURL, to: destinationURL)
        }
    }
}

/// FFmpeg boundary used when one specific audio stream must be handed to Parakeet.
struct ParakeetAudioExtractor: Sendable {
    static let timeout: Duration = .seconds(2 * 60 * 60)
    static let diagnosticCaptureLimit = 256 * 1024
    private let subprocessRunner: any SubprocessRunning

    init(subprocessRunner: any SubprocessRunning = SubprocessRunner()) {
        self.subprocessRunner = subprocessRunner
    }

    func extract(inputFile: URL, outputFile: URL, ffmpegPath: String, audioStreamIndex: Int) async throws {
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: [
                "-y", "-nostdin", "-i", inputFile.path, "-map", "0:\(audioStreamIndex)",
                "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1", outputFile.path
            ],
            timeout: Self.timeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: Self.diagnosticCaptureLimit,
            sensitiveValues: [inputFile.path, outputFile.path]
        )

        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SubprocessRunnerError {
            switch error {
            case .failedToStart(_, let underlying):
                throw ParakeetServiceError.audioExtractionFailed(request.redactedDiagnostic(underlying, limit: 500))
            case .timedOut:
                throw ParakeetServiceError.audioExtractionFailed("FFmpeg exceeded the two-hour audio extraction limit")
            }
        } catch {
            throw ParakeetServiceError.audioExtractionFailed(request.redactedDiagnostic(error.localizedDescription, limit: 500))
        }

        guard result.succeeded else {
            let diagnostic = request.redactedDiagnostic(
                result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines), limit: 500
            )
            throw ParakeetServiceError.audioExtractionFailed(
                "FFmpeg exited \(result.terminationStatus): \(diagnostic.isEmpty ? "unknown error" : diagnostic)"
            )
        }
    }
}

/// parakeet-mlx boundary that keeps process policy and output parsing independently testable.
struct ParakeetCLITranscriber: Sendable {
    static let timeout: Duration = .seconds(12 * 60 * 60)
    static let diagnosticCaptureLimit = 256 * 1024
    private let subprocessRunner: any SubprocessRunning

    init(subprocessRunner: any SubprocessRunning = SubprocessRunner()) {
        self.subprocessRunner = subprocessRunner
    }

    func transcribe(
        inputFile: URL,
        outputDirectory: URL,
        parakeetPath: String,
        ffmpegPath: String?,
        modelID: String,
        chunkDuration: Int,
        overlapDuration: Int,
        progress: @escaping @Sendable (ParakeetProgress) -> Void
    ) async throws {
        try Task.checkCancellation()
        var arguments = [
            inputFile.path, "--output-format", "srt", "--output-dir", outputDirectory.path,
            "--model", modelID
        ]
        if chunkDuration > 0, chunkDuration != AppConstants.defaultParakeetChunkDuration {
            arguments += ["--chunk-duration", "\(chunkDuration)"]
        }
        if overlapDuration > 0, overlapDuration != AppConstants.defaultParakeetOverlapDuration {
            arguments += ["--overlap-duration", "\(overlapDuration)"]
        }

        let extraPathEntries = ffmpegPath.map { [($0 as NSString).deletingLastPathComponent] } ?? []
        let configuration = HomebrewPythonExecutor.pythonToolExecutionConfiguration(
            scriptPath: parakeetPath,
            arguments: arguments,
            extraPathEntries: extraPathEntries
        )

        let request = SubprocessRequest(
            executableURL: configuration.executableURL,
            arguments: configuration.arguments,
            environment: configuration.environment,
            timeout: Self.timeout,
            standardOutputCaptureLimit: Self.diagnosticCaptureLimit,
            standardErrorCaptureLimit: Self.diagnosticCaptureLimit,
            sensitiveValues: [inputFile.path, outputDirectory.path, parakeetPath]
        )
        let progressParser = ParakeetProgressParser(progress: progress)

        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(request) { chunk in
                progressParser.consume(chunk)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SubprocessRunnerError {
            switch error {
            case .failedToStart(_, let underlying):
                throw ParakeetServiceError.transcriptionFailed(request.redactedDiagnostic(underlying, limit: 500))
            case .timedOut:
                throw ParakeetServiceError.transcriptionFailed("parakeet-mlx exceeded the 12-hour transcription limit")
            }
        } catch {
            throw ParakeetServiceError.transcriptionFailed(request.redactedDiagnostic(error.localizedDescription, limit: 500))
        }
        progressParser.finish()

        guard result.succeeded else {
            let combined = [result.standardErrorText, result.standardOutputText]
                .filter { !$0.isEmpty }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let diagnostic = request.redactedDiagnostic(combined, limit: 500)
            throw ParakeetServiceError.transcriptionFailed(
                "parakeet-mlx exited \(result.terminationStatus): \(diagnostic.isEmpty ? "unknown error" : diagnostic)"
            )
        }
    }
}

private final class ParakeetProgressParser: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (ParakeetProgress) -> Void
    private var lastReportedProgress = 0.01
    private var pendingStandardOutput = ""
    private var pendingStandardError = ""

    init(progress: @escaping @Sendable (ParakeetProgress) -> Void) { self.progress = progress }

    func consume(_ chunk: SubprocessOutputChunk) {
        guard !chunk.data.isEmpty else { return }
        lock.withLock {
            let records: [String]
            switch chunk.stream {
            case .standardOutput:
                records = Self.append(chunk.data, to: &pendingStandardOutput)
            case .standardError:
                records = Self.append(chunk.data, to: &pendingStandardError)
            }
            for record in records { parse(record) }
        }
    }

    func finish() {
        lock.withLock {
            for record in [pendingStandardOutput, pendingStandardError] where !record.isEmpty {
                parse(record)
            }
            pendingStandardOutput = ""
            pendingStandardError = ""
        }
    }

    private static func append(_ data: Data, to buffer: inout String) -> [String] {
        var records: [String] = []
        buffer += String(decoding: data, as: UTF8.self)
        while let separator = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            records.append(String(buffer[..<separator]))
            buffer.removeSubrange(...separator)
        }
        if buffer.count > 8 * 1024 { buffer = String(buffer.suffix(8 * 1024)) }
        return records
    }

    private func parse(_ text: String) {
        var parsedProgress: Double?
        if let match = text.range(of: #"(\d+)/(\d+)"#, options: .regularExpression) {
            let parts = text[match].split(separator: "/")
            if parts.count == 2, let current = Double(parts[0]), let total = Double(parts[1]), total > 0 {
                parsedProgress = current / total
            }
        }
        if let match = text.range(of: #"(\d+(?:\.\d+)?)%"#, options: .regularExpression),
           let percentage = Double(text[match].dropLast()) {
            parsedProgress = max(parsedProgress ?? 0, percentage / 100)
        }

        guard let parsedProgress else { return }
        let bounded = min(max(parsedProgress, 0), 0.99)
        guard bounded - lastReportedProgress >= 0.01 else { return }
        lastReportedProgress = bounded
        progress(ParakeetProgress(stage: .transcribing, percentage: bounded, message: nil))
    }
}

enum ParakeetServiceError: Error, LocalizedError {
    case binaryNotFound
    case modelNotDownloaded(ParakeetModel)
    case ffmpegNotFound
    case audioExtractionFailed(String? = nil)
    case transcriptionFailed(String)
    case srtGenerationFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "parakeet-mlx not found. Install with: pip install -U parakeet-mlx"
        case .modelNotDownloaded(let model):
            return "Model '\(model.displayName)' is not downloaded. It will be downloaded on first use."
        case .ffmpegNotFound:
            return "FFmpeg not found"
        case .audioExtractionFailed(let detail):
            return detail.map { "Failed to extract audio from video: \($0)" } ?? "Failed to extract audio from video"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .srtGenerationFailed:
            return "Failed to generate SRT file"
        case .cancelled:
            return "Subtitle generation was cancelled"
        }
    }
}
