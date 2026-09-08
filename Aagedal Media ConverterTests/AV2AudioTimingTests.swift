import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class AV2AudioTimingTests: XCTestCase {
    func testPacketTimingPreservesGapsAndRestoresOpusCodecDelay() throws {
        let track = MatroskaMuxer.AudioTrack(
            info: .init(codecID: "A_OPUS", codecPrivate: nil, sampleRate: 48_000, channels: 1, codecDelayNs: 6_500_000),
            frames: Array(repeating: .init(data: Data([1]), durationSamples: 960), count: 3)
        )
        let manifest = "#tb 0: 1/1000\n0, -7, -7, 20, 1, 0x01\n0, 13, 13, 20, 1, 0x01\n0, 413, 413, 20, 1, 0x01\n"
        let restored = try XCTUnwrap(AV2AudioPacketTiming.applying(manifest: manifest, to: track))
        XCTAssertEqual(restored.frames.map(\.presentationTimestampMilliseconds), [0, 20, 420])
        XCTAssertNil(AV2AudioPacketTiming.applying(manifest: "#tb 0: 1/0\n0, 0, 0, 20, 1, 0x01", to: track))
        XCTAssertNil(AV2AudioPacketTiming.applying(manifest: "#tb 0: 1/1000\n0, 0, nan, 20, 1, 0x01", to: track))
        XCTAssertNil(AV2AudioPacketTiming.applying(manifest: String(manifest.prefix(20)), to: track))
        XCTAssertNil(AV2AudioPacketTiming.applying(manifest: manifest.replacingOccurrences(of: "413, 413", with: "-100, -100"), to: track))
        XCTAssertNil(AV2AudioPacketTiming.applying(manifest: manifest.replacingOccurrences(of: "413, 413", with: "1e30, 1e30"), to: track))
    }

    func testGeneratedRoutedAudioRetainsOffsetsThroughTrimAndFinalMuxForAACAndOpus() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AV2AudioTiming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.mkv")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "color=c=black:s=16x16:r=24:d=1.5",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1",
            "-itsoffset", "0.4", "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=1",
            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "ffv1", "-c:a", "pcm_s16le", sourceURL.path
        ])
        let ivfURL = directory.appendingPathComponent("picture.ivf")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "color=c=black:s=16x16:r=24", "-frames:v", "1",
            "-c:v", "libvpx", "-f", "ivf", ivfURL.path
        ])
        let ivf = try Data(contentsOf: ivfURL)
        XCTAssertGreaterThan(ivf.count, 44)
        let videoFrame = MatroskaMuxer.VideoFrame(data: Data(ivf.dropFirst(44)), isKeyframe: true)
        let inputs = (0...1).map {
            AudioTrackInfo(streamIndex: $0, channels: 1, channelLayout: "mono", codec: "pcm_s16le", codecLongName: nil, sampleRate: 48_000)
        }
        let routing = AudioRoutingConfig(inputTracks: inputs, outputTracks: [
            OutputTrack(streamIndex: 1), OutputTrack(streamIndex: 0), OutputTrack(streamIndex: 1)
        ])
        let source = FFMPEGConverter.PackageAudioInput(
            arguments: ["-i", sourceURL.path], probeURL: sourceURL,
            ffmpegInputIndex: 0, assumesSingleAudioStreamIfProbeUnavailable: false
        )
        let suite = "AV2AudioTimingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for codec in [AV2AudioCodec.aac, .opus] {
            defaults.set(codec.rawValue, forKey: AppConstants.av2AudioCodecKey)
            for trim in [0.0, 0.2] {
                let result = await FFMPEGConverter().extractAudioTracksForAV2Mux(
                    source: source, audioRoutingConfig: routing, trimStart: trim, trimEnd: 1.4,
                    ffmpegPath: ffmpegURL.path, settings: AV2Settings(defaults: defaults)
                )
                guard case .tracks(let tracks) = result else {
                    return XCTFail("Failed \(codec.rawValue) extraction with trim \(trim): \(result)")
                }
                XCTAssertEqual(tracks.count, 3)
                let starts = try tracks.map { try XCTUnwrap($0.frames.first?.presentationTimestampMilliseconds) }
                let encoderPreroll = codec == .aac ? -21.0 : 0.0
                XCTAssertEqual(Double(starts[0]), 400 - trim * 1000 + encoderPreroll, accuracy: 2)
                XCTAssertEqual(Double(starts[1]), encoderPreroll, accuracy: 2)
                XCTAssertEqual(starts[0], starts[2])

                let output = directory.appendingPathComponent("mux-\(codec.rawValue)-\(trim).mkv")
                try MatroskaMuxer.write(
                    to: output,
                    video: .init(codecID: "V_VP8", codecPrivate: nil, width: 16, height: 16, fpsNumerator: 24, fpsDenominator: 1),
                    videoFrames: Array(repeating: videoFrame, count: 36), audioTracks: tracks
                )
                // Read real packets back through FFmpeg; this checks the final EBML block timing,
                // including negative AAC preroll and the Opus CodecDelay interpretation.
                for index in tracks.indices {
                    let manifestURL = directory.appendingPathComponent("readback-\(index).framecrc")
                    try await runFFmpeg([
                        "-copyts", "-i", output.path, "-map", "0:a:\(index)", "-c:a", "copy",
                        "-avoid_negative_ts", "disabled", "-f", "framecrc", manifestURL.path
                    ])
                    let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
                    let restored = try XCTUnwrap(AV2AudioPacketTiming.applying(manifest: manifest, to: tracks[index]))
                    for (actual, expected) in zip(restored.frames, tracks[index].frames) {
                        XCTAssertEqual(
                            Double(try XCTUnwrap(actual.presentationTimestampMilliseconds)),
                            Double(try XCTUnwrap(expected.presentationTimestampMilliseconds)), accuracy: 1
                        )
                    }
                }
            }
        }
    }

    private var ffmpegURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Aagedal Media Converter/Binaries/ffmpeg")
    }

    @discardableResult
    private func runFFmpeg(_ arguments: [String]) async throws -> SubprocessResult {
        let result = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: ffmpegURL, arguments: ["-hide_banner", "-loglevel", "error", "-y"] + arguments,
            timeout: .seconds(30), standardOutputCaptureLimit: 0, standardErrorCaptureLimit: 16_384
        ))
        guard result.succeeded else { throw NSError(domain: "AV2AudioTimingTests", code: Int(result.terminationStatus), userInfo: [NSLocalizedDescriptionKey: result.standardErrorText]) }
        return result
    }
}
