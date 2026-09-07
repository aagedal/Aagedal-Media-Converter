// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

protocol WhisperModelProviding: Sendable {
    func modelPath(for model: WhisperModel) -> URL
    func isModelDownloaded(_ model: WhisperModel) -> Bool
}

extension WhisperModelManager: WhisperModelProviding {}

/// Service for generating subtitles using FFmpeg's built-in whisper filter
actor WhisperService {
    static let shared = WhisperService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "WhisperService")
    private let modelManager: any WhisperModelProviding
    private let transcriber: WhisperFFmpegTranscriber
    private let ffmpegPathProvider: @Sendable () -> String?

    private var activeRunIDs: Set<UUID> = []
    private var cancelledRunIDs: Set<UUID> = []
    private var cancelledOperationIDs: Set<UUID> = []
    private var runIDsByOperationID: [UUID: Set<UUID>] = [:]
    private var currentTranscriptionTasks: [UUID: Task<Void, Error>] = [:]
    private var reservedOutputPaths: Set<String> = []

    init(
        modelManager: any WhisperModelProviding = WhisperModelManager.shared,
        subprocessRunner: any SubprocessRunning = SubprocessRunner(),
        ffmpegPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.ffmpegPath }
    ) {
        self.modelManager = modelManager
        transcriber = WhisperFFmpegTranscriber(subprocessRunner: subprocessRunner)
        self.ffmpegPathProvider = ffmpegPathProvider
    }

    /// Generates SRT subtitle file from video/audio using FFmpeg whisper filter
    /// - Parameters:
    ///   - inputFile: The input video or audio file
    ///   - outputDirectory: Directory to save the SRT file
    ///   - model: The whisper model to use
    ///   - language: Language code (or "auto" for auto-detect)
    ///   - maxLineLength: Maximum characters per subtitle line (currently unused by FFmpeg filter)
    ///   - progress: Callback for progress updates
    /// - Returns: URL to the generated .srt file
    func generateSubtitles(
        inputFile: URL,
        outputDirectory: URL,
        model: WhisperModel,
        language: String,
        operationID: UUID,
        audioStreamIndex: Int? = nil,
        maxLineLength: Int? = nil,
        progress: @escaping @Sendable (WhisperProgress) -> Void
    ) async throws -> URL {
        let runID = UUID()
        registerRun(runID, operationID: operationID)
        defer { finishRun(runID, operationID: operationID) }
        guard !cancelledRunIDs.contains(runID) else {
            throw WhisperServiceError.cancelled
        }

        // Verify model is downloaded
        let modelPath = modelManager.modelPath(for: model)
        guard modelManager.isModelDownloaded(model) else {
            throw WhisperServiceError.modelNotDownloaded(model)
        }

        guard let ffmpegPath = ffmpegPathProvider() else {
            throw WhisperServiceError.ffmpegNotFound
        }

        var shouldStopAccess = false
        if model.isCustom {
            shouldStopAccess = SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: modelPath)
        }
        defer {
            if shouldStopAccess {
                SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: modelPath)
            }
        }

        // Prepare output file path
        let baseName = inputFile.deletingPathExtension().lastPathComponent
        let srtFile = reserveOutputURL(directory: outputDirectory, baseName: baseName)
        defer { reservedOutputPaths.remove(srtFile.path) }
        let stagedSRTFile = outputDirectory.appendingPathComponent(
            ".whisper-\(runID.uuidString).srt"
        )
        defer { try? FileManager.default.removeItem(at: stagedSRTFile) }

        logger.info("Starting FFmpeg whisper transcription: \(model.displayName), language: \(language)")

        progress(WhisperProgress(stage: .transcribing, percentage: 0, message: "Starting transcription..."))

        guard !cancelledRunIDs.contains(runID) else {
            throw WhisperServiceError.cancelled
        }

        let transcriptionTask = Task {
            try await transcriber.transcribe(
                inputFile: inputFile,
                modelPath: modelPath,
                outputFile: stagedSRTFile,
                ffmpegPath: ffmpegPath,
                language: language,
                audioStreamIndex: audioStreamIndex,
                progress: progress
            )
        }
        currentTranscriptionTasks[runID] = transcriptionTask

        do {
            try await withTaskCancellationHandler {
                try await transcriptionTask.value
            } onCancel: {
                transcriptionTask.cancel()
            }
        } catch is CancellationError {
            throw WhisperServiceError.cancelled
        } catch {
            throw error
        }

        guard !cancelledRunIDs.contains(runID) else {
            throw WhisperServiceError.cancelled
        }
        do {
            try Task.checkCancellation()
        } catch {
            throw WhisperServiceError.cancelled
        }

        guard FileManager.default.fileExists(atPath: stagedSRTFile.path) else {
            throw WhisperServiceError.srtGenerationFailed
        }
        do {
            try publish(stagedSRTFile, to: srtFile)
        } catch {
            throw WhisperServiceError.transcriptionFailed(
                "Could not publish subtitle output"
            )
        }

        // Count segments for logging
        let segmentCount = countSRTSegments(at: srtFile)

        progress(WhisperProgress(stage: .complete, percentage: 1.0, message: nil))
        logger.info("Subtitles generated: \(srtFile.lastPathComponent) with \(segmentCount) segments")

        return srtFile
    }

    /// Generates SRT subtitle file directly from input file (no encoding)
    /// Saves the SRT alongside the input file
    func generateSubtitlesOnly(
        inputFile: URL,
        model: WhisperModel,
        language: String,
        operationID: UUID,
        audioStreamIndex: Int? = nil,
        maxLineLength: Int? = nil,
        progress: @escaping @Sendable (WhisperProgress) -> Void
    ) async throws -> URL {
        let outputDirectory = inputFile.deletingLastPathComponent()
        return try await generateSubtitles(
            inputFile: inputFile,
            outputDirectory: outputDirectory,
            model: model,
            language: language,
            operationID: operationID,
            audioStreamIndex: audioStreamIndex,
            maxLineLength: maxLineLength,
            progress: progress
        )
    }

    /// Cancels subtitle generation associated with one queue item or user operation.
    func cancelGeneration(operationID: UUID) {
        cancelledOperationIDs.insert(operationID)
        let runIDs = runIDsByOperationID[operationID] ?? []
        cancelledRunIDs.formUnion(runIDs)
        for runID in runIDs {
            currentTranscriptionTasks[runID]?.cancel()
        }
        logger.info("Subtitle generation cancelled")
    }

    /// Stops every active run during an explicit batch shutdown.
    func cancelAllGeneration() {
        cancelledRunIDs.formUnion(activeRunIDs)
        for task in currentTranscriptionTasks.values {
            task.cancel()
        }
        logger.info("All subtitle generation cancelled")
    }

    // MARK: - Private Methods

    /// Count the number of segments in an SRT file
    private func countSRTSegments(at url: URL) -> Int {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return 0
        }
        // Count lines that are just numbers (segment indices)
        let lines = content.components(separatedBy: .newlines)
        var count = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, Int(trimmed) != nil {
                count += 1
            }
        }
        return count
    }

    private func registerRun(_ runID: UUID, operationID: UUID) {
        activeRunIDs.insert(runID)
        runIDsByOperationID[operationID, default: []].insert(runID)
        if cancelledOperationIDs.contains(operationID) {
            cancelledRunIDs.insert(runID)
        }
    }

    private func finishRun(_ runID: UUID, operationID: UUID) {
        currentTranscriptionTasks.removeValue(forKey: runID)?.cancel()
        activeRunIDs.remove(runID)
        cancelledRunIDs.remove(runID)
        runIDsByOperationID[operationID]?.remove(runID)
        if runIDsByOperationID[operationID]?.isEmpty == true {
            runIDsByOperationID.removeValue(forKey: operationID)
            cancelledOperationIDs.remove(operationID)
        }
    }

    private func reserveOutputURL(directory: URL, baseName: String) -> URL {
        let preferred = SubtitleSRTNaming.outputURL(
            directory: directory,
            baseName: baseName,
            method: .whisper
        )
        if !reservedOutputPaths.contains(preferred.path) {
            reservedOutputPaths.insert(preferred.path)
            return preferred
        }

        let fileManager = FileManager.default
        let methodSpecific = outputCandidate(
            directory: directory,
            baseName: baseName,
            suffix: ".whisper"
        )
        if !reservedOutputPaths.contains(methodSpecific.path),
           !fileManager.fileExists(atPath: methodSpecific.path) {
            reservedOutputPaths.insert(methodSpecific.path)
            return methodSpecific
        }

        var suffix = 2
        while true {
            let candidate = outputCandidate(
                directory: directory,
                baseName: baseName,
                suffix: ".whisper-\(suffix)"
            )
            if !reservedOutputPaths.contains(candidate.path),
               !fileManager.fileExists(atPath: candidate.path) {
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
        while shortenedBase.utf8.count > maximumBaseBytes {
            shortenedBase.removeLast()
        }
        return directory.appendingPathComponent(shortenedBase + ending)
    }

    private func publish(_ stagedURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagedURL)
        } else {
            try fileManager.moveItem(at: stagedURL, to: destinationURL)
        }
    }
}

/// FFmpeg boundary for the built-in Whisper filter. It keeps process policy and
/// incremental parsing independently testable from model discovery and UI state.
struct WhisperFFmpegTranscriber: Sendable {
    /// Whisper can run substantially slower than real time with larger models. The
    /// limit is deliberately generous while still preventing a wedged process from
    /// occupying the conversion queue forever.
    static let timeout: Duration = .seconds(12 * 60 * 60)
    static let diagnosticCaptureLimit = 256 * 1024

    private let subprocessRunner: any SubprocessRunning

    init(subprocessRunner: any SubprocessRunning = SubprocessRunner()) {
        self.subprocessRunner = subprocessRunner
    }

    func transcribe(
        inputFile: URL,
        modelPath: URL,
        outputFile: URL,
        ffmpegPath: String,
        language: String,
        audioStreamIndex: Int?,
        progress: @escaping @Sendable (WhisperProgress) -> Void
    ) async throws {
        try Task.checkCancellation()

        let filter = Self.filter(
            modelPath: modelPath.path,
            outputPath: outputFile.path,
            language: language
        )
        var arguments = ["-nostdin", "-i", inputFile.path]
        if let audioStreamIndex {
            arguments += ["-map", "0:\(audioStreamIndex)"]
        }
        arguments += ["-af", filter, "-f", "null", "-"]

        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: arguments,
            timeout: Self.timeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: Self.diagnosticCaptureLimit,
            sensitiveValues: [inputFile.path, modelPath.path, outputFile.path, filter]
        )
        let progressParser = WhisperFFmpegProgressParser(progress: progress)

        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(request) { chunk in
                if case .standardError = chunk.stream {
                    progressParser.consume(chunk.data)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SubprocessRunnerError {
            switch error {
            case .failedToStart(_, let underlying):
                throw WhisperServiceError.transcriptionFailed(
                    request.redactedDiagnostic(underlying, limit: 500)
                )
            case .timedOut:
                throw WhisperServiceError.transcriptionFailed(
                    "FFmpeg exceeded the 12-hour transcription limit"
                )
            }
        } catch {
            throw WhisperServiceError.transcriptionFailed(
                request.redactedDiagnostic(error.localizedDescription, limit: 500)
            )
        }
        progressParser.finish()

        guard result.succeeded else {
            let diagnostic = request.redactedDiagnostic(
                result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines),
                limit: 500
            )
            let detail = diagnostic.isEmpty ? "unknown error" : diagnostic
            throw WhisperServiceError.transcriptionFailed(
                "FFmpeg exited \(result.terminationStatus): \(detail)"
            )
        }
    }

    static func filter(modelPath: String, outputPath: String, language: String) -> String {
        let components = [
            "model=\(escapeFilterOptionValue(modelPath))",
            "language=\(escapeFilterOptionValue(language))",
            "format=srt",
            "destination=\(escapeFilterOptionValue(outputPath))",
            "use_gpu=true"
        ]
        return "whisper=" + components.joined(separator: ":")
    }

    /// FFmpeg parses filter arguments twice: once as a named option list, then again as
    /// a filtergraph. Each layer has its own separators and treats backslash/apostrophe
    /// specially, so values must be escaped in this order before being passed as direct
    /// argv (with no shell-escaping layer).
    private static func escapeFilterOptionValue(_ value: String) -> String {
        let optionEscaped = escapeFFmpegToken(value, syntaxSpecials: [":"])
        return escapeFFmpegToken(
            optionEscaped,
            syntaxSpecials: ["[", "]", ",", ";"]
        )
    }

    private static func escapeFFmpegToken(
        _ value: String,
        syntaxSpecials: Set<Character>
    ) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            if character == "\\" || character == "'" || syntaxSpecials.contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }
}

private final class WhisperFFmpegProgressParser: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (WhisperProgress) -> Void
    private var duration: Double?
    private var lastReportedProgress = 0.0
    private var pendingText = ""

    init(progress: @escaping @Sendable (WhisperProgress) -> Void) {
        self.progress = progress
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
            if pendingText.count > 8 * 1024 {
                pendingText = String(pendingText.suffix(8 * 1024))
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

    private func parse(_ text: String) {
        if duration == nil {
            duration = ParsingUtils.parseDuration(from: text)
        }
        guard let (fraction, _) = ParsingUtils.parseTimeProgress(
            from: text,
            totalDuration: duration
        ) else { return }

        let cappedFraction = min(fraction, 0.99)
        guard cappedFraction - lastReportedProgress >= 0.01 else { return }
        lastReportedProgress = cappedFraction
        progress(WhisperProgress(
            stage: .transcribing,
            percentage: cappedFraction,
            message: nil
        ))
    }
}

// MARK: - Error Types

enum WhisperServiceError: Error, LocalizedError {
    case binaryNotFound
    case modelNotDownloaded(WhisperModel)
    case ffmpegNotFound
    case audioExtractionFailed
    case transcriptionFailed(String)
    case srtGenerationFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "FFmpeg with whisper support not found"
        case .modelNotDownloaded(let model):
            return "Model '\(model.displayName)' is not downloaded. Please download it in Settings."
        case .ffmpegNotFound:
            return "FFmpeg not found"
        case .audioExtractionFailed:
            return "Failed to extract audio from video"
        case .transcriptionFailed(let message):
            return "Transcription failed: \(message)"
        case .srtGenerationFailed:
            return "Failed to generate SRT file"
        case .cancelled:
            return "Subtitle generation was cancelled"
        }
    }
}
