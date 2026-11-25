// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

struct ParsingUtils {
    private static let durationRegex = try! NSRegularExpression(pattern: "Duration: (\\d+):(\\d+):(\\d+)\\.(\\d+)", options: .caseInsensitive)
    private static let timeRegex = try! NSRegularExpression(pattern: "time=(\\d+):(\\d+):(\\d+)\\.(\\d+)", options: .caseInsensitive)
    private static let frameRegex = try! NSRegularExpression(pattern: "frame=\\s*(\\d+)", options: .caseInsensitive)
    private static let speedRegex = try! NSRegularExpression(pattern: "speed=\\s*([\\d.]+)x", options: .caseInsensitive)
    private static let streamVideoFPSRegex = try! NSRegularExpression(
        pattern: #"Stream\s+#0:\d+[^\n]*Video:[^\n]*?,\s*(\d+(?:\.\d+)?)\s+(?:fps|tbr)\b"#,
        options: .caseInsensitive
    )

    static func parseDuration(from output: String) -> Double? {
        if let match = durationRegex.firstMatch(in: output, options: [], range: NSRange(location: 0, length: output.utf16.count)) {
            if let hoursRange = Range(match.range(at: 1), in: output),
               let minutesRange = Range(match.range(at: 2), in: output),
               let secondsRange = Range(match.range(at: 3), in: output),
               let fractionalSecondsRange = Range(match.range(at: 4), in: output) {
                let hours = Double(output[hoursRange]) ?? 0
                let minutes = Double(output[minutesRange]) ?? 0
                let seconds = Double(output[secondsRange]) ?? 0
                let fractionalSeconds = Double("0.\(output[fractionalSecondsRange])") ?? 0
                return hours * 3600 + minutes * 60 + seconds + fractionalSeconds
            }
        }
        return nil
    }

    /// Parse input video frame rate from FFmpeg stream header lines
    /// (e.g. `Stream #0:0: Video: ..., 60 fps, 60 tbr`).
    static func parseVideoFrameRate(from output: String) -> Double? {
        guard let match = streamVideoFPSRegex.firstMatch(
            in: output, options: [], range: NSRange(location: 0, length: output.utf16.count)
        ),
        let fpsRange = Range(match.range(at: 1), in: output),
        let fps = Double(output[fpsRange]),
        fps > 0, fps <= 1000 else {
            return nil
        }
        return fps
    }

    /// Parse encoding speed from FFmpeg output (speed=Nx format)
    static func parseSpeed(from output: String) -> Double? {
        if let match = speedRegex.firstMatch(in: output, options: [], range: NSRange(location: 0, length: output.utf16.count)) {
            if let speedRange = Range(match.range(at: 1), in: output) {
                if let speed = Double(output[speedRange]), speed > 0.01 {
                    return speed
                }
            }
        }
        return nil
    }

    /// Parse time-based progress from FFmpeg output (time=HH:MM:SS.xx format)
    static func parseTimeProgress(
        from output: String,
        totalDuration: Double?,
        fallbackSpeed: Double? = nil
    ) -> (Double, String?)? {
        guard let totalDuration = totalDuration, totalDuration > 0 else { return nil }

        // Match time= with positive values only (negative times from stream copy are invalid)
        if let match = timeRegex.firstMatch(in: output, options: [], range: NSRange(location: 0, length: output.utf16.count)) {
            if let hoursRange = Range(match.range(at: 1), in: output),
               let minutesRange = Range(match.range(at: 2), in: output),
               let secondsRange = Range(match.range(at: 3), in: output),
               let fractionalSecondsRange = Range(match.range(at: 4), in: output) {
                let hours = Double(output[hoursRange]) ?? 0
                let minutes = Double(output[minutesRange]) ?? 0
                let seconds = Double(output[secondsRange]) ?? 0
                let fractionalSeconds = Double("0.\(output[fractionalSecondsRange])") ?? 0
                let currentTime = hours * 3600 + minutes * 60 + seconds + fractionalSeconds

                // Skip if time is 0 or very small (likely invalid)
                guard currentTime > 0.1 else { return nil }

                var progress = currentTime / totalDuration
                progress = min(max(progress, 0.0), 1.0)

                var etaString: String? = nil
                let remainingTime = max(totalDuration - currentTime, 0)
                if let speed = parseSpeed(from: output) ?? fallbackSpeed, remainingTime > 0 {
                    // ETA = remaining media time / encoding speed
                    let eta = remainingTime / speed
                    if eta.isFinite && eta < 86400 { // Cap at 24 hours
                        etaString = String(format: "%02d:%02d:%02d", Int(eta) / 3600, (Int(eta) % 3600) / 60, Int(eta) % 60)
                    }
                }

                return (progress, etaString)
            }
        }
        return nil
    }

    /// Parse frame number from FFmpeg output (frame=XXXX format)
    static func parseFrameNumber(from output: String) -> Int? {
        // Match frame= followed by digits (handles both regular output and -progress output)
        if let match = frameRegex.firstMatch(in: output, options: [], range: NSRange(location: 0, length: output.utf16.count)) {
            if let frameRange = Range(match.range(at: 1), in: output) {
                return Int(output[frameRange])
            }
        }
        return nil
    }

    /// Parse frame-based progress from FFmpeg output
    /// - Parameters:
    ///   - output: FFmpeg output string
    ///   - totalDuration: Total duration in seconds
    ///   - frameRate: Assumed frame rate (default 24fps)
    /// - Returns: Progress tuple (0-1) and ETA string, or nil if parsing fails
    static func parseFrameProgress(
        from output: String,
        totalDuration: Double?,
        frameRate: Double = 24.0,
        fallbackSpeed: Double? = nil
    ) -> (Double, String?, Int?)? {
        guard let totalDuration = totalDuration, totalDuration > 0 else { return nil }
        guard let currentFrame = parseFrameNumber(from: output) else { return nil }

        let expectedFrames = totalDuration * frameRate
        guard expectedFrames > 0 else { return nil }

        var progress = Double(currentFrame) / expectedFrames
        progress = min(max(progress, 0.0), 1.0)

        var etaString: String? = nil
        let remainingFrames = max(expectedFrames - Double(currentFrame), 0)
        let remainingMediaTime = remainingFrames / frameRate
        if let speed = parseSpeed(from: output) ?? fallbackSpeed, remainingMediaTime > 0 {
            // ETA = remaining media time / encoding speed
            let eta = remainingMediaTime / speed
            if eta.isFinite && eta < 86400 && eta > 0 {
                etaString = String(format: "%02d:%02d:%02d", Int(eta) / 3600, (Int(eta) % 3600) / 60, Int(eta) % 60)
            }
        }

        return (progress, etaString, currentFrame)
    }

    /// Combined progress parsing - tries time-based first, falls back to frame-based
    static func parseProgress(from output: String, totalDuration: Double?, frameRate: Double = 24.0) -> (Double, String?)? {
        // Try time-based progress first (works for encoding)
        if let timeProgress = parseTimeProgress(from: output, totalDuration: totalDuration) {
            return timeProgress
        }

        // Fall back to frame-based progress (works for stream copy)
        if let frameProgress = parseFrameProgress(from: output, totalDuration: totalDuration, frameRate: frameRate) {
            return (frameProgress.0, frameProgress.1)
        }

        return nil
    }
}
