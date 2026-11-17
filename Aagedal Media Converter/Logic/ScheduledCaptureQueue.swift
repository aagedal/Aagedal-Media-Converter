// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One scheduled screen recording. It records with the record-mode settings in effect when it
/// starts.
struct ScheduledCapture: Identifiable, Equatable, Sendable {
    let id: UUID
    var start: Date
    /// Auto-stop after this long; nil records until stopped.
    var duration: TimeInterval?

    init(id: UUID = UUID(), start: Date, duration: TimeInterval?) {
        self.id = id
        self.start = start
        self.duration = duration
    }

    /// The start of the minute holding `date`. Starts are whole minutes, since the picker shows
    /// none of the seconds: a leftover 44 s would start "09:57" at 09:57:44.
    static func minuteStart(of date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .minute, for: date)?.start ?? date
    }

    /// The planned stop time, or nil when the recording runs until stopped.
    var end: Date? { duration.map { start.addingTimeInterval($0) } }

    /// Whether the two recordings would run at the same time. A recording without a stop time
    /// overlaps everything that starts after it.
    func overlaps(_ other: ScheduledCapture) -> Bool {
        start < (other.end ?? .distantFuture) && other.start < (end ?? .distantFuture)
    }
}

/// The scheduled recordings waiting in record mode, soonest first. Shared rather than kept in the
/// control panel, which is rebuilt for each record-mode session; record mode stays open between
/// scheduled recordings, and after them.
@MainActor
final class ScheduledCaptureQueue: ObservableObject {
    static let shared = ScheduledCaptureQueue()

    @Published private(set) var entries: [ScheduledCapture] = []
    /// Whether a scheduled recording has started in this record-mode session. Record mode then
    /// stays open after recordings finish, so the user comes back to it rather than to a closed
    /// overlay.
    private(set) var didStartRecording = false
    /// From `takeDue` until `finishStarting`: the recording is starting but not yet recording,
    /// so neither the next entry nor leaving record mode may interrupt it.
    @Published private(set) var isStartingRecording = false

    private let keepsDisplayAwake: Bool
    private var powerAssertion: UUID?

    init(keepsDisplayAwake: Bool = true) {
        self.keepsDisplayAwake = keepsDisplayAwake
    }

    /// The queued recording that `entry` would overlap, ignoring the queued copy of `entry`
    /// itself when it is being edited.
    func conflict(with entry: ScheduledCapture) -> ScheduledCapture? {
        entries.first { $0.id != entry.id && $0.overlaps(entry) }
    }

    /// Adds `entry`, or replaces the queued entry with the same id. Returns false, leaving the
    /// queue unchanged, when it would overlap another recording.
    @discardableResult
    func save(_ entry: ScheduledCapture) -> Bool {
        guard conflict(with: entry) == nil else { return false }
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        entries.sort { $0.start < $1.start }
        updatePowerAssertion()
        return true
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        updatePowerAssertion()
    }

    func removeAll() {
        entries.removeAll()
        updatePowerAssertion()
    }

    /// Clears the queue for a new record-mode session.
    func reset() {
        removeAll()
        didStartRecording = false
        isStartingRecording = false
    }

    /// Removes and returns the first recording when its start time has come, and marks it as
    /// starting. Recordings whose stop time passed while another recording ran are dropped;
    /// entries never overlap, so at most one due recording is still within its time.
    func takeDue(now: Date = Date()) -> ScheduledCapture? {
        guard !isStartingRecording else { return nil }
        defer { updatePowerAssertion() }
        entries.removeAll { $0.end.map { $0 <= now } ?? false }
        guard let first = entries.first, first.start <= now else { return nil }
        entries.removeFirst()
        didStartRecording = true
        isStartingRecording = true
        return first
    }

    func finishStarting() {
        isStartingRecording = false
    }

    /// A start time for a new recording: the first whole minute at least five minutes from now
    /// and after the last queued recording ends.
    func suggestedStart(now: Date = Date(), calendar: Calendar = .current) -> Date {
        var earliest = now.addingTimeInterval(5 * 60)
        // Entries never overlap, so the last one to start is also the last to end.
        if let lastEnd = entries.last?.end, lastEnd > earliest { earliest = lastEnd }
        let minute = ScheduledCapture.minuteStart(of: earliest, calendar: calendar)
        return minute < earliest ? minute.addingTimeInterval(60) : minute
    }

    // The display, not just the system, must stay awake: an idle display sleep locks the
    // screen, and a recording would then start into a lock screen and capture nothing.
    private func updatePowerAssertion() {
        guard keepsDisplayAwake else { return }
        if entries.isEmpty {
            PowerAssertion.display.release(powerAssertion)
            powerAssertion = nil
        } else if powerAssertion == nil {
            powerAssertion = PowerAssertion.display.acquire(reason: "Waiting for scheduled screen recording")
        }
    }
}
