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
import os

/// Tracks frame stall state for detecting when FFmpeg is closing the file
final class FrameStallTracker: Sendable {
    private struct State {
        var lastFrame: Int = -1
        var lastFrameChangeTime: Date = Date()
        var hasReportedStall: Bool = false
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let stallThreshold: TimeInterval = 5.0  // 5 seconds

    /// Updates the tracker with a new frame number
    /// - Returns: "Closing file..." if stalled, nil otherwise
    func update(frame: Int) -> String? {
        lock.withLock { state in
            let now = Date()

            if frame != state.lastFrame {
                // Frame changed, reset stall tracking
                state.lastFrame = frame
                state.lastFrameChangeTime = now
                state.hasReportedStall = false
                return nil
            }

            // Frame hasn't changed - check for stall
            let stallDuration = now.timeIntervalSince(state.lastFrameChangeTime)
            if stallDuration >= stallThreshold && !state.hasReportedStall {
                state.hasReportedStall = true
                return "Closing file..."
            }

            return state.hasReportedStall ? "Closing file..." : nil
        }
    }

    func reset() {
        lock.withLock { state in
            state.lastFrame = -1
            state.lastFrameChangeTime = Date()
            state.hasReportedStall = false
        }
    }
}

/// Throttles progress update dispatches to the main thread to avoid excessive
/// SwiftUI re-renders. Without throttling, FFmpeg stderr output fires progress
/// callbacks 5-10x/sec, each mutating @State arrays and triggering full
/// updateNSView cycles — causing scroll lag with many queued items.
final class ProgressThrottler: Sendable {
    private struct State {
        var lastDispatchTime: Date = .distantPast
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let minInterval: TimeInterval

    /// - Parameter minInterval: Minimum seconds between dispatches (default 0.25 = 4 Hz)
    init(minInterval: TimeInterval = 0.25) {
        self.minInterval = minInterval
    }

    /// Returns true if the update should be dispatched to the UI.
    /// Always allows completion (progress >= 1.0) through immediately.
    func shouldDispatch(progress: Double) -> Bool {
        // Never throttle completion
        if progress >= 1.0 { return true }

        return lock.withLock { state in
            let now = Date()
            guard now.timeIntervalSince(state.lastDispatchTime) >= minInterval else {
                return false
            }
            state.lastDispatchTime = now
            return true
        }
    }
}

enum FFMPEGProgressParser {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "FFMPEGProgressParser")

    /// Processes FFmpeg output to extract progress and duration information.
    /// - Parameters:
    ///   - output: The FFmpeg output string to process
    ///   - totalDuration: The current total duration if already known
    ///   - effectiveDuration: The effective duration for ETA calculation (trimmed duration if applicable)
    ///   - frameRate: Video frame rate for frame-based progress calculation (default 24fps)
    ///   - frameStallTracker: Optional tracker for detecting frame stalls
    ///   - progressUpdate: Callback to report progress updates
    /// - Returns: A tuple containing the updated total duration (if found) and the current progress
    static func handleOutput(
        _ output: String,
        totalDuration: Double?,
        effectiveDuration: Double?,
        frameRate: Double = 24.0,
        frameStallTracker: FrameStallTracker? = nil,
        progressThrottler: ProgressThrottler? = nil,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void
    ) -> (Double?, (Double, String?)?) {
        var newTotalDuration = totalDuration

        // Try to parse the total duration if not already known
        if newTotalDuration == nil, let duration = ParsingUtils.parseDuration(from: output) {
            newTotalDuration = duration
            logger.debug("Total Duration: \(duration, privacy: .public) seconds")
        }

        let durationForProgress = effectiveDuration ?? newTotalDuration

        var progressTuple: (Double, String?)? = nil

        // Try time-based progress first (works for encoding)
        if let progress = ParsingUtils.parseTimeProgress(from: output, totalDuration: durationForProgress) {
            progressTuple = progress
            if progressThrottler?.shouldDispatch(progress: progress.0) ?? true {
                Task { @MainActor in
                    progressUpdate(progress.0, progress.1)
                }
            }
        }
        // Fall back to frame-based progress (works for stream copy)
        else if let frameProgress = ParsingUtils.parseFrameProgress(from: output, totalDuration: durationForProgress, frameRate: frameRate) {
            var etaString = frameProgress.1

            // Check for frame stall (FFmpeg closing file)
            if let tracker = frameStallTracker, let frame = frameProgress.2 {
                if let stallMessage = tracker.update(frame: frame) {
                    etaString = stallMessage
                }
            }

            progressTuple = (frameProgress.0, etaString)
            if progressThrottler?.shouldDispatch(progress: frameProgress.0) ?? true {
                Task { @MainActor in
                    progressUpdate(frameProgress.0, etaString)
                }
            }
        }

        return (newTotalDuration, progressTuple)
    }
}

/// Separate the generation label from an estimate for all remaining generations.
struct RecursiveEncodingProgress: Sendable {
    let fraction: Double
    let message: String
    let eta: String?

    init(progress: Double, status: String?, generation: Int, total: Int) {
        let passFraction = progress.isFinite ? min(1, max(0, progress)) : 0
        fraction = (Double(generation - 1) + passFraction) / Double(total)
        let label = "Generation \(generation)/\(total)"
        if let status, status.range(of: #"^\d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil {
            message = label
            let parts = status.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 3 else { eta = nil; return }
            let remaining = parts[0] * 3600 + parts[1] * 60 + parts[2]
            // Assuming later passes encode at the current rate, scale this pass's
            // remaining time by the remaining fraction of the entire chain.
            let estimate = passFraction < 1
                ? remaining * (Double(total - generation) + 1 - passFraction) / (1 - passFraction)
                : .infinity
            if estimate.isFinite, estimate >= 0, estimate < 86_400 {
                let seconds = Int(estimate)
                eta = String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            } else {
                eta = nil
            }
        } else {
            message = label + (status.map { " · " + $0 } ?? "")
            eta = nil
        }
    }
}
