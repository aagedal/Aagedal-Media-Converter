// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import OSLog
import Combine
@preconcurrency import ScreenCaptureKit
import AVFoundation
import AppKit
import CoreMedia

/// Service to monitor real-time audio levels from the entire application using ScreenCaptureKit
@MainActor
final class UniversalAudioMeterService: NSObject, ObservableObject {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "UniversalAudioMeter")
    struct AudioLevels {
        let leftChannel: Float  // dB level, typically -60.0 to 0.0
        let rightChannel: Float // dB level, typically -60.0 to 0.0
        let peak: Float         // Peak level across all channels
        
        static let silence = AudioLevels(leftChannel: -60.0, rightChannel: -60.0, peak: -60.0)
    }
    
    @Published private(set) var currentLevels: AudioLevels = .silence
    @Published private(set) var isMonitoring = false
    @Published private(set) var permissionError: Bool = false
    /// Real-time frequency band magnitudes (0.0–1.0 per band). Nil when not monitoring.
    @Published private(set) var frequencyBands: [Float]?

    private var session: (any AudioMeterCaptureSession)?
    private var attemptID: UUID?
    private var startTask: Task<Void, Error>?
    private let timeout: Duration
    private let makeSession: @MainActor () async throws -> any AudioMeterCaptureSession

    override convenience init() {
        self.init(timeout: .seconds(15), makeSession: ScreenAudioMeterCaptureSession.make)
    }

    init(
        timeout: Duration,
        makeSession: @escaping @MainActor () async throws -> any AudioMeterCaptureSession
    ) {
        self.timeout = timeout
        self.makeSession = makeSession
        super.init()
    }

    /// Reload frequency analyzer settings (call when user changes waveform settings).
    func reloadFrequencySettings() {
        session?.reloadFrequencySettings()
    }

    /// Own the complete discovery/start attempt so stop and replacement fence every suspension.
    func startMonitoring() async {
        guard attemptID == nil else { return }
        let id = UUID()
        attemptID = id
        let timeout = timeout
        let factory = makeSession
        let task = Task { @MainActor [weak self] in
            try await NonJoiningTaskDeadline.run(timeout: timeout) { @MainActor [weak self] in
                let candidate = try await factory()
                do {
                    try Task.checkCancellation()
                    guard let self, self.attemptID == id else { throw CancellationError() }
                    candidate.configure(
                        levels: { [weak self] levels in
                            guard let self, self.attemptID == id, self.isMonitoring else { return }
                            self.currentLevels = levels
                        },
                        bands: { [weak self] bands in
                            guard let self, self.attemptID == id, self.isMonitoring else { return }
                            self.frequencyBands = bands
                        }
                    )
                    self.session = candidate
                    try await candidate.start()
                    try Task.checkCancellation()
                    guard self.attemptID == id else { throw CancellationError() }
                } catch {
                    // Also runs when a non-cooperative start finishes after timeout/stop.
                    // Keep its session alive and stop it without joining a stalled callback.
                    await Self.stop(candidate, timeout: timeout)
                    throw error
                }
            }
        }
        startTask = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
                try Task.checkCancellation()
            } onCancel: {
                task.cancel()
            }
            guard attemptID == id else { return }
            startTask = nil
            isMonitoring = true
            permissionError = false
        } catch {
            guard attemptID == id else { return }
            attemptID = nil
            startTask = nil
            let abandonedSession = session
            session = nil
            if !(error is CancellationError) {
                Self.logger.error("Failed to start capture: \(error.localizedDescription, privacy: .public)")
                permissionError = error is SCStreamError
            }
            if let abandonedSession { await Self.stop(abandonedSession, timeout: timeout) }
        }
    }

    func stopMonitoring() async {
        attemptID = nil
        startTask?.cancel()
        startTask = nil
        let stoppedSession = session
        session = nil
        isMonitoring = false
        currentLevels = .silence
        frequencyBands = nil
        if let stoppedSession { await Self.stop(stoppedSession, timeout: timeout) }
    }

    private static func stop(_ session: any AudioMeterCaptureSession, timeout: Duration) async {
        // Cleanup must run even when the initiating task was cancelled.
        await Task.detached {
            try? await NonJoiningTaskDeadline.run(timeout: timeout) {
                try await session.stop()
            }
        }.value
    }

}

/// Injectable boundary for ScreenCaptureKit's potentially non-cooperative callbacks.
@MainActor
protocol AudioMeterCaptureSession: AnyObject, Sendable {
    func configure(
        levels: @escaping @MainActor (UniversalAudioMeterService.AudioLevels) -> Void,
        bands: @escaping @MainActor ([Float]) -> Void
    )
    func reloadFrequencySettings()
    func start() async throws
    func stop() async throws
}

@MainActor
private final class ScreenAudioMeterCaptureSession: AudioMeterCaptureSession {
    private let stream: SCStream
    private let output = StreamOutput()

    private init(filter: SCContentFilter) throws {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.width = 100
        config.height = 100
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.sampleRate = 48000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = false
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        reloadFrequencySettings()
    }

    static func make() async throws -> any AudioMeterCaptureSession {
        let content = try await ScreenCaptureContentDiscovery.current()
        try Task.checkCancellation()
        guard let app = content.applications.first(where: { $0.bundleIdentifier == Bundle.main.bundleIdentifier }),
              let display = content.displays.first else {
            throw NSError(domain: "UniversalAudioMeter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find the application or display"])
        }
        return try ScreenAudioMeterCaptureSession(filter: SCContentFilter(display: display, including: [app], exceptingWindows: []))
    }

    func configure(
        levels: @escaping @MainActor (UniversalAudioMeterService.AudioLevels) -> Void,
        bands: @escaping @MainActor ([Float]) -> Void
    ) {
        output.levelUpdateHandler = { value in Task { @MainActor in levels(value) } }
        output.frequencyUpdateHandler = { value in Task { @MainActor in bands(value) } }
    }

    func reloadFrequencySettings() {
        let config = AudioWaveformPreferences.loadConfig()
        output.replaceAnalyzer(AudioFrequencyAnalyzer(
            bandCount: config.bandCount,
            frequencyDistribution: config.frequencyDistribution
        ))
    }

    func start() async throws { try await stream.startCapture() }
    func stop() async throws { try await stream.stopCapture() }
}

// MARK: - Stream Output Processor

// Handlers are installed before capture starts; mutable analyzer state is confined
// to the serial sample queue, including preference replacements.
private final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.aagedal.audiometer.processing")
    var levelUpdateHandler: ((UniversalAudioMeterService.AudioLevels) -> Void)?
    var frequencyUpdateHandler: (([Float]) -> Void)?
    private var frequencyAnalyzer: AudioFrequencyAnalyzer?

    func replaceAnalyzer(_ analyzer: AudioFrequencyAnalyzer) {
        queue.async { self.frequencyAnalyzer = analyzer }
    }

    private var leftPeak: Float = 0.0
    private var rightPeak: Float = 0.0
    private let floorLevel: Float = -60.0
    
    // Process audio buffers
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        
        // Extract audio samples
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
              let data = dataPointer else {
            return
        }
        
        // Assuming Float32 non-interleaved or interleaved depending on SCStream config
        // SCStream usually outputs Float32.
        // Let's assume standard 2-channel Float32 for simplicity or inspect format.
        // For robustness, we can just look at the raw bytes as Float32 and find max peak.
        // This is a simplification but works well for metering.
        
        let floatCount = totalLength / MemoryLayout<Float>.size
        let floats = data.withMemoryRebound(to: Float.self, capacity: floatCount) { $0 }
        
        var localPeak: Float = 0.0
        for i in 0..<floatCount {
            localPeak = max(localPeak, abs(floats[i]))
        }
        
        // Decay and update
        // We do this on every buffer, but we should probably throttle updates to main thread
        // For now, let's just calculate peaks and update
        
        let db = amplitudeToDecibels(localPeak)
        
        // Simple mono-to-stereo mapping for now since we are just finding max peak in buffer
        // To do true stereo we need to know channel layout from format description
        
        let levels = UniversalAudioMeterService.AudioLevels(
            leftChannel: db,
            rightChannel: db,
            peak: db
        )
        
        levelUpdateHandler?(levels)

        // Run FFT for frequency band visualization
        if let analyzer = frequencyAnalyzer {
            analyzer.process(samples: floats, count: floatCount)
            frequencyUpdateHandler?(analyzer.bands)
        }
    }
    
    private func amplitudeToDecibels(_ amplitude: Float) -> Float {
        guard amplitude > 0 else { return floorLevel }
        let db = 20 * log10(amplitude)
        return max(db, floorLevel)
    }
}
