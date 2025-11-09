//
//  FFMPEGProgressParser.swift
//  Aagedal Media Converter
//
//  Created by Truls Aagedal on 09/11/2025.
//

// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

enum FFMPEGProgressParser {
    /// Processes FFmpeg output to extract progress and duration information.
    /// - Parameters:
    ///   - output: The FFmpeg output string to process
    ///   - totalDuration: The current total duration if already known
    ///   - effectiveDuration: The effective duration for ETA calculation (trimmed duration if applicable)
    ///   - progressUpdate: Callback to report progress updates
    /// - Returns: A tuple containing the updated total duration (if found) and the current progress
    static func handleOutput(
        _ output: String,
        totalDuration: Double?,
        effectiveDuration: Double?,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void
    ) -> (Double?, (Double, String?)?) {
        var newTotalDuration = totalDuration

        // Try to parse the total duration if not already known
        if newTotalDuration == nil, let duration = ParsingUtils.parseDuration(from: output) {
            newTotalDuration = duration
            print("Total Duration: \(duration) seconds")
        }

        let durationForProgress = effectiveDuration ?? newTotalDuration

        var progressTuple: (Double, String?)? = nil
        if let progress = ParsingUtils.parseProgress(from: output, totalDuration: durationForProgress) {
            Task { @MainActor in
                progressUpdate(progress.0, progress.1)
                print("Progress: \(Int(progress.0 * 100))% ETA: \(progress.1 ?? "N/A")")
            }
            progressTuple = progress
        }

        return (newTotalDuration, progressTuple)
    }
}
