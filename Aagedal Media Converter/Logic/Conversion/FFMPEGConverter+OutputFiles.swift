// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Temp-file cleanup and output-file validation for FFMPEGConverter.

import Foundation
import OSLog

extension FFMPEGConverter {
    // MARK: - Temp File Cleanup

    /// Removes a temporary file with proper error logging instead of silently swallowing failures.
    /// Silent `try?` on file removal can hide disk space leaks that accumulate over many conversions.
    static func cleanupTempFile(at url: URL, label: String) {
        do {
            try FileManager.default.removeItem(at: url)
            logger.debug("Cleaned up temp file (\(label, privacy: .public)): \(url.lastPathComponent, privacy: .public)")
        } catch {
            logger.warning("Failed to clean up temp file (\(label, privacy: .public)): \(url.lastPathComponent, privacy: .public) — \(error.localizedDescription, privacy: .public)")
        }
    }

    static func cleanupWaveformTemporaryMXFIfPresent(_ url: URL?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        cleanupTempFile(at: url, label: "waveform BMX rewrap temp MXF")
    }

    // MARK: - Output Validation

    /// Validates that an output file exists and has a non-zero size after FFmpeg reports success.
    /// FFmpeg can exit with status 0 while producing empty or corrupt output (e.g., disk full,
    /// interrupted I/O, or edge-case codec errors that don't set a non-zero exit code).
    static func validateOutputFile(at url: URL) -> String? {
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

    /// Removes an incomplete ordinary-file output and revokes its app-created trust record.
    /// A failed encode must not leave a stale registration that could authorize deleting an
    /// unrelated file created at the same path later.
    static func cleanupFailedOutput(at url: URL) {
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
}
