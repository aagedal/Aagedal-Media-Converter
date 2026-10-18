import Combine
import Darwin
import XCTest
@testable import Aagedal_Media_Converter

/// Explicitly opt in: performance samples are evidence, not CI timing assertions.
final class AudioMeterBenchmarkTests: XCTestCase {
    private struct Reading: Codable {
        let playhead: Double
        let peak: Double?
        let measuredSeconds: Double?
        let timestampHistory: Bool
        let historyIngestSeconds: Double?
    }

    private struct Run: Codable {
        let fixture: String
        let round: Int
        let mode: String
        let audioOutput: String
        let clock: String
        let wallSeconds: Double
        let hostCPUSeconds: Double
        let childCPUSeconds: Double
        let sourceWindows: Int
        let readings: [Reading]
    }

    @MainActor
    func testCompareSourceAndPlaybackMeter() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AMC_AUDIO_METER_BENCHMARK"] == "1" else {
            throw XCTSkip("Run scripts/benchmark-audio-meter.py to collect CPU and signal-transition evidence")
        }
        let modes = (environment["AMC_AUDIO_METER_BENCHMARK_MODES"] ?? "off,source,playback").components(separatedBy: ",")
        guard !modes.isEmpty, Set(modes).count == modes.count,
              Set(modes).isSubset(of: Set(["off", "source", "playback"])) else {
            XCTFail("Benchmark modes must be a nonempty unique selection of off, source and playback")
            return
        }
        let rounds = min(5, max(1, Int(environment["AMC_AUDIO_METER_BENCHMARK_ROUNDS"] ?? "") ?? 3))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-meter-benchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = URL(fileURLWithPath: try XCTUnwrap(BinaryPathResolver.ffmpegPath))
        var runs: [Run] = []
        for channels in [2, 6] {
            let name = channels == 2 ? "stereo-aac-video" : "surround-flac-audio"
            let source = directory.appendingPathComponent(name + ".mkv")
            // Distinct, known levels every two seconds let the report measure
            // signal transitions rather than trusting the decoder's playhead label.
            let tone = "pow(10,(-6-1.5*floor(t/2))/20)*sin(2*PI*1000*t)"
            let expressions = Array(repeating: tone, count: channels).joined(separator: "|")
            var arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                             "-f", "lavfi", "-i", "aevalsrc='\(expressions)':s=48000:d=32:c=\(channels == 2 ? "stereo" : "5.1")"]
            if channels == 2 {
                arguments += ["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=32", "-c:v", "mpeg4"]
            }
            arguments += ["-c:a", channels == 2 ? "aac" : "flac", source.path]
            let generated = try await SubprocessRunner().run(SubprocessRequest(
                executableURL: ffmpeg, arguments: arguments, timeout: .seconds(60)))
            XCTAssertTrue(generated.succeeded, generated.standardErrorText)
            guard generated.succeeded else { return }
            for round in 0..<rounds {
                // Rotate order so decoder/filesystem warm-up does not always favor
                // the same mode. Each Source run still owns a fresh window cache.
                for offset in 0..<modes.count {
                    let mode = modes[(round + offset) % modes.count]
                    let run = try await measure(source: source, name: name, channels: channels,
                                                round: round + 1, mode: mode)
                    runs.append(run)
                    print("Audio meter benchmark: \(name), round \(round + 1), \(mode): \(run.hostCPUSeconds + run.childCPUSeconds) CPU seconds / \(run.wallSeconds) wall seconds")
                }
            }
        }
        let attachment = XCTAttachment(data: try JSONEncoder().encode(runs), uniformTypeIdentifier: "public.json")
        attachment.name = "audio-meter-benchmark.json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func measure(source: URL, name: String, channels: Int, round: Int, mode: String) async throws -> Run {
        let player = MPVPlayer()
        let layer = MPVMetalLayer()
        player.attachDrawable(layer)
        player.isMuted = true
        defer { player.setPlaybackMeterEnabled(false); player.stop(); withExtendedLifetime(layer) {} }
        player.load(url: source, autostart: false)
        for _ in 0..<500 {
            if player.isFileLoaded { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(player.isFileLoaded)
        XCTAssertNil(player.error)
        let cache = PlaybackAudioMeterCache()
        var chunk: PlaybackAudioMeterChunk?
        var window = -1
        var windows = 0
        var readings: [Reading] = []
        let hostStart = try cpuSeconds(children: false)
        let childStart = try cpuSeconds(children: true)
        let start = ProcessInfo.processInfo.systemUptime
        player.setPlaybackMeterEnabled(mode == "playback")
        player.play()
        while ProcessInfo.processInfo.systemUptime - start < 17 {
            let time = player.timePos
            if mode == "source" {
                let nextWindow = Int(max(0, time) / SourceAudioMeterRequest.windowDuration)
                if window != nextWindow {
                    window = nextWindow
                    let request = SourceAudioMeterRequest(url: source, track: 0, channels: channels, window: window)
                    chunk = try await cache.load(request)
                    // Match the panel's one-window lookahead. CPU includes this
                    // work even when the prefetched tail outlives the sample.
                    _ = try await cache.load(request.adjacent(1))
                    windows += 1
                }
            }
            let sample = mode == "source" ? chunk?.sample(at: player.timePos) : player.playbackMeterSample
            readings.append(Reading(playhead: player.timePos, peak: sample?.peaks.first.flatMap { $0 },
                measuredSeconds: sample?.seconds, timestampHistory: mode == "playback" && player.playbackMeterHasTimestampHistory,
                historyIngestSeconds: mode == "playback" ? player.playbackMeterHistoryIngestSeconds : nil))
            try await Task.sleep(for: .milliseconds(100))
        }
        let wall = ProcessInfo.processInfo.systemUptime - start
        let host = try cpuSeconds(children: false) - hostStart
        let child = try cpuSeconds(children: true) - childStart
        let output = player.currentAudioOutput ?? "unknown"
        XCTAssertNotEqual(output, "unknown", "Capture the backend after playback actually initializes it")
        XCTAssertNil(player.error)
        XCTAssertTrue(player.isPlaying)
        XCTAssertGreaterThan(player.timePos, 15, "A stalled output cannot produce a comparable run")
        if mode != "off" {
            XCTAssertGreaterThan(readings.compactMap(\.peak).count, 100, "Meter must produce actual readings")
        }
        if mode == "playback", ProcessInfo.processInfo.environment["AMC_PLAYBACK_METER_HISTORY"] == "1" {
            XCTAssertGreaterThan(readings.filter(\.timestampHistory).count, 100, "Diagnostic run must use actual timestamp history")
            let measured = readings.filter { $0.timestampHistory && $0.measuredSeconds != nil }
            XCTAssertGreaterThan(measured.filter { abs($0.playhead - ($0.measuredSeconds ?? $0.playhead)) > 0.000001 }.count, 80,
                "Measured frame ends must not be replaced with receipt-time playhead labels")
        }
        return Run(fixture: name, round: round, mode: mode, audioOutput: output,
                   clock: mode == "playback" ? (ProcessInfo.processInfo.environment["AMC_PLAYBACK_METER_CLOCK"] ?? "time-pos") : "time-pos", wallSeconds: wall,
                   hostCPUSeconds: host, childCPUSeconds: child, sourceWindows: windows, readings: readings)
    }

    private func cpuSeconds(children: Bool) throws -> Double {
        var usage = rusage()
        guard getrusage(children ? RUSAGE_CHILDREN : RUSAGE_SELF, &usage) == 0 else {
            throw POSIXError(.EIO)
        }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
