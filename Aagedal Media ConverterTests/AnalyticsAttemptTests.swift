import Foundation
import XCTest
import PDFKit
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
                XCTAssertEqual(results.first { $0.metric == .ssimulacra2 }?.comparison?.sampleCount, 2)
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
        XCTAssertEqual(xpsnr.map(\.score), [30, .infinity])
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

    func testSSIMULACRAUsesDecodedFramesAndRejectsTimestampResets() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixtures: [(String, [String], Int, [Double]?)] = [
            ("fractional.mp4", ["-f", "lavfi", "-i", "testsrc2=s=128x128:r=30000/1001:d=0.3", "-c:v", "libx264"], 9, nil),
            ("delayed.mp4", ["-f", "lavfi", "-i", "sine=duration=1", "-itsoffset", "0.4", "-f", "lavfi", "-i", "testsrc2=s=128x128:r=10:d=0.6", "-map", "1:v", "-map", "0:a", "-c:v", "libx264", "-c:a", "aac"], 6, [0, 0.1, 0.2, 0.3, 0.4, 0.5]),
            ("vfr.mkv", ["-f", "lavfi", "-i", "testsrc2=s=128x128:r=4:d=1", "-vf", "setpts=N*N/(4*TB)", "-fps_mode", "passthrough", "-c:v", "ffv1"], 4, [0, 0.25, 1, 2.25]),
            ("duplicate.mkv", ["-f", "lavfi", "-i", "testsrc2=s=128x128:r=10:d=1", "-vf", "setpts=floor(N/2)*1/(10*TB)", "-fps_mode", "passthrough", "-c:v", "ffv1"], 10, [0, 0, 0.1, 0.1, 0.2, 0.2, 0.3, 0.3, 0.4, 0.4]),
            ("negative.mkv", ["-f", "lavfi", "-i", "testsrc2=s=128x128:r=30000/1001:d=1", "-vf", "setpts=PTS-0.2/TB", "-fps_mode", "passthrough", "-avoid_negative_ts", "disabled", "-c:v", "libx264"], -1, nil)
        ]
        for (name, arguments, count, expectedTimes) in fixtures {
            let file = directory.appendingPathComponent(name)
            let generated = try await SubprocessRunner().run(SubprocessRequest(executableURL: URL(fileURLWithPath: ffmpeg),
                arguments: ["-nostdin"] + arguments + [file.path], timeout: .seconds(30)))
            XCTAssertTrue(generated.succeeded, generated.standardErrorText)
            if count < 0 {
                do {
                    _ = try await AnalyticsService().runAnalytics(sourceFile: file, encodedFile: file,
                        enabledMetrics: [.ssimulacra2], vmafModel: .defaultModel, ssimulacra2MaxFrames: 100) { _, _ in }
                    XCTFail("Accepted a decoded timestamp reset")
                } catch AnalyticsError.parsingFailed { }
                continue
            }
            let results = try await AnalyticsService().runAnalytics(sourceFile: file, encodedFile: file,
                enabledMetrics: [.ssimulacra2], vmafModel: .defaultModel, ssimulacra2MaxFrames: 100) { _, _ in }
            let result = try XCTUnwrap(results.first)
            let samples = try XCTUnwrap(result.samples)
            XCTAssertEqual(samples.count, count, name)
            XCTAssertEqual(Set(samples.map(\.frame)).count, count, name)
            XCTAssertEqual(result.overallScore, 100, accuracy: 0.01, name)
            if let expectedTimes {
                XCTAssertEqual(samples.count, expectedTimes.count)
                for (sample, seconds) in zip(samples, expectedTimes) { XCTAssertEqual(sample.seconds, seconds, accuracy: 0.000001, name) }
            }
            for sample in samples {
                let pair = try XCTUnwrap(sample.framePair)
                // Duplicate timestamps are paired by the frame visible at that time;
                // identical inputs preserve ordinal identity to compare all frames.
                XCTAssertEqual(pair.encodedFrame, sample.frame)
                XCTAssertEqual(pair.encodedSeconds, sample.seconds + (result.comparison?.encodedVideoStart ?? 0), accuracy: 0.000001)
            }
            if name == "delayed.mp4" {
                let timeline = QualityTimeline(result: result)
                XCTAssertEqual(timeline.sourceStart, 0.4, accuracy: 0.000001)
                XCTAssertEqual(timeline.encodedStart, 0.4, accuracy: 0.000001)
                XCTAssertEqual(timeline.playbackTime(for: 0.2, source: true), 0.6, accuracy: 0.000001)
                XCTAssertEqual(timeline.playbackTime(for: 0.2, source: false), 0.6, accuracy: 0.000001)
            }
            let roundTrip = try JSONDecoder().decode(MetricResult.self, from: JSONEncoder().encode(result))
            XCTAssertEqual(roundTrip, result)
        }
    }

    func testSSIMULACRADoesNotHoldReferenceThroughAudioOnlyTail() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("short-video-long-audio.mkv")
        let encoded = directory.appendingPathComponent("long-video.mkv")
        for (file, arguments) in [
            (source, ["-f", "lavfi", "-i", "testsrc2=s=128x128:r=2:d=1", "-f", "lavfi", "-i", "sine=duration=3", "-c:v", "ffv1", "-c:a", "pcm_s16le"]),
            (encoded, ["-f", "lavfi", "-i", "testsrc2=s=128x128:r=2:d=3", "-c:v", "ffv1"])
        ] {
            let generated = try await SubprocessRunner().run(SubprocessRequest(executableURL: URL(fileURLWithPath: ffmpeg),
                arguments: ["-nostdin"] + arguments + [file.path], timeout: .seconds(30)))
            XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        }
        let results = try await AnalyticsService().runAnalytics(sourceFile: source, encodedFile: encoded,
            enabledMetrics: [.ssimulacra2], vmafModel: .defaultModel, ssimulacra2MaxFrames: 100) { _, _ in }
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.samples?.map(\.seconds), [0, 0.5])
        XCTAssertEqual(result.overallScore, 100, accuracy: 0.01)
    }

    func testSSIMULACRAMatchesNativeFractionalTrimBoundary() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mp4")
        let encoded = directory.appendingPathComponent("trimmed.mkv")
        for arguments in [
            ["-f", "lavfi", "-i", "testsrc2=s=128x128:r=30000/1001:d=1", "-c:v", "libx264", source.path],
            ["-ss", "0.400410", "-i", source.path, "-t", "0.4", "-c:v", "ffv1", encoded.path]
        ] {
            let generated = try await SubprocessRunner().run(SubprocessRequest(executableURL: URL(fileURLWithPath: ffmpeg),
                arguments: ["-nostdin"] + arguments, timeout: .seconds(30)))
            XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        }
        let results = try await AnalyticsService().runAnalytics(sourceFile: source, encodedFile: encoded,
            sourceRange: AnalyticsSourceRange(start: 0.400410, end: 0.800410),
            enabledMetrics: [.ssimulacra2], vmafModel: .defaultModel, ssimulacra2MaxFrames: 5) { _, _ in }
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.comparison?.sourceVideoStart ?? -1, 0.4004, accuracy: 0.000001)
        XCTAssertEqual(result.overallScore, 100, accuracy: 0.01)
    }

    func testSSIMULACRAOrdinalFallbackOnRealUnseekableRawVideo() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("raw.h264")
        let generated = try await SubprocessRunner().run(SubprocessRequest(executableURL: URL(fileURLWithPath: ffmpeg),
            arguments: ["-nostdin", "-f", "lavfi", "-i", "testsrc2=s=128x128:r=30000/1001:d=1", "-c:v", "libx264", file.path], timeout: .seconds(30)))
        XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        let service = AnalyticsService(mediaInfoProvider: RawSamplingFixtureInfo())
        let results = try await service.runAnalytics(sourceFile: file, encodedFile: file,
            enabledMetrics: [.ssimulacra2], vmafModel: .defaultModel, ssimulacra2MaxFrames: 3) { _, _ in }
        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.samples?.map(\.frame), [0, 15, 29])
        XCTAssertEqual(result.overallScore, 100, accuracy: 0.01)
    }

    func testSSIMULACRAHoldsVFRReferenceAcrossOutputFrameGaps() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("vfr.mkv")
        let output = directory.appendingPathComponent("cfr.mkv")
        for arguments in [
            ["-f", "lavfi", "-i", "testsrc2=s=128x128:r=4:d=1", "-vf", "setpts=N*N/(4*TB)", "-fps_mode", "passthrough", "-c:v", "ffv1", source.path],
            ["-i", source.path, "-vf", "fps=4", "-c:v", "ffv1", output.path]
        ] {
            let generated = try await SubprocessRunner().run(SubprocessRequest(executableURL: URL(fileURLWithPath: ffmpeg),
                arguments: ["-nostdin"] + arguments, timeout: .seconds(30)))
            XCTAssertTrue(generated.succeeded, generated.standardErrorText)
        }
        let results = try await AnalyticsService().runAnalytics(sourceFile: source, encodedFile: output,
            enabledMetrics: [.ssimulacra2], vmafModel: .defaultModel, ssimulacra2MaxFrames: 100) { _, _ in }
        let samples = try XCTUnwrap(results.first?.samples)
        let atHalfSecond = try XCTUnwrap(samples.first { abs($0.seconds - 0.5) < 0.000001 })
        XCTAssertEqual(atHalfSecond.framePair?.sourceSeconds, 0.25,
            "The visible reference at 0.5s is 0.25s; seeking forward to 1s compares future content")
        XCTAssertEqual(atHalfSecond.framePair?.encodedSeconds, 0.5)
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

final class LoudnessExportTests: XCTestCase {
    func testLoudnessJSONPreservesFullTimelinesAndExplicitChannelOrder() throws {
        let samples = (0..<8_000).map {
            LoudnessSample(seconds: Double($0) / 10, momentaryLUFS: $0 == 0 ? nil : -23,
                           shortTermLUFS: nil, peakDBFS: -1, rmsDBFS: nil)
        }
        let results = [LoudnessResults(presentation: .surround51([2, 3, 4, 7, 5, 6]), integratedLUFS: -23,
                                      loudnessRangeLU: 4, maximumTruePeakDBTP: nil, samples: samples),
                       LoudnessResults(presentation: .track(0), integratedLUFS: -70,
                                       loudnessRangeLU: 0, maximumTruePeakDBTP: -90, samples: [])]
        let date = Date(timeIntervalSince1970: 0)
        let data = try AnalyticsExporter.loudnessJSON(results: results,
                    sourceFile: URL(fileURLWithPath: "/private/source.mov"), timestamp: date)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["sourceFileName"] as? String, "source.mov")
        XCTAssertEqual(json["timestamp"] as? String, "1970-01-01T00:00:00Z")
        let reports = try XCTUnwrap(json["results"] as? [[String: Any]])
        XCTAssertEqual(reports.count, 2)
        let presentation = try XCTUnwrap(reports[0]["presentation"] as? [String: Any])
        XCTAssertEqual(presentation["audioRelativeTrackIndices"] as? [Int], [2, 3, 4, 7, 5, 6])
        XCTAssertEqual(presentation["channelOrder"] as? [String], ["FL", "FR", "FC", "LFE", "SL", "SR"])
        XCTAssertTrue(reports[0]["maximumTruePeakDBTP"] is NSNull)
        let readings = try XCTUnwrap(reports[0]["samples"] as? [[String: Any]])
        XCTAssertEqual(readings.count, samples.count)
        XCTAssertTrue(readings[0]["momentaryLUFS"] is NSNull)
        XCTAssertTrue(readings[0]["rmsDBFS"] is NSNull)
        XCTAssertEqual(readings.last?["seconds"] as? Double, 799.9)
        XCTAssertEqual(data, try AnalyticsExporter.loudnessJSON(results: results,
                           sourceFile: URL(fileURLWithPath: "/private/source.mov"), timestamp: date))
    }

    func testLoudnessJSONRejectsInvalidSummariesTopologyAndTimelines() throws {
        let file = URL(fileURLWithPath: "/private/source.mov")
        let date = Date(timeIntervalSince1970: 0)
        func report(_ presentation: LoudnessPresentation = .track(0), integrated: Double = -23,
                    range: Double = 4, peak: Double? = -1, samples: [LoudnessSample] = []) -> LoudnessResults {
            LoudnessResults(presentation: presentation, integratedLUFS: integrated,
                            loudnessRangeLU: range, maximumTruePeakDBTP: peak, samples: samples)
        }
        let invalid: [[LoudnessResults]] = [[], [report(.track(-1))], [report(.stereo(left: 0, right: 0))],
            [report(.surround51([0, 1]))], [report(integrated: .nan)], [report(range: -1)],
            [report(peak: .infinity)], [report(), report()],
            [report(samples: [.init(seconds: -1, momentaryLUFS: -23, shortTermLUFS: nil)])],
            [report(samples: [.init(seconds: 0, momentaryLUFS: .infinity, shortTermLUFS: nil)])],
            [report(samples: [.init(seconds: 1, momentaryLUFS: nil, shortTermLUFS: nil),
                              .init(seconds: 1, momentaryLUFS: nil, shortTermLUFS: nil)])]]
        for results in invalid {
            XCTAssertThrowsError(try AnalyticsExporter.loudnessJSON(results: results, sourceFile: file, timestamp: date))
        }
        XCTAssertThrowsError(try AnalyticsExporter.loudnessJSON(results: [report()], sourceFile: file,
                            timestamp: Date(timeIntervalSince1970: .nan)))
    }

    func testLoudnessJSONFailedValidationPreservesDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("report.json")
        let existing = Data("existing report".utf8)
        try existing.write(to: url)
        XCTAssertThrowsError(try AnalyticsExporter.exportLoudnessJSON(results: [], sourceFile: url,
                             timestamp: Date(), to: url))
        XCTAssertEqual(try Data(contentsOf: url), existing)
    }
}

final class VideoQualityScoreTests: XCTestCase {
    func testXPSNRMatchingChromaCannotHideLumaDistortion() throws {
        let result = try AnalyticsService.parseXPSNRResults(from: "[Parsed_xpsnr_2] XPSNR y: 18.7197 u: inf v: inf (minimum: 18.7197)")
        XCTAssertEqual(result.overallScore, 18.7197)
        XCTAssertEqual(result.channelScores?["U"], .infinity)
        XCTAssertNil(result.min, "The channel minimum is not a minimum across frames")
        XCTAssertEqual(result.scoreAggregation, "minimum_channel_average")
        let timeline = AnalyticsService.parseFrameScores("n: 1 XPSNR y: 30 XPSNR u: inf XPSNR v: 25\nn: 2 XPSNR y: inf XPSNR u: inf XPSNR v: inf",
                                                        metric: .xpsnr, timestamps: [0: 0, 1: 0.25])
        XCTAssertEqual(timeline.map(\.score), [25, .infinity])
    }

    func testPSNRParsesGrayscaleRGBAndAlphaWithoutInventingChannels() throws {
        for (components, keys) in [("y:inf", ["Y"]), ("r:inf g:inf b:inf", ["R", "G", "B"]),
                                   ("y:inf u:inf v:inf a:inf", ["Y", "U", "V", "A"]),
                                   ("r:inf g:inf b:inf a:inf", ["R", "G", "B", "A"])] {
            let result = try AnalyticsService.parsePSNRResults(from: "PSNR \(components) average:inf min:inf max:inf")
            XCTAssertEqual(Set(result.channelScores?.keys.map { $0 } ?? []), Set(keys))
            XCTAssertEqual(result.overallScore, .infinity)
            XCTAssertEqual(result.scoreAggregation, "pooled_mse_all_components")
        }
        let exponent = try AnalyticsService.parsePSNRResults(from: "PSNR y:3.2e1 average:3.2e1 min:+3.0e1 max:4e1")
        XCTAssertEqual(exponent.overallScore, 32)
        for invalid in ["y:nan", "y:-inf", "r:30 g:30", "y:30 u:inf", "y:30 y:30", "y:30 u:bad v:30"] {
            XCTAssertThrowsError(try AnalyticsService.parsePSNRResults(from: "PSNR \(invalid) average:30 min:20 max:40"))
            XCTAssertThrowsError(try AnalyticsService.parseXPSNRResults(from: "XPSNR \(invalid)"))
        }
        XCTAssertThrowsError(try AnalyticsService.parseXPSNRResults(from: "XPSNR y:30 u:40 v:50 (minimum: 40)"))
        XCTAssertThrowsError(try AnalyticsService.parsePSNRResults(from: "PSNR y:30 average:nan min:20 max:40"))
    }

    func testFrameScoresRejectInvalidValuesAndFrameIdentity() {
        let log = "n:1 psnr_avg:nan\nn:2 psnr_avg:-inf\nn:0 psnr_avg:30\nn:3 psnr_avg:20\nn:4 psnr_avg:inf\nn:5 psnr_avg:1e2"
        let samples = AnalyticsService.parseFrameScores(log, metric: .psnr, timestamps: [0: 0, 1: 0.25, 2: .nan, 3: 0.75, 4: 1])
        XCTAssertEqual(samples.map(\.score), [.infinity, 100])
        XCTAssertEqual(samples.map(\.frame), [3, 4])
        let invalid = AnalyticsService.parseFrameScores("n:1 XPSNR y:nan\nn:2 XPSNR r:20 XPSNR g:-inf XPSNR b:30",
                                                       metric: .xpsnr, timestamps: [0: 0, 1: 0.5])
        XCTAssertTrue(invalid.isEmpty)
    }

    func testXPSNRSupportsGrayscaleAndRGBFrameLogs() throws {
        XCTAssertEqual(try AnalyticsService.parseXPSNRResults(from: "XPSNR y: 27").overallScore, 27)
        XCTAssertEqual(try AnalyticsService.parseXPSNRResults(from: "XPSNR r: inf g: 24 b: 25 (minimum: 24)").overallScore, 24)
        let samples = AnalyticsService.parseFrameScores("n: 1 XPSNR y: 27\nn: 2 XPSNR r: inf XPSNR g: 24 XPSNR b: 25",
                                                       metric: .xpsnr, timestamps: [0: 0, 1: 0.5])
        XCTAssertEqual(samples.map(\.score), [27, 24])
    }

    func testBundledMetricsAcceptNativeGrayscaleRGBAlphaAndDistortedLuma() async throws {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for format in ["gray", "gbrp", "yuva444p", "yuv420p"] {
            let source = folder.appendingPathComponent("\(format).nut")
            let distorted = folder.appendingPathComponent("\(format)-distorted.nut")
            let generated = try await SubprocessRunner().run(.init(executableURL: URL(fileURLWithPath: ffmpeg),
                arguments: ["-hide_banner", "-nostdin", "-f", "lavfi", "-i", "testsrc2=s=128x128:r=4:d=1,format=\(format)",
                            "-c:v", "rawvideo", source.path], timeout: .seconds(30)))
            XCTAssertTrue(generated.succeeded, generated.standardErrorText)
            let identical = try await AnalyticsService().runAnalytics(sourceFile: source, encodedFile: source,
                enabledMetrics: [.psnr, .xpsnr], vmafModel: .vmaf_v0_6_1) { _, _ in }
            for metric in identical {
                XCTAssertEqual(metric.overallScore, .infinity, format)
                XCTAssertEqual(metric.samples?.count, 4, format)
                XCTAssertTrue(try XCTUnwrap(metric.samples).allSatisfy { $0.score == .infinity }, format)
            }
            if format == "yuva444p" {
                let changed = try await SubprocessRunner().run(.init(executableURL: URL(fileURLWithPath: ffmpeg),
                    arguments: ["-hide_banner", "-nostdin", "-i", source.path, "-vf", "lut=a=val/2", "-c:v", "rawvideo", distorted.path], timeout: .seconds(30)))
                XCTAssertTrue(changed.succeeded, changed.standardErrorText)
                let results = try await AnalyticsService().runAnalytics(sourceFile: source, encodedFile: distorted,
                    enabledMetrics: [.psnr, .xpsnr], vmafModel: .vmaf_v0_6_1) { _, _ in }
                XCTAssertTrue(try XCTUnwrap(results.first { $0.metric == .psnr }?.overallScore).isFinite)
                XCTAssertTrue(try XCTUnwrap(results.first { $0.metric == .psnr }?.channelScores?["A"]).isFinite)
                let xpsnr = try XCTUnwrap(results.first { $0.metric == .xpsnr })
                XCTAssertEqual(xpsnr.overallScore, .infinity, "FFmpeg XPSNR measures color planes only")
                XCTAssertTrue(try XCTUnwrap(xpsnr.comparison?.pixelProcessing).contains("excludes alpha"))
            }
            if format == "yuv420p" {
                let changed = try await SubprocessRunner().run(.init(executableURL: URL(fileURLWithPath: ffmpeg),
                    arguments: ["-hide_banner", "-nostdin", "-i", source.path, "-vf", "lut=y=val+8", "-c:v", "rawvideo", distorted.path], timeout: .seconds(30)))
                XCTAssertTrue(changed.succeeded, changed.standardErrorText)
                let results = try await AnalyticsService().runAnalytics(sourceFile: source, encodedFile: distorted,
                    enabledMetrics: [.xpsnr], vmafModel: .vmaf_v0_6_1) { _, _ in }
                let report = try XCTUnwrap(results.first)
                XCTAssertEqual(report.overallScore, 18.7197, accuracy: 0.001)
                XCTAssertEqual(report.channelScores?["U"], .infinity)
                XCTAssertTrue(try XCTUnwrap(report.samples).allSatisfy { $0.score.isFinite })
                let data = try XCTUnwrap(AnalyticsResults(sourceFileName: "source.nut", encodedFileName: "distorted.nut",
                    metrics: results, timestamp: Date(), durationSeconds: 1).toJSON())
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let metric = try XCTUnwrap((json["metrics"] as? [[String: Any]])?.first)
                XCTAssertEqual(metric["scoreAggregation"] as? String, "minimum_channel_average")
                XCTAssertEqual(try XCTUnwrap(metric["overallScore"] as? Double), report.overallScore)
            }
        }
    }
}


final class VideoQualityPDFTests: XCTestCase {
    @MainActor
    func testQualityPDFUsesA4PagesAndRetainsTimelinesMethodsAndWorstSections() throws {
        let comparison = AnalyticsComparison(resolution: .encoded, width: 1920, height: 1080,
            scaling: "bicubic", sourceRange: .init(start: 2, end: 12), vmafModel: .vmaf_v0_6_1,
            sourceTiming: .init(duration: 20, frameRate: 24), encodedTiming: .init(duration: 10, frameRate: 24),
            warnings: ["Source interval and encoded duration differ; only overlapping video is compared."])
        let samples = (0..<240).map {
            QualitySample(frame: $0, seconds: Double($0) / 24, score: $0 == 120 ? 12 : 90 + sin(Double($0) / 8) * 5)
        }
        let metrics: [MetricResult] = [
            .init(metric: .vmaf, overallScore: 91, min: 12, max: 95, unit: "score", channelScores: nil, comparison: comparison, samples: samples),
            .init(metric: .xpsnr, overallScore: 32, min: nil, max: nil, unit: "dB", channelScores: ["Y": 32, "U": .infinity, "V": 40],
                  comparison: comparison, samples: samples.map { .init(frame: $0.frame, seconds: $0.seconds, score: $0.score / 2) }, scoreAggregation: "minimum_channel_average"),
            .init(metric: .psnr, overallScore: .infinity, min: .infinity, max: .infinity, unit: "dB", channelScores: ["Y": .infinity],
                  samples: samples.map { .init(frame: $0.frame, seconds: $0.seconds, score: .infinity) }, scoreAggregation: "pooled_mse_all_components"),
            .init(metric: .ssimulacra2, overallScore: 85, min: 12, max: 95, unit: "score", channelScores: nil,
                  comparison: comparison, samples: stride(from: 0, to: samples.count, by: 24).map { samples[$0] })
        ]
        let reports = AnalyticsResults(sourceFileName: "Reference source.mov", encodedFileName: "Delivery.mp4",
                                       metrics: metrics, timestamp: Date(timeIntervalSince1970: 0), durationSeconds: 10)
        let url = URL(fileURLWithPath: "/private/tmp/amc-quality-report-validation.pdf")
        try AnalyticsExporter.exportPDF(results: reports, to: url)
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 4)
        for index in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            XCTAssertEqual(page.bounds(for: .mediaBox).size, CGSize(width: 595, height: 842))
            let text = try XCTUnwrap(page.string)
            for expected in ["Quality Analytics Report", "Reference source.mov", "Delivery.mp4", "Quality timeline", "P05:",
                             "Lowest measured sections", "Generated by Aagedal Media Converter"] {
                XCTAssertTrue(text.contains(expected), "Missing \(expected) on page \(index + 1)")
            }
        }
        XCTAssertTrue(try XCTUnwrap(document.page(at: 1)?.string).contains("XPSNR = min(U, V, Y)"))
        XCTAssertTrue(try XCTUnwrap(document.page(at: 2)?.string).contains("perfect-match"))
        XCTAssertTrue(try XCTUnwrap(document.page(at: 3)?.string).contains("Sampled frames only"))
    }

    @MainActor
    func testQualityPDFPaginatesLongMetadataAndHandlesHistoricalMissingTimeline() throws {
        let warning = String(repeating: "Detailed timing warning with a long source name. ", count: 400) + "END OF WARNING"
        let comparison = AnalyticsComparison(resolution: .source, width: nil, height: nil, scaling: "bicubic",
            sourceRange: .init(), vmafModel: nil, sourceTiming: nil, encodedTiming: nil, warnings: [warning])
        let reports = AnalyticsResults(sourceFileName: String(repeating: "Long source name ", count: 30), encodedFileName: "Output.mp4",
            metrics: [.init(metric: .psnr, overallScore: 30, min: 20, max: 40, unit: "dB", channelScores: ["Y": 30], comparison: comparison)],
            timestamp: Date(), durationSeconds: 10)
        let url = URL(fileURLWithPath: "/private/tmp/amc-quality-report-overflow-validation.pdf")
        try AnalyticsExporter.exportPDF(results: reports, to: url)
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThan(document.pageCount, 1)
        let text = try XCTUnwrap(document.string)
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(normalized.contains("END OF WARNING"))
        XCTAssertTrue(text.contains("No timeline data"))
        XCTAssertEqual(text.components(separatedBy: "Detailed timing warning").count - 1, 400)
        for index in 0..<document.pageCount {
            XCTAssertEqual(document.page(at: index)?.bounds(for: .mediaBox).size, CGSize(width: 595, height: 842))
        }
    }
}

private struct RawSamplingFixtureInfo: AnalyticsMediaInfoProviding {
    func duration(for file: URL) async -> Double? { 1.001 }
    func resolution(for file: URL) async -> (width: Int, height: Int)? { (128, 128) }
    func pixelFormat(for file: URL, ffmpegPath: String) async -> String? { "yuv420p" }
}
