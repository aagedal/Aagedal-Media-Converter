// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Orchestrates the native waveform render loop: smooths frequency band data,
// renders BGRA frames via NativeWaveformVideoRenderer, and streams them to
// FFmpeg as rawvideo input.

import Foundation
import CoreGraphics
import OSLog

enum WaveformFramePipeWriter {

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "WaveformPipeWriter")

    /// Smoothing decay factor per frame. Fast attack (instant rise), slow release.
    /// At 25 fps a value of 0.85 means ~150 ms half-life.
    private static let decayFactor: Float = 0.85

    // MARK: - Public API

    /// Renders all waveform video frames and writes them to a subprocess's standard input.
    ///
    /// This method blocks the calling context until all frames are written (or cancelled).
    /// It should be called from a background Task so FFmpeg can encode concurrently.
    ///
    /// - Parameters:
    ///   - standardInput: The live subprocess input receiving raw BGRA frames.
    ///   - frequencyData: Pre-computed frequency band magnitudes per frame.
    ///   - width: Frame width in pixels.
    ///   - height: Frame height in pixels.
    ///   - foregroundHex: Hex color string for capsule fill.
    ///   - backgroundHex: Hex color string for frame background.
    ///   - foregroundGradientEnabled: Whether to apply a vertical gradient to foreground elements.
    ///   - foregroundGradientEndHex: End color for foreground gradient (start is foregroundHex).
    ///   - backgroundGradientEnabled: Whether to apply a vertical gradient to the background.
    ///   - backgroundGradientEndHex: End color for background gradient (start is backgroundHex).
    ///   - backgroundImage: Pre-scaled CGImage to use as background (takes priority over gradient/solid).
    ///   - waveformOpacity: Opacity for waveform shapes (0.5–1.0), allows background to show through.
    ///   - progressUpdate: Called with 0.0–1.0 progress fraction.
    static func writeFrames(
        to standardInput: SubprocessStandardInputWriter,
        frequencyData: FrequencyBandData,
        style: SwiftWaveformStyle,
        width: Int,
        height: Int,
        foregroundHex: String,
        backgroundHex: String,
        foregroundGradientEnabled: Bool = false,
        foregroundGradientEndHex: String = "FFFFFF",
        backgroundGradientEnabled: Bool = false,
        backgroundGradientEndHex: String = "000000",
        backgroundImage: CGImage? = nil,
        waveformOpacity: Double = 1.0,
        progressUpdate: @escaping @Sendable (Double) -> Void
    ) async {
        let frameCount = frequencyData.frameCount
        let bandCount = frequencyData.bandCount

        let fg = NativeWaveformRenderer.parseHexColor(foregroundHex)
        let bg = NativeWaveformRenderer.parseHexColor(backgroundHex)
        let fgGradientEnd: (r: UInt8, g: UInt8, b: UInt8)? = foregroundGradientEnabled
            ? NativeWaveformRenderer.parseHexColor(foregroundGradientEndHex) : nil
        let bgGradientEnd: (r: UInt8, g: UInt8, b: UInt8)? = backgroundGradientEnabled
            ? NativeWaveformRenderer.parseHexColor(backgroundGradientEndHex) : nil

        // Smoothed magnitudes for animation (fast attack, slow release)
        var smoothed = [Float](repeating: 0, count: bandCount)
        var previousSmoothed: [Float]? = nil

        logger.info("Starting native waveform render: \(frameCount) frames, \(width)x\(height), \(bandCount) bands")

        for frame in 0..<frameCount {
            // Check cancellation
            if Task.isCancelled {
                logger.info("Waveform render cancelled at frame \(frame)/\(frameCount)")
                break
            }

            // Snapshot previous smoothed values for motion blur
            let prevForBlur = previousSmoothed

            // Apply smoothing: fast attack (instant), slow release (decay)
            let rawMagnitudes = frequencyData.magnitudes[frame]
            previousSmoothed = smoothed
            for band in 0..<bandCount {
                let raw = rawMagnitudes[band]
                smoothed[band] = max(raw, smoothed[band] * decayFactor)
            }

            // Render frame with motion blur trail from previous frame
            let frameData = NativeWaveformVideoRenderer.renderFrame(
                style: style,
                bandMagnitudes: smoothed,
                previousMagnitudes: prevForBlur,
                width: width,
                height: height,
                foregroundColor: fg,
                backgroundColor: bg,
                foregroundGradientEnd: fgGradientEnd,
                backgroundGradientEnd: bgGradientEnd,
                backgroundImage: backgroundImage,
                waveformOpacity: waveformOpacity
            )

            // Write to pipe (blocks if FFmpeg's encoding is slower — natural backpressure)
            do {
                try standardInput.write(frameData)
            } catch {
                // Pipe broken (FFmpeg exited or crashed)
                logger.error("Pipe write failed at frame \(frame): \(error.localizedDescription)")
                break
            }

            // Report progress periodically (every 10 frames to avoid overhead)
            if frame % 10 == 0 || frame == frameCount - 1 {
                let progress = Double(frame + 1) / Double(frameCount)
                progressUpdate(progress)
            }
        }

        // Close write end so FFmpeg sees EOF and finishes encoding
        standardInput.finish()
        logger.info("Waveform frame writing complete")
    }
}
