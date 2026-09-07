import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class AV2AudioSettingsTests: XCTestCase {
    func testContainerAndAudioSnapshotPreservesPreferences() throws {
        let suite = "AV2AudioSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AV2Container.mkv.rawValue, forKey: AppConstants.av2ContainerKey)
        defaults.set(AV2AudioCodec.opus.rawValue, forKey: AppConstants.av2AudioCodecKey)
        defaults.set(AudioBitrate.k96.rawValue, forKey: AppConstants.av2AudioBitrateKey)
        let captured = AV2Settings(defaults: defaults)

        defaults.set(AV2Container.ivf.rawValue, forKey: AppConstants.av2ContainerKey)
        defaults.set(AV2AudioCodec.aac.rawValue, forKey: AppConstants.av2AudioCodecKey)
        defaults.set(AudioBitrate.k320.rawValue, forKey: AppConstants.av2AudioBitrateKey)

        XCTAssertEqual(captured.container, .mkv)
        XCTAssertEqual(captured.audioCodec, .opus)
        XCTAssertEqual(captured.audioBitrate, .k96)
        let next = AV2Settings(defaults: defaults)
        XCTAssertEqual(next.container, .ivf)
        XCTAssertEqual(next.audioCodec, .aac)
        XCTAssertEqual(next.audioBitrate, .k320)
    }

    func testInvalidContainerAndAudioPreferencesKeepLegacyFallbacks() throws {
        let suite = "AV2AudioSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in [AppConstants.av2ContainerKey, AppConstants.av2AudioCodecKey, AppConstants.av2AudioBitrateKey] {
            defaults.set("invalid", forKey: key)
        }
        let settings = AV2Settings(defaults: defaults)
        XCTAssertEqual(settings.container, .ivf)
        XCTAssertEqual(settings.audioCodec, .aac)
        XCTAssertEqual(settings.audioBitrate, .k192)
    }

    func testAudioHelperUsesInjectedSnapshotAfterSourceProbeSuspends() async throws {
        let suite = "AV2AudioSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AV2AudioCodec.opus.rawValue, forKey: AppConstants.av2AudioCodecKey)
        defaults.set(AudioBitrate.k96.rawValue, forKey: AppConstants.av2AudioBitrateKey)
        let captured = AV2Settings(defaults: defaults)
        let runner = AV2SettingsRecordingRunner()
        let sourceURL = URL(fileURLWithPath: "/nonexistent/audio.mov")

        let result = await FFMPEGConverter(subprocessRunner: runner).extractAudioTracksForAV2Mux(
            source: FFMPEGConverter.PackageAudioInput(
                arguments: ["-i", sourceURL.path], probeURL: sourceURL,
                ffmpegInputIndex: 0, assumesSingleAudioStreamIfProbeUnavailable: false
            ),
            audioRoutingConfig: nil, trimStart: nil, trimEnd: nil,
            ffmpegPath: "/nonexistent/ffmpeg", settings: captured,
            audioStreamProvider: { _ in
                await Task.yield()
                // Change preferences while the conversion is awaiting metadata.
                let changedDefaults = UserDefaults(suiteName: suite)!
                changedDefaults.set(AV2AudioCodec.aac.rawValue, forKey: AppConstants.av2AudioCodecKey)
                changedDefaults.set(AudioBitrate.k320.rawValue, forKey: AppConstants.av2AudioBitrateKey)
                return [.init(index: 0, channels: 2, channelLayout: "stereo", codecName: "aac")]
            }
        )

        guard case .failed = result else { return XCTFail("Expected the recording helper to stop extraction") }
        let recordedRequest = await runner.request
        let args = try XCTUnwrap(recordedRequest).arguments
        let codecIndex = try XCTUnwrap(args.firstIndex(of: "-c:a"))
        let bitrateIndex = try XCTUnwrap(args.firstIndex(of: "-b:a"))
        XCTAssertEqual(args[codecIndex + 1], "libopus")
        XCTAssertEqual(args[bitrateIndex + 1], "96k")
    }
}

private actor AV2SettingsRecordingRunner: SubprocessRunning {
    private(set) var request: SubprocessRequest?

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        self.request = request
        return SubprocessResult(
            terminationStatus: 1, termination: .exited,
            standardOutput: Data(), standardError: Data("Fixture stopped after command capture".utf8),
            discardedStandardOutputBytes: 0, discardedStandardErrorBytes: 0, duration: .zero
        )
    }
}
