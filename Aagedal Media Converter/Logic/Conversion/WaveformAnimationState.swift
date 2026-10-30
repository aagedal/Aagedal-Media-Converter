// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Per-frame animation state for the native waveform renderer: smoothing,
// peak hold, and sampled spectrum history. Shared by the export render loop
// and the settings style preview so both animate identically.

import Foundation

/// Everything the renderer needs for one frame beyond colors and size.
struct WaveformFrameInput {
    /// Smoothed band levels for this frame, nominally 0–1 (clamped when drawn).
    var magnitudes: [Float]
    /// Earlier smoothed levels drawn as a faint motion trail, if any.
    var previousMagnitudes: [Float]? = nil
    /// Peak-hold levels (LED meter caps, orb outline).
    var peakMagnitudes: [Float]? = nil
    /// Sampled past spectra for the ridgeline style, newest first.
    var history: [[Float]] = []
    /// Fraction (0..<1) of a history step elapsed since `history[0]` was sampled.
    var historyPhase: Double = 0
    /// Seconds since the start of the render (drives slow rotation).
    var time: Double = 0
}

struct WaveformAnimationState {
    /// Number of ridge lines visible at once.
    static let ridgeLineCount = 24
    /// How many ridge lines are sampled per second (scroll speed).
    static let ridgeLinesPerSecond: Double = 10
    /// How long a peak cap holds before it starts falling.
    static let peakHoldSeconds: Double = 0.5
    /// Peak cap fall speed in full-scale units per second.
    static let peakFallPerSecond: Double = 0.9

    /// Smoothing decay factor per frame at the reference frame rate.
    /// Fast attack (instant rise), slow release: 0.85 at 25 fps ≈ 170 ms half-life.
    private static let referenceDecayFactor: Float = 0.85
    private static let referenceFrameRate: Double = 25

    /// Per-frame release factor that keeps the same release *time* at any frame rate.
    static func decayFactor(frameRate: Double) -> Float {
        guard frameRate > 0 else { return referenceDecayFactor }
        return Float(pow(Double(referenceDecayFactor), referenceFrameRate / frameRate))
    }

    /// Frames between ridge history samples at the given frame rate.
    static func historyStride(frameRate: Double) -> Int {
        max(1, Int((frameRate / ridgeLinesPerSecond).rounded()))
    }

    /// Frames of input needed before every part of the animation is fully
    /// populated (used by the preview to simulate from a cold start).
    static func warmUpFrames(frameRate: Double, style: SwiftWaveformStyle) -> Int {
        let fps = frameRate > 0 ? frameRate : referenceFrameRate
        let peakSettle = Int(ceil((peakHoldSeconds + 1.0 / peakFallPerSecond) * fps))
        guard style == .ridgeline else { return peakSettle }
        return max(peakSettle, historyStride(frameRate: fps) * ridgeLineCount + 1)
    }

    let bandCount: Int
    let frameRate: Double
    private(set) var frameIndex: Int

    private let decay: Float
    private let historyStride: Int
    private let keepsHistory: Bool
    private let holdFrames: Int
    private let peakFallPerFrame: Float

    private var smoothed: [Float]
    /// Smoothed levels from before the last update. The trail deliberately
    /// lags two frames behind, which reads better than one and matches the
    /// look of earlier versions.
    private var trailSource: [Float]?
    private var peaks: [Float]
    private var holdCounters: [Int]
    private var history: [[Float]] = []

    init(bandCount: Int, frameRate: Double, style: SwiftWaveformStyle, startFrameIndex: Int = 0) {
        let fps = frameRate > 0 ? frameRate : Self.referenceFrameRate
        self.bandCount = bandCount
        self.frameRate = fps
        self.frameIndex = startFrameIndex
        self.decay = Self.decayFactor(frameRate: fps)
        self.historyStride = Self.historyStride(frameRate: fps)
        self.keepsHistory = style == .ridgeline
        self.holdFrames = Int((Self.peakHoldSeconds * fps).rounded())
        self.peakFallPerFrame = Float(Self.peakFallPerSecond / fps)
        self.smoothed = [Float](repeating: 0, count: bandCount)
        self.trailSource = nil
        self.peaks = [Float](repeating: 0, count: bandCount)
        self.holdCounters = [Int](repeating: 0, count: bandCount)
    }

    /// Consumes one frame of raw band levels and returns the render input for it.
    mutating func advance(raw: [Float]) -> WaveformFrameInput {
        let trail = trailSource
        trailSource = smoothed

        for band in 0..<bandCount {
            let value = band < raw.count ? raw[band] : 0
            smoothed[band] = max(value, smoothed[band] * decay)

            let level = min(1, smoothed[band])
            if level >= peaks[band] {
                peaks[band] = level
                holdCounters[band] = holdFrames
            } else if holdCounters[band] > 0 {
                holdCounters[band] -= 1
            } else {
                peaks[band] = max(level, peaks[band] - peakFallPerFrame)
            }
        }

        let phaseFrames = ((frameIndex % historyStride) + historyStride) % historyStride
        if keepsHistory, phaseFrames == 0 {
            history.insert(smoothed, at: 0)
            if history.count > Self.ridgeLineCount {
                history.removeLast(history.count - Self.ridgeLineCount)
            }
        }

        let input = WaveformFrameInput(
            magnitudes: smoothed,
            previousMagnitudes: trail,
            peakMagnitudes: peaks,
            history: history,
            historyPhase: Double(phaseFrames) / Double(historyStride),
            time: Double(frameIndex) / frameRate
        )
        frameIndex += 1
        return input
    }
}
