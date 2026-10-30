// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Renders frequency band visualizer frames as raw BGRA pixel data
// for piping to FFmpeg during native waveform video generation.
// Supports multiple visual styles: capsules, bars, wire, plus the advanced
// halo, orb, ridgeline and LED meter styles (see +AdvancedStyles).
// Supports gradient fills for foreground/background, background images, and opacity.

import Foundation
import CoreGraphics
import ImageIO
import Accelerate
import OSLog

enum NativeWaveformVideoRenderer {

    static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "NativeWaveformRenderer")

    /// Fraction of band width used as horizontal gap between elements.
    private static let gapFraction: CGFloat = 0.4
    /// Vertical margin (fraction of frame height) above/below tallest element.
    static let verticalMarginFraction: CGFloat = 0.08
    /// Horizontal padding on edges (fraction of frame width).
    static let horizontalPaddingFraction: CGFloat = 0.04

    // MARK: - Public API

    typealias RGB = (r: UInt8, g: UInt8, b: UInt8)

    /// Creates a BGRA bitmap context suitable for `drawFrame`. Reuse one context
    /// across frames to avoid allocating a full frame buffer per frame.
    static func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)  // BGRA layout
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        )
    }

    /// Renders a single video frame as raw BGRA pixel data.
    static func renderFrame(
        style: SwiftWaveformStyle,
        frame: WaveformFrameInput,
        width: Int,
        height: Int,
        foregroundColor: RGB,
        backgroundColor: RGB,
        foregroundGradientEnd: RGB? = nil,
        backgroundGradientEnd: RGB? = nil,
        backgroundImage: CGImage? = nil,
        waveformOpacity: Double = 1.0,
        transparentBackground: Bool = false,
        context: CGContext? = nil
    ) -> Data {
        let byteCount = width * height * 4
        guard let ctx = context ?? makeContext(width: width, height: height),
              ctx.width == width, ctx.height == height else {
            logger.error("Failed to create CGContext for frame rendering")
            return Data(count: max(0, byteCount))
        }

        drawFrame(in: ctx, style: style, frame: frame,
                  foregroundColor: foregroundColor, backgroundColor: backgroundColor,
                  foregroundGradientEnd: foregroundGradientEnd, backgroundGradientEnd: backgroundGradientEnd,
                  backgroundImage: backgroundImage, waveformOpacity: waveformOpacity,
                  transparentBackground: transparentBackground)

        guard let data = ctx.data else {
            return Data(count: byteCount)
        }
        if transparentBackground {
            // CoreGraphics stores premultiplied alpha; FFmpeg's `bgra` is straight alpha.
            // Alpha is the last channel in BGRA as in RGBA, so the RGBA routine applies.
            var buffer = vImage_Buffer(data: data, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: ctx.bytesPerRow)
            vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
        }
        return Data(bytes: data, count: ctx.bytesPerRow * height)
    }

    /// Renders a single frame as a `CGImage` (used by the settings style preview).
    static func renderImage(
        style: SwiftWaveformStyle,
        frame: WaveformFrameInput,
        width: Int,
        height: Int,
        foregroundColor: RGB,
        backgroundColor: RGB,
        foregroundGradientEnd: RGB? = nil,
        backgroundGradientEnd: RGB? = nil,
        backgroundImage: CGImage? = nil,
        waveformOpacity: Double = 1.0,
        transparentBackground: Bool = false
    ) -> CGImage? {
        guard let ctx = makeContext(width: width, height: height) else { return nil }
        drawFrame(in: ctx, style: style, frame: frame,
                  foregroundColor: foregroundColor, backgroundColor: backgroundColor,
                  foregroundGradientEnd: foregroundGradientEnd, backgroundGradientEnd: backgroundGradientEnd,
                  backgroundImage: backgroundImage, waveformOpacity: waveformOpacity,
                  transparentBackground: transparentBackground)
        return ctx.makeImage()
    }

    /// Draws one frame into `ctx`, fully replacing its previous contents.
    static func drawFrame(
        in ctx: CGContext,
        style: SwiftWaveformStyle,
        frame: WaveformFrameInput,
        foregroundColor: RGB,
        backgroundColor: RGB,
        foregroundGradientEnd: RGB? = nil,
        backgroundGradientEnd: RGB? = nil,
        backgroundImage: CGImage? = nil,
        waveformOpacity: Double = 1.0,
        transparentBackground: Bool = false
    ) {
        let width = ctx.width
        let height = ctx.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)

        // Clear first so a reused context never leaks the previous frame through
        // transparent regions of a background image.
        ctx.clear(fullRect)

        let background = BackgroundSpec(color: backgroundColor, gradientEnd: backgroundGradientEnd,
                                        image: backgroundImage, isTransparent: transparentBackground)
        drawBackground(background, in: ctx, colorSpace: colorSpace)

        let bandMagnitudes = frame.magnitudes
        let bandCount = bandMagnitudes.count
        guard bandCount > 0 else { return }
        // Motion blur trail only makes sense when band counts match.
        let previousMagnitudes = frame.previousMagnitudes?.count == bandCount ? frame.previousMagnitudes : nil

        // --- Foreground waveform rendering ---
        let fgR = CGFloat(foregroundColor.r) / 255.0
        let fgG = CGFloat(foregroundColor.g) / 255.0
        let fgB = CGFloat(foregroundColor.b) / 255.0

        // Prepare gradient end colors for foreground (nil if no gradient)
        let fgEndR: CGFloat? = foregroundGradientEnd.map { CGFloat($0.r) / 255.0 }
        let fgEndG: CGFloat? = foregroundGradientEnd.map { CGFloat($0.g) / 255.0 }
        let fgEndB: CGFloat? = foregroundGradientEnd.map { CGFloat($0.b) / 255.0 }

        // Waveform opacity is applied to the whole foreground as one layer so
        // overlapping shapes (motion trail, wire fill + stroke) don't stack up
        // into visibly darker/brighter seams.
        let effectiveOpacity = CGFloat(min(1.0, max(0.5, waveformOpacity)))
        let usesLayer = effectiveOpacity < 1.0
        if usesLayer {
            ctx.setAlpha(effectiveOpacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }

        let layout = FrameLayout(width: width, height: height, bandCount: bandCount)

        switch style {
        case .capsules:
            renderCapsules(ctx: ctx, colorSpace: colorSpace, layout: layout,
                           bandMagnitudes: bandMagnitudes, previousMagnitudes: previousMagnitudes,
                           fgR: fgR, fgG: fgG, fgB: fgB,
                           fgEndR: fgEndR, fgEndG: fgEndG, fgEndB: fgEndB)
        case .bars:
            renderBars(ctx: ctx, colorSpace: colorSpace, layout: layout,
                       bandMagnitudes: bandMagnitudes, previousMagnitudes: previousMagnitudes,
                       fgR: fgR, fgG: fgG, fgB: fgB,
                       fgEndR: fgEndR, fgEndG: fgEndG, fgEndB: fgEndB)
        case .wire:
            renderWire(ctx: ctx, colorSpace: colorSpace, layout: layout,
                       bandMagnitudes: bandMagnitudes, previousMagnitudes: previousMagnitudes,
                       fgR: fgR, fgG: fgG, fgB: fgB,
                       fgEndR: fgEndR, fgEndG: fgEndG, fgEndB: fgEndB)
        case .halo, .orb, .ridgeline, .led:
            let palette = Palette(start: foregroundColor, end: foregroundGradientEnd)
            let input = WaveformFrameInput(
                magnitudes: bandMagnitudes,
                previousMagnitudes: previousMagnitudes,
                peakMagnitudes: frame.peakMagnitudes?.count == bandCount ? frame.peakMagnitudes : nil,
                history: frame.history.filter { $0.count == bandCount },
                historyPhase: frame.historyPhase,
                time: frame.time
            )
            switch style {
            case .halo:
                renderHalo(ctx: ctx, colorSpace: colorSpace, frame: input, palette: palette)
            case .orb:
                renderOrb(ctx: ctx, colorSpace: colorSpace, frame: input, palette: palette)
            case .ridgeline:
                renderRidgeline(ctx: ctx, colorSpace: colorSpace, frame: input, palette: palette,
                                background: background)
            case .led:
                renderLEDMeter(ctx: ctx, colorSpace: colorSpace, layout: layout, frame: input, palette: palette)
            case .capsules, .bars, .wire:
                break
            }
        }

        if usesLayer {
            ctx.endTransparencyLayer()
            ctx.setAlpha(1.0)
        }
    }

    static func cgColor(_ rgb: RGB, _ colorSpace: CGColorSpace) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [
            CGFloat(rgb.r) / 255.0, CGFloat(rgb.g) / 255.0, CGFloat(rgb.b) / 255.0, 1.0
        ]) ?? CGColor(gray: 0, alpha: 1)
    }

    // MARK: - Background

    struct BackgroundSpec {
        let color: RGB
        let gradientEnd: RGB?
        let image: CGImage?
        /// Leave the background empty (alpha export). A background image still wins.
        var isTransparent = false
    }

    /// Fills the current clip with the frame background (priority: image > transparent >
    /// gradient > solid). Also used by the ridgeline style to occlude lines behind each
    /// ridge — for a transparent background that means clearing to zero alpha.
    static func drawBackground(_ background: BackgroundSpec, in ctx: CGContext, colorSpace: CGColorSpace) {
        let fullRect = CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height)
        if background.isTransparent && background.image == nil {
            ctx.saveGState()
            ctx.setBlendMode(.clear)
            ctx.fill(fullRect)
            ctx.restoreGState()
        } else if let bgImage = background.image {
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1.0)
            ctx.fill(fullRect)
            ctx.draw(bgImage, in: fullRect)
        } else if let bgEnd = background.gradientEnd {
            let colors = [cgColor(background.color, colorSpace), cgColor(bgEnd, colorSpace)] as CFArray
            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
                // CGContext origin is bottom-left; visually top = y=height, bottom = y=0
                ctx.drawLinearGradient(gradient,
                    start: CGPoint(x: 0, y: fullRect.height),
                    end: CGPoint(x: 0, y: 0),
                    options: [])
            }
        } else {
            ctx.setFillColor(cgColor(background.color, colorSpace))
            ctx.fill(fullRect)
        }
    }

    // MARK: - Background Image Loading

    /// Loads an image from URL and pre-scales it to the target resolution.
    /// Call once before the render loop to avoid per-frame I/O.
    static func loadBackgroundImage(from url: URL, width: Int, height: Int) -> CGImage? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            logger.error("Failed to load background image from \(url.path)")
            return nil
        }

        // Pre-scale to target resolution
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return cgImage  // Return unscaled as fallback
        }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    // MARK: - Shared Layout

    struct FrameLayout {
        let frameWidth: CGFloat
        let frameHeight: CGFloat
        let centerY: CGFloat
        let maxBarHeight: CGFloat
        let horizontalPadding: CGFloat
        let availableWidth: CGFloat
        let bandStride: CGFloat
        let bandWidth: CGFloat
        let bandCount: Int

        init(width: Int, height: Int, bandCount: Int) {
            self.frameWidth = CGFloat(width)
            self.frameHeight = CGFloat(height)
            self.centerY = frameHeight / 2.0
            let vMargin = frameHeight * verticalMarginFraction
            self.maxBarHeight = frameHeight - 2 * vMargin
            self.horizontalPadding = frameWidth * horizontalPaddingFraction
            self.availableWidth = frameWidth - 2 * horizontalPadding
            self.bandStride = availableWidth / CGFloat(bandCount)
            self.bandWidth = bandStride / (1.0 + gapFraction)
            self.bandCount = bandCount
        }

        /// X position of the center of band at given index.
        func bandCenterX(_ band: Int) -> CGFloat {
            horizontalPadding + CGFloat(band) * bandStride + bandStride / 2.0
        }

        /// X position of the left edge of band at given index.
        func bandLeftX(_ band: Int) -> CGFloat {
            horizontalPadding + CGFloat(band) * bandStride + (bandStride - bandWidth) / 2.0
        }
    }

    // MARK: - Gradient Helper

    /// Draws a vertical gradient clipped to the current clipping path.
    private static func drawVerticalGradient(
        ctx: CGContext, colorSpace: CGColorSpace,
        startR: CGFloat, startG: CGFloat, startB: CGFloat,
        endR: CGFloat, endG: CGFloat, endB: CGFloat,
        fromY: CGFloat, toY: CGFloat, width: CGFloat
    ) {
        let colors = [
            CGColor(colorSpace: colorSpace, components: [startR, startG, startB, 1.0])!,
            CGColor(colorSpace: colorSpace, components: [endR, endG, endB, 1.0])!
        ] as CFArray
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) else { return }
        ctx.drawLinearGradient(gradient,
            start: CGPoint(x: 0, y: fromY),
            end: CGPoint(x: 0, y: toY),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    // MARK: - Capsules Style

    private static func renderCapsules(
        ctx: CGContext, colorSpace: CGColorSpace, layout: FrameLayout,
        bandMagnitudes: [Float], previousMagnitudes: [Float]?,
        fgR: CGFloat, fgG: CGFloat, fgB: CGFloat,
        fgEndR: CGFloat?, fgEndG: CGFloat?, fgEndB: CGFloat?
    ) {
        let cornerRadius = layout.bandWidth / 2.0
        let minHeight = layout.bandWidth  // Never shorter than a circle
        let hasGradient = fgEndR != nil && fgEndG != nil && fgEndB != nil

        // Motion blur pass (always solid color at low alpha)
        if let prevMags = previousMagnitudes {
            ctx.setFillColor(red: fgR, green: fgG, blue: fgB, alpha: 0.25)
            for band in 0..<layout.bandCount {
                let h = max(minHeight, CGFloat(clamp01(prevMags[band])) * layout.maxBarHeight)
                let x = layout.bandLeftX(band)
                let y = layout.centerY - h / 2.0
                let path = CGPath(roundedRect: CGRect(x: x, y: y, width: layout.bandWidth, height: h),
                                  cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                ctx.addPath(path)
                ctx.fillPath()
            }
        }

        // Main pass
        if hasGradient {
            for band in 0..<layout.bandCount {
                let h = max(minHeight, CGFloat(clamp01(bandMagnitudes[band])) * layout.maxBarHeight)
                let x = layout.bandLeftX(band)
                let y = layout.centerY - h / 2.0
                let path = CGPath(roundedRect: CGRect(x: x, y: y, width: layout.bandWidth, height: h),
                                  cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                // Gradient from center (start color) to both ends (end color),
                // mirrored like the bars style.
                for (edgeY, halfRect) in [
                    (y, CGRect(x: x, y: y, width: layout.bandWidth, height: h / 2.0)),
                    (y + h, CGRect(x: x, y: layout.centerY, width: layout.bandWidth, height: h / 2.0)),
                ] {
                    ctx.saveGState()
                    ctx.addPath(path)
                    ctx.clip()
                    ctx.clip(to: halfRect)
                    drawVerticalGradient(ctx: ctx, colorSpace: colorSpace,
                                         startR: fgR, startG: fgG, startB: fgB,
                                         endR: fgEndR!, endG: fgEndG!, endB: fgEndB!,
                                         fromY: layout.centerY, toY: edgeY,
                                         width: layout.frameWidth)
                    ctx.restoreGState()
                }
            }
        } else {
            ctx.setFillColor(red: fgR, green: fgG, blue: fgB, alpha: 1.0)
            for band in 0..<layout.bandCount {
                let h = max(minHeight, CGFloat(clamp01(bandMagnitudes[band])) * layout.maxBarHeight)
                let x = layout.bandLeftX(band)
                let y = layout.centerY - h / 2.0
                let path = CGPath(roundedRect: CGRect(x: x, y: y, width: layout.bandWidth, height: h),
                                  cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                ctx.addPath(path)
                ctx.fillPath()
            }
        }
    }

    // MARK: - Bars Style (mirrored equalizer)

    private static func renderBars(
        ctx: CGContext, colorSpace: CGColorSpace, layout: FrameLayout,
        bandMagnitudes: [Float], previousMagnitudes: [Float]?,
        fgR: CGFloat, fgG: CGFloat, fgB: CGFloat,
        fgEndR: CGFloat?, fgEndG: CGFloat?, fgEndB: CGFloat?
    ) {
        let minHalfHeight: CGFloat = 2  // Minimum pixel height per half
        let hasGradient = fgEndR != nil && fgEndG != nil && fgEndB != nil

        // Motion blur pass (solid color at low alpha)
        if let prevMags = previousMagnitudes {
            ctx.setFillColor(red: fgR, green: fgG, blue: fgB, alpha: 0.20)
            for band in 0..<layout.bandCount {
                let halfH = max(minHalfHeight, CGFloat(clamp01(prevMags[band])) * layout.maxBarHeight / 2.0)
                let x = layout.bandLeftX(band)
                ctx.fill(CGRect(x: x, y: layout.centerY - halfH, width: layout.bandWidth, height: halfH))
                ctx.fill(CGRect(x: x, y: layout.centerY, width: layout.bandWidth, height: halfH))
            }
        }

        // Main pass
        if hasGradient {
            for band in 0..<layout.bandCount {
                let halfH = max(minHalfHeight, CGFloat(clamp01(bandMagnitudes[band])) * layout.maxBarHeight / 2.0)
                let x = layout.bandLeftX(band)
                let topRect = CGRect(x: x, y: layout.centerY - halfH, width: layout.bandWidth, height: halfH)
                let bottomRect = CGRect(x: x, y: layout.centerY, width: layout.bandWidth, height: halfH)

                // Top half: gradient from center (start) to top (end)
                ctx.saveGState()
                ctx.clip(to: [topRect])
                drawVerticalGradient(ctx: ctx, colorSpace: colorSpace,
                                     startR: fgR, startG: fgG, startB: fgB,
                                     endR: fgEndR!, endG: fgEndG!, endB: fgEndB!,
                                     fromY: layout.centerY, toY: layout.centerY - halfH,
                                     width: layout.frameWidth)
                ctx.restoreGState()

                // Bottom half: gradient from center (start) to bottom (end)
                ctx.saveGState()
                ctx.clip(to: [bottomRect])
                drawVerticalGradient(ctx: ctx, colorSpace: colorSpace,
                                     startR: fgR, startG: fgG, startB: fgB,
                                     endR: fgEndR!, endG: fgEndG!, endB: fgEndB!,
                                     fromY: layout.centerY, toY: layout.centerY + halfH,
                                     width: layout.frameWidth)
                ctx.restoreGState()
            }
        } else {
            ctx.setFillColor(red: fgR, green: fgG, blue: fgB, alpha: 1.0)
            for band in 0..<layout.bandCount {
                let halfH = max(minHalfHeight, CGFloat(clamp01(bandMagnitudes[band])) * layout.maxBarHeight / 2.0)
                let x = layout.bandLeftX(band)
                ctx.fill(CGRect(x: x, y: layout.centerY - halfH, width: layout.bandWidth, height: halfH))
                ctx.fill(CGRect(x: x, y: layout.centerY, width: layout.bandWidth, height: halfH))
            }
        }
    }

    // MARK: - Wire Style (smooth curve with filled area)

    private static func renderWire(
        ctx: CGContext, colorSpace: CGColorSpace, layout: FrameLayout,
        bandMagnitudes: [Float], previousMagnitudes: [Float]?,
        fgR: CGFloat, fgG: CGFloat, fgB: CGFloat,
        fgEndR: CGFloat?, fgEndG: CGFloat?, fgEndB: CGFloat?
    ) {
        let vMargin = layout.frameHeight * verticalMarginFraction
        let hasGradient = fgEndR != nil && fgEndG != nil && fgEndB != nil

        // Motion blur: previous curve at low opacity (solid color)
        if let prevMags = previousMagnitudes {
            ctx.setFillColor(red: fgR, green: fgG, blue: fgB, alpha: 0.15)
            drawWireCurve(ctx: ctx, layout: layout, magnitudes: prevMags, vMargin: vMargin, mirrored: true)
        }

        // Main curve — filled area between curve and center, mirrored
        if hasGradient {
            // Top half with gradient
            let topPath = buildWireFillPath(layout: layout, magnitudes: bandMagnitudes, above: true)
            if let topPath {
                ctx.saveGState()
                ctx.addPath(topPath)
                ctx.clip()
                let halfMax = layout.maxBarHeight / 2.0
                drawVerticalGradient(ctx: ctx, colorSpace: colorSpace,
                                     startR: fgR, startG: fgG, startB: fgB,
                                     endR: fgEndR!, endG: fgEndG!, endB: fgEndB!,
                                     fromY: layout.centerY, toY: layout.centerY + halfMax,
                                     width: layout.frameWidth)
                ctx.restoreGState()
            }

            // Bottom half with gradient (mirrored)
            let bottomPath = buildWireFillPath(layout: layout, magnitudes: bandMagnitudes, above: false)
            if let bottomPath {
                ctx.saveGState()
                ctx.addPath(bottomPath)
                ctx.clip()
                let halfMax = layout.maxBarHeight / 2.0
                drawVerticalGradient(ctx: ctx, colorSpace: colorSpace,
                                     startR: fgR, startG: fgG, startB: fgB,
                                     endR: fgEndR!, endG: fgEndG!, endB: fgEndB!,
                                     fromY: layout.centerY, toY: layout.centerY - halfMax,
                                     width: layout.frameWidth)
                ctx.restoreGState()
            }
        } else {
            ctx.setFillColor(red: fgR, green: fgG, blue: fgB, alpha: 1.0)
            drawWireCurve(ctx: ctx, layout: layout, magnitudes: bandMagnitudes, vMargin: vMargin, mirrored: true)
        }

        // Stroke the outline on top for crispness (always solid)
        ctx.setStrokeColor(red: fgR, green: fgG, blue: fgB, alpha: 1.0)
        ctx.setLineWidth(max(1.5, layout.bandWidth * 0.15))
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        drawWireStroke(ctx: ctx, layout: layout, magnitudes: bandMagnitudes, vMargin: vMargin, above: true)
        drawWireStroke(ctx: ctx, layout: layout, magnitudes: bandMagnitudes, vMargin: vMargin, above: false)
    }

    /// Builds the array of (x, magnitude) points for the wire curve,
    /// including virtual zero-magnitude anchors at the frame edges so
    /// the curve extends edge-to-edge and tapers to flat.
    private static func wirePoints(layout: FrameLayout, magnitudes: [Float]) -> [(x: CGFloat, mag: CGFloat)] {
        var pts = [(x: CGFloat, mag: CGFloat)]()
        // Left edge anchor at zero
        pts.append((x: 0, mag: 0))
        // Actual band data
        for band in 0..<layout.bandCount {
            pts.append((x: layout.bandCenterX(band), mag: CGFloat(clamp01(magnitudes[band]))))
        }
        // Right edge anchor at zero
        pts.append((x: layout.frameWidth, mag: 0))
        return pts
    }

    /// Appends a smooth curve through `pts` (after the first, which must already be
    /// the current point) using cubic segments with horizontal tangents at each
    /// band peak. This keeps the curve symmetric between neighbours and never
    /// overshoots below the center line.
    static func addSmoothCurve(to path: CGMutablePath, points: [CGPoint]) {
        guard points.count > 1 else { return }
        for i in 1..<points.count {
            let p0 = points[i - 1]
            let p1 = points[i]
            let midX = (p0.x + p1.x) / 2.0
            path.addCurve(to: p1,
                          control1: CGPoint(x: midX, y: p0.y),
                          control2: CGPoint(x: midX, y: p1.y))
        }
    }

    /// Curve points for one half of the wire (above = +y in CG coordinates).
    private static func wireCurvePoints(layout: FrameLayout, magnitudes: [Float], above: Bool) -> [CGPoint] {
        let halfMax = layout.maxBarHeight / 2.0
        let sign: CGFloat = above ? 1.0 : -1.0
        return wirePoints(layout: layout, magnitudes: magnitudes).map {
            CGPoint(x: $0.x, y: layout.centerY + sign * $0.mag * halfMax)
        }
    }

    /// Builds a CGMutablePath for one half (top or bottom) of the wire fill area.
    private static func buildWireFillPath(layout: FrameLayout, magnitudes: [Float], above: Bool) -> CGMutablePath? {
        let pts = wireCurvePoints(layout: layout, magnitudes: magnitudes, above: above)
        guard pts.count > 2, let first = pts.first, let last = pts.last else { return nil }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: first.x, y: layout.centerY))
        path.addLine(to: first)
        addSmoothCurve(to: path, points: pts)
        path.addLine(to: CGPoint(x: last.x, y: layout.centerY))
        path.closeSubpath()
        return path
    }

    /// Draws a filled area between the curve and center line, optionally mirrored.
    private static func drawWireCurve(
        ctx: CGContext, layout: FrameLayout,
        magnitudes: [Float], vMargin: CGFloat, mirrored: Bool
    ) {
        if let topPath = buildWireFillPath(layout: layout, magnitudes: magnitudes, above: true) {
            ctx.addPath(topPath)
        }
        if mirrored, let bottomPath = buildWireFillPath(layout: layout, magnitudes: magnitudes, above: false) {
            ctx.addPath(bottomPath)
        }
        ctx.fillPath()
    }

    /// Strokes just the curve outline (top or bottom half).
    private static func drawWireStroke(
        ctx: CGContext, layout: FrameLayout,
        magnitudes: [Float], vMargin: CGFloat, above: Bool
    ) {
        let pts = wireCurvePoints(layout: layout, magnitudes: magnitudes, above: above)
        guard pts.count > 2, let first = pts.first else { return }
        let path = CGMutablePath()
        path.move(to: first)
        addSmoothCurve(to: path, points: pts)
        ctx.addPath(path)
        ctx.strokePath()
    }

    // MARK: - Helpers

    static func clamp01(_ value: Float) -> Float {
        max(0, min(1, value))
    }
}
