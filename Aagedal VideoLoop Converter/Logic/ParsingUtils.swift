// Aagedal VideoLoop Converter 2.0
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

struct ParsingUtils {
    static func parseDuration(from output: String) -> Double? {
        print("Starting parseDuration Function")
        let durationRegex = try! NSRegularExpression(pattern: "Duration: (\\d+):(\\d+):(\\d+)\\.(\\d+)", options: .caseInsensitive)
        if let match = durationRegex.firstMatch(in: output, options: [], range: NSRange(location: 0, length: output.utf16.count)) {
            if let hoursRange = Range(match.range(at: 1), in: output),
               let minutesRange = Range(match.range(at: 2), in: output),
               let secondsRange = Range(match.range(at: 3), in: output),
               let millisecondsRange = Range(match.range(at: 4), in: output) {
                let hours = Double(output[hoursRange]) ?? 0
                let minutes = Double(output[minutesRange]) ?? 0
                let seconds = Double(output[secondsRange]) ?? 0
                let milliseconds = Double(output[millisecondsRange]) ?? 0
                return hours * 3600 + minutes * 60 + seconds + milliseconds / 100
            }
        }
        print("returning nil from parseDuration")
        return nil
    }

    static func parseProgress(from output: String, totalDuration: Double?) -> (Double, String?)? {
        print("Starting parseProgress Function")
        guard let totalDuration = totalDuration else { return nil }
        
        let timeRegex = try! NSRegularExpression(pattern: "time=(\\d+):(\\d+):(\\d+)\\.(\\d+)", options: .caseInsensitive)
        if let match = timeRegex.firstMatch(in: output, options: [], range: NSRange(location: 0, length: output.utf16.count)) {
            if let hoursRange = Range(match.range(at: 1), in: output),
               let minutesRange = Range(match.range(at: 2), in: output),
               let secondsRange = Range(match.range(at: 3), in: output),
               let millisecondsRange = Range(match.range(at: 4), in: output) {
                let hours = Double(output[hoursRange]) ?? 0
                let minutes = Double(output[minutesRange]) ?? 0
                let seconds = Double(output[secondsRange]) ?? 0
                let milliseconds = Double(output[millisecondsRange]) ?? 0
                let currentTime = hours * 3600 + minutes * 60 + seconds + milliseconds / 100
                var progress = currentTime / totalDuration
                // Clamp to valid range
                progress = min(max(progress, 0.0), 1.0)
                
                // Compute ETA safely only when progress > 0
                var etaString: String? = nil
                if progress > 0 {
                    let remainingTime = max(totalDuration - currentTime, 0)
                    let eta = remainingTime / progress
                    if eta.isFinite {
                        etaString = String(format: "%02d:%02d:%02d", Int(eta) / 3600, (Int(eta) % 3600) / 60, Int(eta) % 60)
                    }
                }
                
                print("Current Time: \(currentTime), Total Duration: \(totalDuration), Progress: \(progress), ETA: \(etaString ?? "n/a")")
                
                return (progress, etaString)
            } else {
                print("Time parsing failed for output: \(output)")
            }
        }
        print("returning nil from parseProgress")
        return nil
    }
}
