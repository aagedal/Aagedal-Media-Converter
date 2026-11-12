// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// User-facing error reasons extracted from FFmpeg, avmenc and wrapper diagnostics.

import Foundation

extension FFMPEGConverter {
    // MARK: - Extract Error Reason

    /// Composes a user-facing reason for a DCP/IMF wrap-step failure. Appends a short,
    /// trimmed slice of the tool's stderr after the base message when present, so the
    /// queue capsule tooltip carries the diagnostic context without dumping the full log.
    static func dcpIMFErrorReason(base: String, stderr: String) -> String {
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
    static func av2DecoderErrorReason(diagnostic: String, exitCode: Int32) -> String {
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
    static func extractAvmencErrorReason(from stderr: String, exitCode: Int32) -> String {
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
    static func extractErrorReason(from stderr: String, exitCode: Int32) -> String {
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
}
