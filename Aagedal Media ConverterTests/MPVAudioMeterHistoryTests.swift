import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class MPVAudioMeterHistoryTests: XCTestCase {
    func testFutureFramesWaitForIntervalEndWithoutRetimestamping() throws {
        var history = MPVAudioMeterHistory(generation: 7)
        XCTAssertTrue(history.ingest(json: try snapshot(frames: [frame(1), frame(2)]), generation: 7).accepted)
        XCTAssertNil(history.sample(at: 0.099999, generation: 7))
        XCTAssertEqual(history.sample(at: 0.1, generation: 7)?.seconds, 0.1)
        XCTAssertEqual(history.sample(at: 0.15, generation: 7)?.seconds, 0.1)
        XCTAssertEqual(history.sample(at: 0.2, generation: 7)?.seconds, 0.2)
        XCTAssertNil(history.sample(at: 1, generation: 7), "Stale values cannot persist indefinitely")
    }

    func testMeasuredHistoryControlsLoudnessAndDelayedStart() throws {
        var history = MPVAudioMeterHistory()
        let frames = (1...30).map { frame($0, offset: 0.75) }
        XCTAssertTrue(history.ingest(json: try snapshot(frames: frames), generation: 0).accepted)
        XCTAssertNil(history.sample(at: 1.05, generation: 0)?.momentaryLUFS)
        XCTAssertEqual(history.sample(at: 1.15, generation: 0)?.momentaryLUFS, -22)
        XCTAssertNil(history.sample(at: 3.65, generation: 0)?.shortTermLUFS)
        XCTAssertEqual(history.sample(at: 3.75, generation: 0)?.shortTermLUFS, -23)
    }

    func testLoudnessReadinessCountsSamplesWhenFrameSpeedScalesMediaTime() throws {
        for speed in [0.5, 2.0] {
            let frames = try (1...30).map { sequence -> [String: Any] in
                var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try rawFrame(sequence: sequence).utf8)) as? [String: Any])
                value["start"] = Double(sequence - 1) / 10 * speed
                value["end"] = Double(sequence) / 10 * speed
                value["effective-rate"] = 48000 / speed
                value["speed"] = speed
                return ["sequence": sequence, "frame": try encode(value)]
            }
            var history = MPVAudioMeterHistory()
            XCTAssertTrue(history.ingest(json: try snapshot(frames: frames), generation: 0).accepted)
            XCTAssertNil(history.sample(at: 0.3 * speed, generation: 0)?.momentaryLUFS)
            XCTAssertEqual(history.sample(at: 0.4 * speed, generation: 0)?.momentaryLUFS, -22)
            XCTAssertNil(history.sample(at: 2.9 * speed, generation: 0)?.shortTermLUFS)
            XCTAssertEqual(history.sample(at: 3 * speed, generation: 0)?.shortTermLUFS, -23)
        }
    }

    func testRepeatedSnapshotsAreImmutableAndHarmlessEvictionIsNotLoss() throws {
        var history = MPVAudioMeterHistory()
        let first = try snapshot(frames: [frame(1), frame(2)])
        XCTAssertTrue(history.ingest(json: first, generation: 0).accepted)
        XCTAssertTrue(history.ingest(json: first, generation: 0).accepted)
        XCTAssertEqual(history.bufferedFrameCount, 2)
        XCTAssertTrue(history.ingest(json: try snapshot(frames: [frame(2), frame(3)], evicted: 1), generation: 0).accepted)
        XCTAssertFalse(history.needsFilterRestart)
        var changed = frame(3)
        changed["frame"] = try rawFrame(sequence: 3, peak: "-3")
        XCTAssertFalse(history.ingest(json: try snapshot(frames: [changed], evicted: 1), generation: 0).accepted)
        XCTAssertTrue(history.needsFilterRestart)
        XCTAssertNil(history.sample(at: 0.3, generation: 0))
    }

    func testRepeatedRawIdentityUsesBytesRatherThanUnicodeEquivalence() throws {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try rawFrame(sequence: 1).utf8)) as? [String: Any])
        var metadata = try XCTUnwrap(value["metadata"] as? [String: String])
        metadata["note"] = "\u{00e9}"
        value["metadata"] = metadata
        let first = try encode(value)
        metadata["note"] = "e\u{0301}"
        value["metadata"] = metadata
        let changed = try encode(value)
        XCTAssertEqual(first, changed, "Swift String equality treats these Unicode forms as equivalent")
        XCTAssertNotEqual(Data(first.utf8), Data(changed.utf8))
        var history = MPVAudioMeterHistory()
        XCTAssertTrue(history.ingest(json: try snapshot(frames: [["sequence": 1, "frame": first]]), generation: 0).accepted)
        XCTAssertFalse(history.ingest(json: try snapshot(frames: [["sequence": 1, "frame": changed]]), generation: 0).accepted)
        XCTAssertTrue(history.needsFilterRestart)
    }

    func testGapsSuppressLoudnessUntilFreshInstanceEvenAfterThreeSeconds() throws {
        var history = MPVAudioMeterHistory()
        _ = history.ingest(json: try snapshot(frames: [frame(1)]), generation: 0)
        let gap = history.ingest(json: try snapshot(frames: (3...35).map { frame($0) }), generation: 0)
        XCTAssertTrue(gap.accepted)
        XCTAssertTrue(gap.needsFilterRestart)
        let afterGap = try XCTUnwrap(history.sample(at: 3.5, generation: 0))
        XCTAssertEqual(afterGap.peaks.first!, -12)
        XCTAssertNil(afterGap.momentaryLUFS)
        XCTAssertNil(afterGap.shortTermLUFS)
        _ = history.ingest(json: try snapshot(frames: (1...30).map { frame($0) }, instance: 2), generation: 0)
        XCTAssertFalse(history.needsFilterRestart)
        XCTAssertEqual(history.sample(at: 3, generation: 0)?.shortTermLUFS, -23)
    }

    func testEpochLayoutAndTimestampDiscontinuitiesRequestFilterRestart() throws {
        for change in ["epoch", "layout", "time", "rejected"] {
            var history = MPVAudioMeterHistory()
            _ = history.ingest(json: try snapshot(frames: [frame(1)]), generation: 0)
            let next = frame(2, offset: change == "time" ? 1 : 0, layout: change == "layout" ? "mono" : "stereo")
            let outcome = history.ingest(json: try snapshot(frames: [next], epoch: change == "epoch" ? 1 : 0,
                rejected: change == "rejected" ? 1 : 0), generation: 0)
            XCTAssertTrue(outcome.needsFilterRestart, change)
            XCTAssertNil(history.sample(at: change == "time" ? 1.2 : 0.2, generation: 0)?.momentaryLUFS)
        }
    }

    func testStaleGenerationsDoNotReplaceOrClearCurrentHistory() throws {
        var history = MPVAudioMeterHistory(generation: 9)
        _ = history.ingest(json: try snapshot(frames: [frame(1)]), generation: 9)
        XCTAssertFalse(history.ingest(json: "invalid", generation: 8).accepted)
        XCTAssertFalse(history.markUnavailable(generation: 8).accepted)
        XCTAssertNil(history.sample(at: 0.1, generation: 8))
        XCTAssertEqual(history.sample(at: 0.1, generation: 9)?.seconds, 0.1)
        history.reset(generation: 10)
        XCTAssertNil(history.sample(at: 0.1, generation: 10))
        XCTAssertFalse(history.needsFilterRestart)
    }

    func testClockRewindAndMissingHistoryClearPublication() throws {
        var history = MPVAudioMeterHistory()
        _ = history.ingest(json: try snapshot(frames: [frame(1), frame(2)]), generation: 0)
        XCTAssertNotNil(history.sample(at: 0.2, generation: 0))
        XCTAssertNil(history.sample(at: 0.1, generation: 0))
        XCTAssertTrue(history.needsFilterRestart)
        _ = history.ingest(json: try snapshot(frames: [frame(1)], instance: 2), generation: 0)
        XCTAssertNotNil(history.sample(at: 0.1, generation: 0))
        XCTAssertTrue(history.markUnavailable(generation: 0).needsFilterRestart)
        XCTAssertNil(history.sample(at: 0.1, generation: 0))
    }

    func testMalformedCountersIntervalsMetadataAndPayloadBoundsAreRejected() throws {
        let valid = try snapshot(frames: [frame(1)])
        for literal in ["1.0", "1e0"] {
            var history = MPVAudioMeterHistory()
            let fractionalCounter = valid.replacingOccurrences(of: "\"instance\":1", with: "\"instance\":\(literal)")
            XCTAssertFalse(history.ingest(json: fractionalCounter, generation: 0).accepted)
        }
        for key in ["instance", "epoch", "last-sequence", "evicted", "rejected", "capacity", "schema-version"] {
            for invalid in ["true", "1.5", "-1"] {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(valid.utf8)) as? [String: Any])
                object[key] = try JSONSerialization.jsonObject(with: Data(invalid.utf8), options: [.fragmentsAllowed])
                var history = MPVAudioMeterHistory()
                XCTAssertFalse(history.ingest(json: try encode(object), generation: 0).accepted, "\(key): \(invalid)")
            }
        }
        for mutation in ["duration", "metadata", "valid-time", "speed"] {
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try rawFrame(sequence: 1).utf8)) as? [String: Any])
            switch mutation {
            case "duration": value["end"] = 0.9
            case "metadata": value["metadata"] = ["lavfi.astats.1.Peak_level": 2]
            case "valid-time": value["valid-time"] = 1
            default: value["speed"] = 2
            }
            var history = MPVAudioMeterHistory()
            XCTAssertFalse(history.ingest(json: try snapshot(frames: [["sequence": 1, "frame": try encode(value)]]), generation: 0).accepted, mutation)
        }
        var history = MPVAudioMeterHistory()
        XCTAssertFalse(history.ingest(json: String(repeating: " ", count: 3 * 1024 * 1024 + 1), generation: 0).accepted)
        XCTAssertFalse(history.ingest(json: try snapshot(frames: [["sequence": 1, "frame": String(repeating: " ", count: 16 * 1024 + 1)]]), generation: 0).accepted)
        XCTAssertFalse(history.ingest(json: try snapshot(frames: (1...129).map { frame($0) }), generation: 0).accepted)
    }

    func testBackwardCountersAndInitialMissingCoverageAreExplicit() throws {
        var history = MPVAudioMeterHistory()
        let initial = history.ingest(json: try snapshot(frames: [frame(5)], evicted: 4), generation: 0)
        XCTAssertTrue(initial.needsFilterRestart)
        XCTAssertFalse(history.ingest(json: try snapshot(frames: [frame(4)], evicted: 3), generation: 0).accepted)
        _ = history.ingest(json: try snapshot(frames: [frame(1)], instance: 2), generation: 0)
        XCTAssertFalse(history.ingest(json: try snapshot(frames: [frame(1)], instance: 1), generation: 0).accepted)
    }

    func testUnconsumedFutureQueueIsBounded() throws {
        var history = MPVAudioMeterHistory()
        for batch in 0..<2 {
            XCTAssertTrue(history.ingest(json: try snapshot(frames: (1...128).map { frame($0 + batch * 128) }), generation: 0).accepted)
        }
        let overflow = history.ingest(json: try snapshot(frames: [frame(257)]), generation: 0)
        XCTAssertFalse(overflow.accepted)
        XCTAssertTrue(overflow.needsFilterRestart)
        XCTAssertEqual(history.bufferedFrameCount, 0)
    }

    func testRetainedLifecycleCapturesPublishMeasuredEndsRatherThanReceiptClock() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let executable = ["/usr/bin/xz", "/opt/homebrew/bin/xz", "/usr/local/bin/xz"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let executable else { throw XCTSkip("Lifecycle capture replay requires the xz decompressor") }
        for name in ["lossless-null", "aac-null"] {
            let capture = root.appendingPathComponent("docs/provenance/audio-meter-lifecycle-2026-10-18/arm64-null/\(name).jsonl.xz")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-dc", capture.path]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, name)

            var history = MPVAudioMeterHistory()
            var generation: UInt64 = 0
            var measured: [Double: [String: String]] = [:]
            var publications = 0
            var independentlyTimed = 0
            for line in String(decoding: bytes, as: UTF8.self).split(whereSeparator: \.isNewline) {
                let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
                let nextGeneration = try XCTUnwrap(row["requested-generation"] as? NSNumber).uint64Value
                if nextGeneration != generation {
                    generation = nextGeneration
                    history.reset(generation: generation)
                    measured.removeAll()
                }
                if let envelope = row["history"] as? [String: Any] {
                    let result = history.ingest(json: try encode(envelope), generation: generation)
                    XCTAssertTrue(result.accepted, "\(name): \(result.reason ?? "")")
                    for record in try XCTUnwrap(envelope["frames"] as? [[String: Any]]) {
                        let raw = try XCTUnwrap(record["frame"] as? String)
                        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
                        let end = try XCTUnwrap(frame["end"] as? NSNumber).doubleValue
                        measured[end] = try XCTUnwrap(frame["metadata"] as? [String: String])
                    }
                } else {
                    _ = history.markUnavailable(generation: generation)
                }
                guard let clock = (row["position"] as? NSNumber)?.doubleValue,
                      let sample = history.sample(at: clock, generation: generation) else { continue }
                publications += 1
                XCTAssertLessThanOrEqual(sample.seconds, clock, name)
                let metadata = try XCTUnwrap(measured[sample.seconds], name)
                let expected = try XCTUnwrap(MPVAudioMeterMetadata.sample(metadata, seconds: sample.seconds, history: 0))
                XCTAssertEqual(sample.peaks, expected.peaks, name)
                XCTAssertEqual(sample.rms, expected.rms, name)
                if abs(sample.seconds - clock) > 0.000001 { independentlyTimed += 1 }
            }
            XCTAssertGreaterThan(publications, 30, name)
            XCTAssertGreaterThan(independentlyTimed, 20, "Measured end times must differ from receipt-time playhead labels")
        }
    }

    private func frame(_ sequence: Int, offset: Double = 0, layout: String = "stereo") -> [String: Any] {
        ["sequence": sequence, "frame": try! rawFrame(sequence: sequence, offset: offset, layout: layout)]
    }

    private func rawFrame(sequence: Int, offset: Double = 0, layout: String = "stereo", peak: String = "-12") throws -> String {
        try encode(["valid-time": true, "start": offset + Double(sequence - 1) / 10,
            "end": offset + Double(sequence) / 10, "effective-rate": 48000.0, "speed": 1.0,
            "sample-rate": 48000, "samples": 4800, "layout": layout,
            "metadata": ["lavfi.astats.1.Peak_level": peak, "lavfi.astats.1.RMS_level": "-15",
                "lavfi.r128.M": "-22", "lavfi.r128.S": "-23"]])
    }

    private func snapshot(frames: [[String: Any]], instance: Int = 1, epoch: Int = 0,
        evicted: Int = 0, rejected: Int = 0) throws -> String {
        try encode(["schema-version": 1, "instance": instance, "epoch": epoch,
            "last-sequence": frames.last?["sequence"] as? Int ?? 0, "evicted": evicted,
            "rejected": rejected, "capacity": 128, "reset-reason": "fixture", "frames": frames])
    }

    private func encode(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}
