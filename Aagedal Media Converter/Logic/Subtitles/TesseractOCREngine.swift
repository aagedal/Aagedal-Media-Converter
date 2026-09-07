// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// OCR backend that shells out to the Tesseract binary (bundled, Homebrew, or custom).
struct TesseractOCREngine: BitmapSubtitleOCREngine {
    let tesseractPath: String
    let tessdataPrefix: String?
    private let subprocessRunner: any SubprocessRunning

    /// Hard cap per frame. A misbehaving tesseract that wedges shouldn't be able to hang the whole queue.
    private static let perFrameTimeout: Duration = .seconds(10)
    private static let outputCaptureLimit = 256 * 1024

    init(
        tesseractPath: String,
        tessdataPrefix: String?,
        subprocessRunner: any SubprocessRunning = SubprocessRunner()
    ) {
        self.tesseractPath = tesseractPath
        self.tessdataPrefix = tessdataPrefix
        self.subprocessRunner = subprocessRunner
    }

    func recognize(pngURL: URL, language: String) async throws -> String {
        try Task.checkCancellation()

        var env = ProcessInfo.processInfo.environment
        if let tessdataPrefix {
            env["TESSDATA_PREFIX"] = tessdataPrefix
        }

        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: tesseractPath),
            arguments: [pngURL.path, "stdout", "--psm", "6", "-l", language],
            environment: env,
            timeout: Self.perFrameTimeout,
            standardOutputCaptureLimit: Self.outputCaptureLimit,
            standardErrorCaptureLimit: Self.outputCaptureLimit,
            sensitiveValues: [pngURL.path]
        )

        let result: SubprocessResult
        do {
            result = try await subprocessRunner.run(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SubprocessRunnerError {
            switch error {
            case .failedToStart(_, let underlying):
                throw TesseractOCREngineError.processStartFailed(underlying)
            case .timedOut:
                throw TesseractOCREngineError.timedOut
            }
        } catch {
            throw TesseractOCREngineError.processStartFailed(error.localizedDescription)
        }

        guard result.succeeded else {
            let stderr = request.redactedDiagnostic(
                result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines),
                limit: 300
            )
            throw TesseractOCREngineError.processFailed(
                exitCode: result.terminationStatus,
                stderr: stderr
            )
        }

        guard result.discardedStandardOutputBytes == 0 else {
            throw TesseractOCREngineError.outputTooLarge
        }
        return result.standardOutputText
    }
}

enum TesseractOCREngineError: Error, LocalizedError {
    case processStartFailed(String)
    case processFailed(exitCode: Int32, stderr: String)
    case timedOut
    case outputTooLarge

    var errorDescription: String? {
        switch self {
        case .processStartFailed(let msg):
            return "Failed to launch tesseract: \(msg)"
        case .processFailed(let code, let stderr):
            return stderr.isEmpty
                ? "tesseract exited \(code)"
                : "tesseract exited \(code): \(stderr)"
        case .timedOut:
            return "tesseract exceeded the 10-second per-frame limit"
        case .outputTooLarge:
            return "tesseract returned more text than the per-frame safety limit"
        }
    }
}
