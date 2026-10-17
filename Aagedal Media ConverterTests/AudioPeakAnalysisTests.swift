import XCTest
@testable import Aagedal_Media_Converter

final class AudioPeakAnalysisTests: XCTestCase {
    func testJSONReportPreservesEveryIntervalAndMeasurementContext() throws {
        let intervals = (0..<1_005).map { index in
            AudioPeakInterval(start: Double(index) + 2, end: Double(index) + 2.1, channel: 2, peakDBFS: -0.5)
        }
        let result = AudioPeakAnalysisResult(settings: .init(thresholdDBFS: -1, imbalanceThresholdDB: 3),
                                             intervals: intervals,
                                             channels: [.init(channel: 1, peakDBFS: -10, rmsDBFS: -20),
                                                        .init(channel: 2, peakDBFS: -0.5, rmsDBFS: -10)],
                                             duration: 1006.1, imbalanceDB: 10)
        let source = URL(fileURLWithPath: "/private/source folder/quoted\"音声.mkv")
        let date = Date(timeIntervalSince1970: 1_792_152_000)
        let data = try AnalyticsExporter.audioPeakJSON(result: result, sourceFile: source, trackIndex: 3, timestamp: date)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(report["schemaVersion"] as? Int, 1)
        XCTAssertEqual(report["sourceFileName"] as? String, source.lastPathComponent)
        XCTAssertEqual(report["audioRelativeTrackIndex"] as? Int, 3)
        XCTAssertEqual(report["timestamp"] as? String, ISO8601DateFormatter().string(from: date))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("source folder"))
        let semantics = try XCTUnwrap(report["semantics"] as? [String: Any])
        XCTAssertEqual(semantics["peakUnit"] as? String, "dBFS")
        XCTAssertEqual(semantics["windowSamples"] as? Int, 4800)
        XCTAssertEqual(semantics["timeline"] as? String, "file_relative_including_initial_audio_offset")
        let payload = try XCTUnwrap(report["result"] as? [String: Any])
        XCTAssertEqual((payload["intervals"] as? [Any])?.count, 1_005, "Export must include intervals omitted from the chart")
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(AudioPeakAnalysisResult.self, from: JSONSerialization.data(withJSONObject: payload)), result)
    }

    func testJSONReportDistinguishesSilenceInfiniteDifferenceAndUnavailableComparison() throws {
        for levels in [[-Double.infinity, -Double.infinity], [-6, -Double.infinity], [-6]] {
            let collector = AudioPeakLogCollector(settings: .init())
            consume(frame(0, pts: 96000, samples: 4800, peaks: levels, rms: levels), collector)
            complete(collector)
            let result = try collector.finish()
            let data = try AnalyticsExporter.audioPeakJSON(result: result, sourceFile: URL(fileURLWithPath: "/tmp/audio.wav"),
                                                           trackIndex: 0, timestamp: Date())
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let payload = try XCTUnwrap(report["result"] as? [String: Any])
            if result.imbalanceDB == .infinity { XCTAssertEqual(payload["imbalanceDB"] as? String, "Infinity") }
            else { XCTAssertNil(payload["imbalanceDB"]) }
            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
            XCTAssertEqual(try decoder.decode(AudioPeakAnalysisResult.self, from: JSONSerialization.data(withJSONObject: payload)), result)
            XCTAssertEqual(result.duration, 2.1)
        }
    }

    func testJSONReportWritesCanBeRepeatedAndSurfaceDestinationErrors() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = AudioPeakAnalysisResult(settings: .init(), intervals: [],
                                             channels: [.init(channel: 1, peakDBFS: -10, rmsDBFS: -20)], duration: 1, imbalanceDB: nil)
        let file = directory.appendingPathComponent("report.json")
        for track in [0, 2] {
            try AnalyticsExporter.exportAudioPeakJSON(result: result, sourceFile: directory.appendingPathComponent("source.wav"),
                                                       trackIndex: track, timestamp: Date(), to: file)
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            XCTAssertEqual(report["audioRelativeTrackIndex"] as? Int, track)
        }
        XCTAssertThrowsError(try AnalyticsExporter.exportAudioPeakJSON(result: result, sourceFile: file, trackIndex: 0,
                                                                        timestamp: Date(), to: directory))
    }

    func testJSONReportRejectsInvalidMeasurementsInsteadOfPublishingNaN() {
        for value in [Double.nan, .infinity] {
            let result = AudioPeakAnalysisResult(settings: .init(), intervals: [],
                                                 channels: [.init(channel: 1, peakDBFS: value, rmsDBFS: -20)],
                                                 duration: 1, imbalanceDB: nil)
            XCTAssertThrowsError(try AnalyticsExporter.audioPeakJSON(result: result, sourceFile: URL(fileURLWithPath: "/tmp/audio.wav"),
                                                                     trackIndex: 0, timestamp: Date()))
        }
    }

    func testGroupedJSONReportPreservesReorderedChannelMappingAndEveryInterval() throws {
        let presentations: [LoudnessPresentation] = [.stereo(left: 4, right: 1), .surround51([2, 3, 4, 7, 5, 6])]
        for presentation in presentations {
            let count = presentation.streamIndices.count
            let intervals = (0..<1_005).map {
                AudioPeakInterval(start: Double($0), end: Double($0) + 0.1, channel: ($0 % count) + 1, peakDBFS: -0.5)
            }
            var result = AudioPeakAnalysisResult(settings: .init(), intervals: intervals,
                                                 channels: (1...count).map { .init(channel: $0, peakDBFS: -0.5, rmsDBFS: -20) },
                                                 duration: 1005, imbalanceDB: 0)
            result.presentation = presentation
            let data = try AnalyticsExporter.audioPeakJSON(result: result,
                                                            sourceFile: URL(fileURLWithPath: "/private/source.wav"), timestamp: Date())
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(report["schemaVersion"] as? Int, 2)
            XCTAssertNil(report["audioRelativeTrackIndex"], "A group must not be attributed to one source track")
            let context = try XCTUnwrap(report["presentation"] as? [String: Any])
            XCTAssertEqual(context["audioRelativeTrackIndices"] as? [Int], presentation.streamIndices)
            XCTAssertEqual(context["channelOrder"] as? [String], count == 2 ? ["FL", "FR"] : ["FL", "FR", "FC", "LFE", "SL", "SR"])
            XCTAssertEqual(context["channelLayout"] as? String, count == 2 ? "stereo" : "5.1(side)")
            XCTAssertEqual(context["type"] as? String, count == 2 ? "stereo" : "surround51")
            let semantics = try XCTUnwrap(report["semantics"] as? [String: Any])
            XCTAssertEqual(semantics["channelNumbering"] as? String, "one_based_presentation_channel_order")
            let payload = try XCTUnwrap(report["result"] as? [String: Any])
            let exported = try XCTUnwrap(payload["intervals"] as? [[String: Any]])
            XCTAssertEqual(exported.count, intervals.count)
            for (index, interval) in exported.enumerated() {
                XCTAssertEqual(interval["channel"] as? Int, intervals[index].channel)
                XCTAssertEqual(interval["start"] as? Double, intervals[index].start)
                XCTAssertEqual(interval["end"] as? Double, intervals[index].end)
                XCTAssertEqual(interval["peakDBFS"] as? Double, intervals[index].peakDBFS)
            }
        }
    }

    func testJSONReportUsesCapturedTrackAndRejectsCallerRelabelingOrMissingPresentation() throws {
        var result = AudioPeakAnalysisResult(settings: .init(), intervals: [],
                                             channels: [.init(channel: 1, peakDBFS: -10, rmsDBFS: -20)], duration: 1, imbalanceDB: nil)
        let source = URL(fileURLWithPath: "/tmp/audio.wav")
        XCTAssertThrowsError(try AnalyticsExporter.audioPeakJSON(result: result, sourceFile: source, timestamp: Date()))
        result.presentation = .track(3)
        let data = try AnalyticsExporter.audioPeakJSON(result: result, sourceFile: source, timestamp: Date())
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(report["schemaVersion"] as? Int, 1)
        XCTAssertEqual(report["audioRelativeTrackIndex"] as? Int, 3)
        let context = try XCTUnwrap(report["presentation"] as? [String: Any])
        XCTAssertEqual(context["audioRelativeTrackIndices"] as? [Int], [3])
        XCTAssertNoThrow(try AnalyticsExporter.audioPeakJSON(result: result, sourceFile: source, trackIndex: 3, timestamp: Date()))
        XCTAssertThrowsError(try AnalyticsExporter.audioPeakJSON(result: result, sourceFile: source, trackIndex: 0, timestamp: Date()))
        result.presentation = .stereo(left: 0, right: 1)
        XCTAssertThrowsError(try AnalyticsExporter.audioPeakJSON(result: result, sourceFile: source, trackIndex: 0, timestamp: Date()))
    }

    func testGroupedJSONReportRejectsInvalidPresentationAndChannelTopology() {
        let cases: [(LoudnessPresentation, [Int], Int?)] = [
            (.stereo(left: -1, right: 2), [1, 2], nil),
            (.stereo(left: 2, right: 2), [1, 2], nil),
            (.stereo(left: 0, right: 1), [1], nil),
            (.stereo(left: 0, right: 1), [1, 1], nil),
            (.stereo(left: 0, right: 1), [0, 1], nil),
            (.stereo(left: 0, right: 1), [2, 1], nil),
            (.stereo(left: 0, right: 1), [1, 2], 3),
            (.surround51([0, 1, 2, 3, 4]), [1, 2, 3, 4, 5, 6], nil),
            (.surround51([0, 1, 2, 3, 4, 4]), [1, 2, 3, 4, 5, 6], nil),
            (.surround51([0, 1, 2, 3, 4, -1]), [1, 2, 3, 4, 5, 6], nil),
            (.surround51([0, 1, 2, 3, 4, 5]), [1, 2, 3, 4, 5], nil),
            (.track(-1), [1], nil),
            (.track(0), [1, 3], nil)
        ]
        for (presentation, channels, intervalChannel) in cases {
            var result = AudioPeakAnalysisResult(settings: .init(),
                                                 intervals: intervalChannel.map { [.init(start: 0, end: 0.1, channel: $0, peakDBFS: 0)] } ?? [],
                                                 channels: channels.map { .init(channel: $0, peakDBFS: -10, rmsDBFS: -20) },
                                                 duration: 1, imbalanceDB: nil)
            result.presentation = presentation
            XCTAssertThrowsError(try AnalyticsExporter.audioPeakJSON(result: result,
                                                                     sourceFile: URL(fileURLWithPath: "/tmp/audio.wav"), timestamp: Date()),
                                 "Invalid topology must fail: \(presentation), channels \(channels)")
        }
    }

    func testGroupedJSONReportWritesCapturedPresentationAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var result = AudioPeakAnalysisResult(settings: .init(), intervals: [],
                                             channels: [1, 2].map { .init(channel: $0, peakDBFS: -10, rmsDBFS: -20) },
                                             duration: 1, imbalanceDB: 0)
        result.presentation = .stereo(left: 4, right: 2)
        let file = directory.appendingPathComponent("report.json")
        for _ in 0..<2 {
            try AnalyticsExporter.exportAudioPeakJSON(result: result, sourceFile: directory.appendingPathComponent("source.wav"),
                                                       timestamp: Date(), to: file)
            let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            let context = try XCTUnwrap(report["presentation"] as? [String: Any])
            XCTAssertEqual(context["audioRelativeTrackIndices"] as? [Int], [4, 2])
        }
        XCTAssertThrowsError(try AnalyticsExporter.exportAudioPeakJSON(result: result, sourceFile: file, timestamp: Date(), to: directory))
    }

    func testChunkedParserMergesChannelsAndWeightsRMSByActualSamples() throws {
        let collector = AudioPeakLogCollector(settings: .init(thresholdDBFS: -10))
        let log = frame(0, pts: 0, samples: 4800, peaks: [0, -20], rms: [0, -20])
            + frame(1, pts: 4800, samples: 1201, peaks: [-6, -30], rms: [-6, -30])
        for byte in log.utf8 { collector.consume(.init(stream: .standardError, data: Data([byte]))) }
        complete(collector)
        let result = try collector.finish()
        XCTAssertEqual(result.intervals.count, 1)
        let interval = try XCTUnwrap(result.intervals.first)
        XCTAssertEqual(interval.channel, 1)
        XCTAssertEqual(interval.start, 0)
        XCTAssertEqual(interval.end, 6001.0 / 48000, accuracy: 1e-12)
        XCTAssertEqual(interval.peakDBFS, 0)
        XCTAssertEqual(result.duration, interval.end)
        let leftRMS = 10 * log10((4800 + 1201 * pow(10, -0.6)) / 6001)
        let rightRMS = 10 * log10((48 + 1.201) / 6001)
        XCTAssertEqual(result.channels[0].rmsDBFS, leftRMS, accuracy: 1e-10)
        XCTAssertEqual(result.channels[1].rmsDBFS, rightRMS, accuracy: 1e-10)
        XCTAssertEqual(try XCTUnwrap(result.imbalanceDB), leftRMS - rightRMS, accuracy: 1e-10)
    }

    func testThresholdIsInclusiveAndGapsBreakIntervals() throws {
        let collector = AudioPeakLogCollector(settings: .init(thresholdDBFS: -1))
        consume(frame(0, pts: 96000, samples: 4800, peaks: [-1], rms: [-2])
                + frame(1, pts: 105600, samples: 7, peaks: [0], rms: [-2]), collector)
        complete(collector)
        let result = try collector.finish()
        XCTAssertEqual(result.intervals.count, 2)
        XCTAssertEqual(result.intervals[0].start, 2)
        XCTAssertEqual(result.intervals[1].end, 105607.0 / 48000, accuracy: 1e-12)
        XCTAssertNil(result.imbalanceDB)
    }

    func testSilentChannelAndEntirelySilentTopology() throws {
        for levels in [[-Double.infinity, -Double.infinity], [-6, -Double.infinity], [-6]] {
            let collector = AudioPeakLogCollector(settings: .init())
            consume(frame(0, pts: 0, samples: 100, peaks: levels, rms: levels), collector)
            complete(collector)
            let result = try collector.finish()
            XCTAssertTrue(result.intervals.isEmpty)
            if levels.count == 2, levels[0].isFinite { XCTAssertEqual(result.imbalanceDB, .infinity) }
            else { XCTAssertNil(result.imbalanceDB) }
        }
    }

    func testMalformedIncompleteAndChangingTopologyReportsFailClosed() {
        let good = frame(0, pts: 0, samples: 4800, peaks: [-1, -2], rms: [-3, -4])
        let cases = [
            "", String(good.dropLast()),
            good.replacingOccurrences(of: "lavfi.astats.2.RMS_level=-4.0\n", with: ""),
            good.replacingOccurrences(of: "RMS_level=-3.0", with: "RMS_level=nan"),
            good.replacingOccurrences(of: "RMS_level=-3.0", with: "RMS_level=inf"),
            good.replacingOccurrences(of: "Number_of_samples=4800", with: "Number_of_samples=4799"),
            good.replacingOccurrences(of: "frame:0 pts:0", with: "frame:0 pts:1"),
            good + frame(2, pts: 4800, samples: 100, peaks: [-2, -2], rms: [-3, -3]),
            good + frame(1, pts: 4800, samples: 100, peaks: [-2], rms: [-3]),
            good + frame(1, pts: 4700, samples: 100, peaks: [-2, -2], rms: [-3, -3]),
            good + frame(1, pts: 4800, samples: 100, peaks: [-2, -2], rms: [-3, -3], rate: 44100)
        ]
        for log in cases {
            let collector = AudioPeakLogCollector(settings: .init())
            consume(log, collector)
            complete(collector)
            XCTAssertThrowsError(try collector.finish(), log)
        }
        let incomplete = AudioPeakLogCollector(settings: .init())
        consume(good, incomplete)
        XCTAssertThrowsError(try incomplete.finish())
    }

    func testMarkerAndMalformedLineLimitsFailExplicitly() {
        let collector = AudioPeakLogCollector(settings: .init(), markerLimit: 1)
        consume(frame(0, pts: 0, samples: 4800, peaks: [0, 0], rms: [-3, -3]), collector)
        complete(collector)
        XCTAssertThrowsError(try collector.finish())
        let malformed = AudioPeakLogCollector(settings: .init())
        consume(String(repeating: "x", count: 65537), malformed)
        complete(malformed)
        XCTAssertThrowsError(try malformed.finish())
    }

    func testSettingsRejectNonfiniteAndOutOfRangeValues() throws {
        try AudioPeakSettings().validate()
        for value in [Double.nan, .infinity, -.infinity, -121, 1] {
            XCTAssertThrowsError(try AudioPeakSettings(thresholdDBFS: value).validate())
        }
        for value in [Double.nan, .infinity, -.infinity, -1, 121] {
            XCTAssertThrowsError(try AudioPeakSettings(imbalanceThresholdDB: value).validate())
        }
        for value in [Double.nan, .infinity, -.infinity, -121, 7] {
            XCTAssertThrowsError(try AudioPeakSettings(truePeakThresholdDBTP: value).validate())
        }
        try AudioPeakSettings(truePeakThresholdDBTP: 6).validate()
    }

    func testDecoderFailureDoesNotReturnReport() async {
        let service = AudioPeakAnalysisService(runner: PeakFailureRunner(), ffmpegPathProvider: { "/tmp/ffmpeg" })
        do {
            _ = try await service.analyze(file: URL(fileURLWithPath: "/tmp/audio.wav"), trackIndex: 0)
            XCTFail("Failed decoder returned a report")
        } catch { XCTAssertTrue(error.localizedDescription.contains("decoder failure")) }
    }

    func testCancellationPropagatesAndDrainsRunner() async throws {
        let started = expectation(description: "Peak decoder started")
        let runner = PeakCancellationRunner(started: started)
        let service = AudioPeakAnalysisService(runner: runner, ffmpegPathProvider: { "/tmp/ffmpeg" })
        let task = Task { try await service.analyze(file: URL(fileURLWithPath: "/tmp/audio.wav"), trackIndex: 0) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled analysis returned success") }
        catch is CancellationError { }
        let active = await runner.active
        XCTAssertFalse(active)
    }

    func testBundledFFmpegReportsSelectedTrackPeaksAndExactEOFAtSourceRates() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        for rate in [44100, 48000, 96000] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("peaks-\(UUID().uuidString).mkv")
            defer { try? FileManager.default.removeItem(at: file) }
            let sampleCount = rate + 137
            try await generate(ffmpeg, arguments: [
                "-f", "lavfi", "-i", "aevalsrc=0:s=\(rate):d=2",
                "-f", "lavfi", "-i", "aevalsrc=0.95|0.095:s=\(rate):d=2",
                "-map", "0:a", "-map", "1:a", "-af", "atrim=end_sample=\(sampleCount)",
                "-c:a", "pcm_f32le", file.path
            ])
            let service = AudioPeakAnalysisService(ffmpegPathProvider: { ffmpeg })
            let silent = try await service.analyze(file: file, trackIndex: 0)
            XCTAssertTrue(silent.intervals.isEmpty)
            XCTAssertNil(silent.imbalanceDB)
            let result = try await service.analyze(file: file, trackIndex: 1)
            XCTAssertEqual(result.channels.count, 2)
            XCTAssertEqual(result.intervals.count, 1)
            XCTAssertEqual(result.intervals[0].channel, 1)
            XCTAssertEqual(result.intervals[0].start, 0)
            XCTAssertEqual(result.intervals[0].end, Double(sampleCount) / Double(rate), accuracy: 1e-9)
            XCTAssertEqual(result.duration, Double(sampleCount) / Double(rate), accuracy: 1e-9)
            XCTAssertEqual(result.channels[0].peakDBFS, 20 * log10(0.95), accuracy: 0.00001)
            XCTAssertEqual(try XCTUnwrap(result.imbalanceDB), 20, accuracy: 0.00001)
        }
    }

    func testBundledFFmpegRetainsDelayedTimelineAndUnpaddedPartialWindow() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("delayed-peaks-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: file) }
        try await generate(ffmpeg, arguments: [
            "-f", "lavfi", "-i", "color=c=black:s=16x16:r=1:d=4",
            "-itsoffset", "2", "-f", "lavfi", "-i", "aevalsrc=0.95|0:s=48000:d=0.1000208333333333",
            "-map", "0:v", "-map", "1:a", "-c:v", "ffv1", "-c:a", "pcm_f32le", file.path
        ])
        let result = try await AudioPeakAnalysisService(ffmpegPathProvider: { ffmpeg }).analyze(file: file, trackIndex: 0)
        XCTAssertEqual(result.intervals.count, 1)
        XCTAssertEqual(result.intervals[0].start, 2, accuracy: 0.001)
        XCTAssertEqual(result.duration, 2 + 4801.0 / 48000, accuracy: 1e-9)
        XCTAssertEqual(result.channels[0].rmsDBFS, 20 * log10(0.95), accuracy: 0.00001)
        XCTAssertEqual(result.channels[1].rmsDBFS, -.infinity)
        XCTAssertEqual(result.imbalanceDB, .infinity)
    }

    func testBundledTruePeakFindsIntersampleExcursionsWithoutCumulativeQuietMarkersAtAllRates() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        for rate in [44100, 48000, 96000, 192000] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("true-peaks-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: file) }
            // Quarter-rate samples all have magnitude 0.9/sqrt(2); their
            // reconstructed sine reaches 0.9 between samples.
            let wave = "sin(2*PI*n/4+PI/4)"
            try await generate(ffmpeg, arguments: [
                "-f", "lavfi", "-i", "aevalsrc=if(lt(t\\,0.1)\\,0.9*\(wave)\\,0)|if(lt(t\\,0.1)\\,0.09*\(wave)\\,0):s=\(rate):d=0.4",
                "-c:a", "pcm_f64le", file.path
            ])
            let service = AudioPeakAnalysisService(ffmpegPathProvider: { ffmpeg })
            let source = try await service.analyze(file: file, trackIndex: 0, settings: .init(thresholdDBFS: -2))
            let result = try await service.analyze(file: file, trackIndex: 0,
                                                   settings: .init(thresholdDBFS: -2, truePeakThresholdDBTP: -2))
            XCTAssertEqual(result.channels, source.channels, "True-peak analysis must preserve source RMS and sample peaks")
            XCTAssertEqual(result.intervals, source.intervals)
            XCTAssertTrue(result.intervals.isEmpty)
            XCTAssertLessThan(result.channels[0].peakDBFS, -3.9)
            let peaks = try XCTUnwrap(result.truePeaks)
            XCTAssertEqual(peaks.sourceSampleRate, rate)
            XCTAssertEqual(peaks.measurementSampleRate, rate * 4)
            XCTAssertEqual(peaks.windowSourceSamples, 4800)
            XCTAssertEqual(peaks.thresholdDBTP, -2)
            XCTAssertEqual(peaks.channels.map(\.channel), [1, 2])
            XCTAssertGreaterThan(peaks.channels[0].peakDBTP, -1.1)
            XCTAssertLessThan(peaks.channels[1].peakDBTP, -19)
            XCTAssertFalse(peaks.intervals.isEmpty)
            XCTAssertTrue(peaks.intervals.allSatisfy { $0.channel == 1 && $0.end <= 0.21 },
                          "A high early peak must not keep quiet later windows above threshold")
            XCTAssertEqual(result.duration, 0.4, accuracy: 1e-9)
        }
    }

    func testBundledTruePeakPreservesTinyAndPartialEOFOnDelayedTimeline() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        for samples in [1, 17, 4801] {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("tiny-true-peaks-\(UUID().uuidString).mkv")
            defer { try? FileManager.default.removeItem(at: file) }
            try await generate(ffmpeg, arguments: [
                "-f", "lavfi", "-i", "color=c=black:s=16x16:r=1:d=3",
                "-itsoffset", "2", "-f", "lavfi", "-i", "aevalsrc=0.95:s=48000:d=1",
                "-map", "0:v", "-map", "1:a", "-af", "atrim=end_sample=\(samples)",
                "-c:v", "ffv1", "-c:a", "pcm_f64le", file.path
            ])
            let result = try await AudioPeakAnalysisService(ffmpegPathProvider: { ffmpeg }).analyze(
                file: file, trackIndex: 0, settings: .init(truePeakThresholdDBTP: -2))
            let peaks = try XCTUnwrap(result.truePeaks)
            XCTAssertEqual(result.duration, 2 + Double(samples) / 48000, accuracy: 1e-9)
            XCTAssertEqual(peaks.intervals.count, 1)
            let interval = try XCTUnwrap(peaks.intervals.first)
            XCTAssertEqual(interval.start, 2, accuracy: 1e-9)
            XCTAssertEqual(interval.end, result.duration, accuracy: 1e-9)
            XCTAssertEqual(interval.channel, 1)
            XCTAssertGreaterThan(interval.peakDBTP, -2)
        }
    }

    func testBundledTruePeakGroupedPresentationRetainsReorderedChannelsAndJSONContext() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("grouped-true-peaks-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: file) }
        try await generate(ffmpeg, arguments: [
            "-f", "lavfi", "-i", "aevalsrc=0.9*sin(2*PI*n/4+PI/4):s=48000:d=0.1000208333333333",
            "-f", "lavfi", "-i", "aevalsrc=0.09*sin(2*PI*n/4+PI/4):s=48000:d=0.1000208333333333",
            "-map", "0:a", "-map", "1:a", "-c:a", "pcm_f64le", file.path
        ])
        let presentation = LoudnessPresentation.stereo(left: 1, right: 0)
        let result = try await AudioPeakAnalysisService(ffmpegPathProvider: { ffmpeg }).analyze(
            file: file, presentation: presentation, settings: .init(thresholdDBFS: -2, truePeakThresholdDBTP: -2))
        let peaks = try XCTUnwrap(result.truePeaks)
        XCTAssertEqual(peaks.channels.map(\.channel), [1, 2])
        XCTAssertLessThan(peaks.channels[0].peakDBTP, -19)
        XCTAssertGreaterThan(peaks.channels[1].peakDBTP, -1.1)
        XCTAssertTrue(peaks.intervals.allSatisfy { $0.channel == 2 })
        XCTAssertFalse(peaks.intervals.isEmpty)
        XCTAssertEqual(try XCTUnwrap(peaks.intervals.last).end, 0.1, accuracy: 1e-9)
        XCTAssertEqual(result.duration, 4801.0 / 48000, accuracy: 1e-9)
        let data = try AnalyticsExporter.audioPeakJSON(result: result, sourceFile: file, timestamp: Date())
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(report["schemaVersion"] as? Int, 3)
        let context = try XCTUnwrap(report["presentation"] as? [String: Any])
        XCTAssertEqual(context["audioRelativeTrackIndices"] as? [Int], [1, 0])
        let payload = try XCTUnwrap(report["result"] as? [String: Any])
        let truePeakPayload = try XCTUnwrap(payload["truePeaks"] as? [String: Any])
        XCTAssertEqual(truePeakPayload["thresholdDBTP"] as? Double, -2)
        XCTAssertEqual((truePeakPayload["intervals"] as? [Any])?.count, peaks.intervals.count)
        var exportedMeasurements = result
        exportedMeasurements.presentation = nil // Stable presentation context lives beside result.
        XCTAssertEqual(try JSONDecoder().decode(AudioPeakAnalysisResult.self, from: JSONSerialization.data(withJSONObject: payload)), exportedMeasurements)
    }

    func testBundledTruePeakRejectsDecodedGapHiddenInsideOneAnalysisWindow() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gapped-true-peaks-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: file) }
        // Both packets fit within one analysis window, which would otherwise
        // conceal the 100 ms discontinuity between them.
        try await generate(ffmpeg, arguments: [
            "-f", "lavfi", "-i", "aevalsrc=0.95:s=48000:d=0.02,asetnsamples=n=512:p=0,asetpts=PTS+if(gte(N\\,512)\\,4800\\,0)",
            "-c:a", "pcm_f64le", file.path
        ])
        do {
            _ = try await AudioPeakAnalysisService(ffmpegPathProvider: { ffmpeg }).analyze(
                file: file, trackIndex: 0, settings: .init(truePeakThresholdDBTP: -2))
            XCTFail("A discontinuous decoded timeline returned true-peak markers")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("tim") || error.localizedDescription.contains("continu"),
                          error.localizedDescription)
        }
    }

    func testTruePeakJSONRejectsMissingMismatchedAndMalformedMeasurements() throws {
        let source = URL(fileURLWithPath: "/tmp/audio.wav")
        var result = AudioPeakAnalysisResult(settings: .init(truePeakThresholdDBTP: -2), intervals: [],
                                             channels: [.init(channel: 1, peakDBFS: -3, rmsDBFS: -6)], duration: 1,
                                             imbalanceDB: nil, presentation: .track(0))
        XCTAssertThrowsError(try AnalyticsExporter.audioPeakJSON(result: result, sourceFile: source, timestamp: Date()))
        let valid = AudioTruePeakResult(thresholdDBTP: -2, sourceSampleRate: 48000, measurementSampleRate: 192000,
                                        windowSourceSamples: 4800,
                                        method: "estimated_4x_libswresample_swr_filter64_cutoff0.97_no_certification",
                                        channels: [.init(channel: 1, peakDBTP: -1)],
                                        intervals: [.init(start: 0, end: 0.1, channel: 1, peakDBTP: -1)])
        result.truePeaks = valid
        XCTAssertNoThrow(try AnalyticsExporter.audioPeakJSON(result: result, sourceFile: source, timestamp: Date()))
        let malformed: [AudioTruePeakResult] = [
            .init(thresholdDBTP: -3, sourceSampleRate: 48000, measurementSampleRate: 192000,
                  windowSourceSamples: 4800, method: valid.method, channels: valid.channels, intervals: valid.intervals),
            .init(thresholdDBTP: -2, sourceSampleRate: 48000, measurementSampleRate: 48000,
                  windowSourceSamples: 4800, method: valid.method, channels: valid.channels, intervals: valid.intervals),
            .init(thresholdDBTP: -2, sourceSampleRate: 48000, measurementSampleRate: 192000,
                  windowSourceSamples: 4800, method: valid.method,
                  channels: [.init(channel: 1, peakDBTP: .nan)], intervals: valid.intervals),
            .init(thresholdDBTP: -2, sourceSampleRate: 48000, measurementSampleRate: 192000,
                  windowSourceSamples: 4800, method: valid.method,
                  channels: [.init(channel: 2, peakDBTP: -1)], intervals: valid.intervals),
            .init(thresholdDBTP: -2, sourceSampleRate: 48000, measurementSampleRate: 192000,
                  windowSourceSamples: 4800, method: valid.method, channels: valid.channels,
                  intervals: [.init(start: 0, end: 1.1, channel: 1, peakDBTP: -1)]),
            .init(thresholdDBTP: -2, sourceSampleRate: 48000, measurementSampleRate: 192000,
                  windowSourceSamples: 4800, method: valid.method, channels: valid.channels,
                  intervals: [.init(start: 0, end: 0.1, channel: 1, peakDBTP: -3)])
        ]
        for peaks in malformed {
            result.truePeaks = peaks
            XCTAssertThrowsError(try AnalyticsExporter.audioPeakJSON(result: result, sourceFile: source, timestamp: Date()))
        }
        result = .init(settings: .init(), intervals: [], channels: result.channels, duration: 1,
                       imbalanceDB: nil, presentation: .track(0), truePeaks: valid)
        XCTAssertThrowsError(try AnalyticsExporter.audioPeakJSON(result: result, sourceFile: source, timestamp: Date()))
    }

    func testBundledTruePeakSixMonoGroupingPreservesSelectedSurroundOrder() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("surround-true-peaks-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: file) }
        var arguments: [String] = []
        for index in 0..<6 {
            let amplitude = index == 3 ? 0.9 : 0.09
            arguments += ["-f", "lavfi", "-i", "aevalsrc=\(amplitude)*sin(2*PI*n/4+PI/4):s=48000:d=0.1000208333333333"]
        }
        for index in 0..<6 { arguments += ["-map", "\(index):a"] }
        arguments += ["-c:a", "pcm_f64le", file.path]
        try await generate(ffmpeg, arguments: arguments)
        let presentation = LoudnessPresentation.surround51([5, 3, 1, 4, 2, 0])
        let result = try await AudioPeakAnalysisService(ffmpegPathProvider: { ffmpeg }).analyze(
            file: file, presentation: presentation, settings: .init(thresholdDBFS: -2, truePeakThresholdDBTP: -2))
        let peaks = try XCTUnwrap(result.truePeaks)
        XCTAssertEqual(result.presentation, presentation)
        XCTAssertEqual(peaks.channels.map(\.channel), [1, 2, 3, 4, 5, 6])
        XCTAssertGreaterThan(peaks.channels[1].peakDBTP, -1.1)
        XCTAssertTrue(peaks.channels.filter { $0.channel != 2 }.allSatisfy { $0.peakDBTP < -19 })
        XCTAssertFalse(peaks.intervals.isEmpty)
        XCTAssertTrue(peaks.intervals.allSatisfy { $0.channel == 2 })
        XCTAssertEqual(result.duration, 4801.0 / 48000, accuracy: 1e-9)
    }

    func testTruePeakInterpolationFailureAndCancellationNeverReturnPartialReport() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("interpolation-failure-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        try await generate(ffmpeg, arguments: ["-f", "lavfi", "-i", "aevalsrc=0.95:s=48000:d=0.1", "-c:a", "pcm_f64le", file.path])
        let failureRunner = PeakInterpolationRunner(cancellationStarted: nil)
        do {
            _ = try await AudioPeakAnalysisService(runner: failureRunner, ffmpegPathProvider: { ffmpeg }).analyze(
                file: file, trackIndex: 0, settings: .init(truePeakThresholdDBTP: -2))
            XCTFail("Interpolation failure returned partial source-only success")
        } catch { XCTAssertTrue(error.localizedDescription.contains("interpolation failure"), error.localizedDescription) }

        let started = expectation(description: "Interpolation pass started after successful source analysis")
        let cancellationRunner = PeakInterpolationRunner(cancellationStarted: started)
        let service = AudioPeakAnalysisService(runner: cancellationRunner, ffmpegPathProvider: { ffmpeg })
        let task = Task { try await service.analyze(file: file, trackIndex: 0, settings: .init(truePeakThresholdDBTP: -2)) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled interpolation returned a report") }
        catch is CancellationError { }
        let active = await cancellationRunner.active
        XCTAssertFalse(active)
    }

    private func frame(_ index: Int, pts: Int, samples: Int, peaks: [Double], rms: [Double], rate: Int = 48000) -> String {
        var result = "[Parsed_ashowinfo_2 @ 0x1] n:\(index) pts:\(pts) pts_time:0 fmt:dbl channels:\(peaks.count) chlayout:stereo rate:\(rate) nb_samples:\(samples) checksum:0\n"
        result += "[Parsed_ametadata_4 @ 0x1] frame:\(index) pts:\(pts) pts_time:0\n"
        for channel in peaks.indices {
            result += "[Parsed_ametadata_4 @ 0x1] lavfi.astats.\(channel + 1).Peak_level=\(peaks[channel])\n"
            result += "[Parsed_ametadata_4 @ 0x1] lavfi.astats.\(channel + 1).RMS_level=\(rms[channel])\n"
        }
        return result + "[Parsed_ametadata_4 @ 0x1] lavfi.astats.Overall.Number_of_samples=\(samples)\n"
    }

    private func consume(_ text: String, _ collector: AudioPeakLogCollector) {
        collector.consume(.init(stream: .standardError, data: Data(text.utf8)))
    }

    private func complete(_ collector: AudioPeakLogCollector) {
        collector.consume(.init(stream: .standardOutput, data: Data("progress=end\n".utf8)))
    }

    private func generate(_ ffmpeg: String, arguments: [String]) async throws {
        let result = try await SubprocessRunner().run(.init(executableURL: URL(fileURLWithPath: ffmpeg),
                                                          arguments: ["-hide_banner", "-nostdin", "-y"] + arguments,
                                                          timeout: .seconds(30)))
        XCTAssertTrue(result.succeeded, result.standardErrorText)
    }
}

private struct PeakFailureRunner: SubprocessRunning {
    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        let report = """
        [Parsed_ashowinfo_2 @ 0x1] n:0 pts:0 channels:1 rate:48000 nb_samples:1
        [Parsed_ametadata_4 @ 0x1] frame:0 pts:0
        [Parsed_ametadata_4 @ 0x1] lavfi.astats.1.Peak_level=0
        [Parsed_ametadata_4 @ 0x1] lavfi.astats.1.RMS_level=0
        [Parsed_ametadata_4 @ 0x1] lavfi.astats.Overall.Number_of_samples=1

        """
        outputHandler?(.init(stream: .standardError, data: Data(report.utf8)))
        outputHandler?(.init(stream: .standardOutput, data: Data("progress=end\n".utf8)))
        return .init(terminationStatus: 1, termination: .exited, standardOutput: Data(),
                     standardError: Data("decoder failure".utf8), discardedStandardOutputBytes: 0,
                     discardedStandardErrorBytes: 0, duration: .zero)
    }
}

private actor PeakCancellationRunner: SubprocessRunning {
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

private actor PeakInterpolationRunner: SubprocessRunning {
    let cancellationStarted: XCTestExpectation?
    private(set) var active = false

    init(cancellationStarted: XCTestExpectation?) { self.cancellationStarted = cancellationStarted }

    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        guard request.arguments.contains(where: { $0.contains("aresample=") }) else {
            return try await SubprocessRunner().run(request, outputHandler: outputHandler)
        }
        active = true
        defer { active = false }
        if let cancellationStarted {
            cancellationStarted.fulfill()
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        }
        return .init(terminationStatus: 1, termination: .exited, standardOutput: Data(),
                     standardError: Data("interpolation failure".utf8), discardedStandardOutputBytes: 0,
                     discardedStandardErrorBytes: 0, duration: .zero)
    }
}
