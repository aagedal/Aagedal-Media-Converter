// Aagedal Media Converter
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreFoundation
import Foundation

/// Consumes the experimental filter-boundary transport. The supplied clock must
/// be qualified separately: these measurements never establish device timing.
struct MPVAudioMeterHistory: Sendable {
    struct Outcome: Equatable, Sendable {
        let accepted: Bool
        let needsFilterRestart: Bool
        let reason: String?
    }

    private struct Frame: Sendable {
        let sequence: UInt64
        let raw: Data
        let start: Double
        let end: Double
        let rate: Double
        let sampleRate: UInt64
        let measuredDuration: Double
        let speed: Double
        let layout: String
        let metadata: [String: String]
        var history: Double = 0
    }

    private struct Snapshot: Sendable {
        let instance: UInt64
        let epoch: UInt64
        let last: UInt64
        let evicted: UInt64
        let rejected: UInt64
        let resetReason: String
        let frames: [Frame]
    }

    private(set) var generation: UInt64
    private(set) var needsFilterRestart = false
    var bufferedFrameCount: Int { queue.count }
    private var instance: UInt64?
    private var epoch: UInt64 = 0
    private var lastSequence: UInt64 = 0
    private var evicted: UInt64 = 0
    private var rejected: UInt64 = 0
    // Only the current transport snapshot is cached (at most 128 records).
    // Ring reads repeat most records: their exact raw identity permits reusing
    // already validated inner JSON without repeating metadata allocations.
    private var parsedFrames: [UInt64: Frame] = [:]
    private var queue: [Frame] = []
    private var previous: Frame?
    private var continuousMeasuredDuration = 0.0
    private var lastClock: Double?

    init(generation: UInt64 = 0) { self.generation = generation }

    mutating func reset(generation: UInt64) { self = Self(generation: generation) }

    @discardableResult
    mutating func markUnavailable(generation: UInt64) -> Outcome {
        guard generation == self.generation else { return outcome(false, "Stale player generation") }
        return invalidate("Meter history unavailable")
    }

    @discardableResult
    mutating func ingest(json: String, generation: UInt64) -> Outcome {
        guard generation == self.generation else { return outcome(false, "Stale player generation") }
        guard let snapshot = Self.decode(json, cachedInstance: instance, cachedEpoch: epoch,
            cachedFrames: parsedFrames) else { return invalidate("Invalid meter history") }
        let fresh = instance != snapshot.instance
        if let instance, snapshot.instance < instance { return invalidate("Retired filter instance") }
        if !fresh {
            guard snapshot.epoch >= epoch, snapshot.last >= lastSequence,
                  snapshot.evicted >= evicted, snapshot.rejected >= rejected else {
                return invalidate("Backward meter history counters")
            }
            if snapshot.epoch == epoch {
                for frame in snapshot.frames where frame.sequence <= lastSequence {
                    // decode already checked byte identity against this cache.
                    guard parsedFrames[frame.sequence] != nil else {
                        return invalidate("Changed or unrecognized repeated frame")
                    }
                }
            }
        }

        var reason: String?
        // free_graph recreates ebur128 and clears retained records, while the
        // transport's sequence counter remains monotonic. A first snapshot from
        // that new graph can establish a baseline without losing another output
        // buffer to filter recreation. Loss/rejection and later epoch changes
        // still require a new filter instance.
        let graphResetBaseline = fresh && snapshot.epoch > 0
            && snapshot.resetReason == "graph-reset" && snapshot.evicted == 0 && snapshot.rejected == 0
        if fresh {
            queue.removeAll(keepingCapacity: true)
            previous = nil
            continuousMeasuredDuration = 0
            parsedFrames.removeAll(keepingCapacity: true)
            lastSequence = graphResetBaseline ? (snapshot.frames.first.map { $0.sequence - 1 } ?? snapshot.last) : 0
            lastClock = nil
            needsFilterRestart = false
            if (snapshot.epoch != 0 && !graphResetBaseline) || snapshot.rejected != 0 {
                reason = "Filter history began after a discontinuity"
            }
        } else if snapshot.epoch != epoch || snapshot.rejected != rejected {
            reason = "Filter history discontinuity"
        }
        if snapshot.last > 0 && !(graphResetBaseline && snapshot.frames.isEmpty)
            && (snapshot.frames.isEmpty || snapshot.frames.last?.sequence != snapshot.last) {
            reason = "Missing trailing meter records"
        }
        if reason != nil { clearPublication() }
        instance = snapshot.instance
        epoch = snapshot.epoch
        evicted = snapshot.evicted
        rejected = snapshot.rejected

        for var frame in snapshot.frames where fresh || frame.sequence > lastSequence {
            let expected = lastSequence.addingReportingOverflow(1)
            if expected.overflow || frame.sequence != expected.partialValue {
                reason = "Missing received meter records"
                clearPublication()
            }
            if let previous {
                let tolerance = 0.5 / min(previous.rate, frame.rate) + 0.000002
                if previous.layout != frame.layout || previous.sampleRate != frame.sampleRate
                    || previous.speed != frame.speed || abs(frame.start - previous.end) > tolerance {
                    reason = "Discontinuous measured audio"
                    clearPublication()
                }
            }
            // ebur128 windows count nominal decoded samples. Media PTS spans
            // can be scaled by frame speed and must not warm loudness early.
            continuousMeasuredDuration += frame.measuredDuration
            frame.history = continuousMeasuredDuration
            queue.append(frame)
            previous = frame
            lastSequence = frame.sequence
        }
        // The envelope includes rejected sequences, even when no frame was retained.
        lastSequence = snapshot.last
        parsedFrames = Dictionary(uniqueKeysWithValues: snapshot.frames.map { ($0.sequence, $0) })
        if queue.count > 256 || (queue.last.map { end in queue.first.map { end.end - $0.start > 30 } ?? false } ?? false) {
            return invalidate("Unconsumed meter history exceeds bounds")
        }
        return outcome(true, reason)
    }

    /// Values become eligible at the measured interval's end, never at receipt.
    /// Rewinding requires a fresh filter instance before loudness is trusted again.
    mutating func sample(at clock: Double, generation: UInt64) -> PlaybackAudioMeterSample? {
        guard generation == self.generation, clock.isFinite else { return nil }
        if let lastClock, clock < lastClock - 0.000002 {
            _ = invalidate("Presentation clock rewound")
            self.lastClock = clock
            return nil
        }
        lastClock = clock
        guard let index = queue.lastIndex(where: { $0.end <= clock }) else { return nil }
        let frame = queue[index]
        if index > 0 { queue.removeFirst(index) }
        let freshness = max(0.2, min(1, 2 * (frame.end - frame.start)))
        guard clock - frame.end <= freshness else { return nil }
        return MPVAudioMeterMetadata.sample(frame.metadata, seconds: frame.end,
            history: needsFilterRestart ? 0 : frame.history + 0.000002)
    }

    private mutating func clearPublication() {
        queue.removeAll(keepingCapacity: true)
        previous = nil
        continuousMeasuredDuration = 0
        needsFilterRestart = true
    }

    private mutating func invalidate(_ reason: String) -> Outcome {
        clearPublication()
        return outcome(false, reason)
    }

    private func outcome(_ accepted: Bool, _ reason: String?) -> Outcome {
        Outcome(accepted: accepted, needsFilterRestart: needsFilterRestart, reason: reason)
    }

    private static func integer(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
        return UInt64(number.stringValue)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func decode(_ json: String, cachedInstance: UInt64?, cachedEpoch: UInt64,
        cachedFrames: [UInt64: Frame]) -> Snapshot? {
        guard json.utf8.count <= 3 * 1024 * 1024,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              integer(object["schema-version"]) == 1,
              let instance = integer(object["instance"]), instance > 0,
              let epoch = integer(object["epoch"]),
              let last = integer(object["last-sequence"]),
              let evicted = integer(object["evicted"]), let rejected = integer(object["rejected"]),
              integer(object["capacity"]) == 128,
              let reason = object["reset-reason"] as? String, reason.utf8.count <= 1024,
              let records = object["frames"] as? [[String: Any]], records.count <= 128,
              evicted <= last, rejected <= last - evicted else { return nil }
        var frames: [Frame] = []
        frames.reserveCapacity(records.count)
        let canReuse = instance == cachedInstance && epoch == cachedEpoch
        for record in records {
            guard let sequence = integer(record["sequence"]), sequence > 0, sequence <= last,
                  frames.last.map({ sequence > $0.sequence }) ?? true,
                  let raw = record["frame"] as? String, raw.utf8.count <= 16 * 1024,
                  let bytes = raw.data(using: .utf8) else { return nil }
            if canReuse, let cached = cachedFrames[sequence] {
                guard cached.raw == bytes else { return nil }
                frames.append(cached)
                continue
            }
            guard let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let valid = value["valid-time"] as? NSNumber,
                  CFGetTypeID(valid) == CFBooleanGetTypeID(), valid.boolValue,
                  let start = number(value["start"]), let end = number(value["end"]), end > start,
                  let rate = number(value["effective-rate"]), rate > 0,
                  let speed = number(value["speed"]), speed > 0,
                  (rate * speed).isFinite, (rate + speed).isFinite,
                  let sampleRate = integer(value["sample-rate"]), sampleRate > 0,
                  let samples = integer(value["samples"]), samples > 0,
                  sampleRate <= UInt64(Int32.max), samples <= UInt64(Int32.max),
                  let layout = value["layout"] as? String, !layout.isEmpty, layout.utf8.count <= 1024,
                  let metadata = value["metadata"] as? [String: String], metadata.count <= 512,
                  end - start <= 30,
                  (Double(samples) / rate).isFinite,
                  abs((end - start) - Double(samples) / rate) <= 0.5 / rate + 0.000002,
                  // Both factors are serialized to six decimals by MPV. Their
                  // rounding errors matter especially for very small speeds.
                  abs(rate * speed - Double(sampleRate)) <= (rate + speed) * 0.0000005 + 0.000002
            else { return nil }
            frames.append(Frame(sequence: sequence, raw: bytes, start: start, end: end,
                rate: rate, sampleRate: sampleRate, measuredDuration: Double(samples) / Double(sampleRate),
                speed: speed, layout: layout, metadata: metadata))
        }
        return Snapshot(instance: instance, epoch: epoch, last: last, evicted: evicted, rejected: rejected,
            resetReason: reason, frames: frames)
    }
}
