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
    ///   - transparentBackground: Leave the background transparent and emit straight
    ///     (non-premultiplied) alpha. Only pass `true` when the encoder keeps alpha.
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
        transparentBackground: Bool = false,
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

        // Smoothing, peak hold and ridge history (shared with the settings preview)
        var animation = WaveformAnimationState(
            bandCount: bandCount,
            frameRate: frequencyData.frameRate,
            style: style
        )

        // One bitmap reused for every frame — avoids allocating (and zero-filling)
        // a full-resolution buffer per frame, which is ~33 MB at 4K.
        let context = NativeWaveformVideoRenderer.makeContext(width: width, height: height)

        logger.info("Starting native waveform render: \(frameCount) frames, \(width)x\(height), \(bandCount) bands, alpha: \(transparentBackground)")

        for frame in 0..<frameCount {
            // Check cancellation
            if Task.isCancelled {
                logger.info("Waveform render cancelled at frame \(frame)/\(frameCount)")
                break
            }

            let frameInput = animation.advance(raw: frequencyData.magnitudes[frame])

            let frameData = NativeWaveformVideoRenderer.renderFrame(
                style: style,
                frame: frameInput,
                width: width,
                height: height,
                foregroundColor: fg,
                backgroundColor: bg,
                foregroundGradientEnd: fgGradientEnd,
                backgroundGradientEnd: bgGradientEnd,
                backgroundImage: backgroundImage,
                waveformOpacity: waveformOpacity,
                transparentBackground: transparentBackground,
                context: context
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
