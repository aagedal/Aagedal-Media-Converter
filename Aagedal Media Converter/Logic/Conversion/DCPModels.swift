// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - DCP Per-Item Metadata

/// Per-item metadata for DCP export, stored on each VideoItem
struct DCPItemMetadata: Equatable, Sendable {
    /// The title displayed on cinema servers (ContentTitleText in CPL)
    var contentTitleText: String = ""
    /// Content kind: feature, trailer, short, advertisement, etc.
    var contentKind: DCPContentKind = .feature
    /// Free-form annotation (AnnotationText in PKL/CPL)
    var annotationText: String = ""
    /// Film rating label (e.g., "PG-13", "R", "12A")
    var ratingLabel: String = ""
    /// Audio language tag (RFC 5646, e.g., "en", "fr", "nb")
    var audioLanguage: String = "en"
}

/// DCP content kind values (used in CPL ContentKind element)
enum DCPContentKind: String, CaseIterable, Identifiable, Sendable {
    case feature = "feature"
    case trailer = "trailer"
    case short = "short"
    case advertisement = "advertisement"
    case teaser = "teaser"
    case test = "test"
    case rating = "rating"
    case policy = "policy"
    case publicService = "public-service-announcement"
    case transitional = "transitional"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .feature: return "Feature"
        case .trailer: return "Trailer"
        case .short: return "Short"
        case .advertisement: return "Advertisement"
        case .teaser: return "Teaser"
        case .test: return "Test"
        case .rating: return "Rating"
        case .policy: return "Policy"
        case .publicService: return "Public Service Announcement"
        case .transitional: return "Transitional"
        }
    }
}

// MARK: - DCP Resolution

/// DCI resolution options for DCP export
enum DCPResolution: String, CaseIterable, Identifiable, Codable, Sendable {
    case twoKFlat = "2K Flat (1998x1080)"
    case twoKScope = "2K Scope (2048x858)"
    case twoKFull = "2K Full (2048x1080)"
    case fourKFlat = "4K Flat (3996x2160)"
    case fourKScope = "4K Scope (4096x1716)"
    case fourKFull = "4K Full (4096x2160)"

    var id: String { rawValue }

    var width: Int {
        switch self {
        case .twoKFlat: return 1998
        case .twoKScope: return 2048
        case .twoKFull: return 2048
        case .fourKFlat: return 3996
        case .fourKScope: return 4096
        case .fourKFull: return 4096
        }
    }

    var height: Int {
        switch self {
        case .twoKFlat: return 1080
        case .twoKScope: return 858
        case .twoKFull: return 1080
        case .fourKFlat: return 2160
        case .fourKScope: return 1716
        case .fourKFull: return 2160
        }
    }

    /// Maximum DCI bitrate in Mbps for this resolution tier
    var maxBitrateMbps: Int {
        switch self {
        case .twoKFlat, .twoKScope, .twoKFull: return 250
        case .fourKFlat, .fourKScope, .fourKFull: return 500
        }
    }

    /// libopenjpeg profile for DCI-compliant JPEG 2000 encoding
    var openjpegProfile: String {
        switch self {
        case .twoKFlat, .twoKScope, .twoKFull: return "cinema2k"
        case .fourKFlat, .fourKScope, .fourKFull: return "cinema4k"
        }
    }

    /// Short label for display in compact contexts
    var shortLabel: String {
        switch self {
        case .twoKFlat: return "2K Flat (1.85:1)"
        case .twoKScope: return "2K Scope (2.39:1)"
        case .twoKFull: return "2K Full (1.90:1)"
        case .fourKFlat: return "4K Flat (1.85:1)"
        case .fourKScope: return "4K Scope (2.39:1)"
        case .fourKFull: return "4K Full (1.90:1)"
        }
    }
}

// MARK: - DCP Frame Rate

/// DCI-compliant frame rates for DCP export
enum DCPFrameRate: String, CaseIterable, Identifiable, Codable, Sendable {
    case fps24 = "24 fps"
    case fps25 = "25 fps"
    case fps30 = "30 fps"
    case fps48 = "48 fps"

    var id: String { rawValue }

    var ffmpegValue: String {
        switch self {
        case .fps24: return "24"
        case .fps25: return "25"
        case .fps30: return "30"
        case .fps48: return "48"
        }
    }

    /// Edit rate numerator for DCP XML (CPL)
    var editRateNumerator: Int {
        switch self {
        case .fps24: return 24
        case .fps25: return 25
        case .fps30: return 30
        case .fps48: return 48
        }
    }

    /// Edit rate denominator for DCP XML (CPL)
    var editRateDenominator: Int { 1 }

    /// libopenjpeg cinema_mode for DCI-compliant JPEG 2000 encoding
    /// Returns nil for frame rates without a matching cinema mode
    func cinemaModeFor(resolution: DCPResolution) -> String? {
        switch (resolution.openjpegProfile, self) {
        case ("cinema2k", .fps24): return "2k_24"
        case ("cinema2k", .fps48): return "2k_48"
        case ("cinema4k", .fps24): return "4k_24"
        default: return nil
        }
    }
}

// MARK: - DCP Scaling Mode

/// How source video is fitted into the DCP container resolution
enum DCPScalingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case fit = "Fit (letterbox/pillarbox)"
    case fill = "Fill (crop to fill)"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fit: return "Fit (letterbox/pillarbox)"
        case .fill: return "Fill (crop to fill)"
        }
    }
}

// MARK: - DCP Bitrate

/// Video bitrate options for DCP JPEG 2000 encoding
enum DCPBitrate: String, CaseIterable, Identifiable, Codable, Sendable {
    case low = "100 Mbps"
    case medium = "150 Mbps"
    case high = "200 Mbps"
    case max = "250 Mbps"

    var id: String { rawValue }

    var ffmpegValue: String {
        switch self {
        case .low: return "100M"
        case .medium: return "150M"
        case .high: return "200M"
        case .max: return "250M"
        }
    }
}
