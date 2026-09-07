// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

/// Configuration for an imported image sequence
struct ImageSequenceConfig: Equatable, Sendable {
    /// The FFMPEG input pattern (e.g., "frame_%04d.png")
    var pattern: String

    /// The directory containing the sequence files
    var directory: URL

    /// First frame number in the sequence
    var startNumber: Int

    /// Last frame number in the sequence
    var endNumber: Int

    /// Import frame rate (frames per second)
    var frameRate: Double = 24.0

    /// Image format of the sequence
    var imageFormat: ImageSequenceFormat

    /// Total file size of all images in the sequence
    var totalSizeBytes: Int64 = 0

    /// Associated audio file URL (e.g., matching WAV alongside the image frames)
    var associatedAudioURL: URL? = nil

    /// Total frame count
    var frameCount: Int { endNumber - startNumber + 1 }

    /// Computed duration in seconds
    var durationSeconds: Double {
        guard frameRate > 0 else { return 0 }
        return Double(frameCount) / frameRate
    }

    /// Whether this sequence has an associated audio file
    var hasAssociatedAudio: Bool { associatedAudioURL != nil }

    /// URL for the first frame, used for thumbnails and source-geometry inspection.
    var firstFrameURL: URL {
        frameURL(for: startNumber)
    }

    /// Resolve a concrete frame URL from the FFmpeg printf-style sequence pattern.
    func frameURL(for frameNumber: Int) -> URL {
        let placeholderRange = pattern.range(of: #"%0[0-9]+d"#, options: .regularExpression)
            ?? pattern.range(of: "%d")
        guard let placeholderRange else {
            return directory.appendingPathComponent(pattern)
        }

        let placeholder = pattern[placeholderRange]
        let paddingWidth = placeholder == "%d"
            ? 0
            : Int(placeholder.dropFirst(2).dropLast()) ?? 0
        let frameNumberString = paddingWidth > 0
            ? String(format: "%0\(paddingWidth)d", frameNumber)
            : String(frameNumber)

        let fileName = String(pattern[..<placeholderRange.lowerBound])
            + frameNumberString
            + String(pattern[placeholderRange.upperBound...])
        return directory.appendingPathComponent(fileName)
    }

    /// FFMPEG input arguments for this sequence, including associated audio if present
    var ffmpegInputArguments: [String] {
        let patternPath = directory.appendingPathComponent(pattern).path
        var args = [
            "-framerate", String(format: "%.3f", frameRate),
            "-start_number", "\(startNumber)",
            "-i", patternPath
        ]
        if let audioURL = associatedAudioURL {
            args.append(contentsOf: ["-i", audioURL.path])
        }
        return args
    }
}

/// Supported image sequence formats
enum ImageSequenceFormat: String, CaseIterable, Identifiable, Sendable {
    case png = "PNG"
    case jpeg = "JPEG"
    case tiff = "TIFF"
    case exr = "EXR"
    case dpx = "DPX"
    case bmp = "BMP"
    case tga = "TGA"
    case sgi = "SGI"
    case jpegXL = "JPEG XL"
    case jpeg2000 = "JPEG 2000"

    var id: String { rawValue }

    var fileExtensions: [String] {
        switch self {
        case .png: return ["png"]
        case .jpeg: return ["jpg", "jpeg"]
        case .tiff: return ["tif", "tiff"]
        case .exr: return ["exr"]
        case .dpx: return ["dpx"]
        case .bmp: return ["bmp"]
        case .tga: return ["tga"]
        case .sgi: return ["sgi"]
        case .jpegXL: return ["jxl"]
        case .jpeg2000: return ["jp2", "j2k", "j2c"]
        }
    }

    var primaryExtension: String { fileExtensions[0] }

    var ffmpegEncoder: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "mjpeg"
        case .tiff: return "tiff"
        case .exr: return "exr"
        case .dpx: return "dpx"
        case .bmp: return "bmp"
        case .tga: return "targa"
        case .sgi: return "sgi"
        case .jpegXL: return "libjxl"
        case .jpeg2000: return "libopenjpeg"
        }
    }

    /// All recognized image file extensions across all formats
    static var allExtensions: Set<String> {
        Set(allCases.flatMap { $0.fileExtensions })
    }

    /// Find the format matching a given file extension
    static func format(forExtension ext: String) -> ImageSequenceFormat? {
        let lower = ext.lowercased()
        return allCases.first { $0.fileExtensions.contains(lower) }
    }
}
