import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class PostConversionSettingsTests: XCTestCase {
    private func withSettings(_ body: (UserDefaults, PostConversionSettings) throws -> Void) rethrows {
        let suite = "PostConversionSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, PostConversionSettings(defaults: defaults))
    }

    func testParakeetDefaultsAndMalformedDurationsUseCLIDefaults() {
        withSettings { defaults, _ in
            XCTAssertEqual(ParakeetSettingsSnapshot(defaults: defaults).arguments, [])
            let invalidValues: [Any] = [
                0, -1, Int.min, Int.max, Double.nan, Double.infinity, -Double.infinity,
                1.5, true, "invalid", "nan", "inf", "120seconds", [], ["value": 120]
            ]
            for value in invalidValues {
                defaults.set(value, forKey: AppConstants.parakeetChunkDurationKey)
                defaults.set(value, forKey: AppConstants.parakeetOverlapDurationKey)
                XCTAssertEqual(ParakeetSettingsSnapshot(defaults: defaults), ParakeetSettingsSnapshot(), "\(value)")
            }
            XCTAssertEqual(ParakeetSettingsSnapshot(chunkDuration: Int.max, overlapDuration: Int.min).arguments, [])
        }
    }

    func testParakeetDurationsAcceptWholeNumericStringsAndRemainCaptured() {
        withSettings { defaults, _ in
            defaults.set("120", forKey: AppConstants.parakeetChunkDurationKey)
            defaults.set(12.0, forKey: AppConstants.parakeetOverlapDurationKey)
            let snapshot = ParakeetSettingsSnapshot(defaults: defaults)
            defaults.set(600, forKey: AppConstants.parakeetChunkDurationKey)
            defaults.set(30, forKey: AppConstants.parakeetOverlapDurationKey)
            XCTAssertEqual(snapshot.arguments, ["--chunk-duration", "120", "--overlap-duration", "12"])
            XCTAssertEqual(ParakeetSettingsSnapshot(defaults: defaults).arguments,
                           ["--chunk-duration", "600", "--overlap-duration", "30"])
        }
    }

    func testParakeetCustomOverlapSendsChunkEvenWhenItMatchesAppDefault() {
        // The helper's own default can be 120 rather than the app's 300 seconds.
        // Omitting the chunk here would make this otherwise valid overlap fail.
        XCTAssertEqual(ParakeetSettingsSnapshot(overlapDuration: 200).arguments,
                       ["--chunk-duration", "300", "--overlap-duration", "200"])
        XCTAssertEqual(ParakeetSettingsSnapshot(chunkDuration: 60).arguments,
                       ["--chunk-duration", "60", "--overlap-duration", "15"])
    }

    func testParakeetOverlapAlwaysAllowsForwardProgress() {
        for (chunk, overlap, expected) in [(10, 15, 9), (10, 10, 9), (10, 0, 9), (1, 15, 0)] {
            let settings = ParakeetSettingsSnapshot(chunkDuration: chunk, overlapDuration: overlap)
            XCTAssertEqual(settings.overlapDuration, expected)
            XCTAssertEqual(settings.arguments,
                           ["--chunk-duration", "\(chunk)", "--overlap-duration", "\(expected)"])
        }
        let maximum = ParakeetSettingsSnapshot.maximumChunkDuration
        XCTAssertEqual(ParakeetSettingsSnapshot(chunkDuration: maximum).chunkDuration, maximum)
        XCTAssertEqual(ParakeetSettingsSnapshot(chunkDuration: maximum + 1).chunkDuration,
                       AppConstants.defaultParakeetChunkDuration)
    }

    @MainActor
    func testParakeetServiceCapturesSettingsBeforeAudioExtractionAndNextRunSeesEdits() async throws {
        let suite = "ParakeetSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(120, forKey: AppConstants.parakeetChunkDurationKey)
        defaults.set(12, forKey: AppConstants.parakeetOverlapDurationKey)
        let runner = ParakeetSettingsRunner(defaults: defaults)
        let service = ParakeetService(
            subprocessRunner: runner,
            parakeetPathProvider: { "/fixture/parakeet-mlx" },
            ffmpegPathProvider: { "/fixture/ffmpeg" },
            settingsProvider: { runner.snapshot() }
        )
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("clip.mov")
        try Data().write(to: input)
        for _ in 0..<2 {
            _ = try await service.generateSubtitles(
                inputFile: input, outputDirectory: directory, model: ParakeetModel.allModels[0],
                language: nil, operationID: UUID(), audioStreamIndex: 0
            ) { _ in runner.editPreferences() }
        }
        XCTAssertEqual(runner.snapshotCount, 2)
        let requests = runner.transcriptionArguments
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(Array(requests[0].suffix(4)), ["--chunk-duration", "120", "--overlap-duration", "12"])
        XCTAssertEqual(Array(requests[1].suffix(4)), ["--chunk-duration", "600", "--overlap-duration", "30"])
    }

    func testMissingPreferencesKeepExistingDefaults() {
        withSettings { _, settings in
            let transcription = settings.transcriptionSnapshot()
            XCTAssertEqual(transcription.whisperModel.rawValue, AppConstants.defaultWhisperModel)
            XCTAssertEqual(transcription.whisperLanguage, AppConstants.defaultWhisperLanguage)
            XCTAssertEqual(transcription.parakeetModel.id, AppConstants.defaultParakeetModel)
            XCTAssertEqual(transcription.parakeetLanguage, AppConstants.defaultParakeetLanguage)
            XCTAssertFalse(transcription.embedSubtitles)
            let analytics = settings.analyticsSnapshot()
            XCTAssertEqual(analytics.enabledMetrics.map(\.rawValue), AppConstants.defaultAnalyticsEnabledMetrics)
            XCTAssertEqual(analytics.vmafModel.rawValue, AppConstants.defaultAnalyticsVMAFModel)
        }
    }

    func testInvalidModelsFallBackAndUnknownMetricsAreIgnored() {
        withSettings { defaults, settings in
            defaults.set("removed-model", forKey: AppConstants.whisperModelKey)
            defaults.set("removed-model", forKey: AppConstants.parakeetModelKey)
            defaults.set("removed-model", forKey: AppConstants.analyticsVMAFModelKey)
            defaults.set(["unknown", QualityMetric.allCases[0].rawValue], forKey: AppConstants.analyticsEnabledMetricsKey)
            XCTAssertEqual(settings.transcriptionSnapshot().whisperModel, .base)
            XCTAssertEqual(settings.transcriptionSnapshot().parakeetModel, ParakeetModel.allModels[0])
            XCTAssertEqual(settings.analyticsSnapshot().vmafModel, .vmaf_v0_6_1)
            XCTAssertEqual(settings.analyticsSnapshot().enabledMetrics, [QualityMetric.allCases[0]])
            defaults.set([], forKey: AppConstants.analyticsEnabledMetricsKey)
            XCTAssertTrue(settings.analyticsSnapshot().enabledMetrics.isEmpty)
        }
    }

    func testSnapshotsRemainStableWhileNextOperationUsesEditedPreferences() {
        withSettings { defaults, settings in
            defaults.set("en", forKey: AppConstants.whisperLanguageKey)
            defaults.set(true, forKey: AppConstants.embedSubtitlesKey)
            defaults.set([QualityMetric.allCases[0].rawValue], forKey: AppConstants.analyticsEnabledMetricsKey)
            let transcription = settings.transcriptionSnapshot()
            let analytics = settings.analyticsSnapshot()
            defaults.set("no", forKey: AppConstants.whisperLanguageKey)
            defaults.set(false, forKey: AppConstants.embedSubtitlesKey)
            defaults.set([], forKey: AppConstants.analyticsEnabledMetricsKey)
            XCTAssertEqual(transcription.whisperLanguage, "en")
            XCTAssertTrue(transcription.embedSubtitles)
            XCTAssertEqual(analytics.enabledMetrics, [QualityMetric.allCases[0]])
            XCTAssertEqual(settings.transcriptionSnapshot().whisperLanguage, "no")
            XCTAssertFalse(settings.transcriptionSnapshot().embedSubtitles)
            XCTAssertTrue(settings.analyticsSnapshot().enabledMetrics.isEmpty)
        }
    }

    func testOCRLanguageFollowsEngineAndStreamLanguageWins() {
        withSettings { defaults, settings in
            defaults.set("nor", forKey: AppConstants.tesseractLanguageKey)
            defaults.set("fra", forKey: AppConstants.visionLanguageKey)
            defaults.set(OCREngineKind.appleVision.rawValue, forKey: AppConstants.ocrEngineKey)
            let vision = settings.ocrSnapshot()
            XCTAssertEqual(vision.engine, .appleVision)
            XCTAssertEqual(vision.language(forStreamLanguage: nil), "fra")
            XCTAssertEqual(vision.language(forStreamLanguage: "deu"), "deu")
            defaults.set("invalid-engine", forKey: AppConstants.ocrEngineKey)
            XCTAssertEqual(settings.ocrSnapshot().engine, .tesseract)
            XCTAssertEqual(settings.ocrSnapshot().language, "nor")
            XCTAssertEqual(vision.engine, .appleVision)
        }
    }

    func testIndependentStoresDoNotLeakPreferences() {
        withSettings { firstDefaults, first in
            withSettings { secondDefaults, second in
                firstDefaults.set("en", forKey: AppConstants.parakeetLanguageKey)
                secondDefaults.set("no", forKey: AppConstants.parakeetLanguageKey)
                XCTAssertEqual(first.transcriptionSnapshot().parakeetLanguage, "en")
                XCTAssertEqual(second.transcriptionSnapshot().parakeetLanguage, "no")
            }
        }
    }

    func testSSIMULACRA2FrameCountFallbackAndSnapshotStability() {
        withSettings { defaults, settings in
            XCTAssertEqual(settings.analyticsSnapshot().ssimulacra2MaxFrames, AppConstants.defaultSSIMULACRA2MaxFrames)
            for invalidValue in [0, -1, -100] {
                defaults.set(invalidValue, forKey: AppConstants.ssimulacra2MaxFramesKey)
                XCTAssertEqual(settings.analyticsSnapshot().ssimulacra2MaxFrames, AppConstants.defaultSSIMULACRA2MaxFrames)
            }
            defaults.set(12, forKey: AppConstants.ssimulacra2MaxFramesKey)
            let snapshot = settings.analyticsSnapshot()
            defaults.set(25, forKey: AppConstants.ssimulacra2MaxFramesKey)
            XCTAssertEqual(snapshot.ssimulacra2MaxFrames, 12)
            XCTAssertEqual(settings.analyticsSnapshot().ssimulacra2MaxFrames, 25)
        }
    }

    func testAutoExportDefaultsAndInvalidFormatFallback() {
        withSettings { defaults, settings in
            XCTAssertFalse(settings.analyticsSnapshot().autoExport.enabled)
            XCTAssertEqual(settings.analyticsSnapshot().autoExport.format, .json)
            defaults.set(true, forKey: AppConstants.analyticsAutoExportKey)
            defaults.set("removed-format", forKey: AppConstants.analyticsAutoExportFormatKey)
            XCTAssertTrue(settings.analyticsSnapshot().autoExport.enabled)
            XCTAssertEqual(settings.analyticsSnapshot().autoExport.format, .json)
            defaults.set("pdf", forKey: AppConstants.analyticsAutoExportFormatKey)
            XCTAssertEqual(settings.analyticsSnapshot().autoExport.format, .pdf)
        }
    }

    @MainActor
    func testAutoExportUsesCapturedSettingsAndDisabledExportWritesNothing() throws {
        try withSettings { defaults, settings in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let encodedURL = directory.appendingPathComponent("clip.final.mp4")
            let results = AnalyticsResults(
                sourceFileName: "clip.mov", encodedFileName: encodedURL.lastPathComponent,
                metrics: [], timestamp: Date(), durationSeconds: 1
            )
            let disabled = settings.analyticsSnapshot().autoExport
            defaults.set(true, forKey: AppConstants.analyticsAutoExportKey)
            let enabled = settings.analyticsSnapshot().autoExport
            defaults.set(false, forKey: AppConstants.analyticsAutoExportKey)
            defaults.set("pdf", forKey: AppConstants.analyticsAutoExportFormatKey)

            AnalyticsExporter.autoExportIfEnabled(
                results: results, encodedFileURL: encodedURL, settings: disabled
            )
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            AnalyticsExporter.autoExportIfEnabled(
                results: results, encodedFileURL: encodedURL, settings: enabled
            )
            let exportURL = directory.appendingPathComponent("clip.final_analytics.json")
            let data = try Data(contentsOf: exportURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(AnalyticsResults.self, from: data)
            XCTAssertEqual(decoded.encodedFileName, encodedURL.lastPathComponent)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [exportURL.lastPathComponent])
            XCTAssertFalse(settings.analyticsSnapshot().autoExport.enabled)
            XCTAssertEqual(settings.analyticsSnapshot().autoExport.format, .pdf)
        }
    }

}

private final class ParakeetSettingsRunner: SubprocessRunning, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var capturedCount = 0
    private var capturedArguments: [[String]] = []

    init(defaults: UserDefaults) { self.defaults = defaults }

    var snapshotCount: Int { lock.withLock { capturedCount } }
    var transcriptionArguments: [[String]] { lock.withLock { capturedArguments } }

    func editPreferences() {
        defaults.set(600, forKey: AppConstants.parakeetChunkDurationKey)
        defaults.set(30, forKey: AppConstants.parakeetOverlapDurationKey)
    }

    func snapshot() -> ParakeetSettingsSnapshot {
        lock.withLock { capturedCount += 1 }
        return ParakeetSettingsSnapshot(defaults: defaults)
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        if let index = request.arguments.firstIndex(of: "--output-dir") {
            lock.withLock { capturedArguments.append(request.arguments) }
            let directory = URL(fileURLWithPath: request.arguments[index + 1])
            try Data("1\n00:00:00,000 --> 00:00:01,000\nFixture\n".utf8)
                .write(to: directory.appendingPathComponent("input.srt"))
        } else {
            // A preference edit during extraction must affect only the next run.
            editPreferences()
            let destination = try XCTUnwrap(request.arguments.last)
            try Data().write(to: URL(fileURLWithPath: destination))
        }
        return SubprocessResult(
            terminationStatus: 0, termination: .exited, standardOutput: Data(), standardError: Data(),
            discardedStandardOutputBytes: 0, discardedStandardErrorBytes: 0, duration: .zero
        )
    }
}
