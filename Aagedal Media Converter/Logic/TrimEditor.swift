// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

/// Pure trim-range geometry shared by the timeline gestures, the trim bindings and the I/O keys.
///
/// Times are in seconds. `step` is the snapping grid — one frame for video — and also the
/// shortest range allowed, so a trim can never collapse to zero length.
struct TrimEditor: Sendable {
    let duration: Double
    let step: Double

    /// Grid used when the frame rate is unknown or the source has no video.
    static let fallbackStep = 0.01

    init(duration: Double, step: Double) {
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.step = step.isFinite && step > 0 ? step : Self.fallbackStep
    }

    init(duration: Double, frameRate: Double?) {
        let step = frameRate.flatMap { $0.isFinite && $0 > 0 ? 1 / $0 : nil } ?? Self.fallbackStep
        self.init(duration: duration, step: step)
    }

    /// Shortest allowed range; never more than the whole duration.
    var minimumLength: Double { min(step, duration) }

    func snap(_ time: Double) -> Double {
        (time / step).rounded() * step
    }

    func clampedTime(_ time: Double) -> Double {
        min(max(time.isFinite ? time : 0, 0), duration)
    }

    // MARK: Handle drags

    /// Start handle moved to `time`, snapped and kept at least one step before `end`.
    func start(_ time: Double, end: Double) -> Double {
        min(max(snap(time), 0), max(0, end - minimumLength))
    }

    /// End handle moved to `time`, snapped and kept at least one step after `start`.
    func end(_ time: Double, start: Double) -> Double {
        max(min(snap(time), duration), min(duration, start + minimumLength))
    }

    /// Grows (positive) or shrinks (negative) both ends by the same snapped amount. Growth stops
    /// when either end reaches the media bounds, so the range stays centered on the original.
    func symmetric(start: Double, end: Double, growth: Double) -> (start: Double, end: Double) {
        // Limits are whole steps, so a range on the grid stays on it when it hits a limit.
        let maxGrowth = wholeSteps(in: min(start, duration - end))
        let minGrowth = -wholeSteps(in: ((end - start) - minimumLength) / 2)
        let applied = min(max(snap(growth), minGrowth), maxGrowth)
        return (start - applied, end + applied)
    }

    /// The longest whole number of steps that fits in `length`; zero for negative lengths.
    private func wholeSteps(in length: Double) -> Double {
        guard length > 0 else { return 0 }
        // Tolerate rounding error so an exact multiple of the step is not cut short.
        return (length / step + 1e-9).rounded(.down) * step
    }

    /// Moves the whole range by a snapped offset, keeping its length exactly.
    func slid(start: Double, end: Double, by offset: Double) -> (start: Double, end: Double) {
        let applied = min(max(snap(offset), -start), duration - end)
        return (start + applied, end + applied)
    }

    // MARK: Stored values

    /// Trim start as stored on the item: `nil` within half a step of the beginning.
    func storedStart(_ time: Double) -> Double? {
        let time = clampedTime(time)
        return time < step / 2 ? nil : time
    }

    /// Trim end as stored on the item: `nil` within half a step of the end.
    func storedEnd(_ time: Double) -> Double? {
        let time = clampedTime(time)
        return time > duration - step / 2 ? nil : time
    }

    /// Sets the in-point at `time` (I key, or a binding write). An in-point at or after the
    /// out-point clears the out-point instead of collapsing the range.
    func settingIn(_ time: Double, end: Double?) -> (start: Double?, end: Double?) {
        let start = min(clampedTime(time), max(0, duration - minimumLength))
        let storedStart = storedStart(start)
        guard let end else { return (storedStart, nil) }
        return end - start < minimumLength ? (storedStart, nil) : (storedStart, end)
    }

    /// Sets the out-point at `time` (O key, or a binding write). An out-point at or before the
    /// in-point clears the in-point instead of collapsing the range.
    func settingOut(_ time: Double, start: Double?) -> (start: Double?, end: Double?) {
        let end = max(clampedTime(time), min(duration, minimumLength))
        let storedEnd = storedEnd(end)
        guard let start else { return (nil, storedEnd) }
        return end - start < minimumLength ? (nil, storedEnd) : (start, storedEnd)
    }
}
