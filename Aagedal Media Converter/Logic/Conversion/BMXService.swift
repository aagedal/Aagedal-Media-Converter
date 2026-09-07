// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog

// MARK: - MCA Label Models

/// SMPTE ST 377-4 Multi-Channel Audio labels for one MXF audio essence track,
/// extracted from mxf2raw's XML metadata output.
struct AudioTrackMCALabels: Sendable {
    /// 1-based MXF essence track index, in the order mxf2raw emits Sound tracks.
    let trackNumber: Int
    /// Channel count from the sound descriptor (used for content-keyed alignment with FFmpeg).
    let channelCount: Int?
    /// Sampling rate in Hz from the sound descriptor (used for content-keyed alignment with FFmpeg).
    let sampleRate: Int?
    /// Soundfield group symbol such as "5.1", "ST", "7.1DS" (derived from the SoundfieldGroupLabelSubDescriptor).
    let soundfieldGroup: String?
    /// Audio element symbol such as "DX", "ME", "VI-N" (derived from a GroupOfSoundfieldGroupsLabelSubDescriptor
    /// or from a SoundfieldGroup whose tag symbol starts with "ae").
    let audioElement: String?
    /// Per-channel labels in essence channel order (e.g. ["L", "R", "C", "LFE", "Ls", "Rs"]).
    let channelLabels: [String]
}

/// Result of a bmxtranswrap invocation. `stderr` is the captured stderr output —
/// useful for showing the actual failure cause to the user instead of a generic
/// "rejected by bmxtranswrap" string.
struct BMXRewrapResult: Sendable {
    let success: Bool
    let stderr: String
    let cancelled: Bool

    init(success: Bool, stderr: String, cancelled: Bool = false) {
        self.success = success
        self.stderr = stderr
        self.cancelled = cancelled
    }

    /// Convenience for chained `if` checks where only the success bit matters.
    var isSuccess: Bool { success }
}

/// Service for handling BMX tools operations (MXF rewrapping + MCA label extraction)
actor BMXService {
    static let shared = BMXService()

    private static let transwrapTimeout: Duration = .seconds(12 * 60 * 60)
    private static let probeTimeout: Duration = .seconds(5 * 60)
    private static let diagnosticCaptureLimit = 256 * 1024
    private static let infoCaptureLimit = 4 * 1024 * 1024
    private static let mcaXMLCaptureLimit = 16 * 1024 * 1024

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "BMXService")
    private let subprocessRunner: any SubprocessRunning
    private let bmxtranswrapPathProvider: @Sendable () -> String?
    private let mxf2rawPathProvider: @Sendable () -> String?
    private var activeTranswrapID: UUID?
    private var currentTranswrapTask: Task<SubprocessResult, Error>?
    private var pendingTranswrapIDs: Set<UUID> = []
    private var retainedCancellationTrackingIDs: Set<UUID> = []
    private var cancelledTranswrapIDs: Set<UUID> = []
    private var transwrapSlotIsOccupied = false
    private struct TranswrapSlotWaiter {
        let operationID: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var transwrapSlotWaiters: [TranswrapSlotWaiter] = []

    /// Cache keyed by URL; entries invalidate when the file's modification date changes.
    private struct MCACacheEntry {
        let modificationDate: Date?
        let labels: [AudioTrackMCALabels]
    }
    private var mcaCache: [URL: MCACacheEntry] = [:]

    init(
        subprocessRunner: any SubprocessRunning = SubprocessRunner(),
        bmxtranswrapPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.bmxtranswrapPath },
        mxf2rawPathProvider: @escaping @Sendable () -> String? = { BinaryPathResolver.mxf2rawPath }
    ) {
        self.subprocessRunner = subprocessRunner
        self.bmxtranswrapPathProvider = bmxtranswrapPathProvider
        self.mxf2rawPathProvider = mxf2rawPathProvider
    }

    // MARK: - Public API

    /// Rewraps an MXF file to OP1a format using bmxtranswrap
    /// - Parameters:
    ///   - inputURL: The source MXF file (from FFmpeg)
    ///   - outputURL: The destination MXF file (OP1a compliant)
    ///   - clipName: Optional clip name for the output
    ///   - mcaLabelsFile: Optional path to a bmx MCA labels file. When provided, MCA
    ///     descriptors (Soundfield Group, channel labels) are injected into the OP1a
    ///     output for downstream broadcast/MAM systems. When nil, no labels are written
    ///     (preserves pre-existing behavior).
    ///   - progress: Progress callback (0.0 to 1.0)
    /// - Returns: true if successful, false otherwise
    func rewrapToOP1a(
        inputURL: URL,
        outputURL: URL,
        clipName: String? = nil,
        mcaLabelsFile: URL? = nil,
        operationID: UUID = UUID(),
        progress: @escaping @Sendable (Double) -> Void
    ) async -> BMXRewrapResult {
        var arguments: [String] = [
            "-t", "op1a",
            "--use-avc-subdesc",
        ]

        if let name = clipName, !name.isEmpty {
            arguments.append(contentsOf: ["--clip", name])
        }

        if let mcaLabelsFile {
            // The <scheme> argument is ignored unless it is "as11"; pass a placeholder.
            arguments.append(contentsOf: ["--track-mca-labels", "x", mcaLabelsFile.path])
        }

        return await runBMXTranswrap(
            inputURL: inputURL,
            outputURL: outputURL,
            extraArguments: arguments,
            operationID: operationID,
            progress: progress
        )
    }

    /// Rewraps an MXF/MOV file to OP1a for IMF essence delivery (ST 2067-2 / 2067-21 / 2067-50).
    /// - Parameters:
    ///   - inputURL: The source MXF or MOV file (from FFmpeg or asdcp-wrap).
    ///   - outputURL: The destination OP1a MXF.
    ///   - colorPrimaries: bmx `--color-prim` value (e.g. "bt709", "bt2020"); nil to omit.
    ///   - transferCharacteristic: bmx `--transfer-ch` value (e.g. "bt709", "bt2020", "st2084", "hlg"); nil to omit.
    ///   - codingEquations: bmx `--coding-eq` value (e.g. "bt709", "bt2020"); nil to omit.
    ///   - clipName: Optional clip name written to the MXF.
    ///   - mcaLabelsFile: Optional MCA labels file (for IMF audio essences carrying SMPTE ST 377-4 labels).
    ///   - progress: Progress callback (0.0 to 1.0).
    /// - Returns: true on success.
    func rewrapToIMFOP1a(
        inputURL: URL,
        outputURL: URL,
        colorPrimaries: String? = nil,
        transferCharacteristic: String? = nil,
        codingEquations: String? = nil,
        clipName: String? = nil,
        mcaLabelsFile: URL? = nil,
        operationID: UUID = UUID(),
        progress: @escaping @Sendable (Double) -> Void
    ) async -> BMXRewrapResult {
        var arguments: [String] = [
            "-t", "op1a",
        ]

        if let value = colorPrimaries {
            arguments.append(contentsOf: ["--color-prim", value])
        }
        if let value = transferCharacteristic {
            arguments.append(contentsOf: ["--transfer-ch", value])
        }
        if let value = codingEquations {
            arguments.append(contentsOf: ["--coding-eq", value])
        }
        if let name = clipName, !name.isEmpty {
            arguments.append(contentsOf: ["--clip", name])
        }
        if let mcaLabelsFile {
            arguments.append(contentsOf: ["--track-mca-labels", "x", mcaLabelsFile.path])
        }

        return await runBMXTranswrap(
            inputURL: inputURL,
            outputURL: outputURL,
            extraArguments: arguments,
            operationID: operationID,
            progress: progress
        )
    }

    /// Rewraps an MXF file to RDD9 (SMPTE RDD 9) format for DCP-compliant ASDCP MXF
    /// - Parameters:
    ///   - inputURL: The source MXF file (from FFmpeg)
    ///   - outputURL: The destination MXF file (ASDCP compliant)
    ///   - isVideo: Whether this is a video MXF (adds DCI color metadata)
    ///   - clipName: Optional clip name for the output
    ///   - progress: Progress callback (0.0 to 1.0)
    /// - Returns: true if successful, false otherwise
    func rewrapToRDD9(
        inputURL: URL,
        outputURL: URL,
        isVideo: Bool = true,
        clipName: String? = nil,
        operationID: UUID = UUID(),
        progress: @escaping @Sendable (Double) -> Void
    ) async -> BMXRewrapResult {
        var arguments: [String] = [
            "-t", "rdd9",
        ]

        // Add DCI color metadata for video MXF
        if isVideo {
            arguments.append(contentsOf: [
                "--signal-std", "st428",
                "--transfer-ch", "dcdm",
                "--color-prim", "dcdm",
                "--coding-eq", "gbr",
            ])
        }

        if let name = clipName, !name.isEmpty {
            arguments.append(contentsOf: ["--clip", name])
        }

        return await runBMXTranswrap(
            inputURL: inputURL,
            outputURL: outputURL,
            extraArguments: arguments,
            operationID: operationID,
            progress: progress
        )
    }

    /// Cancels the current bmxtranswrap operation
    func cancel() {
        if currentTranswrapTask != nil {
            if let activeTranswrapID {
                cancelledTranswrapIDs.insert(activeTranswrapID)
            }
            currentTranswrapTask?.cancel()
            logger.info("bmxtranswrap cancelled")
        }
    }

    /// Cancels one conversion's rewrap, retaining cancellation if it arrives before
    /// that operation reaches the subprocess registration point.
    func cancel(operationID: UUID) {
        if activeTranswrapID == operationID {
            cancelledTranswrapIDs.insert(operationID)
            currentTranswrapTask?.cancel()
        } else if let waiterIndex = transwrapSlotWaiters.firstIndex(where: { $0.operationID == operationID }) {
            let waiter = transwrapSlotWaiters.remove(at: waiterIndex)
            waiter.continuation.resume(returning: false)
        } else if pendingTranswrapIDs.contains(operationID)
            || retainedCancellationTrackingIDs.contains(operationID) {
            cancelledTranswrapIDs.insert(operationID)
        }
        logger.info("bmxtranswrap operation cancelled")
    }

    /// Retains targeted cancellation while a conversion prepares the inputs for BMX.
    func prepareCancellationTracking(operationID: UUID) {
        retainedCancellationTrackingIDs.insert(operationID)
    }

    /// Ends pre-registration tracking and reports cancellation that arrived after the
    /// subprocess completed but before its caller resumed.
    func finishCancellationTracking(operationID: UUID) -> Bool {
        retainedCancellationTrackingIDs.remove(operationID)
        let wasCancelled = cancelledTranswrapIDs.contains(operationID)
        if !pendingTranswrapIDs.contains(operationID) {
            cancelledTranswrapIDs.remove(operationID)
        }
        return wasCancelled
    }

    /// Internal state probe used by deterministic cancellation tests.
    func isWaitingForTranswrapSlot(operationID: UUID) -> Bool {
        transwrapSlotWaiters.contains { $0.operationID == operationID }
    }

    // MARK: - Shared Process Execution

    /// Shared bmxtranswrap execution with input/output validation, progress parsing, and error handling
    private func runBMXTranswrap(
        inputURL: URL,
        outputURL: URL,
        extraArguments: [String],
        operationID: UUID,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> BMXRewrapResult {
        pendingTranswrapIDs.insert(operationID)
        defer {
            pendingTranswrapIDs.remove(operationID)
            if !retainedCancellationTrackingIDs.contains(operationID) {
                cancelledTranswrapIDs.remove(operationID)
            }
        }

        if consumeCancellation(for: operationID) {
            return cancelledResult()
        }

        guard await acquireTranswrapSlot(operationID: operationID) else {
            return cancelledResult()
        }
        defer { releaseTranswrapSlot() }

        if consumeCancellation(for: operationID) {
            return cancelledResult()
        }

        guard let bmxtranswrapPath = bmxtranswrapPathProvider() else {
            logger.error("bmxtranswrap binary not found")
            return BMXRewrapResult(success: false, stderr: "bmxtranswrap binary not found")
        }

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            logger.error("Input MXF file not found: \(inputURL.path)")
            return BMXRewrapResult(success: false, stderr: "Input file not found: \(inputURL.lastPathComponent)")
        }

        let outputDir = outputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create output directory: \(error.localizedDescription, privacy: .private(mask: .hash))")
            return BMXRewrapResult(success: false, stderr: "Failed to create output directory")
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            do {
                try FileManager.default.removeItem(at: outputURL)
            } catch {
                logger.error("Failed to remove existing output file: \(error.localizedDescription, privacy: .private(mask: .hash))")
                return BMXRewrapResult(success: false, stderr: "Failed to replace existing output file")
            }
        }

        var arguments = extraArguments
        arguments.append(contentsOf: ["-o", outputURL.path, "-p"])
        arguments.append(inputURL.path)

        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: bmxtranswrapPath),
            arguments: arguments,
            timeout: Self.transwrapTimeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: Self.diagnosticCaptureLimit,
            sensitiveArgumentNames: ["--clip"],
            sensitiveValues: Set(
                [bmxtranswrapPath, inputURL.path, outputURL.path]
                    + arguments.filter { $0.hasPrefix("/") }
            )
        )
        logger.info("Running bmxtranswrap: \(request.redactedCommandDescription, privacy: .public)")

        let progressParser = BMXProgressParser(progress: progress)
        activeTranswrapID = operationID
        let task = Task {
            try await subprocessRunner.run(request) { chunk in
                guard case .standardOutput = chunk.stream else { return }
                progressParser.consume(chunk.data)
            }
        }
        currentTranswrapTask = task

        let result: SubprocessResult
        do {
            result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            clearTranswrap(if: operationID)
            cleanupPartialOutput(at: outputURL)
            return cancelledResult()
        } catch let error as SubprocessRunnerError {
            clearTranswrap(if: operationID)
            cleanupPartialOutput(at: outputURL)
            let message: String
            switch error {
            case .timedOut:
                message = "bmxtranswrap exceeded the 12-hour processing limit"
            case .failedToStart:
                message = request.redactedDiagnostic(error.localizedDescription)
            }
            logger.error("bmxtranswrap failed: \(message, privacy: .private(mask: .hash))")
            return BMXRewrapResult(success: false, stderr: message)
        } catch {
            clearTranswrap(if: operationID)
            cleanupPartialOutput(at: outputURL)
            let message = request.redactedDiagnostic(error.localizedDescription)
            logger.error("bmxtranswrap failed: \(message, privacy: .private(mask: .hash))")
            return BMXRewrapResult(success: false, stderr: message)
        }

        progressParser.finish()
        clearTranswrap(if: operationID)

        if consumeCancellation(for: operationID) {
            cleanupPartialOutput(at: outputURL)
            return cancelledResult()
        }

        let success = result.succeeded
        let stderrString = request.redactedDiagnostic(result.standardErrorText)

        if success {
            guard isNonemptyFile(outputURL) else {
                cleanupPartialOutput(at: outputURL)
                logger.error("bmxtranswrap exited successfully without producing a valid output")
                return BMXRewrapResult(
                    success: false,
                    stderr: "bmxtranswrap did not produce a valid output file"
                )
            }
            logger.info("bmxtranswrap completed successfully: \(outputURL.lastPathComponent)")
            progress(1.0)
        } else {
            cleanupPartialOutput(at: outputURL)
            logger.error("bmxtranswrap exited \(result.terminationStatus): \(stderrString, privacy: .private(mask: .hash))")
        }

        return BMXRewrapResult(success: success, stderr: stderrString)
    }

    private func clearTranswrap(if transwrapID: UUID) {
        guard activeTranswrapID == transwrapID else { return }
        activeTranswrapID = nil
        currentTranswrapTask = nil
    }

    private func consumeCancellation(for operationID: UUID) -> Bool {
        cancelledTranswrapIDs.remove(operationID) != nil || Task.isCancelled
    }

    private func acquireTranswrapSlot(operationID: UUID) async -> Bool {
        if consumeCancellation(for: operationID) {
            return false
        }
        if !transwrapSlotIsOccupied {
            transwrapSlotIsOccupied = true
            return true
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if consumeCancellation(for: operationID) {
                    continuation.resume(returning: false)
                } else {
                    transwrapSlotWaiters.append(
                        TranswrapSlotWaiter(operationID: operationID, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            Task { await self.cancel(operationID: operationID) }
        }
    }

    private func releaseTranswrapSlot() {
        if transwrapSlotWaiters.isEmpty {
            transwrapSlotIsOccupied = false
        } else {
            transwrapSlotWaiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelledResult() -> BMXRewrapResult {
        BMXRewrapResult(success: false, stderr: "bmxtranswrap cancelled", cancelled: true)
    }

    private func isNonemptyFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.int64Value > 0
    }

    private func cleanupPartialOutput(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logger.warning("Failed to remove partial BMX output: \(error.localizedDescription, privacy: .private(mask: .hash))")
        }
    }

    // MARK: - MXF Info

    /// Gets information about an MXF file using mxf2raw
    /// - Parameter url: The MXF file to analyze
    /// - Returns: MXF info string, or nil if failed
    func getMXFInfo(url: URL) async -> String? {
        guard let mxf2rawPath = mxf2rawPathProvider() else {
            logger.error("mxf2raw binary not found")
            return nil
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("MXF file not found: \(url.path)")
            return nil
        }

        let request = mxf2rawRequest(
            executablePath: mxf2rawPath,
            arguments: ["--info", url.path],
            sourceURL: url,
            outputCaptureLimit: Self.infoCaptureLimit
        )
        do {
            let result = try await subprocessRunner.run(request)
            guard result.succeeded else {
                let diagnostic = request.redactedDiagnostic(result.standardErrorText)
                logger.warning("mxf2raw exited \(result.terminationStatus): \(diagnostic, privacy: .private(mask: .hash))")
                return nil
            }
            guard result.discardedStandardOutputBytes == 0 else {
                logger.warning("mxf2raw info exceeded the \(Self.infoCaptureLimit)-byte output limit")
                return nil
            }
            return result.standardOutputText
        } catch is CancellationError {
            return nil
        } catch {
            logger.error("Failed to run mxf2raw: \(request.redactedDiagnostic(error.localizedDescription), privacy: .private(mask: .hash))")
        }

        return nil
    }

    /// Checks if an MXF file is OP1a compliant
    /// - Parameter url: The MXF file to check
    /// - Returns: true if OP1a, false otherwise or if check failed
    func isOP1a(url: URL) async -> Bool {
        guard let info = await getMXFInfo(url: url) else {
            return false
        }
        // Check for OP1a in the info output
        return info.contains("OP-1a") || info.contains("OP1a")
    }

    // MARK: - MCA Audio Track Labels

    /// Extracts SMPTE ST 377-4 MCA labels for each audio essence track in an MXF file.
    /// - Parameter url: The MXF file to inspect (caller is responsible for security-scoped access).
    /// - Returns: Per-track MCA labels in the order mxf2raw emits Sound tracks, or nil if mxf2raw fails.
    ///           Tracks without MCA descriptors yield entries with nil/empty label fields.
    func getAudioTrackLabels(url: URL) async -> [AudioTrackMCALabels]? {
        logger.info("getAudioTrackLabels: starting for \(url.lastPathComponent, privacy: .public)")

        // Open security-scoped access so the mxf2raw subprocess can read user-imported
        // MXFs that live outside the sandbox container. Mirrors the pattern in
        // VideoMetadataService — try direct scope first, fall back to a saved bookmark.
        let directAccess = url.startAccessingSecurityScopedResource()
        var bookmarkAccess = false
        if !directAccess {
            bookmarkAccess = SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: url)
        }
        logger.info("getAudioTrackLabels: scope direct=\(directAccess) bookmark=\(bookmarkAccess) for \(url.lastPathComponent, privacy: .public)")
        defer {
            if directAccess { url.stopAccessingSecurityScopedResource() }
            else if bookmarkAccess { SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: url) }
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date
        if let cached = mcaCache[url], cached.modificationDate == mtime {
            logger.info("getAudioTrackLabels: cache hit (\(cached.labels.count) entries) for \(url.lastPathComponent, privacy: .public)")
            return cached.labels
        }

        guard let mxf2rawPath = mxf2rawPathProvider() else {
            logger.error("mxf2raw binary not found")
            return nil
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.error("getAudioTrackLabels: file not reachable in sandbox at \(url.path, privacy: .public) (scope direct=\(directAccess) bookmark=\(bookmarkAccess))")
            return nil
        }

        let arguments = [
            "--info",
            "--info-format", "xml",
            "--mca-detail",
            url.path,
        ]
        let request = mxf2rawRequest(
            executablePath: mxf2rawPath,
            arguments: arguments,
            sourceURL: url,
            outputCaptureLimit: Self.mcaXMLCaptureLimit
        )
        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(request)
        } catch is CancellationError {
            return nil
        } catch {
            logger.error("Failed to run mxf2raw for MCA labels: \(request.redactedDiagnostic(error.localizedDescription), privacy: .private(mask: .hash))")
            return nil
        }

        guard result.succeeded else {
            let diagnostic = request.redactedDiagnostic(result.standardErrorText)
            logger.warning("mxf2raw exited \(result.terminationStatus) for \(url.lastPathComponent): \(diagnostic, privacy: .private(mask: .hash))")
            return nil
        }
        guard result.discardedStandardOutputBytes == 0 else {
            logger.warning("mxf2raw MCA XML exceeded the \(Self.mcaXMLCaptureLimit)-byte output limit")
            return nil
        }

        let xmlData = result.standardOutput
        let labels = MXFInfoMCAParser.parse(xmlData: xmlData)
        mcaCache[url] = MCACacheEntry(modificationDate: mtime, labels: labels)
        let summary = labels.map { "[ch=\($0.channelCount ?? -1) sg=\($0.soundfieldGroup ?? "-") el=\($0.audioElement ?? "-") chs=\($0.channelLabels.count)]" }.joined(separator: " ")
        logger.notice("Parsed \(labels.count) MCA-bearing audio tracks from \(url.lastPathComponent, privacy: .public): \(summary, privacy: .public)")
        if labels.isEmpty {
            logger.warning("getAudioTrackLabels: parser produced 0 entries — XML may not contain MCA descriptors. Stdout size=\(xmlData.count)")
        }
        return labels
    }

    private func mxf2rawRequest(
        executablePath: String,
        arguments: [String],
        sourceURL: URL,
        outputCaptureLimit: Int
    ) -> SubprocessRequest {
        SubprocessRequest(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            timeout: Self.probeTimeout,
            standardOutputCaptureLimit: outputCaptureLimit,
            standardErrorCaptureLimit: Self.diagnosticCaptureLimit,
            sensitiveValues: [executablePath, sourceURL.path]
        )
    }

    /// Invalidates the cached MCA labels for a URL (e.g. when the file is replaced on disk).
    func invalidateMCACache(for url: URL) {
        mcaCache.removeValue(forKey: url)
    }
}

private final class BMXProgressParser: @unchecked Sendable {
    private static let maximumPendingBytes = 8 * 1024
    private let lock = NSLock()
    private var pending = Data()
    private let progress: @Sendable (Double) -> Void

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func consume(_ data: Data) {
        let lines = lock.withLock { () -> [Data] in
            pending.append(data)
            let lines = drainCompleteLines()
            if pending.count > Self.maximumPendingBytes {
                pending = pending.suffix(Self.maximumPendingBytes)
            }
            return lines
        }
        publish(lines)
    }

    func finish() {
        let remainder = lock.withLock { () -> [Data] in
            guard !pending.isEmpty else { return [] }
            defer { pending.removeAll(keepingCapacity: false) }
            return [pending]
        }
        publish(remainder)
    }

    private func drainCompleteLines() -> [Data] {
        var lines: [Data] = []
        while let separator = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            lines.append(pending[..<separator])
            var nextIndex = pending.index(after: separator)
            if pending[separator] == 0x0D,
               nextIndex < pending.endIndex,
               pending[nextIndex] == 0x0A {
                nextIndex = pending.index(after: nextIndex)
            }
            pending.removeSubrange(..<nextIndex)
        }
        return lines
    }

    private func publish(_ lines: [Data]) {
        for data in lines {
            let line = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasSuffix("%"),
                  let percent = Double(line.dropLast()) else { continue }
            progress(min(max(percent / 100, 0), 1))
        }
    }
}

// MARK: - MXF Info MCA XML Parser

/// Streams mxf2raw's XML output and extracts per-track MCA labels.
/// Element names match bmx 1.6's BBC schema (`http://bbc.co.uk/rd/bmx/201312`):
///   `<bmx><clip><tracks><track index="N"><essence_kind>Sound</essence_kind>
///       <sound_descriptor>... <channel_count> <sampling_rate> ...</sound_descriptor>
///       <mca_labels>
///         <channel_label><tag_symbol>chL</tag_symbol><tag_name>Left</tag_name></channel_label>
///         <soundfield_group><tag_symbol>sg51</tag_symbol><tag_name>5.1</tag_name></soundfield_group>
///         <group_of_soundfield_group><tag_symbol>aeDX</tag_symbol><tag_name>Dialog</tag_name></group_of_soundfield_group>
///       </mca_labels>
///     </track></tracks></clip></bmx>`
private final class MXFInfoMCAParser: NSObject, XMLParserDelegate {
    static func parse(xmlData: Data) -> [AudioTrackMCALabels] {
        let delegate = MXFInfoMCAParser()
        let parser = XMLParser(data: xmlData)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.completedTracks
    }

    // MARK: parser state

    private var elementStack: [String] = []
    private var textBuffer: String = ""

    // Per-track scratch state (only populated when inside a Sound track)
    private var inSoundTrack = false
    private var currentTrackSoundIndex = 0    // 1-based index across Sound tracks only
    private var soundTracksSeen = 0
    private var currentChannelCount: Int?
    private var currentSampleRate: Int?
    private var currentChannelLabels: [(channelID: Int?, symbol: String?, name: String?)] = []
    private var currentSoundfieldGroups: [(symbol: String?, name: String?)] = []
    private var currentAudioElements: [(symbol: String?, name: String?)] = []

    // Per-MCA-block scratch state
    private enum MCABlockKind { case channelLabel, soundfieldGroup, groupOfSoundfieldGroups }
    private var currentBlockKind: MCABlockKind?
    private var currentBlockSymbol: String?
    private var currentBlockName: String?
    private var currentBlockChannelID: Int?

    private var completedTracks: [AudioTrackMCALabels] = []

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let local = localName(of: elementName)
        elementStack.append(local)
        textBuffer = ""

        switch local {
        case "track":
            // Reset per-track state; we'll find out if it's a Sound track when essence_kind appears.
            inSoundTrack = false
            currentChannelCount = nil
            currentSampleRate = nil
            currentChannelLabels = []
            currentSoundfieldGroups = []
            currentAudioElements = []
        case "channel_label":
            currentBlockKind = .channelLabel
            currentBlockSymbol = nil
            currentBlockName = nil
            currentBlockChannelID = nil
        case "soundfield_group":
            currentBlockKind = .soundfieldGroup
            currentBlockSymbol = nil
            currentBlockName = nil
            currentBlockChannelID = nil
        case "group_of_soundfield_group", "group_of_soundfield_groups":
            currentBlockKind = .groupOfSoundfieldGroups
            currentBlockSymbol = nil
            currentBlockName = nil
            currentBlockChannelID = nil
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        textBuffer.append(string)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = localName(of: elementName)
        let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch local {
        case "essence_kind":
            // Direct child of <track>.
            if elementStack.dropLast().last == "track", value == "Sound" {
                inSoundTrack = true
                soundTracksSeen += 1
                currentTrackSoundIndex = soundTracksSeen
            }
        case "channel_count":
            if inSoundTrack, let n = Int(value) {
                currentChannelCount = n
            }
        case "sampling_rate":
            if inSoundTrack {
                currentSampleRate = parseRate(value)
            }
        case "tag_symbol":
            if currentBlockKind != nil { currentBlockSymbol = value }
        case "tag_name":
            if currentBlockKind != nil { currentBlockName = value }
        case "channel_id":
            if currentBlockKind == .channelLabel { currentBlockChannelID = Int(value) }
        case "channel_label":
            if inSoundTrack, currentBlockKind == .channelLabel {
                currentChannelLabels.append((channelID: currentBlockChannelID, symbol: currentBlockSymbol, name: currentBlockName))
            }
            currentBlockKind = nil
        case "soundfield_group":
            if inSoundTrack, currentBlockKind == .soundfieldGroup {
                // Audio elements often appear as soundfield groups whose tag symbol starts with "ae".
                let symbol = currentBlockSymbol ?? ""
                if symbol.lowercased().hasPrefix("ae") {
                    currentAudioElements.append((symbol: currentBlockSymbol, name: currentBlockName))
                } else {
                    currentSoundfieldGroups.append((symbol: currentBlockSymbol, name: currentBlockName))
                }
            }
            currentBlockKind = nil
        case "group_of_soundfield_group", "group_of_soundfield_groups":
            if inSoundTrack, currentBlockKind == .groupOfSoundfieldGroups {
                currentAudioElements.append((symbol: currentBlockSymbol, name: currentBlockName))
            }
            currentBlockKind = nil
        case "track":
            if inSoundTrack {
                let channels = currentChannelLabels
                    .sorted { (a, b) in (a.channelID ?? Int.max) < (b.channelID ?? Int.max) }
                    .compactMap { displayLabel(symbol: $0.symbol, name: $0.name) }
                let soundfield = currentSoundfieldGroups.first.flatMap { displayLabel(symbol: $0.symbol, name: $0.name) }
                let element = currentAudioElements.first.flatMap { displayLabel(symbol: $0.symbol, name: $0.name) }
                completedTracks.append(AudioTrackMCALabels(
                    trackNumber: currentTrackSoundIndex,
                    channelCount: currentChannelCount,
                    sampleRate: currentSampleRate,
                    soundfieldGroup: soundfield,
                    audioElement: element,
                    channelLabels: channels
                ))
            }
            inSoundTrack = false
        default:
            break
        }

        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
        textBuffer = ""
    }

    // MARK: helpers

    private func localName(of elementName: String) -> String {
        // Strip an XML namespace prefix if any (`prefix:local`).
        if let colon = elementName.firstIndex(of: ":") {
            return String(elementName[elementName.index(after: colon)...])
        }
        return elementName
    }

    /// Convert a sampling_rate of the form "48000/1" to integer Hz; tolerate bare integers.
    private func parseRate(_ value: String) -> Int? {
        if let slash = value.firstIndex(of: "/") {
            let num = Int(value[..<slash]) ?? 0
            let den = Int(value[value.index(after: slash)...]) ?? 1
            guard den != 0 else { return nil }
            return num / den
        }
        return Int(value)
    }

    /// Prefer the human-readable Tag Name when available; fall back to the SMPTE Tag Symbol
    /// (stripped of its "ch"/"sg"/"ae" prefix to keep the routing UI compact).
    private func displayLabel(symbol: String?, name: String?) -> String? {
        if let name, !name.isEmpty { return name }
        guard let symbol, !symbol.isEmpty else { return nil }
        let lowered = symbol.lowercased()
        if lowered.hasPrefix("ch") || lowered.hasPrefix("sg") || lowered.hasPrefix("ae") {
            return String(symbol.dropFirst(2))
        }
        return symbol
    }
}

// MARK: - BMX Errors

enum BMXError: Error, LocalizedError {
    case binaryNotFound
    case inputNotFound
    case rewrapFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "BMX tools not found"
        case .inputNotFound:
            return "Input MXF file not found"
        case .rewrapFailed(let message):
            return "MXF rewrap failed: \(message)"
        case .cancelled:
            return "Operation was cancelled"
        }
    }
}
