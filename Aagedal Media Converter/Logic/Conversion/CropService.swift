// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

/// Service for building FFMPEG crop filters from crop configurations
enum CropService {
    /// Builds FFmpeg crop filter string from config
    /// Returns nil if no crop or invalid config
    /// - Parameters:
    ///   - config: The crop configuration
    ///   - sourceWidth: Source video width in pixels
    ///   - sourceHeight: Source video height in pixels
    /// - Returns: FFmpeg crop filter string like "crop=1280:720:320:180" or nil
    static func buildCropFilter(
        config: CropConfig,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> String? {
        CropGeometryPlan(config: config, sourceWidth: sourceWidth, sourceHeight: sourceHeight)?.filter
    }
}

/// Resolves crop bounds once so pixel filters and encoder dimensions describe the same area.
struct CropGeometryPlan: Equatable, Sendable {
    let rect: PixelCropRect

    init?(config: CropConfig, sourceWidth: Int, sourceHeight: Int) {
        let normalized = config.normalizedRect
        guard config.isActive,
              sourceWidth >= 2, sourceHeight >= 2,
              sourceWidth <= Int32.max, sourceHeight <= Int32.max,
              [normalized.x, normalized.y, normalized.width, normalized.height].allSatisfy(\.isFinite),
              normalized.width > 0, normalized.height > 0 else { return nil }

        // Bound normalized values before converting to integers, including imported settings.
        func pixels(_ value: Double, _ dimension: Int) -> Int {
            Int((min(1, max(0, value)) * Double(dimension)).rounded())
        }
        rect = PixelCropRect(
            x: pixels(normalized.x, sourceWidth),
            y: pixels(normalized.y, sourceHeight),
            width: pixels(normalized.width, sourceWidth),
            height: pixels(normalized.height, sourceHeight)
        ).clamped(maxWidth: sourceWidth, maxHeight: sourceHeight).evenDimensions()
    }

    var filter: String { "crop=\(rect.width):\(rect.height):\(rect.x):\(rect.y)" }

    /// FFmpeg dimensions are signed 32-bit integers. Validate before narrowing or rounding.
    static func squarePixelDimensions(
        width: Int, height: Int, pixelAspectRatio: Double, roundWidthUp: Bool = false
    ) -> (width: Int, height: Int)? {
        let scaledWidth = (Double(width) * pixelAspectRatio).rounded()
        guard width >= 2, height >= 2, height <= Int32.max,
              pixelAspectRatio.isFinite, pixelAspectRatio > 0,
              scaledWidth.isFinite, scaledWidth >= 1, scaledWidth < Double(Int32.max) else { return nil }
        let integerWidth = Int(scaledWidth)
        let evenWidth = roundWidthUp ? (integerWidth + 1) / 2 * 2 : integerWidth / 2 * 2
        return (max(2, evenWidth), height / 2 * 2)
    }
}
