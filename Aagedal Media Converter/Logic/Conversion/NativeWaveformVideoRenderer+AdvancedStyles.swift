// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Advanced native waveform styles: halo (radial spokes), orb (rotating blob),
// ridgeline (scrolling stacked spectra) and LED meter (segments + peak hold).

import Foundation
import CoreGraphics

extension NativeWaveformVideoRenderer {

    // MARK: - Palette

    /// Foreground colors for the advanced styles. With a gradient enabled,
    /// `color(at:)` interpolates start → end; otherwise it is always the start color.
    struct Palette {
        let start: (r: CGFloat, g: CGFloat, b: CGFloat)
        let end: (r: CGFloat, g: CGFloat, b: CGFloat)?

        init(start: RGB, end: RGB?) {
            self.start = (CGFloat(start.r) / 255, CGFloat(start.g) / 255, CGFloat(start.b) / 255)
            self.end = end.map { (CGFloat($0.r) / 255, CGFloat($0.g) / 255, CGFloat($0.b) / 255) }
        }

        var hasGradient: Bool { end != nil }

        func color(at t: CGFloat, alpha: CGFloat = 1, colorSpace: CGColorSpace) -> CGColor {
            let e = end ?? start
            let t = max(0, min(1, t))
            let components = [
                start.r + (e.r - start.r) * t,
                start.g + (e.g - start.g) * t,
                start.b + (e.b - start.b) * t,
                max(0, min(1, alpha)),
            ]
            return CGColor(colorSpace: colorSpace, components: components) ?? CGColor(gray: 1, alpha: alpha)
        }

        func gradient(colorSpace: CGColorSpace) -> CGGradient? {
            guard hasGradient else { return nil }
            let colors = [color(at: 0, colorSpace: colorSpace), color(at: 1, colorSpace: colorSpace)] as CFArray
            return CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])
        }
    }

    // MARK: - Shared Radial Helpers

    /// Band index for point `index` of a ring of `2 * bandCount` points that is
    /// mirrored left/right, so bass sits at the top and treble meets at the bottom.
    private static func mirroredBand(_ index: Int, bandCount: Int) -> Int {
        index < bandCount ? index : 2 * bandCount - 1 - index
    }

    /// Average level of the lowest bands (drives the pulsing ring/core).
    private static func bassEnergy(_ magnitudes: [Float]) -> CGFloat {
        let count = max(1, magnitudes.count / 8)
        let sum = magnitudes.prefix(count).reduce(Float(0)) { $0 + clamp01($1) }
        return CGFloat(sum / Float(count))
    }

    /// Unit direction for the angle (radians, CG coordinates: y up).
    private static func direction(_ angle: CGFloat) -> CGPoint {
        CGPoint(x: cos(angle), y: sin(angle))
    }

    /// Closed Catmull–Rom spline through `points`, converted to cubic Béziers.
    private static func closedSmoothPath(_ points: [CGPoint]) -> CGMutablePath {
        let path = CGMutablePath()
        let n = points.count
        guard n > 2 else { return path }
        path.move(to: points[0])
        for i in 0..<n {
            let p0 = points[(i - 1 + n) % n]
            let p1 = points[i]
            let p2 = points[(i + 1) % n]
            let p3 = points[(i + 2) % n]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Halo Style (radial spokes around a pulsing ring)

    static func renderHalo(
        ctx: CGContext, colorSpace: CGColorSpace,
        frame: WaveformFrameInput, palette: Palette
    ) {
        let width = CGFloat(ctx.width)
        let height = CGFloat(ctx.height)
        let center = CGPoint(x: width / 2, y: height / 2)
        let minDim = min(width, height)
        let bandCount = frame.magnitudes.count

        let bass = bassEnergy(frame.magnitudes)
        let ringRadius = minDim * (0.16 + 0.035 * bass)
        let maxSpoke = minDim * 0.26
        let spokeCount = bandCount * 2
        let step = 2 * CGFloat.pi / CGFloat(spokeCount)
        let lineWidth = max(1.5, min(ringRadius * step * 0.6, minDim * 0.03))
        let innerRadius = ringRadius + lineWidth * 1.5

        func spokesPath(_ levels: [Float]) -> CGMutablePath {
            let path = CGMutablePath()
            for i in 0..<spokeCount {
                let band = mirroredBand(i, bandCount: bandCount)
                let length = max(lineWidth * 0.25, CGFloat(clamp01(levels[band])) * maxSpoke)
                let dir = direction(CGFloat.pi / 2 - (CGFloat(i) + 0.5) * step)
                path.move(to: CGPoint(x: center.x + dir.x * innerRadius, y: center.y + dir.y * innerRadius))
                path.addLine(to: CGPoint(x: center.x + dir.x * (innerRadius + length),
                                         y: center.y + dir.y * (innerRadius + length)))
            }
            return path
        }

        // Soft inner glow and ring, both breathing with the bass.
        let glowRadius = ringRadius * 0.92
        ctx.setFillColor(palette.color(at: 0, alpha: 0.06 + 0.22 * bass, colorSpace: colorSpace))
        ctx.fillEllipse(in: CGRect(x: center.x - glowRadius, y: center.y - glowRadius,
                                   width: glowRadius * 2, height: glowRadius * 2))
        ctx.setStrokeColor(palette.color(at: 0, alpha: 0.9, colorSpace: colorSpace))
        ctx.setLineWidth(max(1, lineWidth * 0.45))
        ctx.strokeEllipse(in: CGRect(x: center.x - ringRadius, y: center.y - ringRadius,
                                     width: ringRadius * 2, height: ringRadius * 2))

        ctx.setLineCap(.round)
        ctx.setLineWidth(lineWidth)

        // Motion trail
        if let previous = frame.previousMagnitudes {
            ctx.setStrokeColor(palette.color(at: 0, alpha: 0.22, colorSpace: colorSpace))
            ctx.addPath(spokesPath(previous))
            ctx.strokePath()
        }

        // Main spokes: radial gradient from the ring outwards.
        let spokes = spokesPath(frame.magnitudes)
        if let gradient = palette.gradient(colorSpace: colorSpace) {
            ctx.saveGState()
            ctx.addPath(spokes)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.drawRadialGradient(gradient,
                                   startCenter: center, startRadius: innerRadius,
                                   endCenter: center, endRadius: innerRadius + maxSpoke,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        } else {
            ctx.setStrokeColor(palette.color(at: 0, colorSpace: colorSpace))
            ctx.addPath(spokes)
            ctx.strokePath()
        }
    }

    // MARK: - Orb Style (rotating blob with peak outline and counter-rotating core)

    static func renderOrb(
        ctx: CGContext, colorSpace: CGColorSpace,
        frame: WaveformFrameInput, palette: Palette
    ) {
        let width = CGFloat(ctx.width)
        let height = CGFloat(ctx.height)
        let center = CGPoint(x: width / 2, y: height / 2)
        let minDim = min(width, height)
        let bandCount = frame.magnitudes.count

        let baseRadius = minDim * 0.2
        let amplitude = minDim * 0.2
        let rotation = CGFloat(frame.time * 0.25)  // radians per second
        let pointCount = bandCount * 2
        let step = 2 * CGFloat.pi / CGFloat(pointCount)

        func blobPath(_ levels: [Float], base: CGFloat, amp: CGFloat,
                      rotation: CGFloat, reversed: Bool = false) -> CGMutablePath {
            let points = (0..<pointCount).map { i -> CGPoint in
                var band = mirroredBand(i, bandCount: bandCount)
                if reversed { band = bandCount - 1 - band }
                let radius = base + CGFloat(clamp01(levels[band])) * amp
                let dir = direction(CGFloat.pi / 2 + rotation - CGFloat(i) * step)
                return CGPoint(x: center.x + dir.x * radius, y: center.y + dir.y * radius)
            }
            return closedSmoothPath(points)
        }

        ctx.setLineJoin(.round)

        // Peak-hold outline
        if let peaks = frame.peakMagnitudes {
            ctx.setStrokeColor(palette.color(at: 1, alpha: 0.35, colorSpace: colorSpace))
            ctx.setLineWidth(max(1, minDim * 0.003))
            ctx.addPath(blobPath(peaks, base: baseRadius, amp: amplitude, rotation: rotation))
            ctx.strokePath()
        }

        // Motion trail
        if let previous = frame.previousMagnitudes {
            ctx.setFillColor(palette.color(at: 0, alpha: 0.15, colorSpace: colorSpace))
            ctx.addPath(blobPath(previous, base: baseRadius, amp: amplitude, rotation: rotation))
            ctx.fillPath()
        }

        // Main blob
        let main = blobPath(frame.magnitudes, base: baseRadius, amp: amplitude, rotation: rotation)
        if let gradient = palette.gradient(colorSpace: colorSpace) {
            ctx.saveGState()
            ctx.addPath(main)
            ctx.clip()
            ctx.drawRadialGradient(gradient,
                                   startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: baseRadius + amplitude,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            ctx.restoreGState()
        } else {
            ctx.setFillColor(palette.color(at: 0, alpha: 0.35, colorSpace: colorSpace))
            ctx.addPath(main)
            ctx.fillPath()
        }
        ctx.setStrokeColor(palette.color(at: 0, colorSpace: colorSpace))
        ctx.setLineWidth(max(1.5, minDim * 0.006))
        ctx.addPath(main)
        ctx.strokePath()

        // Counter-rotating core led by the treble bands.
        let core = blobPath(frame.magnitudes, base: baseRadius * 0.45, amp: amplitude * 0.3,
                            rotation: -rotation * 1.6, reversed: true)
        ctx.setFillColor(palette.color(at: palette.hasGradient ? 1 : 0, alpha: 0.85, colorSpace: colorSpace))
        ctx.addPath(core)
        ctx.fillPath()
    }

    // MARK: - Ridgeline Style (stacked spectra scrolling into the distance)

    static func renderRidgeline(
        ctx: CGContext, colorSpace: CGColorSpace,
        frame: WaveformFrameInput, palette: Palette,
        background: BackgroundSpec
    ) {
        let width = CGFloat(ctx.width)
        let height = CGFloat(ctx.height)
        let lineCount = WaveformAnimationState.ridgeLineCount
        let maxDepth = CGFloat(max(1, lineCount - 1))

        // Current frame at the front, sampled history behind it. Ages are in
        // line units and grow continuously so the stack scrolls smoothly.
        var lines: [(age: CGFloat, levels: [Float])] = [(0, frame.magnitudes)]
        for (index, levels) in frame.history.enumerated() {
            let age = CGFloat(index) + CGFloat(frame.historyPhase)
            // Age 0 is the current frame itself (sampled this very frame).
            guard age > 0.01, age < CGFloat(lineCount) else { continue }
            lines.append((age, levels))
        }
        lines.sort { $0.age > $1.age }  // back to front

        let frontBaseline = height * 0.12
        let depthSpan = height * 0.6
        let centerX = width / 2

        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        for line in lines {
            let depth = line.age / maxDepth  // 0 = front, 1 = back
            // Fade the oldest line out as it scrolls off the back.
            let fade = max(0, min(1, CGFloat(lineCount) - line.age))
            guard fade > 0 else { continue }

            let baseline = frontBaseline + depth * depthSpan
            let amplitude = height * 0.24 * (1 - 0.3 * depth)
            let perspective = 1 - 0.2 * depth
            let points = ridgePoints(line.levels, centerX: centerX, baseline: baseline,
                                     amplitude: amplitude,
                                     halfWidth: width * 0.36 * perspective,
                                     tailHalfWidth: width * 0.44 * perspective)
            guard let first = points.first, let last = points.last else { continue }

            let curve = CGMutablePath()
            curve.move(to: first)
            addSmoothCurve(to: curve, points: points)

            // Occlude the ridges behind by repainting the background under this
            // one. Lines further back never dip below their own (higher)
            // baseline, so the repaint only has to reach just below this one's.
            let lineWidth = max(1.2, height * 0.0035) * (1 - 0.35 * depth)
            let occlusionBottom = baseline - lineWidth
            let fill = curve.mutableCopy() ?? CGMutablePath()
            fill.addLine(to: CGPoint(x: last.x, y: occlusionBottom))
            fill.addLine(to: CGPoint(x: first.x, y: occlusionBottom))
            fill.closeSubpath()
            ctx.saveGState()
            ctx.addPath(fill)
            ctx.clip()
            drawBackground(background, in: ctx, colorSpace: colorSpace)
            ctx.restoreGState()

            ctx.setStrokeColor(palette.color(at: depth, alpha: (1 - 0.55 * depth) * fade, colorSpace: colorSpace))
            ctx.setLineWidth(lineWidth)
            ctx.addPath(curve)
            ctx.strokePath()
        }
    }

    /// Ridge profile: bands mirrored outward from the center (bass in the middle),
    /// tapered towards the sides, with flat tails out to `tailHalfWidth`.
    private static func ridgePoints(
        _ levels: [Float], centerX: CGFloat, baseline: CGFloat,
        amplitude: CGFloat, halfWidth: CGFloat, tailHalfWidth: CGFloat
    ) -> [CGPoint] {
        let bandCount = levels.count
        guard bandCount > 0 else { return [] }
        let span = max(1, bandCount - 1)
        var points = [CGPoint(x: centerX - tailHalfWidth, y: baseline)]
        for k in -(bandCount - 1)...(bandCount - 1) {
            let u = CGFloat(abs(k)) / CGFloat(span)
            let taper = 0.15 + 0.85 * pow(1 - u * u, 1.5)
            let level = CGFloat(clamp01(levels[abs(k)]))
            points.append(CGPoint(x: centerX + CGFloat(k) / CGFloat(span) * halfWidth,
                                  y: baseline + level * taper * amplitude))
        }
        points.append(CGPoint(x: centerX + tailHalfWidth, y: baseline))
        return points
    }

    // MARK: - LED Meter Style (segmented columns with peak hold)

    static func renderLEDMeter(
        ctx: CGContext, colorSpace: CGColorSpace, layout: FrameLayout,
        frame: WaveformFrameInput, palette: Palette
    ) {
        let bandCount = layout.bandCount
        let bottom = layout.frameHeight * verticalMarginFraction
        let available = layout.maxBarHeight
        let targetPitch = max(4, layout.bandWidth * 0.6)
        let segmentCount = max(8, min(48, Int(available / targetPitch)))
        let pitch = available / CGFloat(segmentCount)
        let segmentHeight = pitch * 0.7
        let corner = min(segmentHeight, layout.bandWidth) * 0.22

        func litSegments(_ level: Float) -> Int {
            let v = clamp01(level)
            return v < 0.01 ? 0 : min(segmentCount, Int(ceil(v * Float(segmentCount))))
        }
        let lit = frame.magnitudes.map(litSegments)
        let trailLit = frame.previousMagnitudes?.map(litSegments)
        let peakSegment: [Int?] = (0..<bandCount).map { band in
            guard let peak = frame.peakMagnitudes?[band], clamp01(peak) > 0.02 else { return nil }
            return min(segmentCount - 1, Int(clamp01(peak) * Float(segmentCount)))
        }

        // One fill per row and state: color only varies with height.
        for segment in 0..<segmentCount {
            let t = CGFloat(segment) / CGFloat(max(1, segmentCount - 1))
            let y = bottom + CGFloat(segment) * pitch + (pitch - segmentHeight) / 2
            let on = CGMutablePath()
            let trail = CGMutablePath()
            let off = CGMutablePath()
            for band in 0..<bandCount {
                let rect = CGRect(x: layout.bandLeftX(band), y: y, width: layout.bandWidth, height: segmentHeight)
                let target: CGMutablePath
                if segment < lit[band] || peakSegment[band] == segment {
                    target = on
                } else if let trailLit, segment < trailLit[band] {
                    target = trail
                } else {
                    target = off
                }
                target.addRoundedRect(in: rect, cornerWidth: corner, cornerHeight: corner)
            }
            for (path, alpha) in [(off, 0.07), (trail, 0.3), (on, 1.0)] where !path.isEmpty {
                ctx.setFillColor(palette.color(at: t, alpha: alpha, colorSpace: colorSpace))
                ctx.addPath(path)
                ctx.fillPath()
            }
        }
    }
}
