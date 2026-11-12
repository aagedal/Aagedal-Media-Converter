// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Helper passes that run around the main FFmpeg encode: package wrappers, the
// loudness measurement pass, stream-copy end cuts, MXF index offsets, package
// codestream preparation and the native MXF merge.

import Foundation
import OSLog

extension FFMPEGConverter {
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
            try Task.checkCancellation()
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

    /// Lists the trim's video packets and picks its clean end. Nil when cancelled.
    enum LoudnessMeasurementResult: Sendable {
        case measured([LoudnormMeasurement])
        case failed
        case cancelled
    }

    /// First loudness pass: decodes the export's audio graph and reads each loudnorm's statistics.
    func measureLoudness(conversionID: UUID, ffmpegPath: String, arguments: [String]) async -> LoudnessMeasurementResult {
        var arguments = arguments
        if let progress = arguments.firstIndex(of: "-progress"), progress + 1 < arguments.count {
            arguments.removeSubrange(progress...progress + 1)
        }
        arguments = ["-hide_banner", "-nostats"] + arguments
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: arguments,
            timeout: nil,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 4 * 1024 * 1024,
            sensitiveValues: Set(arguments.filter { $0.hasPrefix("/") } + [ffmpegPath])
        )
        let runner = subprocessRunner
        let task = Task { () -> SubprocessResult? in try? await runner.run(request) }
        currentLoudnessMeasurementTask?.cancel()
        currentLoudnessMeasurementTask = task
        let result = await task.value
        if currentLoudnessMeasurementTask == task { currentLoudnessMeasurementTask = nil }
        guard activeConversionID == conversionID, !task.isCancelled else { return .cancelled }
        guard let result, result.succeeded else {
            Self.logger.error("Loudness measurement failed: \(result.map { request.redactedDiagnostic($0.standardErrorText) } ?? "did not run", privacy: .public)")
            return .failed
        }
        return .measured(MediaAdjustmentsPlan.parseLoudnormMeasurements(from: result.standardErrorText))
    }

    func findStreamCopyEndCut(
        conversionID: UUID, ffmpegPath: String, inputURL: URL, seek: [String], end: Double
    ) async -> StreamCopyEndCut.Cut? {
        let listURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim_packets_\(UUID().uuidString).txt")
        defer { Self.cleanupTempFile(at: listURL, label: "trim packet list") }
        let arguments = ["-v", "error"]
            + StreamCopyEndCut.listingArguments(inputURL: inputURL, seek: seek, end: end, listURL: listURL)
        let runner = subprocessRunner
        let task = Task {
            await Self.runPackageWrapper(
                executablePath: ffmpegPath, arguments: arguments, outputURL: listURL, subprocessRunner: runner
            )
        }
        currentEndCutListingTask?.cancel()
        currentEndCutListingTask = task
        let result = await task.value
        if currentEndCutListingTask == task { currentEndCutListingTask = nil }
        guard activeConversionID == conversionID else { return nil }
        guard case .success = result else { return .unknown }
        return StreamCopyEndCut.cut(fromListing: try? String(contentsOf: listURL, encoding: .utf8), end: end)
    }

    /// Lists the merge inputs' video packets and writes their temporal offsets into
    /// FFmpeg's index of the merged MXF (see `MXFIndexTemporalOffsets`).
    func writeAVCMXFIndexTemporalOffsets(
        conversionID: UUID, ffmpegPath: String, concatInput: [String], outputURL: URL
    ) async -> PostProcessingStepResult {
        let listURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("merge_packets_\(UUID().uuidString).txt")
        defer { Self.cleanupTempFile(at: listURL, label: "merge packet list") }
        let result = await runTrackedPackageWrapper(
            conversionID: conversionID, executablePath: ffmpegPath,
            arguments: ["-y", "-v", "error"] + concatInput + ["-map", "0:v:0", "-c", "copy", "-f", "framecrc", listURL.path],
            outputURL: listURL
        )
        switch result {
        case .success:
            break
        case .failed(_, let reason, _):
            return .failed(reason: reason)
        case .cancelled:
            return .cancelled
        }
        guard let text = try? String(contentsOf: listURL, encoding: .utf8),
              let (_, packets) = FrameCRC.packets(from: text),
              let offsets = MXFIndexTemporalOffsets.temporalOffsets(presentationTimes: packets.map(\.pts)) else {
            return .failed(reason: "The merge inputs' packet timestamps could not be read")
        }
        do {
            return try MXFIndexTemporalOffsets.write(offsets, to: outputURL)
                ? .success : .failed(reason: "The index doesn't list one entry per packet")
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    func runTrackedPackageWrapper(
        conversionID: UUID,
        executablePath: String,
        arguments: [String],
        outputURL: URL
    ) async -> PackageWrapperResult {
        guard postProcessingConversionID == conversionID else { return .cancelled }

        let taskID = UUID()
        let runner = subprocessRunner
        let task = Task {
            await Self.$runningSubprocessID.withValue(taskID) {
                await Self.runPackageWrapper(
                    executablePath: executablePath,
                    arguments: arguments,
                    outputURL: outputURL,
                    subprocessRunner: runner
                )
            }
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
    func prepareTrackedPackageCodestreams(
        conversionID: UUID,
        sourceDirectory: URL,
        frameNames: [String],
        destinationDirectory: URL,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> Int64 {
        guard postProcessingConversionID == conversionID else { throw CancellationError() }
        let taskID = UUID()
        let task = Task.detached {
            try Self.$runningSubprocessID.withValue(taskID) {
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

    /// Rewraps a Stream Copy MXF merge with bmxtranswrap. Returns false when bmx rejected
    /// the inputs or dropped a track kind, so the caller continues with FFmpeg's concat path.
    func runNativeMXFMerge(
        _ merge: NativeMXFMergeRequest,
        request: ConversionRequest,
        conversionID: UUID,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void,
        completion: @escaping @Sendable (Bool, String?) -> Void
    ) async -> Bool {
        let outputURL = Self.outputReservations.reserveUnique(
            request.outputURL.appendingPathExtension("mxf"),
            notOverwriting: request.inputURL,
            owner: conversionID
        )
        FileSafetyUtils.registerCreatedFile(outputURL)
        request.outputURLResolved?(outputURL)
        let finish: @Sendable (Bool, String?) -> Void = { success, reason in
            let ownsOutput = Self.outputReservations.release(outputURL, owner: conversionID)
            if ownsOutput {
                if success { FileSafetyUtils.markCompletedOutput(outputURL) } else { Self.cleanupFailedOutput(at: outputURL) }
            }
            completion(success, reason)
        }

        guard await activateBMXOperationIfActiveConversion(conversionID) else {
            finish(false, "Conversion cancelled")
            return true
        }

        var xmlURL: URL?
        if let xml = merge.nonRealTimeMetaXML {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("nrt_\(conversionID.uuidString).xml")
            if (try? xml.write(to: url, atomically: true, encoding: .utf8)) != nil { xmlURL = url }
        }
        defer { if let xmlURL { Self.cleanupTempFile(at: xmlURL, label: "NonRealTimeMeta XML") } }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        // Trimmed segments are rewrapped copies that already start at the trimmed timecode.
        let firstSegmentInfo: String? = if merge.startTimecode == nil, let first = merge.segmentURLs.first {
            await bmxService.getMXFInfo(url: first)
        } else { nil }
        progressUpdate(0, "Merging MXF…")
        let result = await bmxService.mergeMXFSequence(
            inputURLs: merge.segmentURLs,
            outputURL: outputURL,
            arguments: NativeMXFMerge.mergeArguments(
                companyName: merge.companyName,
                appVersion: appVersion,
                startTimecode: merge.startTimecode ?? firstSegmentInfo.flatMap(NativeMXFMerge.startTimecode(fromMXFInfo:)),
                embeddedXMLURL: xmlURL
            ),
            operationID: conversionID,
            progress: { value in progressUpdate(value, "Merging MXF…") }
        )
        let lateCancellation = await bmxService.finishCancellationTracking(operationID: conversionID)
        clearActiveBMXOperation(if: conversionID)
        if result.cancelled || lateCancellation || activeConversionID != conversionID {
            if activeConversionID == conversionID { activeConversionID = nil }
            finish(false, "Conversion cancelled")
            return true
        }
        var failure: String?
        if !result.success {
            failure = result.stderr
        } else {
            // bmx's sequence reader silently omits tracks that differ between inputs.
            let inputKinds = firstSegmentInfo.map(NativeMXFMerge.essenceKinds(fromMXFInfo:)) ?? []
            let outputKinds = await bmxService.getMXFInfo(url: outputURL).map(NativeMXFMerge.essenceKinds(fromMXFInfo:)) ?? []
            if inputKinds.isEmpty || Set(inputKinds) != Set(outputKinds) || outputKinds.count < inputKinds.count {
                failure = "Merged tracks \(outputKinds) do not match source tracks \(inputKinds)"
            }
        }
        // cancelConversion() clears activeConversionID while the probes above run.
        guard activeConversionID == conversionID else {
            finish(false, "Conversion cancelled")
            return true
        }
        if let failure {
            Self.logger.error("bmxtranswrap MXF merge rejected: \(failure, privacy: .public)")
            _ = Self.outputReservations.release(outputURL, owner: conversionID)
            Self.cleanupFailedOutput(at: outputURL)
            Self.logger.warning("Falling back to FFmpeg concat for MXF merge")
            request.nativeMXFMergeFellBack?()
            return false
        }
        activeConversionID = nil

        if let xml = merge.nonRealTimeMetaXML {
            let sidecar = NativeMXFMerge.sidecarURL(for: outputURL)
            do {
                try xml.write(to: sidecar, atomically: true, encoding: .utf8)
                FileSafetyUtils.registerCreatedFile(sidecar)
            } catch {
                Self.logger.error("Failed to write NonRealTimeMeta sidecar: \(error.localizedDescription, privacy: .public)")
            }
        }
        progressUpdate(1, nil)
        finish(true, nil)
        return true
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
