// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

/// Encapsulates all data needed to perform a single FFMPEG conversion.
/// Callbacks (progressUpdate, completion) are passed separately.
struct ConversionRequest: Sendable {
    // MARK: - Input / Output
    let inputURL: URL
    let outputURL: URL
    let preset: ExportPreset

    // MARK: - Metadata
    var comment: String = ""
    var includeDateTag: Bool = true
    var sourceMetadata: VideoMetadata? = nil
    var sourceCameraMetadata: CameraMetadata? = nil
    var dcpMetadata: DCPItemMetadata? = nil
    var imfMetadata: IMFItemMetadata? = nil

    // MARK: - Trim & Timing
    var trimStart: Double? = nil
    var trimEnd: Double? = nil
    var expectedDuration: Double? = nil
    var videoFrameRate: Double? = nil

    // MARK: - Processing Configuration
    var audioRoutingConfig: AudioRoutingConfig? = nil
    var cropConfig: CropConfig? = nil
    var timecodeConfig: TimecodeConfig? = nil
    var isMuted: Bool = false

    // MARK: - Special Rendering
    var waveformRequest: WaveformVideoRequest? = nil
    var synthesizedVideoRequest: SynthesizedVideoRequest? = nil
    var waveformBackgroundImageURL: URL? = nil

    /// A representative visual input used for geometry inspection when `inputURL`
    /// is a virtual source such as an image-sequence directory.
    var visualSourceURL: URL? = nil

    // MARK: - FFMPEG Argument Overrides
    var customInputArguments: [String]? = nil
    var additionalOutputArguments: [String]? = nil
}
