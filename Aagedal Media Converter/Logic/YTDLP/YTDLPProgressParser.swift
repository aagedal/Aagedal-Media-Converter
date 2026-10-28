// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Parses yt-dlp output for progress information
struct YTDLPProgressParser: Sendable {
    static let liveStatusPrefix = "__AMC_LIVE_STATUS__="
    static let sourceDurationPrefix = "__AMC_SOURCE_DURATION__="

    struct ProgressInfo: Sendable {
        let progress: Double      // 0.0 to 1.0 (0.5 for downloads with unknown total)
        let speed: String?        // e.g., "5.2MiB/s"
        let eta: String?          // e.g., "01:23"
        let downloaded: String?   // e.g., "45.2MiB"
        let total: String?        // e.g., "1.23GiB"
        let isLiveStream: Bool    // true if this is live stream progress (no percentage)
    }

    /// Parses a line of yt-dlp output for download progress
    /// Example lines:
    /// [download]  45.2% of 1.23GiB at 5.67MiB/s ETA 01:23
    /// [download] 100% of 1.23GiB in 00:04:32
    /// [download] Destination: Video Title.mp4
    /// Live stream: [download] 234.5MiB at 2.3MiB/s (no percentage)
    static func parse(_ line: String) -> ProgressInfo? {
        // First try percentage-based progress
        let progressPattern = #"\[download\]\s+(\d+\.?\d*)%"#
        if let progressMatch = line.range(of: progressPattern, options: .regularExpression) {
            let progressString = String(line[progressMatch])
            let numberPattern = #"(\d+\.?\d*)"#
            if let numberMatch = progressString.range(of: numberPattern, options: .regularExpression) {
                let percentString = String(progressString[numberMatch])
                if let percent = Double(percentString) {
                    let progress = percent / 100.0
                    return ProgressInfo(
                        progress: progress,
                        speed: extractSpeed(from: line),
                        eta: extractETA(from: line),
                        downloaded: nil,
                        total: extractTotal(from: line),
                        isLiveStream: false
                    )
                }
            }
        }

        // A total is not always available for ordinary VOD downloads, so a size and
        // speed without a percentage is indeterminate progress, not proof of a live stream.
        let indeterminatePattern = #"\[download\]\s+([\d.]+\s*\w+iB)\s+at\s+([\d.]+\s*\w+/s)"#
        if let indeterminateMatch = line.range(of: indeterminatePattern, options: .regularExpression) {
            let matchStr = String(line[indeterminateMatch])
            let speed = extractSpeed(from: line)
            // Extract downloaded size
            let sizePattern = #"([\d.]+\s*\w+iB)"#
            var downloaded: String? = nil
            if let sizeMatch = matchStr.range(of: sizePattern, options: .regularExpression) {
                downloaded = String(matchStr[sizeMatch])
            }
            return ProgressInfo(
                progress: 0.5,  // Indeterminate progress when no total is available
                speed: speed,
                eta: nil,
                downloaded: downloaded,
                total: nil,
                isLiveStream: false
            )
        }

        // Fragment downloads are also used for fixed-length HLS/DASH videos.
        if line.contains("[download]") && (line.contains("fragment") || line.contains("Fragment")) {
            let speed = extractSpeed(from: line)
            return ProgressInfo(
                progress: 0.5,
                speed: speed,
                eta: nil,
                downloaded: nil,
                total: nil,
                isLiveStream: false
            )
        }

        // Detect active download status even without progress numbers
        // Examples: [download] Downloading video X, [youtube:tab] Downloading, etc.
        if line.contains("[download]") && line.contains("Downloading") {
            return ProgressInfo(
                progress: 0.1,  // Small progress to indicate activity
                speed: nil,
                eta: nil,
                downloaded: nil,
                total: nil,
                isLiveStream: false
            )
        }

        // Detect webpage/info fetching as initial progress
        if line.contains("Downloading webpage") || line.contains("Downloading API") || line.contains("Extracting URL") {
            return ProgressInfo(
                progress: 0.05,  // Minimal progress to show activity started
                speed: nil,
                eta: nil,
                downloaded: nil,
                total: nil,
                isLiveStream: false
            )
        }

        // yt-dlp uses ffmpeg and m3u8 playlists for ordinary HLS VODs too. Live
        // classification comes from the explicit live_status marker instead.
        if line.contains("Invoking ffmpeg downloader") || line.contains("yt_live_broadcast") {
            return ProgressInfo(
                progress: 0.5,
                speed: nil,
                eta: nil,
                downloaded: nil,
                total: nil,
                isLiveStream: false
            )
        }

        // HLS/m3u8 describes transport, not whether the source is currently live.
        if line.contains("Downloading m3u8") || line.contains("playlist_type/DVR") {
            return ProgressInfo(
                progress: 0.3,
                speed: nil,
                eta: nil,
                downloaded: nil,
                total: nil,
                isLiveStream: false
            )
        }

        return nil
    }

    /// Parses the source-duration marker emitted by the `before_dl` print template.
    static func parseSourceDuration(_ line: String) -> Double? {
        guard line.hasPrefix(sourceDurationPrefix) else { return nil }
        let value = line.dropFirst(sourceDurationPrefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = Double(value), seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    /// Parses the output position from an ffmpeg stats line
    /// (`frame=  209 fps= 83 ... time=00:00:12.85 bitrate=... speed=1.7x`).
    /// Section downloads run through ffmpeg, which reports no percentage of its own.
    /// Pre-roll is reported as negative time and clamps to zero.
    static func parseFFmpegTime(_ line: String) -> Double? {
        guard line.contains("speed="),
              let match = line.range(of: #"time=-?\d+:\d{2}:\d{2}(\.\d+)?"#, options: .regularExpression)
        else { return nil }
        let value = line[match].dropFirst("time=".count)
        guard !value.hasPrefix("-") else { return 0 }
        let parts = value.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2])
        else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// Recorded duration and output size from an ffmpeg stats line
    /// (`frame= 1499 fps= 42 q=-1.0 size=    5632KiB time=00:00:49.99 bitrate=… speed=1.39x`).
    static func parseFFmpegStats(_ line: String) -> (time: Double?, bytes: Int64?)? {
        guard line.contains("speed=") else { return nil }
        let time = parseFFmpegTime(line)
        var bytes: Int64?
        if let match = line.range(of: #"L?size=\s*\d+(\.\d+)?\s*[A-Za-z]*B"#, options: .regularExpression) {
            bytes = byteCount(line[match].drop { $0 != "=" }.dropFirst())
        }
        guard time != nil || bytes != nil else { return nil }
        return (time, bytes)
    }

    /// Recorded duration and downloaded size from a yt-dlp-rs `--growing-file`
    /// progress line (`[download]   24.79MiB at  122.26KiB/s (00:03:27), recorded 00:03:40`).
    static func parseGrowingFileProgress(_ line: String) -> (time: Double, bytes: Int64?)? {
        guard line.hasPrefix("[download]"),
              let match = line.range(of: #", recorded \d+:\d{2}:\d{2}$"#, options: .regularExpression)
        else { return nil }
        let parts = line[match].dropFirst(", recorded ".count).split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2])
        else { return nil }
        let size = line.range(of: #"^\[download\]\s+[\d.]+\s*[KMG]?i?B\b"#, options: .regularExpression)
            .map { line[$0].dropFirst("[download]".count) }
        return (h * 3600 + m * 60 + s, size.flatMap(byteCount))
    }

    /// "5632KiB", "24.79 MiB", "512B" → bytes.
    private static func byteCount(_ text: Substring) -> Int64? {
        let value = text.trimmingCharacters(in: .whitespaces)
        let digits = value.prefix { $0.isNumber || $0 == "." }
        let unit = value.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).lowercased()
        let multiplier: Double? = switch unit {
        case "b": 1
        case "kib", "kb": 1024
        case "mib", "mb": 1024 * 1024
        case "gib", "gb": 1024 * 1024 * 1024
        default: nil
        }
        guard let number = Double(digits), let multiplier else { return nil }
        return Int64(number * multiplier)
    }

    /// Whether a yt-dlp error means the stream exists but has not started (a scheduled
    /// live event or premiere, or a channel that is not live yet), so the download can
    /// wait for it with `--wait-for-video`.
    static func isStreamNotStartedError(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return [
            "live event will begin",
            "premieres in",
            "premiere will begin",
            "is not currently live",
        ].contains { lowered.contains($0) }
    }

    /// Parses the marker emitted by yt-dlp's `before_dl` print template.
    /// A recording is live only while yt-dlp reports `is_live`; archived and
    /// post-live videos are finite VOD downloads.
    static func parseLiveStatus(_ line: String) -> Bool? {
        guard line.hasPrefix(liveStatusPrefix) else { return nil }
        let status = String(line.dropFirst(liveStatusPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case "is_live":
            return true
        case "not_live", "is_upcoming", "was_live", "post_live":
            return false
        default:
            return nil
        }
    }

    private static func extractSpeed(from line: String) -> String? {
        let speedPattern = #"at\s+([\d.]+\s*\w+/s)"#
        if let speedMatch = line.range(of: speedPattern, options: .regularExpression) {
            let speedFull = String(line[speedMatch])
            if let atIndex = speedFull.range(of: "at ") {
                return String(speedFull[atIndex.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func extractETA(from line: String) -> String? {
        let etaPattern = #"ETA\s+(\d{1,2}:\d{2}(?::\d{2})?)"#
        if let etaMatch = line.range(of: etaPattern, options: .regularExpression) {
            let etaFull = String(line[etaMatch])
            if let etaIndex = etaFull.range(of: "ETA ") {
                return String(etaFull[etaIndex.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func extractTotal(from line: String) -> String? {
        let totalPattern = #"of\s+([\d.]+\s*\w+)"#
        if let totalMatch = line.range(of: totalPattern, options: .regularExpression) {
            let totalFull = String(line[totalMatch])
            if let ofIndex = totalFull.range(of: "of ") {
                return String(totalFull[ofIndex.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Parses the final output path from yt-dlp
    /// Example: [Merger] Merging formats into "Video Title.mp4"
    /// Or from --print after_move:filepath output
    static func parseOutputPath(_ line: String) -> String? {
        // Check for merger output
        let mergerPattern = #"\[Merger\] Merging formats into \"(.+)\""#
        if let mergerMatch = line.range(of: mergerPattern, options: .regularExpression) {
            let fullMatch = String(line[mergerMatch])
            if let firstQuote = fullMatch.firstIndex(of: "\""),
               let lastQuote = fullMatch.lastIndex(of: "\""),
               firstQuote < lastQuote {
                let pathStart = fullMatch.index(after: firstQuote)
                return String(fullMatch[pathStart..<lastQuote])
            }
        }

        // Check for download destination
        let destPattern = #"\[download\] Destination: (.+)$"#
        if let destMatch = line.range(of: destPattern, options: .regularExpression) {
            let fullMatch = String(line[destMatch])
            if let colonIndex = fullMatch.range(of: "Destination: ") {
                return String(fullMatch[colonIndex.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Check for ExtractAudio output
        let extractPattern = #"\[ExtractAudio\] Destination: (.+)$"#
        if let extractMatch = line.range(of: extractPattern, options: .regularExpression) {
            let fullMatch = String(line[extractMatch])
            if let colonIndex = fullMatch.range(of: "Destination: ") {
                return String(fullMatch[colonIndex.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    /// Parses video title from yt-dlp metadata output
    /// Example lines:
    /// [youtube] Extracting URL: https://...
    /// [youtube] VIDEO_ID: Downloading webpage
    /// [info] VIDEO_ID: Downloading 1 format(s)
    /// [download] Destination: Video Title.mp4
    static func parseTitle(_ line: String) -> String? {
        // From destination line - most reliable
        if line.contains("Destination:") {
            let destPattern = #"Destination:\s*(.+)\.(mp4|mkv|webm|mov|avi|flv|ts|m4v)$"#
            if let destMatch = line.range(of: destPattern, options: .regularExpression) {
                var fullMatch = String(line[destMatch])
                if let colonIndex = fullMatch.range(of: "Destination:") {
                    fullMatch = String(fullMatch[colonIndex.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                // Remove extension
                if let dotIndex = fullMatch.lastIndex(of: ".") {
                    return String(fullMatch[..<dotIndex])
                }
                return fullMatch
            }
        }

        // From extraction info: [youtube] Title: Downloading
        let titlePattern = #"\[.*\] (.+): Downloading"#
        if let titleMatch = line.range(of: titlePattern, options: .regularExpression) {
            let fullMatch = String(line[titleMatch])
            if let colonIndex = fullMatch.range(of: ": Downloading") {
                let afterBracket = fullMatch.firstIndex(of: "]")
                if let start = afterBracket {
                    let titleStart = fullMatch.index(after: start)
                    let title = String(fullMatch[titleStart..<colonIndex.lowerBound]).trimmingCharacters(in: .whitespaces)
                    // Skip if it looks like a video ID (short alphanumeric)
                    if title.count > 15 || title.contains(" ") {
                        return title
                    }
                }
            }
        }

        // From merger output: [Merger] Merging formats into "Video Title.mp4"
        let mergerPattern = #"\[Merger\] Merging formats into \"(.+)\""#
        if let mergerMatch = line.range(of: mergerPattern, options: .regularExpression) {
            let fullMatch = String(line[mergerMatch])
            if let firstQuote = fullMatch.firstIndex(of: "\""),
               let lastQuote = fullMatch.lastIndex(of: "\""),
               firstQuote < lastQuote {
                let pathStart = fullMatch.index(after: firstQuote)
                var title = String(fullMatch[pathStart..<lastQuote])
                // Remove extension
                if let dotIndex = title.lastIndex(of: ".") {
                    title = String(title[..<dotIndex])
                }
                return title
            }
        }

        return nil
    }

    /// Checks if the line indicates an error
    static func parseError(_ line: String) -> String? {
        if line.contains("ERROR:") {
            if let errorIndex = line.range(of: "ERROR:") {
                return String(line[errorIndex.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            return line
        }
        return nil
    }
}
