//
//  EncodeHistoryTracker.swift
//  Aagedal Media Converter
//
//  Turns successive snapshots of queue row statuses into encode start/finish
//  events. Observing rows (instead of hooking the engines) covers both the
//  legacy ConversionManager path and projected ApplicationJobService rows.
//

import Foundation

struct EncodeHistoryTracker {
    typealias Status = ConversionManager.ConversionStatus

    enum Event: Equatable {
        case started(UUID)
        case finished(UUID, EncodeOutcome)
    }

    private(set) var statuses: [UUID: Status] = [:]

    /// Number of rows currently encoding.
    var convertingCount: Int { statuses.values.lazy.filter { $0 == .converting }.count }

    mutating func update(_ rows: [(id: UUID, status: Status)]) -> [Event] {
        var events: [Event] = []
        var next: [UUID: Status] = [:]
        next.reserveCapacity(rows.count)

        for row in rows {
            next[row.id] = row.status
            let previous = statuses[row.id]
            if row.status == .converting, previous != .converting {
                events.append(.started(row.id))
            } else if previous == .converting, row.status != .converting {
                events.append(.finished(row.id, Self.outcome(for: row.status)))
            }
        }
        // A row removed mid-encode was cancelled by the removal.
        for (id, status) in statuses where status == .converting && next[id] == nil {
            events.append(.finished(id, .cancelled))
        }

        statuses = next
        return events
    }

    static func outcome(for status: Status) -> EncodeOutcome {
        switch status {
        case .done: return .completed
        case .failed: return .failed
        case .cancelled, .waiting: return .cancelled
        case .converting: return .running
        }
    }
}
