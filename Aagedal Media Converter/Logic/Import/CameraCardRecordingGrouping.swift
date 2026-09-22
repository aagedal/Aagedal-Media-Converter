// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Date grouping is deliberately independent of card scanning. A caller must first
/// resolve spanned clips into complete logical recordings; filenames and filesystem
/// dates are not reliable evidence of either a span or a recording timestamp.
enum CameraCardRecordingGrouping {
    /// The reviewer explicitly marks which files continue the previous recording.
    /// A scanner must not infer this from adjacent names or timestamps.
    static func resolvedSegments(urls: [URL], continuesPrevious: Set<URL>) -> [[URL]] {
        var result: [[URL]] = []
        for url in urls {
            if continuesPrevious.contains(url), !result.isEmpty {
                result[result.count - 1].append(url)
            } else {
                result.append([url])
            }
        }
        return result
    }

    struct Recording: Equatable {
        /// All segments, in playback order. A recording is indivisible here.
        let urls: [URL]
        let start: Date?
        /// Complete logical duration, not just the first segment's duration.
        let duration: TimeInterval?

        init(urls: [URL], cameraDate: Date?, containerDate: Date?, duration: TimeInterval?) {
            self.urls = urls
            self.start = Self.validDate(cameraDate) ?? Self.validDate(containerDate)
            self.duration = duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }

        private static func validDate(_ date: Date?) -> Date? {
            date.flatMap { $0.timeIntervalSinceReferenceDate.isFinite ? $0 : nil }
        }

        var end: Date? {
            guard let start, let duration else { return nil }
            return Self.validDate(start.addingTimeInterval(duration))
        }
    }

    enum Mode {
        case singleGroup
        case recordingDay(splitOnLongGaps: Bool)
    }

    enum Compatibility: Equatable {
        case compatible
        case incompatible
        case unknown
    }

    struct ProposedGroup: Equatable {
        let recordings: [Recording]
        /// Unknown or internally incompatible spans require review; they must
        /// never be converted into multiple recordings to make a merge pass.
        let compatibility: Compatibility

        var urls: [URL] { recordings.flatMap(\.urls) }
        var requiresReview: Bool { compatibility != .compatible }
    }

    /// Produces a conservative proposal after logical spans have been resolved.
    /// The evaluator must inspect every URL, including every segment of a span,
    /// and return `unknown` for missing metadata. It must not accept a group by
    /// comparing only the first segment or ignoring unprobed files.
    ///
    /// Compatibility partitions are contiguous: A/B/A stays A/B/A, never A/A/B.
    /// Unknown or conflicting recordings remain intact in isolated review groups.
    /// `singleGroup` bypasses all splitting but still exposes compatibility, so a
    /// future preview can offer retaining one group without implying it can merge.
    static func proposal(
        for recordings: [Recording],
        mode: Mode,
        timeZone: TimeZone,
        evaluateCompatibility: ([URL]) -> Compatibility
    ) -> [ProposedGroup] {
        guard !recordings.isEmpty else { return [] }

        func compatibility(of recordings: [Recording]) -> Compatibility {
            guard recordings.allSatisfy({ !$0.urls.isEmpty }) else { return .unknown }
            return evaluateCompatibility(recordings.flatMap(\.urls))
        }

        if case .singleGroup = mode {
            return [ProposedGroup(recordings: recordings, compatibility: compatibility(of: recordings))]
        }

        var result: [ProposedGroup] = []
        for datedGroup in groups(for: recordings, mode: mode, timeZone: timeZone) {
            var pending: [Recording] = []
            for recording in datedGroup {
                let status = compatibility(of: [recording])
                guard status == .compatible else {
                    if !pending.isEmpty {
                        result.append(ProposedGroup(recordings: pending, compatibility: .compatible))
                        pending = []
                    }
                    result.append(ProposedGroup(recordings: [recording], compatibility: status))
                    continue
                }

                if !pending.isEmpty, compatibility(of: pending + [recording]) != .compatible {
                    result.append(ProposedGroup(recordings: pending, compatibility: .compatible))
                    pending = []
                }
                pending.append(recording)
            }
            if !pending.isEmpty {
                result.append(ProposedGroup(recordings: pending, compatibility: .compatible))
            }
        }
        return result
    }

    /// Uses one explicitly chosen timezone for the whole import. Camera offset
    /// changes therefore do not change the interpretation of the day mid-card.
    /// Unknown dates form separate contiguous runs; no filesystem fallback or
    /// guessed date is used. Missing durations disable only the gap comparison.
    /// The result preserves input order, including repeated, nonadjacent days.
    /// Compatibility splitting can be applied within these groups afterwards,
    /// provided it also treats each logical recording as indivisible.
    static func groups(
        for recordings: [Recording],
        mode: Mode,
        timeZone: TimeZone
    ) -> [[Recording]] {
        guard !recordings.isEmpty else { return [] }
        guard case .recordingDay(let splitOnLongGaps) = mode else { return [recordings] }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var result: [[Recording]] = []
        var previous: Recording?

        for recording in recordings {
            let startsGroup: Bool
            if let previous {
                switch (previous.start, recording.start) {
                case let (previousStart?, start?):
                    let changesDay = !calendar.isDate(previousStart, inSameDayAs: start)
                    let hasLongGap = splitOnLongGaps && previous.end.map {
                        start.timeIntervalSince($0) > 2 * 60 * 60
                    } == true
                    startsGroup = changesDay || hasLongGap
                case (nil, nil):
                    startsGroup = false
                default:
                    startsGroup = true
                }
            } else {
                startsGroup = true
            }

            if startsGroup {
                result.append([recording])
            } else {
                result[result.count - 1].append(recording)
            }
            previous = recording
        }
        return result
    }
}
