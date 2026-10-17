import XCTest
@testable import Aagedal_Media_Converter

final class AudioPhaseAnalysisTests: XCTestCase {
    func testBundledSourceStatisticsAndFinalPartialWindow() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let cases: [(String, Double?, Double?, Double, Double)] = [
            ("0.5*sin(2*PI*n/48)|0.5*sin(2*PI*n/48)", 1, 0, 0.353553390593, 0),
            ("0.5*sin(2*PI*n/48)|-0.5*sin(2*PI*n/48)", -1, -.infinity, 0, 0.353553390593),
            ("0.5*sin(2*PI*n/48)|0.5*cos(2*PI*n/48)", 0, -3.01029995664, 0.25, 0.25),
            ("0|0", nil, nil, 0, 0),
            ("0.5*sin(2*PI*n/48)|0", nil, -3.01029995664, 0.176776695297, 0.176776695297),
            ("0.5*sin(2*PI*n/48)|0.5*sin(2*PI*(n-8)/48)", 0.5, -1.24938736608, 0.306186217848, 0.176776695297)
        ]
        for (expression, correlation, delta, mid, side) in cases {
            let file = temporary("wav")
            defer { try? FileManager.default.removeItem(at: file) }
            try await generate(ffmpeg, ["-f", "lavfi", "-i", "aevalsrc=\(expression):s=48000:d=0.1000208333333333", "-c:a", "pcm_f64le", file.path])
            let report = try await AudioPhaseAnalysisService(ffmpegPathProvider: { ffmpeg }).analyze(file: file, trackIndex: 0)
            XCTAssertEqual(report.windows.count, 2)
            XCTAssertEqual(report.totals.sampleCount, 4801)
            XCTAssertEqual(report.scope.bins.reduce(0, +), 4801)
            XCTAssertEqual(report.scope.clippedSampleCount, 0)
            XCTAssertEqual(report.windows[1].measurement.sampleCount, 1)
            XCTAssertEqual(report.duration, 4801.0 / 48000, accuracy: 1e-12)
            let measured = report.windows[0].measurement
            if let correlation { XCTAssertEqual(try XCTUnwrap(measured.correlation), correlation, accuracy: 1e-10) }
            else { XCTAssertNil(measured.correlation) }
            if let delta {
                if delta.isInfinite { XCTAssertEqual(measured.monoFoldDownDeltaDB, delta) }
                else { XCTAssertEqual(try XCTUnwrap(measured.monoFoldDownDeltaDB), delta, accuracy: 1e-10) }
            } else { XCTAssertNil(measured.monoFoldDownDeltaDB) }
            XCTAssertEqual(measured.midRMS, mid, accuracy: 1e-10)
            XCTAssertEqual(measured.sideRMS, side, accuracy: 1e-10)
        }
    }

    func testBundledGroupingPreservesMappingAndRejectsMismatches() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        for second in ["-0.25", "-0.25:d=0.09", "-0.25:s=44100"] {
            let file = temporary("mkv")
            defer { try? FileManager.default.removeItem(at: file) }
            let right = second.contains(":") ? "aevalsrc=\(second)" : "aevalsrc=\(second):s=48000:d=0.1"
            try await generate(ffmpeg, ["-f", "lavfi", "-i", "aevalsrc=0.5:s=48000:d=0.1",
                                       "-f", "lavfi", "-i", right.contains("d=") ? right : right + ":d=0.1",
                                       "-map", "0:a", "-map", "1:a", "-c:a", "pcm_f64le", file.path])
            let service = AudioPhaseAnalysisService(ffmpegPathProvider: { ffmpeg })
            if second == "-0.25" {
                let result = try await service.analyze(file: file, presentation: .stereo(left: 1, right: 0))
                XCTAssertEqual(try XCTUnwrap(result.totals.correlation), -1, accuracy: 1e-12)
                XCTAssertEqual(result.totals.leftEnergy, 300, accuracy: 1e-10)
                XCTAssertEqual(result.totals.rightEnergy, 1200, accuracy: 1e-10)
            } else {
                do { _ = try await service.analyze(file: file, presentation: .stereo(left: 0, right: 1)); XCTFail("Mismatched grouping accepted") }
                catch { XCTAssertTrue(error.localizedDescription.contains("matching"), error.localizedDescription) }
            }
        }
    }

    func testBundledRejectsMonoMultichannelAndHiddenTimestampGap() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let sources = ["aevalsrc=0.25:s=48000:d=0.1", "aevalsrc=0.1|0.2|0.3:s=48000:d=0.1",
                       "aevalsrc=0.5|0.5:s=48000:d=0.02,asetnsamples=n=512:p=0,asetpts=PTS+if(gte(N\\,512)\\,4800\\,0)"]
        for source in sources {
            let file = temporary("mkv")
            defer { try? FileManager.default.removeItem(at: file) }
            try await generate(ffmpeg, ["-f", "lavfi", "-i", source, "-c:a", "pcm_f64le", file.path])
            do { _ = try await AudioPhaseAnalysisService(ffmpegPathProvider: { ffmpeg }).analyze(file: file, trackIndex: 0); XCTFail("Invalid source accepted") }
            catch { XCTAssertFalse(error is CancellationError) }
        }
    }

    func testCollectorRejectsMalformedIncompleteNonFiniteAndOversizeStreams() {
        for variant in 0..<7 {
            let collector = AudioPhaseSampleCollector(windowLimit: variant == 5 ? 0 : 100_000)
            let pts = variant == 6 ? Int64.max : 96000
            let frames = "[ashowinfo@amc_phase_source @ 0x1] n:0 pts:\(pts) channels:2 rate:48000 nb_samples:1\n"
                + "[ashowinfo@amc_phase_window @ 0x1] n:0 pts:\(variant == 3 ? 96001 : pts) channels:2 rate:48000 nb_samples:1\n"
            collector.consume(.init(stream: .standardError, data: Data((frames + (variant == 4 ? "" : "progress=end\n")).utf8)))
            var bytes = Data()
            for value in [variant == 0 ? Double.nan : 0.5, -0.5] {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
            }
            if variant == 1 { bytes.removeLast() }
            if variant == 2 { bytes.append(contentsOf: [0, 0]) }
            collector.consume(.init(stream: .standardOutput, data: bytes))
            XCTAssertThrowsError(try collector.finish(presentation: .track(0)))
        }
    }

    func testCollectorPreservesOffsetAcrossArbitraryPipeChunkBoundariesAndJSONSemantics() throws {
        let collector = AudioPhaseSampleCollector()
        var bytes = Data()
        for value in [0.5, -0.5] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        for byte in bytes { collector.consume(.init(stream: .standardOutput, data: Data([byte]))) }
        let text = "[ashowinfo@amc_phase_source @ x] n:0 pts:96000 channels:2 rate:48000 nb_samples:1\n"
            + "[ashowinfo@amc_phase_window @ x] n:0 pts:96000 channels:2 rate:48000 nb_samples:1\nprogress=end\n"
        for byte in text.utf8 { collector.consume(.init(stream: .standardError, data: Data([byte]))) }
        let report = try collector.finish(presentation: .track(2))
        XCTAssertEqual(report.windows[0].start, 2)
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let data = try encoder.encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let totals = try XCTUnwrap(object["totals"] as? [String: Any])
        XCTAssertEqual(totals["correlation"] as? Double, -1)
        XCTAssertEqual(totals["monoFoldDownDeltaDB"] as? String, "-Infinity")
        XCTAssertEqual(object["duration"] as? Double, report.duration)
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        XCTAssertEqual(try decoder.decode(AudioPhaseAnalysisResult.self, from: data), report)
    }

    func testWholeSourceScopeUsesFixedMidSideCoordinatesAndIncludesTail() throws {
        let cases: [(Double, Double, Int, Int, Int64)] = [
            (0.5, 0.5, 16, 24, 0), (0.5, -0.5, 24, 16, 0),
            (0.5, 0, 20, 20, 0), (3, 0, 32, 32, 1), (0, 0, 16, 16, 0)
        ]
        for (left, right, x, y, clipped) in cases {
            let collector = AudioPhaseSampleCollector()
            var bytes = Data()
            for value in [left, right] {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
            }
            collector.consume(.init(stream: .standardOutput, data: bytes))
            let text = "[ashowinfo@amc_phase_source @ x] n:0 pts:0 channels:2 rate:48000 nb_samples:1\n"
                + "[ashowinfo@amc_phase_window @ x] n:0 pts:0 channels:2 rate:48000 nb_samples:1\nprogress=end\n"
            collector.consume(.init(stream: .standardError, data: Data(text.utf8)))
            let scope = try collector.finish(presentation: .track(0)).scope
            XCTAssertEqual(scope.dimension, 33)
            XCTAssertEqual(scope.bins.count, 1089)
            XCTAssertEqual(scope.bins[y * 33 + x], 1)
            XCTAssertEqual(scope.bins.reduce(0, +), 1)
            XCTAssertEqual(scope.clippedSampleCount, clipped)
        }
    }

    func testCancellationStopsRunnerWithoutReturningPartialReport() async throws {
        let started = expectation(description: "Phase process started")
        let runner = PhaseCancellationRunner(started: started)
        let service = AudioPhaseAnalysisService(runner: runner, ffmpegPathProvider: { "/unused/ffmpeg" })
        let task = Task { try await service.analyze(file: URL(fileURLWithPath: "/tmp/phase.wav"), trackIndex: 0) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation returned a report") } catch is CancellationError { }
        let active = await runner.active
        XCTAssertFalse(active)
    }

    func testPhaseExportRetainsAllWindowsRolesScopeAndAnalysisTime() throws {
        let report = try exportFixture()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let source = URL(fileURLWithPath: "/private/source/quoted \"日本語\".wav")
        let data = try AnalyticsExporter.audioPhaseJSON(result: report, sourceFile: source, timestamp: timestamp)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["analysis"] as? String, "source_stereo_phase_analysis")
        XCTAssertEqual(json["sourceFileName"] as? String, source.lastPathComponent)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("/private/source"))
        let presentation = try XCTUnwrap(json["presentation"] as? [String: Any])
        XCTAssertEqual(presentation["audioRelativeTrackIndices"] as? [Int], [2, 0])
        XCTAssertEqual(presentation["channelOrder"] as? [String], ["L", "R"])
        let result = try XCTUnwrap(json["result"] as? [String: Any])
        let windows = try XCTUnwrap(result["windows"] as? [[String: Any]])
        XCTAssertEqual(windows.count, 2)
        let first = try XCTUnwrap(windows[0]["measurement"] as? [String: Any])
        let second = try XCTUnwrap(windows[1]["measurement"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(first["correlation"] as? Double), 1, accuracy: 1e-12)
        XCTAssertEqual(first["monoFoldDownDeltaDB"] as? Double, 0)
        XCTAssertEqual(second["correlation"] as? Double, -1)
        XCTAssertEqual(second["monoFoldDownDeltaDB"] as? String, "-Infinity")
        XCTAssertEqual(windows[0]["start"] as? Double, 2)
        XCTAssertEqual(result["duration"] as? Double, 2.1000208333333332)
        let scope = try XCTUnwrap(result["scope"] as? [String: Any])
        XCTAssertEqual((scope["bins"] as? [Int64])?.reduce(0, +), 4801)
        let destination = temporary("json")
        defer { try? FileManager.default.removeItem(at: destination) }
        try AnalyticsExporter.exportAudioPhaseJSON(result: report, sourceFile: source, timestamp: timestamp, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), data)
        try AnalyticsExporter.exportAudioPhaseJSON(result: report, sourceFile: source, timestamp: timestamp, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), data)
        XCTAssertThrowsError(try AnalyticsExporter.exportAudioPhaseJSON(result: report, sourceFile: source, timestamp: timestamp,
                                                                       to: destination.appendingPathComponent("missing/report.json")))
    }

    func testPhaseExportRejectsInvalidTimelineEnergiesTotalsAndScope() throws {
        let good = try exportFixture()
        let badEnergy = AudioPhaseMeasurement(sampleCount: 4800, leftEnergy: .nan, rightEnergy: 1,
                                             midEnergy: 1, sideEnergy: 0, crossProduct: 1)
        let badTotal = AudioPhaseMeasurement(sampleCount: 4801, leftEnergy: 1, rightEnergy: 1,
                                            midEnergy: 1, sideEnergy: 0, crossProduct: 1)
        let variants = [
            AudioPhaseAnalysisResult(presentation: .stereo(left: 1, right: 1), sampleRate: good.sampleRate,
                                     windowSourceSamples: 4800, windows: good.windows, totals: good.totals, scope: good.scope),
            AudioPhaseAnalysisResult(presentation: .surround51([0,1,2,3,4,5]), sampleRate: good.sampleRate,
                                     windowSourceSamples: 4800, windows: good.windows, totals: good.totals, scope: good.scope),
            AudioPhaseAnalysisResult(presentation: good.presentation, sampleRate: 0,
                                     windowSourceSamples: 4800, windows: good.windows, totals: good.totals, scope: good.scope),
            AudioPhaseAnalysisResult(presentation: good.presentation, sampleRate: good.sampleRate,
                                     windowSourceSamples: 4800, windows: [.init(start: 2, end: 2.1, measurement: badEnergy)], totals: badEnergy, scope: good.scope),
            AudioPhaseAnalysisResult(presentation: good.presentation, sampleRate: good.sampleRate,
                                     windowSourceSamples: 4800, windows: good.windows, totals: badTotal, scope: good.scope),
            AudioPhaseAnalysisResult(presentation: good.presentation, sampleRate: good.sampleRate,
                                     windowSourceSamples: 4800, windows: [good.windows[0], .init(start: 2.2, end: 2.2000208333333333, measurement: good.windows[1].measurement)],
                                     totals: good.totals, scope: good.scope),
            AudioPhaseAnalysisResult(presentation: good.presentation, sampleRate: good.sampleRate,
                                     windowSourceSamples: 4800, windows: good.windows, totals: good.totals,
                                     scope: .init(dimension: 33, bins: [Int64](repeating: .max, count: 1089), clippedSampleCount: 0))
        ]
        for report in variants {
            XCTAssertThrowsError(try AnalyticsExporter.audioPhaseJSON(result: report, sourceFile: temporary("wav"), timestamp: Date()))
        }
        XCTAssertThrowsError(try AnalyticsExporter.audioPhaseJSON(result: good, sourceFile: temporary("wav"), timestamp: Date(timeIntervalSince1970: .nan)))
    }

    func testGroupedDecodeCannotDropTailAfterSuccessfulCompletePreflight() async throws {
        let service = AudioPhaseAnalysisService(runner: PhaseTruncatedRunner(failDecode: false),
                                               ffmpegPathProvider: { "/unused/ffmpeg" })
        do {
            _ = try await service.analyze(file: URL(fileURLWithPath: "/tmp/grouped-phase.mkv"),
                                          presentation: .stereo(left: 3, right: 1))
            XCTFail("A merged decode silently dropped the preflight's final source sample")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testFailedProcessCannotPublishOtherwiseCompletePartialReport() async throws {
        let service = AudioPhaseAnalysisService(runner: PhaseTruncatedRunner(failDecode: true),
                                               ffmpegPathProvider: { "/unused/ffmpeg" })
        do {
            _ = try await service.analyze(file: URL(fileURLWithPath: "/tmp/failed-phase.wav"), trackIndex: 0)
            XCTFail("An unsuccessful decoder returned its apparently complete measurements")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("phase decoder failure"), error.localizedDescription)
        }
    }

    func testBundledPreservesNativeRatesAndOffsetWithoutPaddingFinalWindow() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        for rate in [44_100, 96_000] {
            let file = temporary("mkv")
            defer { try? FileManager.default.removeItem(at: file) }
            // Video anchors the file timeline at zero while audio begins at 2 s.
            // A sample-count trim avoids duration-rounding ambiguity at native rates.
            try await generate(ffmpeg, [
                "-f", "lavfi", "-i", "color=size=16x16:rate=1:duration=3",
                "-itsoffset", "2", "-f", "lavfi", "-i", "aevalsrc=0.5|-0.5:s=\(rate),atrim=end_sample=4801",
                "-map", "0:v", "-map", "1:a", "-c:v", "ffv1", "-c:a", "pcm_f64le", file.path
            ])
            let result = try await AudioPhaseAnalysisService(ffmpegPathProvider: { ffmpeg }).analyze(file: file, trackIndex: 0)
            XCTAssertEqual(result.sampleRate, rate)
            XCTAssertEqual(result.totals.sampleCount, 4801)
            XCTAssertEqual(result.windows.map { $0.measurement.sampleCount }, [4800, 1])
            XCTAssertEqual(result.windows[0].start, 2, accuracy: 1.0 / Double(rate))
            XCTAssertEqual(result.duration, 2 + 4801.0 / Double(rate), accuracy: 1.0 / Double(rate))
            XCTAssertEqual(result.scope.bins.reduce(0, +), 4801)
        }
    }

    func testExportSilenceAndOneSidedAudioUseNullUnavailableMetrics() throws {
        for rightSilentOnly in [false, true] {
            let collector = AudioPhaseSampleCollector()
            var bytes = Data()
            for value in [rightSilentOnly ? 0.5 : 0, 0] {
                var bits = Double(value).bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
            }
            collector.consume(.init(stream: .standardOutput, data: bytes))
            let metadata = "[ashowinfo@amc_phase_source @ x] n:0 pts:0 channels:2 rate:48000 nb_samples:1\n"
                + "[ashowinfo@amc_phase_window @ x] n:0 pts:0 channels:2 rate:48000 nb_samples:1\nprogress=end\n"
            collector.consume(.init(stream: .standardError, data: Data(metadata.utf8)))
            let result = try collector.finish(presentation: .track(0))
            let data = try AnalyticsExporter.audioPhaseJSON(result: result, sourceFile: temporary("wav"), timestamp: Date())
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let payload = try XCTUnwrap(envelope["result"] as? [String: Any])
            let totals = try XCTUnwrap(payload["totals"] as? [String: Any])
            let windows = try XCTUnwrap(payload["windows"] as? [[String: Any]])
            let window = try XCTUnwrap(windows.first?["measurement"] as? [String: Any])
            for measurement in [totals, window] {
                XCTAssertTrue(measurement["correlation"] is NSNull)
                if rightSilentOnly {
                    XCTAssertEqual(try XCTUnwrap(measurement["monoFoldDownDeltaDB"] as? Double), -3.010299956639812, accuracy: 1e-12)
                } else {
                    XCTAssertTrue(measurement["monoFoldDownDeltaDB"] is NSNull)
                }
            }
            let scope = try XCTUnwrap(payload["scope"] as? [String: Any])
            XCTAssertEqual((scope["bins"] as? [Int64])?.reduce(0, +), 1)
            XCTAssertEqual(totals["sampleCount"] as? Int, 1)
        }
    }

    private func exportFixture() throws -> AudioPhaseAnalysisResult {
        let collector = AudioPhaseSampleCollector()
        var data = Data()
        for index in 0..<4801 {
            for value in [0.5, index < 4800 ? 0.5 : -0.5] {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }
        collector.consume(.init(stream: .standardOutput, data: data))
        let metadata = "[ashowinfo@amc_phase_source @ x] n:0 pts:96000 channels:2 rate:48000 nb_samples:4801\n"
            + "[ashowinfo@amc_phase_window @ x] n:0 pts:96000 channels:2 rate:48000 nb_samples:4800\n"
            + "[ashowinfo@amc_phase_window @ x] n:1 pts:100800 channels:2 rate:48000 nb_samples:1\nprogress=end\n"
        collector.consume(.init(stream: .standardError, data: Data(metadata.utf8)))
        return try collector.finish(presentation: .stereo(left: 2, right: 0))
    }

    private func temporary(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("phase-\(UUID().uuidString).\(suffix)")
    }
    private func generate(_ path: String, _ arguments: [String]) async throws {
        let result = try await SubprocessRunner().run(.init(executableURL: URL(fileURLWithPath: path),
                                                          arguments: ["-hide_banner", "-nostdin", "-y"] + arguments,
                                                          timeout: .seconds(30)))
        XCTAssertTrue(result.succeeded, result.standardErrorText)
    }
}

private actor PhaseCancellationRunner: SubprocessRunning {
    let started: XCTestExpectation
    private(set) var active = false
    init(started: XCTestExpectation) { self.started = started }
    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        active = true
        defer { active = false }
        started.fulfill()
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}

/// The preflight sees 4,801 matching samples on both mono tracks, but the
/// subsequent merged decode emits only 4,800 internally consistent samples.
private struct PhaseTruncatedRunner: SubprocessRunning {
    let failDecode: Bool

    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        if request.arguments.contains(where: { $0.contains("ashowinfo@amc_peak_timing_") }) {
            let metadata = (0..<2).map { index in
                "[ashowinfo@amc_peak_timing_\(index) @ x] n:0 pts:0 channels:1 rate:48000 nb_samples:4801\n"
            }.joined()
            outputHandler?(.init(stream: .standardError, data: Data(metadata.utf8)))
            outputHandler?(.init(stream: .standardOutput, data: Data("progress=end\n".utf8)))
        } else {
            var bytes = Data()
            for _ in 0..<(4800 * 2) {
                var bits = Double(0.5).bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
            }
            outputHandler?(.init(stream: .standardOutput, data: bytes))
            let metadata = "[ashowinfo@amc_phase_source @ x] n:0 pts:0 channels:2 rate:48000 nb_samples:4800\n"
                + "[ashowinfo@amc_phase_window @ x] n:0 pts:0 channels:2 rate:48000 nb_samples:4800\nprogress=end\n"
            outputHandler?(.init(stream: .standardError, data: Data(metadata.utf8)))
        }
        return .init(terminationStatus: failDecode ? 1 : 0, termination: .exited,
                     standardOutput: Data(), standardError: failDecode ? Data("phase decoder failure".utf8) : Data(),
                     discardedStandardOutputBytes: 0, discardedStandardErrorBytes: 0, duration: .zero)
    }
}
