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
        let padding: [Int64] = [0, 0, 20_833] // One 48 kHz sample, below the container's millisecond clock.
        let padded = try XCTUnwrap(AV2AudioPacketTiming.applying(manifest: manifest, to: track, discardPaddingNanoseconds: padding))
        XCTAssertEqual(padded.frames.map(\.discardPaddingNanoseconds), padding)
        XCTAssertEqual(AV2AudioPacketTiming.applying(manifest: manifest, to: padded)?.frames.map(\.discardPaddingNanoseconds), padding)
        XCTAssertNil(AV2AudioPacketTiming.applying(manifest: manifest, to: track, discardPaddingNanoseconds: [0]))
        XCTAssertNil(AV2AudioPacketTiming.applying(manifest: manifest, to: track, discardPaddingNanoseconds: [0, 0, -1]))
        XCTAssertNil(AV2AudioPacketTiming.applying(manifest: manifest, to: track, discardPaddingNanoseconds: [0, 0, 20_000_001]))
    }

    func testPaddingReaderRejectsTruncationLacingAndNegativeEndPadding() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("AV2PaddingReader-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: output) }
        let track = MatroskaMuxer.AudioTrack(
            info: .init(codecID: "A_OPUS", codecPrivate: nil, sampleRate: 48_000, channels: 1),
            frames: [
                .init(data: Data([1, 2]), durationSamples: 960),
                .init(data: Data([3, 4]), durationSamples: 960, discardPaddingNanoseconds: 128)
            ]
        )
        try MatroskaMuxer.write(
            to: output,
            video: .init(codecPrivate: nil, width: 16, height: 16, fpsNumerator: 24, fpsDenominator: 1),
            videoFrames: [.init(data: Data([5, 6]), isKeyframe: true)], audioTracks: [track]
        )
        let data = try Data(contentsOf: output)
        // 128 needs a leading zero if written minimally as a signed integer.
        XCTAssertEqual(AV2AudioPacketTiming.discardPadding(inMatroska: data), [[0, 128]])
        for length in [0, 1, 7, data.count / 2, data.count - 1] {
            XCTAssertNil(AV2AudioPacketTiming.discardPadding(inMatroska: Data(data.prefix(length))))
        }
        var laced = data
        let block = try XCTUnwrap(laced.range(of: Data([0xA3, 0x86, 0x82, 0, 0, 0x80, 1, 2])))
        laced[block.lowerBound + 5] |= 0x02
        XCTAssertNil(AV2AudioPacketTiming.discardPadding(inMatroska: laced))
        var negative = data
        let discard = try XCTUnwrap(negative.range(of: Data([0x75, 0xA2, 0x88])))
        negative[discard.upperBound] = 0xFF
        XCTAssertNil(AV2AudioPacketTiming.discardPadding(inMatroska: negative))
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
                    if codec == .opus {
                        let samples = try await decodedSampleCount(in: output, track: index, directory: directory)
                        XCTAssertEqual(samples, index == 1 && trim > 0 ? 38_400 : 48_000)
                    }
                }
                if codec == .opus {
                    let readbackPadding = try XCTUnwrap(AV2AudioPacketTiming.discardPadding(inMatroska: Data(contentsOf: output)))
                    XCTAssertEqual(readbackPadding, tracks.map { $0.frames.map(\.discardPaddingNanoseconds) })
                    XCTAssertEqual(readbackPadding[0], readbackPadding[2])
                }
            }
        }
    }

    func testGeneratedOpusMuxDecodesToExactSampleCountsIncludingSubMillisecondPadding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AV2OpusSamples-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ivfURL = directory.appendingPathComponent("picture.ivf")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "color=c=black:s=16x16:r=24", "-frames:v", "1",
            "-c:v", "libvpx", "-f", "ivf", ivfURL.path
        ])
        let videoFrame = MatroskaMuxer.VideoFrame(data: Data(try Data(contentsOf: ivfURL).dropFirst(44)), isKeyframe: true)
        let suite = "AV2OpusSamples.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AV2AudioCodec.opus.rawValue, forKey: AppConstants.av2AudioCodecKey)
        // 648 input + 312 pre-skip fills one Opus packet exactly; 1,607 leaves exactly one
        // discarded sample on packet two. The one-sample fixture checks exact padding bytes;
        // FFmpeg drops end padding when adding first-packet pre-skip, even for its own files.
        for sampleCount in [1, 648, 649, 1_607, 48_001] {
            let sourceURL = directory.appendingPathComponent("source-\(sampleCount).wav")
            try await runFFmpeg([
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                "-af", "atrim=end_sample=\(sampleCount)", "-c:a", "pcm_s16le", sourceURL.path
            ])
            let result = await FFMPEGConverter().extractAudioTracksForAV2Mux(
                source: FFMPEGConverter.packageAudioInput(inputURL: sourceURL, customInputArguments: nil),
                audioRoutingConfig: nil, trimStart: nil, trimEnd: nil,
                ffmpegPath: ffmpegURL.path, settings: AV2Settings(defaults: defaults)
            )
            guard case .tracks(let tracks) = result, tracks.count == 1 else {
                return XCTFail("Failed to extract \(sampleCount)-sample Opus audio: \(result)")
            }
            let track = tracks[0]
            let preSkipSamples = Int((Double(track.info.codecDelayNs ?? 0) * 48_000 / 1_000_000_000).rounded())
            let encodedSamples = track.frames.reduce(0) { $0 + $1.durationSamples }
            let expectedPaddingSamples = encodedSamples - preSkipSamples - sampleCount
            let actualPaddingNs = track.frames.reduce(Int64(0)) { $0 + $1.discardPaddingNanoseconds }
            XCTAssertEqual(actualPaddingNs, Int64((Double(expectedPaddingSamples) * 1_000_000_000 / 48_000).rounded()))
            if sampleCount == 648 { XCTAssertEqual(actualPaddingNs, 0) }
            let output = directory.appendingPathComponent("mux-\(sampleCount).mkv")
            try MatroskaMuxer.write(
                to: output,
                video: .init(codecID: "V_VP8", codecPrivate: nil, width: 16, height: 16, fpsNumerator: 24, fpsDenominator: 1),
                videoFrames: [videoFrame], audioTracks: tracks
            )
            XCTAssertEqual(
                AV2AudioPacketTiming.discardPadding(inMatroska: try Data(contentsOf: output)),
                [track.frames.map(\.discardPaddingNanoseconds)]
            )
            if sampleCount == 1 {
                XCTAssertEqual(track.frames.count, 1)
                continue // The external decoder cannot honor pre-skip and end padding on this same packet.
            }
            let readbackCount = try await decodedSampleCount(in: output, track: 0, directory: directory)
            XCTAssertEqual(readbackCount, sampleCount, "Opus \(sampleCount)-sample source changed length after final mux")
        }
    }

    private func decodedSampleCount(in url: URL, track: Int, directory: URL) async throws -> Int {
        let decoded = directory.appendingPathComponent("decoded-\(UUID().uuidString).s16le")
        try await runFFmpeg([
            "-i", url.path, "-map", "0:a:\(track)", "-c:a", "pcm_s16le", "-f", "s16le", decoded.path
        ])
        let byteCount = try Data(contentsOf: decoded).count
        XCTAssertEqual(byteCount % 2, 0)
        return byteCount / 2 // Every generated fixture is mono at 48 kHz.
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
