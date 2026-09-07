// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import OSLog

private final class AudioDurationProbeResolution: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Double?, Never>?
    private var resolvedValue: Double?
    private var isResolved = false
    private var probeTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<Double?, Never>) {
        let value = lock.withLock { () -> (resolved: Bool, value: Double?) in
            if isResolved {
                return (true, resolvedValue)
            }
            self.continuation = continuation
            return (false, nil)
        }
        if value.resolved {
            continuation.resume(returning: value.value)
        }
    }

    func install(probeTask: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
        let shouldCancel = lock.withLock { () -> Bool in
            if isResolved { return true }
            self.probeTask = probeTask
            self.timeoutTask = timeoutTask
            return false
        }
        if shouldCancel {
            probeTask.cancel()
            timeoutTask.cancel()
        }
    }

    func resolve(_ value: Double?) {
        let state = lock.withLock { () -> (
            continuation: CheckedContinuation<Double?, Never>?,
            probeTask: Task<Void, Never>?,
            timeoutTask: Task<Void, Never>?
        )? in
            guard !isResolved else { return nil }
            isResolved = true
            resolvedValue = value
            let state = (continuation, probeTask, timeoutTask)
            continuation = nil
            self.probeTask = nil
            self.timeoutTask = nil
            return state
        }
        guard let state else { return }
        state.probeTask?.cancel()
        state.timeoutTask?.cancel()
        state.continuation?.resume(returning: value)
    }
}

enum ImageSequenceDetector {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "ImageSequenceDetector")
    typealias AudioDurationProbe = @Sendable (URL) async -> Double?

    struct SecurityScope: Sendable {
        let start: @Sendable (URL) -> Bool
        let stop: @Sendable (URL) -> Void

        static let live = SecurityScope(
            start: { $0.startAccessingSecurityScopedResource() },
            stop: { $0.stopAccessingSecurityScopedResource() }
        )
    }

    /// Regex to match a filename with a numeric suffix before the extension.
    /// Captures: (prefix)(number).(extension)
    /// Examples: "frame_0001.png" → ("frame_", "0001", "png")
    ///           "render.0042.exr" → ("render.", "0042", "exr")
    private static let sequencePattern = try! NSRegularExpression(
        pattern: #"^(.+?)(\d+)$"#,
        options: []
    )

    // MARK: - Public API

    /// Detect all image sequences in a folder.
    /// Groups files by matching prefix and extension, returns sequences with ≥2 frames.
    static func detectSequences(
        inFolder folderURL: URL,
        audioDurationTimeout: Duration = .seconds(5),
        securityScopedAccessURL: URL? = nil,
        securityScope: SecurityScope = .live,
        detectsAssociatedAudio: Bool = true,
        audioDurationProbe: @escaping AudioDurationProbe = { url in
            // probeAudioDuration owns the selected folder scope and deadline.
            await SwiftExifMediaProbe.durationWithoutDeadline(for: url)
        }
    ) async -> [ImageSequenceConfig] {
        guard !Task.isCancelled else { return [] }
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            logger.warning("Could not list contents of folder: \(folderURL.path, privacy: .public)")
            return []
        }

        return await buildSequences(
            from: contents,
            directory: folderURL,
            audioDurationTimeout: audioDurationTimeout,
            securityScopedAccessURL: securityScopedAccessURL,
            securityScope: securityScope,
            detectsAssociatedAudio: detectsAssociatedAudio,
            audioDurationProbe: audioDurationProbe
        )
    }

    /// Detect an image sequence from a single file by scanning its parent directory
    /// for other files matching the same prefix and extension.
    static func detectSequence(
        fromFile fileURL: URL,
        audioDurationTimeout: Duration = .seconds(5),
        securityScopedAccessURL: URL? = nil,
        securityScope: SecurityScope = .live,
        detectsAssociatedAudio: Bool = true,
        audioDurationProbe: @escaping AudioDurationProbe = { url in
            // probeAudioDuration owns the selected folder scope and deadline.
            await SwiftExifMediaProbe.durationWithoutDeadline(for: url)
        }
    ) async -> ImageSequenceConfig? {
        guard !Task.isCancelled else { return nil }
        let ext = fileURL.pathExtension.lowercased()
        guard ImageSequenceFormat.allExtensions.contains(ext) else { return nil }

        let directory = fileURL.deletingLastPathComponent()
        let sequences = await detectSequences(
            inFolder: directory,
            audioDurationTimeout: audioDurationTimeout,
            securityScopedAccessURL: securityScopedAccessURL,
            securityScope: securityScope,
            detectsAssociatedAudio: detectsAssociatedAudio,
            audioDurationProbe: audioDurationProbe
        )
        guard !Task.isCancelled else { return nil }

        // Find the sequence that contains this file's pattern
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        guard let parsed = parseFilename(baseName) else { return nil }

        return sequences.first { seq in
            // Match by prefix and extension
            let seqExt = seq.pattern.components(separatedBy: ".").last ?? ""
            let seqPrefix = extractPrefix(from: seq.pattern)
            return seqPrefix == parsed.prefix && seqExt == ext
        }
    }

    // MARK: - Private

    private struct ParsedFile {
        let url: URL
        let prefix: String
        let number: Int
        let paddingWidth: Int
        let ext: String
        let fileSize: Int64
    }

    /// Parse a filename (without extension) into prefix and numeric parts
    private static func parseFilename(_ baseName: String) -> (prefix: String, number: Int, paddingWidth: Int)? {
        let nsString = baseName as NSString
        let range = NSRange(location: 0, length: nsString.length)

        guard let match = sequencePattern.firstMatch(in: baseName, options: [], range: range) else {
            return nil
        }

        let prefix = nsString.substring(with: match.range(at: 1))
        let numberStr = nsString.substring(with: match.range(at: 2))

        guard let number = Int(numberStr) else { return nil }

        let paddingWidth = numberStr.count
        return (prefix, number, paddingWidth)
    }

    /// Extract the prefix from an FFMPEG pattern string (e.g., "frame_%04d.png" → "frame_")
    private static func extractPrefix(from pattern: String) -> String {
        // Remove the %0Nd.ext part
        guard let percentRange = pattern.range(of: "%") else { return pattern }
        return String(pattern[pattern.startIndex..<percentRange.lowerBound])
    }

    /// Build sequences from a list of file URLs
    private static func buildSequences(
        from urls: [URL],
        directory: URL,
        audioDurationTimeout: Duration,
        securityScopedAccessURL: URL?,
        securityScope: SecurityScope,
        detectsAssociatedAudio: Bool,
        audioDurationProbe: @escaping AudioDurationProbe
    ) async -> [ImageSequenceConfig] {
        let imageExtensions = ImageSequenceFormat.allExtensions
        var groups: [String: [ParsedFile]] = [:]

        for url in urls {
            guard !Task.isCancelled else { return [] }
            let ext = url.pathExtension.lowercased()
            guard imageExtensions.contains(ext) else { continue }

            // Check it's a regular file
            guard let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  resourceValues.isRegularFile == true else { continue }

            let baseName = url.deletingPathExtension().lastPathComponent
            guard let parsed = parseFilename(baseName) else { continue }

            let fileSize = Int64(resourceValues.fileSize ?? 0)
            let key = "\(parsed.prefix)|\(ext)"

            let parsedFile = ParsedFile(
                url: url,
                prefix: parsed.prefix,
                number: parsed.number,
                paddingWidth: parsed.paddingWidth,
                ext: ext,
                fileSize: fileSize
            )

            groups[key, default: []].append(parsedFile)
        }

        var sequences: [ImageSequenceConfig] = []

        for (_, files) in groups {
            guard !Task.isCancelled else { return [] }
            guard files.count >= 2 else { continue }

            let sorted = files.sorted { $0.number < $1.number }
            guard let first = sorted.first, let last = sorted.last else { continue }

            guard let format = ImageSequenceFormat.format(forExtension: first.ext) else { continue }

            // Determine padding width from the majority of files
            let paddingWidth = first.paddingWidth
            let totalSize = sorted.reduce(Int64(0)) { $0 + $1.fileSize }

            // Build the FFMPEG pattern
            let pattern = "\(first.prefix)%0\(paddingWidth)d.\(first.ext)"

            // Check for gaps in numbering
            let hasGaps = checkForGaps(in: sorted)
            if hasGaps {
                logger.info("Sequence '\(pattern, privacy: .public)' has gaps in numbering (\(sorted.count) files, range \(first.number)-\(last.number))")
            }

            let defaultFrameRate = UserDefaults.standard.double(forKey: AppConstants.imageSequenceFrameRateKey)
            let frameRate = defaultFrameRate > 0 ? defaultFrameRate : AppConstants.defaultImageSequenceFrameRate

            var config = ImageSequenceConfig(
                pattern: pattern,
                directory: directory,
                startNumber: first.number,
                endNumber: last.number,
                frameRate: frameRate,
                imageFormat: format,
                totalSizeBytes: totalSize
            )

            // Detect associated audio file in the same directory
            if detectsAssociatedAudio {
                config.associatedAudioURL = detectAssociatedAudio(for: config)
            }

            // If audio was found, derive frame rate from audio duration
            if let audioURL = config.associatedAudioURL {
                let audioDuration = await probeAudioDuration(
                    audioURL,
                    timeout: audioDurationTimeout,
                    securityScopedAccessURL: securityScopedAccessURL,
                    securityScope: securityScope,
                    probe: audioDurationProbe
                )
                guard !Task.isCancelled else { return [] }
                if let audioDuration, audioDuration > 0 {
                    let derivedRate = Double(config.frameCount) / audioDuration
                    config.frameRate = derivedRate
                    logger.info("Derived frame rate \(String(format: "%.3f", derivedRate)) fps from audio duration \(String(format: "%.3f", audioDuration))s (\(config.frameCount) frames)")
                }
            }

            sequences.append(config)
        }

        // Sort by pattern name for consistent ordering
        sequences.sort { $0.pattern < $1.pattern }

        return sequences
    }

    /// Check if a sorted list of parsed files has gaps in numbering
    private static func checkForGaps(in sortedFiles: [ParsedFile]) -> Bool {
        guard let first = sortedFiles.first, let last = sortedFiles.last else { return false }
        let expectedCount = last.number - first.number + 1
        return sortedFiles.count != expectedCount
    }

    // MARK: - Audio File Detection

    /// Audio file extensions to look for alongside image sequences
    private static let audioExtensions: Set<String> = [
        "wav", "aif", "aiff", "mp3", "aac", "m4a", "flac", "ogg", "opus", "wma"
    ]

    /// Detect an associated audio file for a given image sequence config.
    /// Searches the sequence directory for audio files matching the sequence prefix
    /// or common names like "audio.wav".
    static func detectAssociatedAudio(for config: ImageSequenceConfig) -> URL? {
        let prefix = extractPrefix(from: config.pattern)
        let directory = config.directory
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return nil }

        let audioFiles = contents.filter { url in
            audioExtensions.contains(url.pathExtension.lowercased())
        }

        guard !audioFiles.isEmpty else { return nil }

        // Priority 1: Exact prefix match (e.g., "render_.wav" for "render_%04d.exr")
        let trimmedPrefix = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "._- "))
        for file in audioFiles {
            let baseName = file.deletingPathExtension().lastPathComponent
            if baseName == trimmedPrefix {
                logger.info("Found matching audio file: \(file.lastPathComponent, privacy: .public)")
                return file
            }
        }

        // Priority 2: Prefix starts with the sequence prefix
        for file in audioFiles {
            let baseName = file.deletingPathExtension().lastPathComponent.lowercased()
            if baseName.hasPrefix(trimmedPrefix.lowercased()) {
                logger.info("Found prefix-matching audio file: \(file.lastPathComponent, privacy: .public)")
                return file
            }
        }

        // Priority 3: Common audio names
        let commonNames: Set<String> = ["audio", "sound", "soundtrack", "music", "mix"]
        for file in audioFiles {
            let baseName = file.deletingPathExtension().lastPathComponent.lowercased()
            if commonNames.contains(baseName) {
                logger.info("Found common-name audio file: \(file.lastPathComponent, privacy: .public)")
                return file
            }
        }

        // Priority 4: If only one audio file in the folder, use it
        if audioFiles.count == 1 {
            logger.info("Using sole audio file in folder: \(audioFiles[0].lastPathComponent, privacy: .public)")
            return audioFiles[0]
        }

        return nil
    }

    /// Resolves a potentially non-cooperative metadata load without joining it after the
    /// deadline. The probe owns a separate security-scope access for as long as a late load
    /// remains alive, while the caller can release its folder access promptly.
    private static func probeAudioDuration(
        _ url: URL,
        timeout: Duration,
        securityScopedAccessURL: URL?,
        securityScope: SecurityScope,
        probe: @escaping AudioDurationProbe
    ) async -> Double? {
        let resolution = AudioDurationProbeResolution()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                resolution.install(continuation)
                guard !Task.isCancelled else {
                    resolution.resolve(nil)
                    return
                }

                let probeTask = Task {
                    guard !Task.isCancelled else { return }
                    let hasAccess = securityScopedAccessURL.map(securityScope.start) ?? false
                    defer {
                        if hasAccess, let securityScopedAccessURL {
                            securityScope.stop(securityScopedAccessURL)
                        }
                    }
                    guard !Task.isCancelled else { return }
                    resolution.resolve(await probe(url))
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    resolution.resolve(nil)
                }
                resolution.install(probeTask: probeTask, timeoutTask: timeoutTask)
            }
        } onCancel: {
            resolution.resolve(nil)
        }
    }

}
