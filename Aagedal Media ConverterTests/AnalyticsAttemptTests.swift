import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class AnalyticsAttemptTests: XCTestCase {
    func testCancelledAttemptCannotOverwriteRetryOrExportOldResults() {
        var item = makeItem()
        let outputURL = item.outputURL!
        let oldAttempt = AnalyticsAttempt(item: &item, encodedURL: outputURL)
        item.analyticsOperationID = nil
        item.analyticsStatus = .notQueued
        let retry = AnalyticsAttempt(item: &item, encodedURL: outputURL)
        var items = [item]
        var exportCount = 0
        XCTAssertFalse(oldAttempt.apply(to: &items) { item in
            item.analyticsStatus = .completed
            exportCount += 1
        })
        XCTAssertFalse(oldAttempt.apply(to: &items) { $0.analyticsStatus = .failed("Old failure") })
        XCTAssertEqual(items[0].analyticsStatus, .pending)
        XCTAssertEqual(items[0].analyticsOperationID, retry.operationID)
        XCTAssertEqual(exportCount, 0)

        XCTAssertTrue(retry.apply(to: &items) { item in
            item.analyticsStatus = .completed
            item.analyticsOperationID = nil
            exportCount += 1
        })
        XCTAssertFalse(retry.apply(to: &items) { $0.analyticsStatus = .running(metric: .psnr, progress: 0.5) })
        XCTAssertEqual(items[0].analyticsStatus, .completed)
        XCTAssertEqual(exportCount, 1)
    }

    func testResetRemovalAndChangedOutputRejectManualPublication() {
        var item = makeItem()
        let outputURL = item.outputURL!
        let attempt = AnalyticsAttempt(item: &item, encodedURL: outputURL)
        var items = [item]
        items[0].resetConversionState()
        XCTAssertNil(items[0].analyticsOperationID)
        XCTAssertFalse(attempt.apply(to: &items) { _ in XCTFail("Reset row accepted old result") })
        items = [item]
        items[0].outputURL = URL(fileURLWithPath: "/fixture/replacement.mp4")
        XCTAssertFalse(attempt.apply(to: &items) { _ in XCTFail("Changed output accepted old result") })
        items = []
        XCTAssertFalse(attempt.apply(to: &items) { _ in XCTFail("Removed row accepted old result") })
    }

    func testDelayedCancellationForOldOperationDoesNotCancelNewServiceRun() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        let output = directory.appendingPathComponent("output.mp4")
        try Data([0]).write(to: source)
        try Data([0]).write(to: output)
        let started = expectation(description: "Replacement analytics running")
        let runner = AnalyticsAttemptRunner(started: started)
        let service = AnalyticsService(subprocessRunner: runner, ffmpegPathProvider: { "/fixture/ffmpeg" })
        let task = Task {
            try await service.runAnalytics(
                sourceFile: source, encodedFile: output, enabledMetrics: [.psnr],
                vmafModel: .vmaf_v0_6_1, operationID: UUID()
            ) { _, _ in }
        }
        await fulfillment(of: [started], timeout: 2)
        await service.cancelAnalysis(operationID: UUID())
        await runner.finish()
        let results = try await task.value
        XCTAssertEqual(results.first?.overallScore, 39.01)
    }

    func testManualAnalysisRetainsCompletedOutputRangeAfterQueueEdits() {
        var item = makeItem()
        item.analyticsSourceRange = AnalyticsSourceRange(start: 2, end: 4)
        item.trimStart = 7
        item.trimEnd = 9
        let output = item.outputURL!
        let attempt = AnalyticsAttempt(item: &item, encodedURL: output)
        let followUp = ConversionFollowUp(item: item, ownership: ConversionCallbackOwnership())
        XCTAssertEqual(attempt.sourceRange, AnalyticsSourceRange(start: 2, end: 4))
        XCTAssertEqual(followUp.sourceRange, attempt.sourceRange)
        item.outputURL = URL(fileURLWithPath: "/fixture/replaced.mp4")
        XCTAssertNil(item.analyticsSourceRange)
        item.analyticsSourceRange = attempt.sourceRange
        item.resetConversionState()
        XCTAssertNil(item.analyticsSourceRange)
    }

    @MainActor
    func testAutomaticReportsPreserveExistingFilesAndNumberRepeatedExports() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output.mp4")
        let metric = MetricResult(metric: .psnr, overallScore: .infinity, min: .infinity,
                                  max: .infinity, unit: "dB", channelScores: ["Y": .infinity])
        let results = AnalyticsResults(sourceFileName: "source.mov", encodedFileName: "output.mp4",
                                       metrics: [metric], timestamp: Date(), durationSeconds: 2)
        XCTAssertEqual(metric.formattedScore, "∞ dB")
        for format in [AnalyticsExportFormat.json, .pdf] {
            let existing = directory.appendingPathComponent("output_analytics.\(format.fileExtension)")
            let sentinel = Data("An existing edited report".utf8)
            try sentinel.write(to: existing)
            let first = try AnalyticsExporter.autoExport(results: results, encodedFileURL: output, format: format)
            let second = try AnalyticsExporter.autoExport(results: results, encodedFileURL: output, format: format)
            XCTAssertEqual(first.lastPathComponent, "output_analytics_1.\(format.fileExtension)")
            XCTAssertEqual(second.lastPathComponent, "output_analytics_2.\(format.fileExtension)")
            XCTAssertEqual(try Data(contentsOf: existing), sentinel)
            XCTAssertFalse(try Data(contentsOf: first).isEmpty)
            XCTAssertFalse(try Data(contentsOf: second).isEmpty)
            if format == .json {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: first)) as? [String: Any])
                let metrics = try XCTUnwrap(json["metrics"] as? [[String: Any]])
                XCTAssertEqual(metrics[0]["overallScore"] as? String, "Infinity")
            }
        }
    }

    func testBundledMetricsAlignTrimmedLosslessOutputAndAcceptPerfectScores() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mkv")
        let output = directory.appendingPathComponent("trimmed.mkv")
        let runner = SubprocessRunner()
        for arguments in [
            ["-f", "lavfi", "-i", "testsrc2=s=128x128:r=4:d=6", "-c:v", "ffv1", source.path],
            ["-ss", "2", "-t", "2", "-i", source.path, "-c:v", "ffv1", output.path]
        ] {
            let generated = try await runner.run(SubprocessRequest(
                executableURL: URL(fileURLWithPath: ffmpeg), arguments: ["-hide_banner", "-nostdin"] + arguments,
                timeout: .seconds(30)
            ))
            XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        }
        let service = AnalyticsService()
        let unaligned = try await service.runAnalytics(sourceFile: source, encodedFile: output,
                                                       enabledMetrics: [.psnr], vmafModel: .vmaf_v0_6_1) { _, _ in }
        XCTAssertTrue(try XCTUnwrap(unaligned.first).overallScore.isFinite)
        let aligned = try await service.runAnalytics(sourceFile: source, encodedFile: output,
                                                     sourceRange: AnalyticsSourceRange(start: 2, end: 4),
                                                     enabledMetrics: [.psnr, .xpsnr, .vmaf, .ssimulacra2],
                                                     vmafModel: .vmaf_v0_6_1, ssimulacra2MaxFrames: 2) { _, _ in }
        XCTAssertEqual(aligned.count, 4)
        XCTAssertEqual(aligned[0].overallScore, .infinity)
        XCTAssertEqual(aligned[1].overallScore, .infinity)
        XCTAssertGreaterThan(aligned[2].overallScore, 99)
        XCTAssertEqual(aligned[3].overallScore, 100, accuracy: 0.1)
    }

    func testInvalidSourceIntervalsAreRejected() async throws {
        let service = AnalyticsService()
        for range in [AnalyticsSourceRange(start: -1), AnalyticsSourceRange(start: .nan),
                      AnalyticsSourceRange(start: 2, end: 2), AnalyticsSourceRange(end: .infinity)] {
            do {
                _ = try await service.runAnalytics(sourceFile: URL(fileURLWithPath: "/unused/source"),
                                                    encodedFile: URL(fileURLWithPath: "/unused/output"),
                                                    sourceRange: range, enabledMetrics: [.psnr],
                                                    vmafModel: .vmaf_v0_6_1) { _, _ in }
                XCTFail("Invalid interval was accepted")
            } catch let error as AnalyticsError {
                guard case .parsingFailed = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testComparisonMetadataRoundTripsAndOldReportsRemainReadable() throws {
        let comparison = AnalyticsComparison(
            resolution: .source, width: 1920, height: 1080, scaling: "bicubic",
            sourceRange: AnalyticsSourceRange(start: 2, end: 4), vmafModel: .defaultModel,
            sampleCount: 2, sampleTimestamps: [0, 1],
            sourceTiming: AnalyticsTiming(duration: 6, frameRate: 24, frameCount: 144),
            encodedTiming: AnalyticsTiming(duration: 2, frameRate: 24, frameCount: 48), warnings: []
        )
        let metric = MetricResult(metric: .vmaf, overallScore: 95, min: nil, max: nil,
                                  unit: "", channelScores: nil, comparison: comparison)
        let report = AnalyticsResults(sourceFileName: "source.mov", encodedFileName: "output.ivf",
                                      metrics: [metric], timestamp: Date(), durationSeconds: 2)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try XCTUnwrap(report.toJSON())
        XCTAssertEqual(try decoder.decode(AnalyticsResults.self, from: data).metrics[0].comparison, comparison)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var metrics = try XCTUnwrap(json["metrics"] as? [[String: Any]])
        metrics[0].removeValue(forKey: "comparison")
        json["metrics"] = metrics
        let legacy = try decoder.decode(AnalyticsResults.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.metrics[0].comparison)
    }

    func testTimingWarningsRespectTrimAndFlagRateDurationAndCountDifferences() {
        let source = AnalyticsTiming(duration: 6, frameRate: 24, frameCount: 144)
        XCTAssertTrue(AnalyticsComparison.timingWarnings(
            source: source, encoded: AnalyticsTiming(duration: 2, frameRate: 24, frameCount: 48),
            range: AnalyticsSourceRange(start: 2, end: 4)).isEmpty)
        let warnings = AnalyticsComparison.timingWarnings(
            source: source, encoded: AnalyticsTiming(duration: 5, frameRate: 30, frameCount: 150),
            range: AnalyticsSourceRange())
        XCTAssertEqual(warnings.count, 3)
        XCTAssertEqual(AnalyticsComparison.timingWarnings(source: nil, encoded: nil, range: AnalyticsSourceRange()).count, 1)
    }

    func testBundledAV2IVFAndMatroskaAnalysisUsesAllMetrics() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let encoder = try XCTUnwrap(BinaryPathResolver.avmencPath)
        let decoder = try XCTUnwrap(BinaryPathResolver.avmdecPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for depth in [8, 10] {
            let y4m = directory.appendingPathComponent("source-\(depth).y4m")
            let ivf = directory.appendingPathComponent("encoded-\(depth).ivf")
            let mkv = directory.appendingPathComponent("encoded-\(depth).mkv")
            let reference = directory.appendingPathComponent("decoded-\(depth).mkv")
            let runner = SubprocessRunner()
            let generated = try await runner.run(SubprocessRequest(executableURL: URL(fileURLWithPath: ffmpeg),
                arguments: ["-nostdin", "-f", "lavfi", "-i", "testsrc2=s=128x128:r=2:d=1", "-pix_fmt", depth == 10 ? "yuv420p10le" : "yuv420p", "-strict", "-1", y4m.path], timeout: .seconds(30)))
            XCTAssertTrue(generated.succeeded, generated.standardErrorText)
            let encoded = try await runner.run(SubprocessRequest(executableURL: URL(fileURLWithPath: encoder),
                arguments: ["--ivf", "--bit-depth=\(depth)", "--input-bit-depth=\(depth)", "--end-usage=q", "--qp=110", "--cpu-used=9", "--threads=2", "--lag-in-frames=0",
                            "--limit=2", "-o", ivf.path, y4m.path], timeout: .seconds(120)))
            XCTAssertTrue(encoded.succeeded, encoded.standardErrorText)
            // Build an independently decoded reference so the analysis bridge must be lossless.
            let decoded = try await runner.runPipeline(
                producer: SubprocessRequest(executableURL: URL(fileURLWithPath: decoder), arguments: [ivf.path, "-o", "-"], timeout: .seconds(30)),
                consumer: SubprocessRequest(executableURL: URL(fileURLWithPath: ffmpeg),
                    arguments: ["-nostdin", "-f", "yuv4mpegpipe", "-i", "pipe:0", "-c:v", "ffv1", reference.path], timeout: .seconds(30)),
                drainProducer: true)
            XCTAssertTrue(decoded.consumer.succeeded, decoded.consumer.standardErrorText)
            // Stream the independently decodable IVF payload into the production muxer.
            try MatroskaMuxer.write(to: mkv,
                video: .init(codecPrivate: nil, width: 128, height: 128, fpsNumerator: 2, fpsDenominator: 1),
                videoIVFURL: ivf, keyframeIndices: [0], audioTracks: [])
            let service = AnalyticsService()
            let baseline = try await service.runAnalytics(sourceFile: reference, encodedFile: reference,
                enabledMetrics: QualityMetric.allCases, vmafModel: .vmaf_v0_6_1, ssimulacra2MaxFrames: 2) { _, _ in }
            for output in [ivf, mkv] {
                var preview: AnalyticsPreviewAsset? = try await service.prepareQualityPreview(output)
                let previewURL = try XCTUnwrap(preview?.url)
                XCTAssertNotEqual(previewURL, output)
                XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path))
                preview = nil
                XCTAssertFalse(FileManager.default.fileExists(atPath: previewURL.deletingLastPathComponent().path))
                let results = try await service.runAnalytics(sourceFile: reference, encodedFile: output,
                    enabledMetrics: QualityMetric.allCases, vmafModel: .vmaf_v0_6_1, ssimulacra2MaxFrames: 2) { _, _ in }
                XCTAssertEqual(results.count, 4)
                for result in results {
                    XCTAssertFalse(result.samples?.isEmpty ?? true, result.metric.rawValue)
                    XCTAssertEqual(result.samples?.first?.seconds, 0)
                }
                XCTAssertEqual(results.first { $0.metric == .psnr }?.overallScore, .infinity)
                XCTAssertEqual(results.first { $0.metric == .xpsnr }?.overallScore, .infinity)
                XCTAssertEqual(try XCTUnwrap(results.first { $0.metric == .vmaf }).overallScore,
                               try XCTUnwrap(baseline.first { $0.metric == .vmaf }).overallScore, accuracy: 0.000001)
                XCTAssertEqual(try XCTUnwrap(results.first { $0.metric == .ssimulacra2 }).overallScore, 100, accuracy: 0.1)
                XCTAssertEqual(results.first?.comparison?.width, 128)
                XCTAssertEqual(results.first?.comparison?.resolution, .encoded)
                XCTAssertEqual(results.first { $0.metric == .ssimulacra2 }?.comparison?.sampleCount, 1)
            }
            // AV2 is also supported as the reference input; test the opposite scaling policy.
            let reversed = try await service.runAnalytics(sourceFile: ivf, encodedFile: reference,
                enabledMetrics: [.psnr], vmafModel: .defaultModel, comparisonResolution: .source) { _, _ in }
            XCTAssertEqual(reversed.first?.overallScore, .infinity)
            XCTAssertEqual(reversed.first?.comparison?.resolution, .source)
        }
    }

    func testAllMetricsUseChosenResolutionForResizedOutput() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mkv")
        let encoded = directory.appendingPathComponent("small.mkv")
        let runner = SubprocessRunner()
        for arguments in [
            ["-f", "lavfi", "-i", "testsrc2=s=256x256:r=2:d=1", "-c:v", "ffv1", source.path],
            ["-i", source.path, "-vf", "scale=128:128:flags=bicubic", "-c:v", "ffv1", encoded.path]
        ] {
            let result = try await runner.run(SubprocessRequest(executableURL: URL(fileURLWithPath: ffmpeg),
                arguments: ["-nostdin"] + arguments, timeout: .seconds(30)))
            XCTAssertTrue(result.succeeded, result.standardErrorText)
        }
        let service = AnalyticsService()
        for resolution in AnalyticsComparisonResolution.allCases {
            let results = try await service.runAnalytics(sourceFile: source, encodedFile: encoded,
                enabledMetrics: QualityMetric.allCases, vmafModel: .vmaf_v0_6_1, ssimulacra2MaxFrames: 1,
                comparisonResolution: resolution) { _, _ in }
            for result in results {
                XCTAssertEqual(result.comparison?.resolution, resolution)
                XCTAssertEqual(result.comparison?.width, resolution == .source ? 256 : 128)
                XCTAssertEqual(result.comparison?.scaling, "bicubic")
                XCTAssertTrue(result.comparison?.warnings.isEmpty == true)
            }
            if resolution == .encoded {
                XCTAssertEqual(results.first { $0.metric == .psnr }?.overallScore, .infinity)
                XCTAssertEqual(try XCTUnwrap(results.first { $0.metric == .ssimulacra2 }).overallScore, 100, accuracy: 0.1)
            } else {
                XCTAssertTrue(try XCTUnwrap(results.first { $0.metric == .psnr }).overallScore.isFinite)
            }
        }
    }

    func testQualityTimelinePreservesDropsAndFindsDistinctLowSections() {
        let samples = (0..<1000).map { index in
            QualitySample(frame: index, seconds: Double(index) / 100, score: index == 555 ? 12 : 95)
        }
        let result = MetricResult(metric: .vmaf, overallScore: 94, min: 12, max: 95,
                                  unit: "score", channelScores: nil, samples: samples)
        let timeline = QualityTimeline(result: result, maxBuckets: 10)
        XCTAssertLessThanOrEqual(timeline.graphSamples.count, 40)
        XCTAssertTrue(timeline.graphSamples.contains { $0.frame == 555 })
        XCTAssertEqual(timeline.worstSamples.first?.frame, 555)
        XCTAssertEqual(timeline.fifthPercentile, 95)
        XCTAssertEqual(timeline.sample(nearest: 5.553)?.frame, 555)
        for a in timeline.worstSamples.indices {
            for b in timeline.worstSamples.indices where a < b {
                XCTAssertGreaterThanOrEqual(abs(timeline.worstSamples[a].seconds - timeline.worstSamples[b].seconds), 1)
            }
        }
    }

    func testQualityTimelineHandlesPerfectScoresAndTrimmedPlayback() throws {
        let comparison = AnalyticsComparison(resolution: .encoded, width: 128, height: 128, scaling: "bicubic",
            sourceRange: AnalyticsSourceRange(start: 8, end: 10), vmafModel: nil,
            sourceTiming: nil, encodedTiming: AnalyticsTiming(duration: 2, frameRate: 24), warnings: [])
        let result = MetricResult(metric: .psnr, overallScore: .infinity, min: nil, max: nil,
            unit: "dB", channelScores: nil, comparison: comparison,
            samples: [.init(frame: 0, seconds: 0, score: .infinity), .init(frame: 1, seconds: 1, score: .infinity),
                      .init(frame: 2, seconds: .nan, score: 20), .init(frame: 3, seconds: 2, score: .nan)])
        let timeline = QualityTimeline(result: result)
        XCTAssertEqual(timeline.samples.count, 2)
        XCTAssertEqual(timeline.fifthPercentile, .infinity)
        XCTAssertTrue(timeline.worstSamples.isEmpty)
        XCTAssertEqual(timeline.playbackTime(for: 1.5, source: true), 9.5)
        XCTAssertEqual(timeline.playbackTime(for: 1.5, source: false), 1.5)
        XCTAssertEqual(timeline.playbackTime(for: 99, source: true), 10)
        XCTAssertEqual(timeline.playbackTime(for: .nan, source: false), 0)
        XCTAssertEqual(timeline.sample(nearest: 0.9)?.frame, 1)
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
        XCTAssertEqual(try decoder.decode([QualitySample].self, from: encoder.encode(timeline.samples)), timeline.samples)
    }

    func testFrameScoreLogsUseMeasuredTimestampsAndKeepPerfectMatches() {
        let timestamps = [0: 0.0, 1: 0.125, 2: 0.9]
        let psnr = AnalyticsService.parseFrameScores("n:1 psnr_avg:inf\nn:2 psnr_avg:31.2\nn:3 psnr_avg:20\nn:4 psnr_avg:10", metric: .psnr, timestamps: timestamps)
        XCTAssertEqual(psnr.map(\.seconds), [0, 0.125, 0.9])
        XCTAssertEqual(psnr.map(\.score), [.infinity, 31.2, 20])
        let xpsnr = AnalyticsService.parseFrameScores("n: 1 XPSNR y: 30 XPSNR u: 40 XPSNR v: 40\nn: 2 XPSNR y: inf XPSNR u: inf XPSNR v: inf", metric: .xpsnr, timestamps: timestamps)
        XCTAssertEqual(xpsnr.map(\.score), [32.5, .infinity])
        XCTAssertEqual(xpsnr.map(\.seconds), [0, 0.125])
    }

    func testBundledMetricTimelinesRetainVariableFrameTimestamps() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("variable.mkv")
        let generated = try await SubprocessRunner().run(SubprocessRequest(executableURL: URL(fileURLWithPath: ffmpeg),
            arguments: ["-nostdin", "-f", "lavfi", "-i", "testsrc2=s=128x128:r=4:d=1", "-vf", "setpts=N*N/(4*TB)",
                        "-fps_mode", "passthrough", "-c:v", "ffv1", source.path], timeout: .seconds(30)))
        XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        let results = try await AnalyticsService().runAnalytics(sourceFile: source, encodedFile: source,
            enabledMetrics: [.vmaf, .psnr, .xpsnr], vmafModel: .vmaf_v0_6_1) { _, _ in }
        for result in results {
            let samples = try XCTUnwrap(result.samples)
            XCTAssertEqual(samples.count, 4, result.metric.rawValue)
            XCTAssertEqual(samples.map(\.seconds), [0, 0.25, 1, 2.25], result.metric.rawValue)
        }
    }

    private func makeItem() -> VideoItem {
        VideoItem(
            url: URL(fileURLWithPath: "/fixture/source.mov"), name: "source.mov", size: 0,
            duration: "00:00:10", durationSeconds: 10, status: .done,
            progress: 1, eta: nil, outputURL: URL(fileURLWithPath: "/fixture/output.mp4")
        )
    }
}

private actor AnalyticsAttemptRunner: SubprocessRunning {
    private let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(started: XCTestExpectation) {
        self.started = started
    }

    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
        try Task.checkCancellation()
        return SubprocessResult(
            terminationStatus: 0, termination: .exited, standardOutput: Data(),
            standardError: Data("PSNR y:38.12 u:42.34 v:43.56 average:39.01 min:25.67 max:48.90".utf8),
            discardedStandardOutputBytes: 0, discardedStandardErrorBytes: 0, duration: .milliseconds(1)
        )
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
