// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import XCTest
@testable import Aagedal_Media_Converter

final class MediaAdjustmentsTests: XCTestCase {
    // MARK: - Video filter placement

    func testStagesFollowCropNormalizationAndDeinterlaceButPrecedeScaling() {
        let stages = ["transpose=clock"]
        XCTAssertEqual(
            MediaAdjustmentsPlan.insert(stages, intoChain: "bwdif=mode=send_frame,scale=w=1920:h=1080"),
            "bwdif=mode=send_frame,transpose=clock,scale=w=1920:h=1080"
        )
        XCTAssertEqual(
            MediaAdjustmentsPlan.insert(stages, intoChain: "crop=100:50:0:0,scale=134:50,setsar=1/1,scale=w=1280:h=720"),
            "crop=100:50:0:0,scale=134:50,setsar=1/1,transpose=clock,scale=w=1280:h=720"
        )
        XCTAssertEqual(
            MediaAdjustmentsPlan.insert(stages, intoChain: "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1"),
            "transpose=clock,scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1"
        )
        // A labelled graph runs the stages first, on the decoded picture.
        XCTAssertEqual(
            MediaAdjustmentsPlan.insert(stages, intoChain: "fps=15,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse"),
            "transpose=clock,fps=15,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse"
        )
    }

    func testVideoStagesOrderRotationSubtitlesSpeedAndFades() throws {
        var adjustments = MediaAdjustments()
        adjustments.rotation = .rotate180
        adjustments.flipHorizontal = true
        adjustments.speed = 2
        adjustments.videoFadeIn = 0.5
        adjustments.videoFadeOut = 1
        adjustments.burnInSubtitles = .init(source: .embedded(streamIndex: 0))
        let stages = try MediaAdjustmentsPlan.videoFilterStages(
            for: adjustments, inputURL: URL(fileURLWithPath: "/tmp/a:b.mkv"), trimStart: 10,
            outputDuration: 5, sourceSubtitleCodecs: ["subrip"]
        ).get()
        XCTAssertEqual(Array(stages.prefix(4)), ["hflip", "vflip", "hflip", "setpts=PTS+10/TB"])
        XCTAssertTrue(stages[4].hasPrefix("subtitles=filename=/tmp/a\\\\:b.mkv:si=0:force_style=FontSize=20\\,"))
        XCTAssertEqual(Array(stages.suffix(4)), [
            "setpts=PTS-STARTPTS", "setpts=(PTS-STARTPTS)/2", "fade=t=in:st=0:d=0.5", "fade=t=out:st=4:d=1",
        ])
    }

    func testBitmapSubtitlesAndUnknownDurationsAreRejected() {
        var adjustments = MediaAdjustments()
        adjustments.burnInSubtitles = .init(source: .embedded(streamIndex: 0))
        let bitmap = MediaAdjustmentsPlan.videoFilterStages(
            for: adjustments, inputURL: URL(fileURLWithPath: "/tmp/a.mkv"), trimStart: nil,
            outputDuration: 5, sourceSubtitleCodecs: ["hdmv_pgs_subtitle"]
        )
        XCTAssertEqual(bitmap, .failure(.bitmapSubtitles))

        var fade = MediaAdjustments()
        fade.videoFadeOut = 1
        let unknown = MediaAdjustmentsPlan.videoFilterStages(
            for: fade, inputURL: URL(fileURLWithPath: "/tmp/a.mkv"), trimStart: nil,
            outputDuration: nil, sourceSubtitleCodecs: []
        )
        XCTAssertEqual(unknown, .failure(.unknownDuration))
    }

    // MARK: - Audio chains

    func testAtempoChainsStayWithinTheCleanRange() {
        XCTAssertEqual(MediaAdjustmentsPlan.atempoStages(for: 0.25), ["atempo=0.5", "atempo=0.5"])
        XCTAssertEqual(MediaAdjustmentsPlan.atempoStages(for: 3), ["atempo=2", "atempo=1.5"])
        XCTAssertEqual(MediaAdjustmentsPlan.atempoStages(for: 1.25), ["atempo=1.25"])
    }

    func testAudioChainOrdersOffsetTempoFitLoudnessAndFades() throws {
        var adjustments = MediaAdjustments()
        adjustments.audioOffset = -0.25
        adjustments.speed = 0.5
        adjustments.audioFadeOut = 2
        let chain = try MediaAdjustmentsPlan.audioFilterChain(
            for: adjustments, loudness: LoudnessNormalizationSettings(), measurement: nil,
            context: .init(outputDuration: 8, sampleRate: 44100, fitsToDuration: true)
        ).get()
        XCTAssertEqual(chain, "atrim=start=0.25,asetpts=PTS-STARTPTS,atempo=0.5,apad,atrim=duration=8,"
            + "loudnorm=I=-23:TP=-1:LRA=20:print_format=json,aresample=44100,afade=t=out:st=6:d=2")

        let measured = try MediaAdjustmentsPlan.audioFilterChain(
            for: MediaAdjustments(), loudness: LoudnessNormalizationSettings(),
            measurement: LoudnormMeasurement(inputIntegrated: "-30.1", inputTruePeak: "-9.0", inputLoudnessRange: "3.2",
                                             inputThreshold: "-40.5", targetOffset: "0.3"),
            context: .init(outputDuration: nil, sampleRate: 48000, fitsToDuration: false)
        ).get()
        XCTAssertEqual(measured, "loudnorm=I=-23:TP=-1:LRA=20:measured_I=-30.1:measured_TP=-9.0:measured_LRA=3.2:"
            + "measured_thresh=-40.5:offset=0.3:linear=true:print_format=summary,aresample=48000")
    }

    func testExportVolumePrecedesLoudnessAndFadesAndCountsOnlyWhenAudible() throws {
        var adjustments = MediaAdjustments()
        adjustments.audioGain = 6
        adjustments.audioFadeIn = 1
        let chain = try MediaAdjustmentsPlan.audioFilterChain(
            for: adjustments, loudness: LoudnessNormalizationSettings(), measurement: nil,
            context: .init(outputDuration: 8, sampleRate: 48000, fitsToDuration: false)
        ).get()
        XCTAssertEqual(chain, "volume=6dB,loudnorm=I=-23:TP=-1:LRA=20:print_format=json,aresample=48000,"
            + "afade=t=in:st=0:d=1")
        XCTAssertTrue(adjustments.hasAudioAdjustments)
        XCTAssertEqual(adjustments.summary, ["Audio fade 1 s / 0 s", "Volume +6 dB"])

        // An enabled volume at 0 dB keeps the item's setting without touching the audio.
        var unity = MediaAdjustments()
        unity.audioGain = 0.02
        XCTAssertFalse(unity.hasAudioAdjustments)
        XCTAssertTrue(unity.isActive)
        XCTAssertNil(try MediaAdjustmentsPlan.audioFilterChain(
            for: unity, loudness: nil, measurement: nil,
            context: .init(outputDuration: nil, sampleRate: 48000, fitsToDuration: false)
        ).get())
        XCTAssertEqual(MediaAdjustments.formattedGain(-2.96), "−3 dB")
        XCTAssertEqual(MediaAdjustments.formattedGain(0.02), "0 dB")
    }

    func testOutputChainsExpandGenericMapsAndExtendRoutingGraphs() throws {
        var direct = ["-map", "0:v:0", "-map", "0:a?", "-c:v", "libx264", "-c:a", "aac"]
        let directCount = try MediaAdjustmentsPlan.applyAudioChains(
            to: &direct, placement: .outputs, audioStreamCount: { _ in 2 }, chain: { "volume=\($0)" }
        ).get()
        XCTAssertEqual(directCount, 2)
        XCTAssertEqual(direct, [
            "-filter_complex", "[0:a:0]volume=0[afx0];[0:a:1]volume=1[afx1]",
            "-map", "0:v:0", "-map", "[afx0]", "-map", "[afx1]", "-c:v", "libx264", "-c:a", "aac",
        ])

        var routed = ["-filter_complex", "[0:a:0]pan=stereo|c0=c1|c1=c0[aout]", "-map", "0:v:0", "-map", "[aout]"]
        _ = try MediaAdjustmentsPlan.applyAudioChains(
            to: &routed, placement: .outputs, audioStreamCount: { _ in 1 }, chain: { _ in "anull" }
        ).get()
        XCTAssertEqual(routed[1], "[0:a:0]pan=stereo|c0=c1|c1=c0[aout];[aout]anull[afx0]")
        XCTAssertEqual(Array(routed.suffix(2)), ["-map", "[afx0]"])

        var copied = ["-map", "0:a:0", "-c:a:0", "copy"]
        XCTAssertEqual(
            MediaAdjustmentsPlan.applyAudioChains(to: &copied, placement: .outputs, audioStreamCount: { _ in 1 }, chain: { _ in "anull" }),
            .failure(.copiedAudio)
        )
    }

    func testSourceChainsRunBeforeMonoSplitsAndShareTracksThroughAsplit() throws {
        var split = [
            "-filter_complex", "[0:a:0]channelsplit=channel_layout=stereo[l][r];[0:a:0]anull[keep]",
            "-map", "0:v:0", "-map", "[l]", "-map", "[r]", "-map", "[keep]", "-map", "0:a:1",
        ]
        let count = try MediaAdjustmentsPlan.applyAudioChains(
            to: &split, placement: .sources, audioStreamCount: { _ in 2 }, chain: { "volume=\($0)" }
        ).get()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(split[1], "[0:a:0]volume=0,asplit=2[asrc0_0][asrc0_1];[0:a:1]volume=1[asrc1_0];"
            + "[asrc0_0]channelsplit=channel_layout=stereo[l][r];[asrc0_1]anull[keep]")
        XCTAssertEqual(Array(split.suffix(2)), ["-map", "[asrc1_0]"])
    }

    func testReplacementRedirectsEverySourceAudioReference() {
        var arguments = ["-filter_complex", "[0:a:0][0:a:1]amerge=inputs=2[aout]", "-map", "0:v:0", "-map", "0:a?", "-map", "[aout]"]
        MediaAdjustmentsPlan.redirectSourceAudio(to: 1, in: &arguments)
        XCTAssertEqual(arguments, ["-filter_complex", "[1:a:0][1:a:1]amerge=inputs=2[aout]", "-map", "0:v:0", "-map", "1:a?", "-map", "[aout]"])
    }

    func testLoudnessOverrideResolution() {
        var global = LoudnessNormalizationSettings()
        XCTAssertNil(global.resolved(for: .useDefault))
        XCTAssertNotNil(global.resolved(for: .on))
        global.enabled = true
        global.standard = .atscA85
        XCTAssertEqual(global.resolved(for: .useDefault)?.integrated, -24)
        XCTAssertNil(global.resolved(for: .off))
        global.standard = .custom
        global.customIntegrated = -100
        XCTAssertEqual(global.integrated, LoudnessNormalizationSettings.integratedRange.lowerBound)
    }

    func testAdjustmentsRoundTripAndTolerateUnknownValues() throws {
        var adjustments = MediaAdjustments()
        adjustments.rotation = .counterClockwise90
        adjustments.speed = 1.5
        adjustments.replacementAudio = .init(path: "/tmp/voice.wav", mode: .add)
        adjustments.burnInSubtitles = .init(source: .file(path: "/tmp/subs.srt"), fontSize: 24, backgroundBox: true, position: .top)
        adjustments.audioGain = -4.5
        let data = try JSONEncoder().encode(adjustments)
        XCTAssertEqual(try JSONDecoder().decode(MediaAdjustments.self, from: data), adjustments)

        let future = Data(#"{"rotation": 45, "speed": 99, "videoFadeIn": -2, "loudness": "loud", "audioGain": 99}"#.utf8)
        let decoded = try JSONDecoder().decode(MediaAdjustments.self, from: future)
        XCTAssertEqual(decoded.audioGain, MediaAdjustments.audioGainRange.upperBound)
        let malformed = Data(#"{"audioGain": "loud"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(MediaAdjustments.self, from: malformed).audioGain)
        XCTAssertEqual(decoded.rotation, .none)
        XCTAssertEqual(decoded.speed, MediaAdjustments.maximumSpeed)
        XCTAssertEqual(decoded.videoFadeIn, 0)
        XCTAssertEqual(decoded.loudness, .useDefault)
    }

    func testOnlyTheGlobalLoudnessDefaultIsSkippedForStreamCopy() async {
        let global = LoudnessNormalizationSettings.enabledEBU
        let skipped = await FFMPEGCommandBuilder.buildCommand(
            inputURL: URL(fileURLWithPath: "/private/source.mov"), outputFileURL: URL(fileURLWithPath: "/private/out.mov"),
            preset: .streamCopy, comment: "", includeDateTag: false, trimStart: nil, trimEnd: nil,
            adjustments: ResolvedMediaAdjustments(adjustments: nil, globalLoudness: global)
        )
        XCTAssertNil(skipped.preparationError)
        XCTAssertFalse(skipped.arguments.joined(separator: " ").contains("loudnorm"))

        var explicit = MediaAdjustments()
        explicit.rotation = .clockwise90
        let rejected = await FFMPEGCommandBuilder.buildCommand(
            inputURL: URL(fileURLWithPath: "/private/source.mov"), outputFileURL: URL(fileURLWithPath: "/private/out.mov"),
            preset: .streamCopy, comment: "", includeDateTag: false, trimStart: nil, trimEnd: nil,
            adjustments: ResolvedMediaAdjustments(adjustments: explicit, globalLoudness: global)
        )
        XCTAssertNotNil(rejected.preparationError)
    }

    // MARK: - End to end with the bundled FFmpeg

    func testRotatedSpeedChangedExportWithBurnedSubtitlesIsNormalizedToTarget() async throws {
        let fixture = try await Fixture.make(audioTracks: 2)
        defer { fixture.remove() }
        var adjustments = MediaAdjustments()
        adjustments.rotation = .clockwise90
        adjustments.speed = 2
        adjustments.videoFadeIn = 0.25
        adjustments.videoFadeOut = 0.25
        adjustments.audioFadeOut = 0.25
        adjustments.burnInSubtitles = .init(source: .file(path: fixture.subtitles.path))
        let output = fixture.directory.appendingPathComponent("rotated.mkv")
        let command = try await fixture.export(
            preset: .lossless, adjustments: ResolvedMediaAdjustments(
                adjustments: adjustments, globalLoudness: .enabledEBU
            ), to: output
        )
        XCTAssertEqual(command.loudnessTrackCount, 2)
        XCTAssertTrue(command.arguments.contains { $0.contains("linear=true") })

        let probe = try await fixture.probe(output)
        XCTAssertEqual(probe.width, 240)
        XCTAssertEqual(probe.height, 320)
        XCTAssertEqual(probe.audioTracks, 2)
        XCTAssertEqual(probe.duration, 2, accuracy: 0.15)
        for track in 0..<2 {
            let integrated = try await fixture.integratedLoudness(output, track: track)
            XCTAssertEqual(integrated, -23, accuracy: 1, "track \(track)")
        }
    }

    func testExportVolumeRaisesIntegratedLoudness() async throws {
        let fixture = try await Fixture.make(audioTracks: 1)
        defer { fixture.remove() }
        let plain = fixture.directory.appendingPathComponent("plain.mkv")
        _ = try await fixture.export(
            preset: .lossless, adjustments: ResolvedMediaAdjustments(adjustments: nil, globalLoudness: .init()), to: plain
        )
        var adjustments = MediaAdjustments()
        adjustments.audioGain = 6
        let louder = fixture.directory.appendingPathComponent("louder.mkv")
        let command = try await fixture.export(
            preset: .lossless, adjustments: ResolvedMediaAdjustments(adjustments: adjustments, globalLoudness: .init()),
            to: louder
        )
        XCTAssertTrue(command.arguments.contains { $0.contains("volume=6dB") })
        let difference = try await fixture.integratedLoudness(louder, track: 0)
            - fixture.integratedLoudness(plain, track: 0)
        XCTAssertEqual(difference, 6, accuracy: 0.3)
    }

    func testReplacementAudioReplacesOrAddsTracksAndFollowsTheTrim() async throws {
        let fixture = try await Fixture.make(audioTracks: 2)
        defer { fixture.remove() }
        for (mode, expectedTracks) in [(MediaAdjustments.AudioReplacementMode.replace, 1), (.add, 3)] {
            var adjustments = MediaAdjustments()
            adjustments.replacementAudio = .init(path: fixture.replacementAudio.path, mode: mode)
            adjustments.audioOffset = 0.5
            let output = fixture.directory.appendingPathComponent("replaced-\(mode.rawValue).mkv")
            _ = try await fixture.export(
                preset: .lossless, adjustments: ResolvedMediaAdjustments(adjustments: adjustments, globalLoudness: .init()),
                to: output, trimStart: 1, trimEnd: 3
            )
            let probe = try await fixture.probe(output)
            XCTAssertEqual(probe.audioTracks, expectedTracks, mode.rawValue)
            XCTAssertEqual(probe.duration, 2, accuracy: 0.15, mode.rawValue)
        }
    }

    func testMonoTrackBroadcastPresetNormalizesSourcesBeforeTheSplit() async throws {
        let fixture = try await Fixture.make(audioTracks: 1, size: "1920x1080")
        defer { fixture.remove() }
        for preset in [ExportPreset.tvAVCIntra, .xdcamHD422] {
            XCTAssertTrue(preset.splitsAudioIntoMonoTracks)
            let output = fixture.directory.appendingPathComponent("\(preset.rawValue.filter(\.isLetter)).mxf")
            let command = try await fixture.export(
                preset: preset, adjustments: ResolvedMediaAdjustments(adjustments: nil, globalLoudness: .enabledEBU),
                to: output
            )
            XCTAssertEqual(command.loudnessTrackCount, 1, preset.rawValue)
            let graph = try XCTUnwrap(command.arguments.firstIndex(of: "-filter_complex").map { command.arguments[$0 + 1] })
            XCTAssertTrue(graph.hasPrefix("[0:a:0]loudnorm="), graph)
            let probe = try await fixture.probe(output)
            XCTAssertGreaterThanOrEqual(probe.audioTracks, 2, preset.rawValue)
        }
    }

    func testParsesLoudnormStatisticsInGraphOrder() {
        let log = """
        [Parsed_loudnorm_3 @ 0x7b9ac09440]
        {
        \t"input_i" : "-21.05", "input_tp" : "-18.06", "input_lra" : "0.00", "input_thresh" : "-31.05",
        \t"output_i" : "-23.0", "target_offset" : "0.01"
        }
        [Parsed_loudnorm_1 @ 0x7b9ac092c0]
        {
        \t"input_i" : "-inf", "input_tp" : "-inf", "input_lra" : "0.00", "input_thresh" : "-70.00",
        \t"target_offset" : "inf"
        }
        """
        let measurements = MediaAdjustmentsPlan.parseLoudnormMeasurements(from: log)
        XCTAssertEqual(measurements.map(\.inputIntegrated), ["-inf", "-21.05"])
        XCTAssertFalse(MediaAdjustmentsPlan.measurementIsUsable(measurements[0]))
        XCTAssertTrue(MediaAdjustmentsPlan.measurementIsUsable(measurements[1]))
    }
}

private extension LoudnessNormalizationSettings {
    static var enabledEBU: LoudnessNormalizationSettings {
        var settings = LoudnessNormalizationSettings()
        settings.enabled = true
        return settings
    }
}

/// A short test clip with quiet stereo tracks, an SRT file and a replacement voice track.
private struct Fixture {
    let directory: URL
    let source: URL
    let subtitles: URL
    let replacementAudio: URL
    let ffmpeg: String

    static func make(audioTracks: Int, size: String = "320x240") async throws -> Fixture {
        let ffmpeg = try XCTUnwrap(BinaryPathResolver.ffmpegPath)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("adjustments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = Fixture(
            directory: directory, source: directory.appendingPathComponent("source.mov"),
            subtitles: directory.appendingPathComponent("subs.srt"),
            replacementAudio: directory.appendingPathComponent("voice.wav"), ffmpeg: ffmpeg
        )
        try "1\n00:00:00,500 --> 00:00:03,000\nHello: world, [test]\n\n".write(to: fixture.subtitles, atomically: true, encoding: .utf8)
        var arguments = ["-y", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc2=d=4:s=\(size):r=25"]
        for track in 0..<audioTracks {
            arguments += ["-f", "lavfi", "-i", "sine=f=\(440 + track * 220):d=4:sample_rate=48000,volume=\(-30 - track * 6)dB,pan=stereo|c0=c0|c1=c0"]
        }
        arguments += ["-map", "0:v"] + (0..<audioTracks).flatMap { ["-map", "\($0 + 1):a"] }
        arguments += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "pcm_s24le", fixture.source.path]
        try await fixture.run(arguments)
        try await fixture.run(["-y", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                               "sine=f=330:d=6:sample_rate=48000", "-c:a", "pcm_s16le", fixture.replacementAudio.path])
        return fixture
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }

    @discardableResult
    func run(_ arguments: [String]) async throws -> SubprocessResult {
        let result = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpeg), arguments: arguments,
            standardErrorCaptureLimit: 4 * 1024 * 1024
        ))
        XCTAssertTrue(result.succeeded, result.standardErrorText)
        return result
    }

    /// Builds, measures when loudness is on, rebuilds and encodes, as `FFMPEGConverter` does.
    func export(
        preset: ExportPreset, adjustments: ResolvedMediaAdjustments, to output: URL,
        trimStart: Double? = nil, trimEnd: Double? = nil
    ) async throws -> FFMPEGCommand {
        let metadata = try await BoundedVideoMetadataProbe.metadata(for: source)
        func build(_ measurements: [LoudnormMeasurement]?) async -> FFMPEGCommand {
            await FFMPEGCommandBuilder.buildCommand(
                inputURL: source, outputFileURL: output, preset: preset,
                codecSettings: CodecExportSettings(preset: preset, defaults: UserDefaults(suiteName: "adjustments-\(UUID())")!),
                comment: "", includeDateTag: false, trimStart: trimStart, trimEnd: trimEnd,
                sourceMetadata: metadata, adjustments: adjustments, loudnessMeasurements: measurements
            )
        }
        var command = await build(nil)
        if let error = command.preparationError { XCTFail(error) }
        if let measurement = command.loudnessMeasurementArguments {
            let result = try await run(["-hide_banner", "-nostats"] + measurement.filter { $0 != "-progress" && $0 != "pipe:2" })
            let measurements = MediaAdjustmentsPlan.parseLoudnormMeasurements(from: result.standardErrorText)
            XCTAssertEqual(measurements.count, command.loudnessTrackCount)
            command = await build(measurements)
            if let error = command.preparationError { XCTFail(error) }
        }
        try await run(command.arguments.filter { $0 != "-progress" && $0 != "pipe:2" })
        return command
    }

    struct Probe { var width = 0, height = 0, audioTracks = 0, duration = 0.0 }

    func probe(_ url: URL) async throws -> Probe {
        let metadata = try await BoundedVideoMetadataProbe.metadata(for: url)
        let video = metadata.videoStreams.first
        return Probe(
            width: video?.width ?? 0, height: video?.height ?? 0,
            audioTracks: metadata.audioStreams.count, duration: metadata.duration ?? 0
        )
    }

    func integratedLoudness(_ url: URL, track: Int) async throws -> Double {
        let result = try await run(["-hide_banner", "-nostats", "-i", url.path, "-map", "0:a:\(track)",
                                    "-af", "ebur128", "-f", "null", "-"])
        let summary = try XCTUnwrap(result.standardErrorText.range(of: "Summary:"))
        let tail = result.standardErrorText[summary.upperBound...]
        let match = try XCTUnwrap(tail.firstMatch(of: /I:\s+(-?[\d.]+) LUFS/))
        return try XCTUnwrap(Double(match.output.1))
    }
}

@MainActor
final class PlayerItemAudioGainTests: XCTestCase {
    func testTapIsInstalledOnlyForAGain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("tone.wav")
        let result = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: try XCTUnwrap(BinaryPathResolver.ffmpegPath)),
            arguments: ["-hide_banner", "-loglevel", "error", "-nostdin", "-f", "lavfi",
                        "-i", "sine=f=440:d=1:sample_rate=48000", "-y", source.path],
            timeout: .seconds(20)))
        XCTAssertTrue(result.succeeded, result.standardErrorText)

        let unity = AVPlayerItem(url: source)
        let untouched = PlayerItemAudioGain()
        untouched.apply(to: unity)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(unity.audioMix)

        let item = AVPlayerItem(url: source)
        let gain = PlayerItemAudioGain()
        gain.decibels = 6
        gain.apply(to: item)
        for _ in 0..<50 where item.audioMix == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        let parameters = try XCTUnwrap(item.audioMix?.inputParameters.first)
        XCTAssertNotNil(parameters.audioTapProcessor)

        // The tap scales the samples: +6 dB doubles the sine's peak, −6 dB halves it.
        let tracks = try await AVURLAsset(url: source).loadTracks(withMediaType: .audio)
        let plain = try peak(of: source, mix: nil)
        gain.decibels = 6.0206
        XCTAssertEqual(try peak(of: source, mix: gain.audioMix(for: tracks)) / plain, 2, accuracy: 0.01)
        gain.decibels = -6.0206
        XCTAssertEqual(try peak(of: source, mix: gain.audioMix(for: tracks)) / plain, 0.5, accuracy: 0.01)
    }

    private func peak(of url: URL, mix: AVAudioMix?) throws -> Float {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        let tracks = asset.tracks(withMediaType: .audio)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        output.audioMix = mix
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var peak: Float = 0
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples in
                for index in 0..<(length / 4) { peak = max(peak, abs(samples[index])) }
            }
        }
        return peak
    }
}
