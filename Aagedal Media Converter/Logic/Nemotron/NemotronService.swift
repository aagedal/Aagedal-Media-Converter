// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

/// Service for generating subtitles using NeMo Speech CLI.
actor NemotronService {
    static let shared = NemotronService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "NemotronService")
    private let transcriber: NemotronCLITranscriber
    private let audioExtractor: NemotronAudioExtractor
    private let nemotronPathProvider: @Sendable () -> String?
    private let ffmpegPathProvider: @Sendable () -> String?

    private var activeRunIDs: Set<UUID> = []
    private var publicationsByRunID: [UUID: SubtitleSRTPublication] = [:]
    private var cancelledRunIDs: Set<UUID> = []
    private var cancelledOperationIDs: Set<UUID> = []
    private var runIDsByOperationID: [UUID: Set<UUID>] = [:]
    private var currentGenerationTasks: [UUID: Task<Void, Error>] = [:]

    init(
        subprocessRunner: any SubprocessRunning = SubprocessRunner(),
        nemotronPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.nemotronPath },
        ffmpegPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.ffmpegPath }
    ) {
        transcriber = NemotronCLITranscriber(subprocessRunner: subprocessRunner)
        audioExtractor = NemotronAudioExtractor(subprocessRunner: subprocessRunner)
        self.nemotronPathProvider = nemotronPathProvider
        self.ffmpegPathProvider = ffmpegPathProvider
    }

    func generateSubtitles(
        inputFile: URL,
        outputDirectory: URL,
        model: String,
        language: String?,
        operationID: UUID,
        audioStreamIndex: Int? = nil,
        publicationIsCurrent: @escaping @MainActor @Sendable () -> Bool = { true },
        progress: @escaping @Sendable (NemotronProgress) -> Void
    ) async throws -> URL {
        let runID = UUID()
        let publication = registerRun(runID, operationID: operationID)
        defer { finishRun(runID, operationID: operationID) }
        guard !cancelledRunIDs.contains(runID) else { throw NemotronServiceError.cancelled }

        guard let nemotronPath = nemotronPathProvider() else {
            throw NemotronServiceError.binaryNotFound
        }
        guard let ffmpegPath = ffmpegPathProvider() else { throw NemotronServiceError.ffmpegNotFound }

        let reservation = SubtitleSRTNaming.shared.reserve(
            directory: outputDirectory, sourceFile: inputFile, method: .nemotron
        )
        defer { reservation.release() }
        let finalSRT = reservation.url

        let stagingDirectory = outputDirectory.appendingPathComponent(
            ".nemotron-\(runID.uuidString)", isDirectory: true
        )
        let temporaryAudio = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemotron-\(runID.uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: temporaryAudio)
            try? FileManager.default.removeItem(at: stagingDirectory)
        }

        logger.info("Starting Nemotron transcription with \(model, privacy: .public), language setting: \(language ?? "default", privacy: .public)")
        progress(NemotronProgress(stage: .transcribing, percentage: 0, message: "Starting transcription..."))

        let transcriber = self.transcriber
        let audioExtractor = self.audioExtractor
        let generationTask = Task {
            try Task.checkCancellation()
            progress(NemotronProgress(stage: .extractingAudio, percentage: 0, message: "Extracting audio..."))
            try await audioExtractor.extract(
                inputFile: inputFile, outputFile: temporaryAudio,
                ffmpegPath: ffmpegPath, audioStreamIndex: audioStreamIndex
            )
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
            progress(NemotronProgress(stage: .transcribing, percentage: 0.01, message: "Transcribing..."))
            try await transcriber.transcribe(
                inputFile: temporaryAudio,
                outputFile: stagingDirectory.appendingPathComponent("input.srt"),
                nemotronPath: nemotronPath, modelID: model,
                language: Self.normalizedLanguage(language)
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
            throw NemotronServiceError.cancelled
        } catch let error as NemotronServiceError {
            throw error
        } catch {
            throw NemotronServiceError.transcriptionFailed(
                "Could not prepare transcription staging"
            )
        }

        guard !cancelledRunIDs.contains(runID) else { throw NemotronServiceError.cancelled }
        do { try Task.checkCancellation() } catch { throw NemotronServiceError.cancelled }

        let stagedSRT = stagingDirectory.appendingPathComponent("input.srt")
        guard FileManager.default.fileExists(atPath: stagedSRT.path) else {
            throw NemotronServiceError.srtGenerationFailed
        }
        do {
            try await publication.publish(
                stagedURL: stagedSRT,
                reservation: reservation,
                isCurrent: publicationIsCurrent
            )
        } catch is CancellationError {
            throw NemotronServiceError.cancelled
        } catch {
            throw NemotronServiceError.transcriptionFailed("Could not publish subtitle output")
        }

        progress(NemotronProgress(stage: .complete, percentage: 1, message: nil))
        logger.info("Subtitles generated: \(finalSRT.lastPathComponent, privacy: .public)")
        return finalSRT
    }

    func generateSubtitlesOnly(
        inputFile: URL,
        model: String,
        language: String?,
        operationID: UUID,
        audioStreamIndex: Int? = nil,
        publicationIsCurrent: @escaping @MainActor @Sendable () -> Bool = { true },
        progress: @escaping @Sendable (NemotronProgress) -> Void
    ) async throws -> URL {
        try await generateSubtitles(
            inputFile: inputFile,
            outputDirectory: inputFile.deletingLastPathComponent(),
            model: model,
            language: language,
            operationID: operationID,
            audioStreamIndex: audioStreamIndex,
            publicationIsCurrent: publicationIsCurrent,
            progress: progress
        )
    }

    func cancelGeneration(operationID: UUID) {
        cancelledOperationIDs.insert(operationID)
        let runIDs = runIDsByOperationID[operationID] ?? []
        cancelledRunIDs.formUnion(runIDs)
        for runID in runIDs { publicationsByRunID[runID]?.cancel() }
        for runID in runIDs { currentGenerationTasks[runID]?.cancel() }
        logger.info("Nemotron subtitle generation cancelled")
    }

    func cancelAllGeneration() {
        cancelledRunIDs.formUnion(activeRunIDs)
        for publication in publicationsByRunID.values { publication.cancel() }
        for task in currentGenerationTasks.values { task.cancel() }
        logger.info("All Nemotron subtitle generation cancelled")
    }

    nonisolated static func normalizedLanguage(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "auto" : trimmed
    }

    private func registerRun(_ runID: UUID, operationID: UUID) -> SubtitleSRTPublication {
        let publication = SubtitleSRTPublication()
        publicationsByRunID[runID] = publication
        activeRunIDs.insert(runID)
        runIDsByOperationID[operationID, default: []].insert(runID)
        if cancelledOperationIDs.contains(operationID) {
            cancelledRunIDs.insert(runID)
            publication.cancel()
        }
        return publication
    }

    private func finishRun(_ runID: UUID, operationID: UUID) {
        publicationsByRunID.removeValue(forKey: runID)
        currentGenerationTasks.removeValue(forKey: runID)?.cancel()
        activeRunIDs.remove(runID)
        cancelledRunIDs.remove(runID)
        runIDsByOperationID[operationID]?.remove(runID)
        if runIDsByOperationID[operationID]?.isEmpty == true {
            runIDsByOperationID.removeValue(forKey: operationID)
            cancelledOperationIDs.remove(operationID)
        }
    }


}


// Uses the same progress stages as the other file transcription engine.
typealias NemotronProgress = ParakeetProgress

struct NemotronAudioExtractor: Sendable {
    let subprocessRunner: any SubprocessRunning

    func extract(inputFile: URL, outputFile: URL, ffmpegPath: String, audioStreamIndex: Int?) async throws {
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: ["-y", "-nostdin", "-i", inputFile.path,
                        "-map", audioStreamIndex.map { "0:\($0)" } ?? "0:a:0",
                        "-vn", "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1", outputFile.path],
            timeout: .seconds(2 * 60 * 60),
            standardOutputCaptureLimit: 0, standardErrorCaptureLimit: 256 * 1024,
            sensitiveValues: [inputFile.path, outputFile.path]
        )
        try await NemotronCLITranscriber.run(request, using: subprocessRunner)
    }
}

struct NemotronCLITranscriber: Sendable {
    let subprocessRunner: any SubprocessRunning

    func transcribe(inputFile: URL, outputFile: URL, nemotronPath: String, modelID: String, language: String) async throws {
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: nemotronPath),
            arguments: ["transcribe", inputFile.path, "--model", modelID,
                        "--language", language, "--format", "srt", "--output", outputFile.path],
            timeout: .seconds(12 * 60 * 60),
            standardOutputCaptureLimit: 256 * 1024, standardErrorCaptureLimit: 256 * 1024,
            sensitiveValues: [inputFile.path, outputFile.path, nemotronPath]
        )
        try await Self.run(request, using: subprocessRunner)
    }

    static func run(_ request: SubprocessRequest, using runner: any SubprocessRunning) async throws {
        do {
            let result = try await runner.run(request)
            guard result.succeeded else {
                throw NemotronServiceError.transcriptionFailed(request.redactedDiagnostic(
                    result.standardErrorText, limit: 1000
                ))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as NemotronServiceError {
            throw error
        } catch {
            throw NemotronServiceError.transcriptionFailed(request.redactedDiagnostic(error.localizedDescription, limit: 1000))
        }
    }
}

enum NemotronServiceError: Error, LocalizedError {
    case binaryNotFound, ffmpegNotFound, srtGenerationFailed, cancelled
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound: return "NeMo Speech runtime not found. Configure Nemotron in Settings → Transcription."
        case .ffmpegNotFound: return "FFmpeg not found"
        case .srtGenerationFailed: return "Nemotron did not produce an SRT file"
        case .cancelled: return "Subtitle generation was cancelled"
        case .transcriptionFailed(let detail): return "Nemotron failed: \(detail)"
        }
    }
}
