// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import CoreGraphics

/// Represents crop configuration for a video item
/// Stores crop rectangle in normalized coordinates (0.0 to 1.0) for resolution independence
struct CropConfig: Equatable, Sendable, Codable {
    /// Crop rectangle in normalized coordinates (0.0 to 1.0)
    /// Normalized coordinates are resolution-independent and survive preset changes
    var normalizedRect: CropRect

    /// Optional aspect ratio lock (nil = free-form)
    var aspectRatioLock: AspectRatio? = nil

    init(normalizedRect: CropRect, aspectRatioLock: AspectRatio? = nil) {
        self.normalizedRect = normalizedRect
        self.aspectRatioLock = aspectRatioLock
    }

    /// Locks to `ratio` (`.free` unlocks) and reshapes the box to match it.
    mutating func lockAspectRatio(_ ratio: AspectRatio, using editor: CropEditor) {
        aspectRatioLock = ratio == .free ? nil : ratio
        if let numericRatio = ratio.numericRatio {
            normalizedRect = editor.fitted(normalizedRect, to: numericRatio)
        }
    }

    /// Returns true if crop differs from full frame (no crop)
    var isActive: Bool {
        !normalizedRect.isFullFrame
    }

    /// Converts normalized rect to pixel coordinates for given dimensions
    func pixelRect(sourceWidth: Int, sourceHeight: Int) -> PixelCropRect {
        normalizedRect.toPixelRect(width: sourceWidth, height: sourceHeight)
    }

    /// Creates config from pixel coordinates (for UI input)
    static func fromPixelRect(
        _ pixelRect: PixelCropRect,
        sourceWidth: Int,
        sourceHeight: Int,
        aspectRatioLock: AspectRatio? = nil
    ) -> CropConfig {
        let normalized = CropRect.fromPixelRect(
            pixelRect,
            width: sourceWidth,
            height: sourceHeight
        )
        return CropConfig(normalizedRect: normalized, aspectRatioLock: aspectRatioLock)
    }
}

/// Normalized crop rectangle (0.0 to 1.0 coordinates)
/// These coordinates are resolution-independent and can be applied to any source resolution
struct CropRect: Equatable, Sendable, Codable {
    var x: Double      // 0.0 = left edge, 1.0 = right edge
    var y: Double      // 0.0 = top edge, 1.0 = bottom edge
    var width: Double  // 0.0 to 1.0 of frame width
    var height: Double // 0.0 to 1.0 of frame height

    /// Full frame crop (no crop applied)
    static let fullFrame = CropRect(x: 0, y: 0, width: 1, height: 1)

    /// Returns true if this represents a full frame (no crop)
    var isFullFrame: Bool {
        abs(x) < 0.001 && abs(y) < 0.001 &&
        abs(width - 1.0) < 0.001 && abs(height - 1.0) < 0.001
    }

    /// Converts normalized coordinates to pixel coordinates for a given resolution
    func toPixelRect(width: Int, height: Int) -> PixelCropRect {
        PixelCropRect(
            x: Int((x * Double(width)).rounded()),
            y: Int((y * Double(height)).rounded()),
            width: Int((self.width * Double(width)).rounded()),
            height: Int((self.height * Double(height)).rounded())
        )
    }

    /// Creates normalized coordinates from pixel coordinates
    static func fromPixelRect(_ pixel: PixelCropRect, width: Int, height: Int) -> CropRect {
        guard width > 0, height > 0 else { return .fullFrame }
        return CropRect(
            x: Double(pixel.x) / Double(width),
            y: Double(pixel.y) / Double(height),
            width: Double(pixel.width) / Double(width),
            height: Double(pixel.height) / Double(height)
        )
    }
}

/// Pixel-based crop rectangle for UI display and FFMPEG command construction
struct PixelCropRect: Equatable, Sendable, Codable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    /// Ensures dimensions are even (required by most video codecs)
    /// Many video codecs require even dimensions for chroma subsampling
    func evenDimensions() -> PixelCropRect {
        PixelCropRect(
            x: x,
            y: y,
            width: (width / 2) * 2,  // Round down to nearest even number
            height: (height / 2) * 2
        )
    }

    /// Clamps crop rectangle to source dimensions
    /// Ensures crop doesn't exceed source bounds and maintains minimum size
    func clamped(maxWidth: Int, maxHeight: Int) -> PixelCropRect {
        // Ensure position is within bounds
        let clampedX = max(0, min(x, maxWidth - 2))
        let clampedY = max(0, min(y, maxHeight - 2))

        // Ensure size is within bounds and minimum 2x2
        let clampedWidth = max(2, min(width, maxWidth - clampedX))
        let clampedHeight = max(2, min(height, maxHeight - clampedY))

        return PixelCropRect(
            x: clampedX,
            y: clampedY,
            width: clampedWidth,
            height: clampedHeight
        )
    }
}

/// Common aspect ratios for crop constraints
enum AspectRatio: String, CaseIterable, Identifiable, Sendable, Codable {
    case free = "Free"
    case ratio21_9 = "21:9"
    case ratio16_9 = "16:9"
    case ratio3_2 = "3:2"
    case ratio4_3 = "4:3"
    case ratio1_1 = "1:1 (Square)"
    case ratio3_4 = "3:4"
    case ratio2_3 = "2:3"
    case ratio9_16 = "9:16 (Vertical)"

    var id: String { rawValue }

    var displayName: String { rawValue }

    /// Numeric ratio (width / height), nil for free-form
    var numericRatio: Double? {
        switch self {
        case .free: return nil
        case .ratio21_9: return 21.0 / 9.0
        case .ratio16_9: return 16.0 / 9.0
        case .ratio3_2: return 3.0 / 2.0
        case .ratio4_3: return 4.0 / 3.0
        case .ratio1_1: return 1.0
        case .ratio3_4: return 3.0 / 4.0
        case .ratio2_3: return 2.0 / 3.0
        case .ratio9_16: return 9.0 / 16.0
        }
    }
}

// MARK: - Crop Frame

/// The frame crop coordinates refer to, oriented the way the preview shows it and the way
/// FFmpeg's filters see it (after autorotation). Normalized crop rects are fractions of this
/// frame's pixel grid, which may be anamorphic: `displayAspectRatio` is the shape on screen.
struct CropFrame: Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    /// Width / height of the displayed picture, including pixel aspect ratio.
    let displayAspectRatio: Double

    init(pixelWidth: Int, pixelHeight: Int, displayAspectRatio: Double? = nil) {
        self.pixelWidth = max(pixelWidth, 1)
        self.pixelHeight = max(pixelHeight, 1)
        let storageAspect = Double(self.pixelWidth) / Double(self.pixelHeight)
        if let displayAspectRatio, displayAspectRatio.isFinite, displayAspectRatio > 0 {
            self.displayAspectRatio = displayAspectRatio
        } else {
            self.displayAspectRatio = storageAspect
        }
    }

    /// Width of one stored pixel relative to its height.
    var pixelAspectRatio: Double {
        displayAspectRatio * Double(pixelHeight) / Double(pixelWidth)
    }

    /// Encoded size of an active crop: the even-sized pixel area, widened to square pixels
    /// for anamorphic sources exactly as `FFMPEGCommandBuilder.applyCropToVideoFilter` does.
    func outputSize(for config: CropConfig) -> (width: Int, height: Int)? {
        guard let plan = CropGeometryPlan(config: config, sourceWidth: pixelWidth, sourceHeight: pixelHeight) else {
            return nil
        }
        guard abs(pixelAspectRatio - 1) > 0.01 else { return (plan.rect.width, plan.rect.height) }
        return CropGeometryPlan.squarePixelDimensions(
            width: plan.rect.width, height: plan.rect.height,
            pixelAspectRatio: pixelAspectRatio, roundWidthUp: true
        )
    }
}

// MARK: - Crop Editing

/// The part of the crop box a pointer interaction grabs.
enum CropHandle: Sendable, CaseIterable {
    case move
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// -1 when the left edge moves, 1 when the right edge moves, 0 when neither does.
    var horizontal: Int {
        switch self {
        case .topLeft, .left, .bottomLeft: -1
        case .topRight, .right, .bottomRight: 1
        case .move, .top, .bottom: 0
        }
    }

    /// -1 when the top edge moves, 1 when the bottom edge moves, 0 when neither does.
    var vertical: Int {
        switch self {
        case .topLeft, .top, .topRight: -1
        case .bottomLeft, .bottom, .bottomRight: 1
        case .move, .left, .right: 0
        }
    }

    var isCorner: Bool { horizontal != 0 && vertical != 0 }

    /// Finds the handle under `point` for a crop box drawn at `rect` (both in view coordinates).
    /// Edges are grabbable along their whole length, `tolerance` points outside the box and up
    /// to a quarter of the box inside it, so small boxes can still be moved.
    static func hitTest(_ point: CGPoint, in rect: CGRect, tolerance: CGFloat = 10) -> CropHandle? {
        let inner = max(0, min(tolerance, rect.width / 4, rect.height / 4))
        guard point.x >= rect.minX - tolerance, point.x <= rect.maxX + tolerance,
              point.y >= rect.minY - tolerance, point.y <= rect.maxY + tolerance else { return nil }

        let nearLeft = point.x <= rect.minX + inner
        let nearRight = point.x >= rect.maxX - inner
        let nearTop = point.y <= rect.minY + inner
        let nearBottom = point.y >= rect.maxY - inner

        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return .move
        }
    }
}

/// Pure crop-box geometry shared by the overlay, the crop panel and keyboard shortcuts.
///
/// Rects are stored normalized to the frame's pixel grid, but all shape decisions are made in
/// display units (frame = `displayAspectRatio` × 1), so aspect ratios and "square" mean what the
/// user sees for square-pixel, anamorphic and rotated sources alike.
struct CropEditor: Sendable {
    /// Smallest box side, as a fraction of the frame.
    static let minimumFraction = 0.02

    let displayAspectRatio: Double

    init(displayAspectRatio: Double) {
        self.displayAspectRatio = displayAspectRatio.isFinite && displayAspectRatio > 0 ? displayAspectRatio : 16.0 / 9.0
    }

    init(frame: CropFrame) {
        self.init(displayAspectRatio: frame.displayAspectRatio)
    }

    /// Box in display units: x in 0...displayAspectRatio, y in 0...1.
    private struct Box {
        var minX: Double, minY: Double, maxX: Double, maxY: Double
        var width: Double { maxX - minX }
        var height: Double { maxY - minY }
        var midX: Double { (minX + maxX) / 2 }
        var midY: Double { (minY + maxY) / 2 }
    }

    private var frameWidth: Double { displayAspectRatio }
    private var minWidth: Double { Self.minimumFraction * frameWidth }
    private var minHeight: Double { Self.minimumFraction }

    private func box(_ rect: CropRect) -> Box {
        let rect = clamped(rect)
        return Box(
            minX: rect.x * frameWidth, minY: rect.y,
            maxX: (rect.x + rect.width) * frameWidth, maxY: rect.y + rect.height
        )
    }

    private func rect(_ box: Box) -> CropRect {
        clamped(CropRect(x: box.minX / frameWidth, y: box.minY, width: box.width / frameWidth, height: box.height))
    }

    /// Display-space aspect ratio (width / height) of a normalized rect.
    func displayAspectRatio(of rect: CropRect) -> Double {
        rect.height > 0 ? rect.width / rect.height * displayAspectRatio : displayAspectRatio
    }

    /// Makes any rect valid: finite, at least the minimum size and inside the frame.
    func clamped(_ rect: CropRect) -> CropRect {
        func finite(_ value: Double, _ fallback: Double) -> Double { value.isFinite ? value : fallback }
        let width = clamp(finite(rect.width, 1), Self.minimumFraction, 1)
        let height = clamp(finite(rect.height, 1), Self.minimumFraction, 1)
        return CropRect(
            x: clamp(finite(rect.x, 0), 0, 1 - width),
            y: clamp(finite(rect.y, 0), 0, 1 - height),
            width: width,
            height: height
        )
    }

    /// Translates the box, stopping at the frame edges.
    func moved(_ rect: CropRect, by delta: CGSize) -> CropRect {
        let rect = clamped(rect)
        return CropRect(
            x: clamp(rect.x + delta.width, 0, 1 - rect.width),
            y: clamp(rect.y + delta.height, 0, 1 - rect.height),
            width: rect.width,
            height: rect.height
        )
    }

    /// Centers the box in the frame without changing its size.
    func centered(_ rect: CropRect) -> CropRect {
        let rect = clamped(rect)
        return CropRect(x: (1 - rect.width) / 2, y: (1 - rect.height) / 2, width: rect.width, height: rect.height)
    }

    /// Resizes `start` by dragging `handle` by a normalized `delta`.
    ///
    /// The edges opposite the handle stay put (or the center, with `fromCenter`); the moving
    /// edges stop at the frame and at the minimum size instead of pushing the box around.
    /// With an `aspectRatio` (display width / height), corners follow whichever axis makes the
    /// box larger, and edge handles grow the perpendicular axis around its center.
    func resized(
        _ start: CropRect,
        handle: CropHandle,
        by delta: CGSize,
        fromCenter: Bool = false,
        aspectRatio: Double? = nil
    ) -> CropRect {
        if handle == .move { return moved(start, by: delta) }
        let start = box(start)
        let dx = delta.width * frameWidth
        let dy = delta.height
        let h = Double(handle.horizontal)
        let v = Double(handle.vertical)

        guard let ratio = aspectRatio, ratio.isFinite, ratio > 0 else {
            var result = start
            if h != 0 {
                (result.minX, result.maxX) = resizeAxis(
                    start.minX, start.maxX, by: dx, direction: h, fromCenter: fromCenter,
                    minimum: minWidth, limit: frameWidth
                )
            }
            if v != 0 {
                (result.minY, result.maxY) = resizeAxis(
                    start.minY, start.maxY, by: dy, direction: v, fromCenter: fromCenter,
                    minimum: minHeight, limit: 1
                )
            }
            return rect(result)
        }

        // Proposed size along each axis that the pointer controls.
        let growth = fromCenter ? 2.0 : 1.0
        let widthFromX = h != 0 ? start.width + growth * h * dx : nil
        let heightFromY = v != 0 ? start.height + growth * v * dy : nil
        var width: Double = switch (widthFromX, heightFromY) {
        case let (w?, ht?): max(w, ht * ratio)
        case let (w?, nil): w
        case let (nil, ht?): ht * ratio
        case (nil, nil): start.width
        }

        // Room available while keeping the anchor (opposite edge or center) fixed.
        let availableWidth: Double
        let availableHeight: Double
        if fromCenter {
            availableWidth = 2 * min(start.midX, frameWidth - start.midX)
            availableHeight = 2 * min(start.midY, 1 - start.midY)
        } else {
            availableWidth = h > 0 ? frameWidth - start.minX : h < 0 ? start.maxX : frameWidth
            availableHeight = v > 0 ? 1 - start.minY : v < 0 ? start.maxY : 1
        }
        let maxWidth = min(availableWidth, availableHeight * ratio)
        let minimumWidth = max(minWidth, minHeight * ratio)
        width = min(max(width, minimumWidth), maxWidth)
        let height = width / ratio

        var result = Box(minX: 0, minY: 0, maxX: 0, maxY: 0)
        if fromCenter {
            result.minX = start.midX - width / 2
            result.minY = start.midY - height / 2
        } else {
            result.minX = h > 0 ? start.minX : h < 0 ? start.maxX - width
                : clamp(start.midX - width / 2, 0, frameWidth - width)
            result.minY = v > 0 ? start.minY : v < 0 ? start.maxY - height
                : clamp(start.midY - height / 2, 0, 1 - height)
        }
        result.maxX = result.minX + width
        result.maxY = result.minY + height
        return rect(result)
    }

    /// Reshapes the box to a display aspect ratio, keeping its center and area where the frame
    /// allows. Choosing a ratio for an uncropped frame therefore gives the largest box that fits.
    func fitted(_ rect: CropRect, to aspectRatio: Double) -> CropRect {
        guard aspectRatio.isFinite, aspectRatio > 0 else { return clamped(rect) }
        let start = box(rect)
        let area = start.width * start.height
        return sized(width: (area * aspectRatio).squareRoot(), aspectRatio: aspectRatio, around: start)
    }

    /// Scales the box around its center. A locked ratio is kept exactly; a free box keeps its
    /// shape until one side reaches the frame, after which only the other side keeps growing.
    func scaled(_ rect: CropRect, by factor: Double, aspectRatio: Double? = nil) -> CropRect {
        guard factor.isFinite, factor > 0 else { return clamped(rect) }
        let start = box(rect)
        if let aspectRatio, aspectRatio.isFinite, aspectRatio > 0 {
            return sized(width: start.width * factor, aspectRatio: aspectRatio, around: start)
        }
        let width = clamp(start.width * factor, minWidth, frameWidth)
        let height = clamp(start.height * factor, minHeight, 1)
        return self.rect(centeredBox(width: width, height: height, around: start))
    }

    /// Applies a typed pixel size under an aspect-ratio lock: the edited dimension wins and
    /// the other follows. The box keeps its origin unless it would leave the frame.
    func matching(_ rect: CropRect, aspectRatio: Double, keepingWidth: Bool) -> CropRect {
        guard aspectRatio.isFinite, aspectRatio > 0 else { return clamped(rect) }
        let start = box(rect)
        var width = keepingWidth ? start.width : start.height * aspectRatio
        width = min(max(width, max(minWidth, minHeight * aspectRatio)), min(frameWidth, aspectRatio))
        let height = width / aspectRatio
        let minX = clamp(start.minX, 0, frameWidth - width)
        let minY = clamp(start.minY, 0, 1 - height)
        return self.rect(Box(minX: minX, minY: minY, maxX: minX + width, maxY: minY + height))
    }

    // MARK: Helpers

    private func sized(width proposed: Double, aspectRatio: Double, around start: Box) -> CropRect {
        let maxWidth = min(frameWidth, aspectRatio)
        let width = min(max(proposed, max(minWidth, minHeight * aspectRatio)), maxWidth)
        return rect(centeredBox(width: width, height: width / aspectRatio, around: start))
    }

    /// A box of the given size centered on `start`, shifted (not shrunk) to stay inside the frame.
    private func centeredBox(width: Double, height: Double, around start: Box) -> Box {
        let minX = clamp(start.midX - width / 2, 0, frameWidth - width)
        let minY = clamp(start.midY - height / 2, 0, 1 - height)
        return Box(minX: minX, minY: minY, maxX: minX + width, maxY: minY + height)
    }

    private func resizeAxis(
        _ lower: Double, _ upper: Double, by delta: Double, direction: Double,
        fromCenter: Bool, minimum: Double, limit: Double
    ) -> (Double, Double) {
        if fromCenter {
            let center = (lower + upper) / 2
            let maxHalf = min(center, limit - center)
            let half = min(max((upper - lower) / 2 + direction * delta, minimum / 2), maxHalf)
            return (center - half, center + half)
        }
        if direction > 0 {
            return (lower, min(max(upper + delta, lower + minimum), limit))
        }
        return (max(min(lower + delta, upper - minimum), 0), upper)
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), max(lower, upper))
    }
}
