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

    var isFourK: Bool {
        switch self {
        case .fourKFlat, .fourKScope, .fourKFull: return true
        case .twoKFlat, .twoKScope, .twoKFull: return false
        }
    }

    /// Resolution count (DWT levels + 1). DCI requires 5 levels for 2K and 6 for 4K, so
    /// a 4K codestream still carries a 2K-decodable subset.
    var openjpegNumResolution: Int { isFourK ? 7 : 6 }

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

    /// SMPTE DCI allows 4K only up to 30 fps; high frame rates are 2K-only.
    func isSupported(by resolution: DCPResolution) -> Bool {
        !(resolution.isFourK && self == .fps48)
    }
}

// MARK: - JPEG 2000 Rate Control

/// FFmpeg's libopenjpeg wrapper ignores `-b:v`. Its only rate control is the DCI
/// `cinema_mode`, which caps every codestream at a fixed byte size. This plan picks
/// the cap that best honours the requested bitrate without exceeding the 250 Mbps
/// DCI ceiling at the chosen frame rate.
struct DCPJ2KRatePlan: Equatable, Sendable {
    /// OPJ_CINEMA_24_CS and OPJ_CINEMA_48_CS from openjpeg.h.
    static let largeFrameCap = 1_302_083
    static let smallFrameCap = 651_041
    static let dciMaxBitsPerSecond = 250_000_000.0

    let cinemaMode: String
    let maxFrameBytes: Int
    let frameRate: DCPFrameRate

    init(resolution: DCPResolution, frameRate: DCPFrameRate, bitrate: DCPBitrate) {
        self.frameRate = frameRate
        let fps = Double(frameRate.editRateNumerator)
        if resolution.isFourK {
            // 2k_48 conflicts with the cinema4k profile, so 4K has a single cap.
            cinemaMode = "4k_24"
            maxFrameBytes = Self.largeFrameCap
        } else if bitrate.megabitsPerSecond >= 200,
                  Double(Self.largeFrameCap) * 8 * fps <= Self.dciMaxBitsPerSecond + 1 {
            cinemaMode = "2k_24"
            maxFrameBytes = Self.largeFrameCap
        } else {
            cinemaMode = "2k_48"
            maxFrameBytes = Self.smallFrameCap
        }
    }

    var peakMegabitsPerSecond: Int {
        Int((Double(maxFrameBytes) * 8 * Double(frameRate.editRateNumerator) / 1_000_000).rounded())
    }

    /// True when the cap allows frames above the DCI 250 Mbps limit (4K at 25/30 fps).
    var mayExceedDCILimit: Bool {
        Double(maxFrameBytes) * 8 * Double(frameRate.editRateNumerator) > Self.dciMaxBitsPerSecond + 1
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

    var megabitsPerSecond: Int {
        switch self {
        case .low: return 100
        case .medium: return 150
        case .high: return 200
        case .max: return 250
        }
    }

    var ffmpegValue: String {
        switch self {
        case .low: return "100M"
        case .medium: return "150M"
        case .high: return "200M"
        case .max: return "250M"
        }
    }
}

// MARK: - DCP Audio Carrier

/// DCP sound is always written as a 6-channel (5.1) carrier, as DCP-o-matic does: cinema
/// servers route channels by position, so mono belongs in C and stereo in L/R.
struct DCPAudioCarrier: Equatable, Sendable {
    static let channelCount = 6
    /// asdcp-wrap `-m` expression for SMPTE ST 377-4 MCA labels.
    static let mcaExpression = "51(L,R,C,LFE,Ls,Rs)"
    /// CPL metadata (ST 429-16) MainSoundConfiguration for the same layout.
    static let mainSoundConfiguration = "51/L,R,C,LFE,Ls,Rs"

    /// Exact picture duration in seconds; audio is padded/cut to this length so the sound
    /// MXF has the same number of edit units as the picture MXF.
    let duration: Double

    init(frameCount: Int, frameRate: DCPFrameRate) {
        duration = Double(frameCount) * Double(frameRate.editRateDenominator) / Double(frameRate.editRateNumerator)
    }

    /// Maps the source channels (in FFmpeg/WAV order) onto L,R,C,LFE,Ls,Rs.
    static func channelMapFilter(sourceChannels: Int?) -> String {
        switch sourceChannels {
        case 1:
            return "pan=5.1|c2=c0"
        case 2:
            return "pan=5.1|c0=c0|c1=c1"
        case 6:
            return "pan=5.1|c0=c0|c1=c1|c2=c2|c3=c3|c4=c4|c5=c5"
        case 8:
            // 7.1 (FL FR FC LFE BL BR SL SR): fold side and back surrounds at -3 dB.
            return "pan=5.1|c0=c0|c1=c1|c2=c2|c3=c3|c4=0.707*c4+0.707*c6|c5=0.707*c5+0.707*c7"
        default:
            return "aformat=channel_layouts=5.1"
        }
    }

    /// ISDCF naming audio field for the source layout.
    static func isdcfAudioCode(sourceChannels: Int?) -> String {
        switch sourceChannels {
        case 0: return "MOS"
        case 1: return "10"
        case 2, nil: return "20"
        default: return "51"
        }
    }
}
