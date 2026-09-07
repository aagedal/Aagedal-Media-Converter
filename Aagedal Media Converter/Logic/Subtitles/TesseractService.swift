// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

// MARK: - Progress & Error Types

struct TesseractProgress: Sendable {
    enum Stage: Sendable {
        case extractingTrack
        case parsingFrames
        case recognizing(frame: Int, total: Int)
        case writingSRT
        case complete
        case failed(String)
    }
    let stage: Stage
    let percentage: Double

    var stageDescription: String {
        switch stage {
        case .extractingTrack:  return "Extracting subtitle track…"
        case .parsingFrames:    return "Parsing subtitle images…"
        case .recognizing(let f, let t): return "Recognising text (\(f)/\(t))…"
        case .writingSRT:       return "Writing SRT file…"
        case .complete:         return "Done"
        case .failed(let e):    return "Failed: \(e)"
        }
    }
}

enum TesseractServiceError: Error, LocalizedError {
    case tesseractNotFound
    case ffmpegNotFound
    case noSubtitleStream
    case extractionFailed(String)
    case parsingFailed(String)
    case ocrFailed(String)
    case engineUnstable(String)
    case srtGenerationFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .tesseractNotFound:
            return "Tesseract not found. Install via Homebrew or configure in Settings → OCR."
        case .ffmpegNotFound:
            return "FFmpeg binary not found."
        case .noSubtitleStream:
            return "No bitmap subtitle stream found in source file."
        case .extractionFailed(let msg):
            return "Subtitle extraction failed: \(msg)"
        case .parsingFailed(let msg):
            return "Subtitle parsing failed: \(msg)"
        case .ocrFailed(let msg):
            return "OCR failed: \(msg)"
        case .engineUnstable(let msg):
            return "OCR engine failed repeatedly — likely misconfigured (\(msg))"
        case .srtGenerationFailed:
            return "Failed to write SRT file."
        case .cancelled:
            return "OCR was cancelled."
        }
    }
}

// MARK: - TesseractService

/// Converts bitmap subtitle streams (PGS/VOBSUB) to SRT using Tesseract OCR.
///
/// Pipeline:
///   1. FFmpeg extracts the subtitle stream to a temporary .sup or .sub file
///   2. PGSParser / VOBSUBParser decodes frames into SubtitleFrame values
///   3. Tesseract OCRs each PNG frame
///   4. An SRT file is assembled and written to the output directory
actor TesseractService {
    static let shared = TesseractService()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "TesseractService")

    /// Prefix shared by every per-run scratch directory under `NSTemporaryDirectory()`.
    /// Used both when creating a run dir and when sweeping orphans on launch.
    private static let tempDirPrefix = "TesseractOCR-"

    private let subtitleStreamExtractor: TesseractSubtitleStreamExtractor
    private var activeRunIDs: Set<UUID> = []
    private var cancelledRunIDs: Set<UUID> = []
    private var cancelledOperationIDs: Set<UUID> = []
    private var runIDsByOperationID: [UUID: Set<UUID>] = [:]
    private var currentExtractionTasks: [UUID: Task<Void, Error>] = [:]
    private var currentOCRTasks: [UUID: Task<String, Error>] = [:]

    init(subprocessRunner: any SubprocessRunning = SubprocessRunner()) {
        subtitleStreamExtractor = TesseractSubtitleStreamExtractor(
            subprocessRunner: subprocessRunner
        )
    }

    /// Sweep scratch directories left over from a previous run that crashed before its
    /// `defer` cleanup could fire. Safe to call from anywhere; never throws.
    nonisolated static func purgeOrphanTempDirs() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(tempDirPrefix) {
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: - Public API

    /// Converts a bitmap subtitle stream in `sourceFile` to SRT, saving alongside the
    /// encoded output in `outputDirectory`.
    func generateSubtitles(
        sourceFile: URL,
        outputDirectory: URL,
        operationID: UUID,
        subtitleStreamIndex: Int,
        codec: String,
        language: String,
        engineKind: OCREngineKind = .userPreferred,
        progress: @escaping @Sendable (TesseractProgress) -> Void
    ) async throws -> URL {
        let runID = UUID()
        registerRun(runID, operationID: operationID)
        defer { finishRun(runID, operationID: operationID) }
        guard !cancelledRunIDs.contains(runID) else {
            throw TesseractServiceError.cancelled
        }
        let baseName = sourceFile.deletingPathExtension().lastPathComponent
        let srtURL = SubtitleSRTNaming.outputURL(directory: outputDirectory, baseName: baseName, method: .ocr)
        return try await runPipeline(
            sourceFile: sourceFile,
            srtURL: srtURL,
            subtitleStreamIndex: subtitleStreamIndex,
            codec: codec,
            language: language,
            engineKind: engineKind,
            runID: runID,
            progress: progress
        )
    }

    /// Converts a bitmap subtitle stream in `sourceFile` to SRT, saving alongside
    /// the source file. Used for "transcribe-only" (Option+click) mode.
    func generateSubtitlesOnly(
        sourceFile: URL,
        operationID: UUID,
        subtitleStreamIndex: Int,
        codec: String,
        language: String,
        engineKind: OCREngineKind = .userPreferred,
        progress: @escaping @Sendable (TesseractProgress) -> Void
    ) async throws -> URL {
        let runID = UUID()
        registerRun(runID, operationID: operationID)
        defer { finishRun(runID, operationID: operationID) }
        guard !cancelledRunIDs.contains(runID) else {
            throw TesseractServiceError.cancelled
        }
        let outputDirectory = sourceFile.deletingLastPathComponent()
        let baseName = sourceFile.deletingPathExtension().lastPathComponent
        let srtURL = SubtitleSRTNaming.outputURL(directory: outputDirectory, baseName: baseName, method: .ocr)
        return try await runPipeline(
            sourceFile: sourceFile,
            srtURL: srtURL,
            subtitleStreamIndex: subtitleStreamIndex,
            codec: codec,
            language: language,
            engineKind: engineKind,
            runID: runID,
            progress: progress
        )
    }

    /// Cancels OCR associated with one queue item or user operation.
    func cancelGeneration(operationID: UUID) {
        cancelledOperationIDs.insert(operationID)
        let runIDs = runIDsByOperationID[operationID] ?? []
        cancelledRunIDs.formUnion(runIDs)
        for runID in runIDs {
            currentExtractionTasks[runID]?.cancel()
            currentOCRTasks[runID]?.cancel()
        }
    }

    /// Stops every active OCR run during an explicit batch shutdown.
    func cancelAllGeneration() {
        cancelledRunIDs.formUnion(activeRunIDs)
        for task in currentExtractionTasks.values { task.cancel() }
        for task in currentOCRTasks.values { task.cancel() }
    }

    // MARK: - Pipeline

    private func runPipeline(
        sourceFile: URL,
        srtURL: URL,
        subtitleStreamIndex: Int,
        codec: String,
        language: String,
        engineKind: OCREngineKind,
        runID: UUID,
        progress: @escaping @Sendable (TesseractProgress) -> Void
    ) async throws -> URL {
        // Sandboxed FFmpeg subprocess can't open user-imported files on external volumes
        // unless we hold security scope on the source URL for the duration of the run.
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: sourceFile)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }

        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else {
            throw TesseractServiceError.ffmpegNotFound
        }

        let engine: any BitmapSubtitleOCREngine
        switch engineKind {
        case .tesseract:
            guard let tesseractPath = BinaryPathResolver.tesseractPath else {
                throw TesseractServiceError.tesseractNotFound
            }
            engine = TesseractOCREngine(
                tesseractPath: tesseractPath,
                tessdataPrefix: BinaryPathResolver.tessdataDirectory
            )
        case .appleVision:
            engine = VisionOCREngine()
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.tempDirPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Step 1 — Extract subtitle stream
        progress(TesseractProgress(stage: .extractingTrack, percentage: 0.0))
        logger.info("Extracting subtitle stream \(subtitleStreamIndex) from \(sourceFile.lastPathComponent)")

        let isPGS = isBitmapPGS(codec: codec)
        let frames = try await extractAndParse(
            sourceFile: sourceFile,
            streamIndex: subtitleStreamIndex,
            isPGS: isPGS,
            ffmpegPath: ffmpegPath,
            tempDir: tempDir,
            runID: runID,
            progress: progress
        )

        guard !frames.isEmpty else {
            throw TesseractServiceError.parsingFailed("No subtitle frames found in stream")
        }

        guard !cancelledRunIDs.contains(runID) else { throw TesseractServiceError.cancelled }

        // Step 3 — OCR each frame
        let total = frames.count
        var srtEntries: [(index: Int, start: TimeInterval, end: TimeInterval, text: String)] = []
        var consecutiveFailures = 0
        let maxConsecutiveFailures = 5

        for (i, frame) in frames.enumerated() {
            guard !cancelledRunIDs.contains(runID) else { throw TesseractServiceError.cancelled }

            // Recognize starts where extract+parse left off (15%) so the bar doesn't
            // visibly jump when the pipeline transitions from extract to OCR.
            let pct = 0.15 + 0.80 * (Double(i) / Double(total))
            progress(TesseractProgress(stage: .recognizing(frame: i + 1, total: total), percentage: pct))

            let pngFile = tempDir.appendingPathComponent("frame_\(i).png")
            try frame.imageData.write(to: pngFile)

            let task = Task<String, Error> {
                try await engine.recognize(pngURL: pngFile, language: language)
            }
            currentOCRTasks[runID] = task
            defer { currentOCRTasks[runID] = nil }

            let text: String
            do {
                text = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                consecutiveFailures = 0
            } catch is CancellationError {
                throw TesseractServiceError.cancelled
            } catch {
                // Single-frame failure is non-fatal — but a streak almost certainly means
                // the engine itself is broken (wrong tessdata path, missing language pack,
                // unreadable PNG dimensions). Log every failure; bail after a streak.
                consecutiveFailures += 1
                logger.warning("OCR engine failure on frame \(i + 1)/\(total): \(error.localizedDescription, privacy: .public)")
                if consecutiveFailures >= maxConsecutiveFailures {
                    throw TesseractServiceError.engineUnstable(error.localizedDescription)
                }
                continue
            }

            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                srtEntries.append((index: srtEntries.count + 1, start: frame.startTime, end: frame.endTime, text: trimmed))
            }
        }

        guard !cancelledRunIDs.contains(runID) else { throw TesseractServiceError.cancelled }

        // Step 4 — Write SRT
        progress(TesseractProgress(stage: .writingSRT, percentage: 0.97))
        let srtContent = buildSRT(from: srtEntries)
        do {
            try srtContent.write(to: srtURL, atomically: true, encoding: .utf8)
        } catch {
            throw TesseractServiceError.srtGenerationFailed
        }

        progress(TesseractProgress(stage: .complete, percentage: 1.0))
        logger.info("OCR complete: \(srtURL.lastPathComponent) (\(srtEntries.count) subtitles)")
        return srtURL
    }

    // MARK: - Extract + Parse

    private func extractAndParse(
        sourceFile: URL,
        streamIndex: Int,
        isPGS: Bool,
        ffmpegPath: String,
        tempDir: URL,
        runID: UUID,
        progress: @escaping @Sendable (TesseractProgress) -> Void
    ) async throws -> [SubtitleFrame] {
        // Map FFmpeg's 0…1 demux progress into the extractingTrack slice (0…15%) of the
        // overall pipeline so the queue card moves while the stream is being dumped.
        let extractProgress: @Sendable (Double) -> Void = { fraction in
            progress(TesseractProgress(stage: .extractingTrack, percentage: fraction * 0.15))
        }

        if isPGS {
            let supFile = tempDir.appendingPathComponent("subs.sup")
            try await extractStream(
                source: sourceFile.path,
                streamIndex: streamIndex,
                outputPath: supFile.path,
                ffmpegPath: ffmpegPath,
                runID: runID,
                progress: extractProgress
            )
            progress(TesseractProgress(stage: .parsingFrames, percentage: 0.15))
            do {
                let data = try Data(contentsOf: supFile)
                return try PGSParser.parse(supData: data)
            } catch {
                throw TesseractServiceError.parsingFailed(error.localizedDescription)
            }
        } else {
            // VOBSUB — FFmpeg outputs .sub + .idx
            let subFile = tempDir.appendingPathComponent("subs.sub")
            let idxFile = tempDir.appendingPathComponent("subs.idx")
            try await extractStream(
                source: sourceFile.path,
                streamIndex: streamIndex,
                outputPath: subFile.path,
                ffmpegPath: ffmpegPath,
                runID: runID,
                progress: extractProgress
            )
            progress(TesseractProgress(stage: .parsingFrames, percentage: 0.15))
            guard FileManager.default.fileExists(atPath: subFile.path),
                  FileManager.default.fileExists(atPath: idxFile.path) else {
                throw TesseractServiceError.extractionFailed("VOBSUB .sub/.idx files not created")
            }
            do {
                return try VOBSUBParser.parse(idxURL: idxFile, subURL: subFile)
            } catch {
                throw TesseractServiceError.parsingFailed(error.localizedDescription)
            }
        }
    }

    private func extractStream(
        source: String,
        streamIndex: Int,
        outputPath: String,
        ffmpegPath: String,
        runID: UUID,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard !cancelledRunIDs.contains(runID) else {
            throw TesseractServiceError.cancelled
        }
        let extractionTask = Task {
            try await subtitleStreamExtractor.extract(
                source: source,
                streamIndex: streamIndex,
                outputPath: outputPath,
                ffmpegPath: ffmpegPath,
                progress: progress
            )
        }
        currentExtractionTasks[runID] = extractionTask
        defer {
            currentExtractionTasks[runID] = nil
        }

        do {
            try await withTaskCancellationHandler {
                try await extractionTask.value
            } onCancel: {
                extractionTask.cancel()
            }
        } catch is CancellationError {
            throw TesseractServiceError.cancelled
        }
    }

    // MARK: - SRT Builder

    private func buildSRT(from entries: [(index: Int, start: TimeInterval, end: TimeInterval, text: String)]) -> String {
        var lines: [String] = []
        for entry in entries {
            lines.append("\(entry.index)")
            lines.append("\(srtTimestamp(entry.start)) --> \(srtTimestamp(entry.end))")
            lines.append(entry.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func srtTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds * 1000)
        let ms = total % 1000
        let s  = (total / 1000) % 60
        let m  = (total / 60_000) % 60
        let h  = total / 3_600_000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    // MARK: - Helpers

    private func isBitmapPGS(codec: String) -> Bool {
        let lower = codec.lowercased()
        // FFprobe-style + Matroska container ID (SwiftExif's MKV reader emits the latter).
        return lower == "pgssub" || lower == "hdmv_pgs_subtitle" || lower == "s_hdmv/pgs"
    }

    private func registerRun(_ runID: UUID, operationID: UUID) {
        activeRunIDs.insert(runID)
        runIDsByOperationID[operationID, default: []].insert(runID)
        if cancelledOperationIDs.contains(operationID) {
            cancelledRunIDs.insert(runID)
        }
    }

    private func finishRun(_ runID: UUID, operationID: UUID) {
        currentExtractionTasks.removeValue(forKey: runID)?.cancel()
        currentOCRTasks.removeValue(forKey: runID)?.cancel()
        activeRunIDs.remove(runID)
        cancelledRunIDs.remove(runID)
        runIDsByOperationID[operationID]?.remove(runID)
        if runIDsByOperationID[operationID]?.isEmpty == true {
            runIDsByOperationID.removeValue(forKey: operationID)
            cancelledOperationIDs.remove(operationID)
        }
    }
}

/// FFmpeg boundary for bitmap-subtitle extraction. Keeping this separate from the actor
/// makes request construction, deadlines, diagnostics, and cancellation directly testable.
struct TesseractSubtitleStreamExtractor: Sendable {
    /// A feature-length PGS dump usually finishes in about a minute at full speed. Slow
    /// disks and network shares need a generous bound, but a wedged FFmpeg must not pin
    /// the conversion queue forever.
    static let timeout: Duration = .seconds(30 * 60)
    static let diagnosticCaptureLimit = 256 * 1024

    private let subprocessRunner: any SubprocessRunning

    init(subprocessRunner: any SubprocessRunning = SubprocessRunner()) {
        self.subprocessRunner = subprocessRunner
    }

    func extract(
        source: String,
        streamIndex: Int,
        outputPath: String,
        ffmpegPath: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()

        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: [
                "-y",
                "-i", source,
                "-map", "0:s:\(streamIndex)",
                "-c", "copy",
                outputPath
            ],
            timeout: Self.timeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: Self.diagnosticCaptureLimit,
            sensitiveValues: [source, outputPath]
        )
        let progressParser = TesseractExtractionProgressParser(progress: progress)

        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(request) { chunk in
                switch chunk.stream {
                case .standardError:
                    progressParser.consume(chunk.data)
                case .standardOutput:
                    break
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SubprocessRunnerError {
            switch error {
            case .failedToStart(_, let underlying):
                throw TesseractServiceError.extractionFailed(
                    request.redactedDiagnostic(underlying, limit: 300)
                )
            case .timedOut:
                throw TesseractServiceError.extractionFailed(
                    "FFmpeg exceeded the 30-minute subtitle extraction limit"
                )
            }
        } catch {
            throw TesseractServiceError.extractionFailed(
                request.redactedDiagnostic(error.localizedDescription, limit: 300)
            )
        }
        progressParser.finish()

        guard result.succeeded else {
            let diagnostic = request.redactedDiagnostic(
                result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines),
                limit: 300
            )
            let detail = diagnostic.isEmpty ? "unknown error" : diagnostic
            throw TesseractServiceError.extractionFailed(
                "FFmpeg exited \(result.terminationStatus): \(detail)"
            )
        }
    }
}

/// Serializes FFmpeg's incremental stderr parser state because runner output callbacks
/// may arrive from either pipe-draining queue.
private final class TesseractExtractionProgressParser: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: (@Sendable (Double) -> Void)?
    private let throttler = ProgressThrottler(minInterval: 0.25)
    private var duration: Double?
    private var pendingText = ""

    init(progress: (@Sendable (Double) -> Void)?) {
        self.progress = progress
    }

    func consume(_ data: Data) {
        guard let progress, !data.isEmpty else { return }

        lock.withLock {
            pendingText += String(decoding: data, as: UTF8.self)
            while let separator = pendingText.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                let record = String(pendingText[..<separator])
                pendingText.removeSubrange(...separator)
                parse(record, progress: progress)
            }
            if pendingText.count > 8 * 1024 {
                pendingText = String(pendingText.suffix(8 * 1024))
            }
        }
    }

    func finish() {
        guard let progress else { return }
        lock.withLock {
            guard !pendingText.isEmpty else { return }
            let record = pendingText
            pendingText = ""
            parse(record, progress: progress)
        }
    }

    private func parse(_ text: String, progress: @escaping @Sendable (Double) -> Void) {
        guard !text.isEmpty else { return }
        let (newDuration, _) = FFMPEGProgressParser.handleOutput(
            text,
            totalDuration: duration,
            effectiveDuration: duration,
            progressThrottler: throttler
        ) { fraction, _ in
            progress(fraction)
        }
        duration = newDuration
    }
}
