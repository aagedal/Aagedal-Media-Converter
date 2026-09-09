import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class AV2AACParserTests: XCTestCase {
    func testFixedChannelConfigurationsAndCRCHeadersRetainAccessUnits() throws {
        for (configuration, channels) in [(1, 1), (2, 2), (6, 6), (7, 8)] {
            for crc in [false, true] {
                let first = Data([0x21, 0x22, 0x23])
                let second = Data([0x31, 0x32])
                let parsed = try XCTUnwrap(AV2AACParser.parse(
                    adts(first, channels: configuration, crc: crc) + adts(second, channels: configuration, crc: crc)
                ))
                XCTAssertEqual(parsed.frames, [first, second])
                XCTAssertEqual(parsed.channels, channels)
                XCTAssertEqual(parsed.sampleRate, 48_000)
                XCTAssertEqual(parsed.audioSpecificConfig, Data([0x11, 0x80 | UInt8(configuration << 3)]))
            }
        }
    }

    func testProgramConfigMovesToCodecPrivateWithIndependentByteAlignment() throws {
        // Minimal 2.1 PCE: one front channel pair and one LFE. No comment, followed by ID_END.
        let payload = Data([0xA0, 0x98, 0x80, 0x20, 0x04, 0x00, 0x00, 0xE0])
        let parsed = try XCTUnwrap(AV2AACParser.parse(adts(payload, channels: 0)))
        XCTAssertEqual(parsed.channels, 3)
        XCTAssertEqual(parsed.audioSpecificConfig, Data([0x11, 0x80, 0x04, 0xC4, 0x01, 0x00, 0x20, 0x00, 0x00]))
        XCTAssertEqual(parsed.frames, [Data([0xE0])])
        let repeated = try XCTUnwrap(AV2AACParser.parse(adts(payload, channels: 0) + adts(payload, channels: 0)))
        XCTAssertEqual(repeated.frames, [Data([0xE0]), Data([0xE0])])
        XCTAssertEqual(repeated.audioSpecificConfig, parsed.audioSpecificConfig)
    }

    func testTruncatedOrTrailingADTSNeverPublishesPartialAudio() {
        let frame = adts(Data([0x21, 0x22, 0x23]), channels: 2)
        XCTAssertNil(AV2AACParser.parse(Data()))
        for length in 1..<frame.count {
            XCTAssertNil(AV2AACParser.parse(frame + Data(frame.prefix(length))), "Truncated next frame: \(length)")
        }
        XCTAssertNil(AV2AACParser.parse(frame + Data([0])))
        XCTAssertNil(AV2AACParser.parse(adts(Data(), channels: 2)))
    }

    func testInvalidHeadersAndChangingConfigurationsAreRejected() {
        let frame = adts(Data([0x21, 0x22]), channels: 2)
        for (offset, mask) in [(1, UInt8(2)), (2, UInt8(0x3C)), (6, UInt8(1))] {
            var invalid = frame
            invalid[offset] |= mask // Nonzero layer, reserved rate, or multiple raw data blocks.
            XCTAssertNil(AV2AACParser.parse(invalid))
        }
        XCTAssertNil(AV2AACParser.parse(frame + adts(Data([0x21]), channels: 1)))
        var changedRate = frame
        changedRate[2] ^= 0x04
        XCTAssertNil(AV2AACParser.parse(frame + changedRate))
        var changedProfile = frame
        changedProfile[2] ^= 0x40
        XCTAssertNil(AV2AACParser.parse(frame + changedProfile))
    }

    func testMissingMalformedAndChangedProgramConfigurationsAreRejected() {
        let pce = Data([0xA0, 0x98, 0x80, 0x20, 0x04, 0x00, 0x00, 0xE0])
        XCTAssertNil(AV2AACParser.parse(adts(Data([0x21, 0x22]), channels: 0)))
        for length in 1..<pce.count {
            XCTAssertNil(AV2AACParser.parse(adts(Data(pce.prefix(length)), channels: 0)))
        }
        for (offset, mask) in [(1, UInt8(0x80)), (1, UInt8(0x08)), (6, UInt8(0xFF))] {
            var invalid = pce
            invalid[offset] ^= mask // PCE/header profile or rate mismatch; truncated comment.
            XCTAssertNil(AV2AACParser.parse(adts(invalid, channels: 0)))
        }
        var changedTag = pce
        changedTag[0] ^= 0x02
        XCTAssertNil(AV2AACParser.parse(adts(pce, channels: 0) + adts(changedTag, channels: 0)))
    }

    func testGeneratedProgramConfigLayoutsDecodeIdenticallyAfterFinalMux() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let videoFrame = try await makeVideoFrame(in: directory)
        // Native AAC describes its 6.1 PCE as 6.1(back), including in its own ADTS output.
        for (layout, decodedLayout, channels) in [("2.1", "2.1", 3), ("quad", "quad", 4), ("6.1", "6.1(back)", 7)] {
            let encoded = directory.appendingPathComponent("\(layout).aac")
            let tones = (0..<channels).map { "0.1*sin(2*PI*\(80 + $0 * 110)*t)" }.joined(separator: "|")
            try await runFFmpeg([
                "-f", "lavfi", "-i", "aevalsrc=\(tones):s=48000:d=0.25:c=\(layout)",
                "-c:a", "aac", "-f", "adts", encoded.path
            ])
            let parsed = try XCTUnwrap(AV2AACParser.parse(Data(contentsOf: encoded)), layout)
            XCTAssertEqual(parsed.channels, channels)
            XCTAssertGreaterThan(parsed.audioSpecificConfig.count, 2, "Fixture must use a PCE: \(layout)")
            let mux = directory.appendingPathComponent("\(layout).mkv")
            try MatroskaMuxer.write(
                to: mux,
                video: .init(codecID: "V_VP8", codecPrivate: nil, width: 16, height: 16, fpsNumerator: 24, fpsDenominator: 1),
                videoFrames: [videoFrame],
                audioTracks: [.init(
                    info: .init(codecID: "A_AAC", codecPrivate: parsed.audioSpecificConfig, sampleRate: parsed.sampleRate, channels: parsed.channels),
                    frames: parsed.frames.map { .init(data: $0, durationSamples: 1024) }
                )]
            )
            let probedStreams = await FFMPEGProbeService.fetchAudioStreams(for: mux)
            let streams = try XCTUnwrap(probedStreams)
            XCTAssertEqual(streams.count, 1)
            XCTAssertEqual(streams.first?.channels, channels)
            // SwiftMediaMetadata infers Matroska layouts from channel count (quad becomes
            // "4.0"). Inspect the decoder's PCE interpretation as well as its actual samples.
            let inspection = try await runFFmpeg([
                "-loglevel", "info", "-i", mux.path, "-map", "0:a:0", "-c:a", "copy", "-f", "null", "-"
            ])
            XCTAssertTrue(inspection.standardErrorText.contains("48000 Hz, \(decodedLayout),"), inspection.standardErrorText)
            let referenceInspection = try await runFFmpeg([
                "-loglevel", "info", "-i", encoded.path, "-map", "0:a:0", "-c:a", "copy", "-f", "null", "-"
            ])
            XCTAssertTrue(referenceInspection.standardErrorText.contains("48000 Hz, \(decodedLayout),"), referenceInspection.standardErrorText)
            let reference = try await decode(encoded, track: 0, in: directory)
            let actual = try await decode(mux, track: 0, in: directory)
            XCTAssertFalse(reference.isEmpty)
            XCTAssertEqual(actual, reference, "Channel samples/order changed for \(layout)")
        }
    }

    func testGeneratedRoutedProgramConfigTracksSupportTrimDuplicationAndDownmix() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("quad.wav")
        try await runFFmpeg([
            "-f", "lavfi", "-i", "aevalsrc=0.1*sin(2*PI*110*t)|0.1*sin(2*PI*220*t)|0.1*sin(2*PI*330*t)|0.1*sin(2*PI*440*t):s=48000:d=0.5:c=quad",
            "-c:a", "pcm_s16le", source.path
        ])
        let routing = AudioRoutingConfig(
            inputTracks: [.init(streamIndex: 0, channels: 4, channelLayout: "quad", codec: "pcm_s16le", codecLongName: nil, sampleRate: 48_000)],
            outputTracks: [OutputTrack(streamIndex: 0), OutputTrack(streamIndex: 0, downmixToStereo: true), OutputTrack(streamIndex: 0)]
        )
        let suite = "AV2AACParserTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AV2AudioCodec.aac.rawValue, forKey: AppConstants.av2AudioCodecKey)
        let result = await FFMPEGConverter().extractAudioTracksForAV2Mux(
            source: FFMPEGConverter.packageAudioInput(inputURL: source, customInputArguments: nil),
            audioRoutingConfig: routing, trimStart: 0.1, trimEnd: 0.4,
            ffmpegPath: ffmpegURL.path, settings: AV2Settings(defaults: defaults)
        )
        guard case .tracks(let tracks) = result else { return XCTFail("Routed PCE extraction failed: \(result)") }
        XCTAssertEqual(tracks.map(\.info.channels), [4, 2, 4])
        XCTAssertEqual(tracks[0].frames.map(\.data), tracks[2].frames.map(\.data))
        XCTAssertEqual(tracks[0].frames.map(\.presentationTimestampMilliseconds), tracks[2].frames.map(\.presentationTimestampMilliseconds))
        let output = directory.appendingPathComponent("routed.mkv")
        let videoFrame = try await makeVideoFrame(in: directory)
        try MatroskaMuxer.write(
            to: output,
            video: .init(codecID: "V_VP8", codecPrivate: nil, width: 16, height: 16, fpsNumerator: 24, fpsDenominator: 1),
            videoFrames: [videoFrame], audioTracks: tracks
        )
        let first = try await decode(output, track: 0, in: directory)
        let second = try await decode(output, track: 1, in: directory)
        let third = try await decode(output, track: 2, in: directory)
        XCTAssertEqual(first, third)
        XCTAssertEqual(first.count, tracks[0].frames.count * 1024 * 4 * 2)
        XCTAssertEqual(second.count, tracks[1].frames.count * 1024 * 2 * 2)
    }

    private func adts(_ payload: Data, channels: Int, crc: Bool = false) -> Data {
        let length = payload.count + (crc ? 9 : 7)
        var header: [UInt8] = [
            0xFF, crc ? 0xF0 : 0xF1, 0x4C | UInt8(channels >> 2),
            UInt8((channels & 3) << 6 | length >> 11), UInt8((length >> 3) & 255),
            UInt8((length & 7) << 5 | 0x1F), 0xFC
        ]
        if crc { header += [0, 0] }
        return Data(header) + payload
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AV2AACParser-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeVideoFrame(in directory: URL) async throws -> MatroskaMuxer.VideoFrame {
        let url = directory.appendingPathComponent("picture.ivf")
        try await runFFmpeg(["-f", "lavfi", "-i", "color=c=black:s=16x16:r=24", "-frames:v", "1", "-c:v", "libvpx", "-f", "ivf", url.path])
        return .init(data: Data(try Data(contentsOf: url).dropFirst(44)), isKeyframe: true)
    }

    private func decode(_ url: URL, track: Int, in directory: URL) async throws -> Data {
        let output = directory.appendingPathComponent("\(UUID().uuidString).s16le")
        try await runFFmpeg(["-i", url.path, "-map", "0:a:\(track)", "-c:a", "pcm_s16le", "-f", "s16le", output.path])
        return try Data(contentsOf: output)
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
        guard result.succeeded else { throw NSError(domain: "AV2AACParserTests", code: Int(result.terminationStatus), userInfo: [NSLocalizedDescriptionKey: result.standardErrorText]) }
        return result
    }
}
