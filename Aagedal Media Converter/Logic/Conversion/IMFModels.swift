// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - IMF Per-Item Metadata

/// Per-item metadata for IMF export, stored on each VideoItem
struct IMFItemMetadata: Equatable, Sendable {
    /// CPL ContentTitleText (the human-readable title shown by IMF players)
    var contentTitleText: String = ""
    /// CPL ContentKind (uses IANA-like asset-type values)
    var contentKind: IMFContentKind = .feature
    /// Free-form annotation text written into PKL/CPL AnnotationText
    var annotationText: String = ""
    /// Audio language tag (RFC 5646, e.g. "en", "fr", "nb")
    var audioLanguage: String = "en"
}

/// IMF content kind — used for the `<ContentKind>` element in the CPL.
/// Values follow common practice in IMF delivery specs (Netflix, Sony).
enum IMFContentKind: String, CaseIterable, Identifiable, Sendable {
    case feature = "feature"
    case episode = "episode"
    case trailer = "trailer"
    case promo = "promo"
    case advertisement = "advertisement"
    case teaser = "teaser"
    case test = "test"
    case bonus = "bonus"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .feature: return "Feature"
        case .episode: return "Episode"
        case .trailer: return "Trailer"
        case .promo: return "Promo"
        case .advertisement: return "Advertisement"
        case .teaser: return "Teaser"
        case .test: return "Test"
        case .bonus: return "Bonus"
        }
    }
}

// MARK: - IMF Application

/// Selects which IMF Application the export targets. Each Application has its own
/// ST 2067-x specification controlling the video essence codec and constraints.
enum IMFApplication: String, CaseIterable, Identifiable, Codable, Sendable {
    /// ST 2067-21: J2K Application #2 Extended (cinema/broadcast HD/UHD).
    case app2e = "app2e"
    /// Apple ProRes IMF per SMPTE RDD 45.
    case rdd45 = "rdd45"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .app2e: return "App #2e (JPEG 2000)"
        case .rdd45: return "RDD 45 (ProRes)"
        }
    }
}

// MARK: - IMF Resolution

/// Image resolutions offered by the experimental App #2e and RDD 45 exporters.
enum IMFResolution: String, CaseIterable, Identifiable, Codable, Sendable {
    case hd1080 = "HD 1920x1080"
    case uhd2160 = "UHD 3840x2160"

    var id: String { rawValue }

    var width: Int {
        switch self {
        case .hd1080: return 1920
        case .uhd2160: return 3840
        }
    }

    var height: Int {
        switch self {
        case .hd1080: return 1080
        case .uhd2160: return 2160
        }
    }

    /// Short label used in folder names ("2K", "4K").
    var shortTier: String {
        switch self {
        case .hd1080: return "2K"
        case .uhd2160: return "4K"
        }
    }
}

// MARK: - IMF Frame Rate

/// IMF-allowed frame rates. Drop-frame variants (23.976, 29.97, 59.94) are represented as
/// non-integer edit rates per ST 2067-2.
enum IMFFrameRate: String, CaseIterable, Identifiable, Codable, Sendable {
    case fps23_976 = "23.976 fps"
    case fps24 = "24 fps"
    case fps25 = "25 fps"
    case fps29_97 = "29.97 fps"
    case fps30 = "30 fps"
    case fps50 = "50 fps"
    case fps59_94 = "59.94 fps"
    case fps60 = "60 fps"

    var id: String { rawValue }

    /// Value passed to FFmpeg `-r`.
    var ffmpegValue: String {
        switch self {
        case .fps23_976: return "24000/1001"
        case .fps24:     return "24"
        case .fps25:     return "25"
        case .fps29_97:  return "30000/1001"
        case .fps30:     return "30"
        case .fps50:     return "50"
        case .fps59_94:  return "60000/1001"
        case .fps60:     return "60"
        }
    }

    /// Edit rate numerator for `<EditRate>` in CPL.
    var editRateNumerator: Int {
        switch self {
        case .fps23_976: return 24000
        case .fps24:     return 24
        case .fps25:     return 25
        case .fps29_97:  return 30000
        case .fps30:     return 30
        case .fps50:     return 50
        case .fps59_94:  return 60000
        case .fps60:     return 60
        }
    }

    /// Edit rate denominator for `<EditRate>` in CPL.
    var editRateDenominator: Int {
        switch self {
        case .fps23_976, .fps29_97, .fps59_94: return 1001
        default: return 1
        }
    }

    /// Approximate fps used for folder-name suffixes ("24", "30", "60").
    var folderTag: String {
        switch self {
        case .fps23_976, .fps24: return "24"
        case .fps25:             return "25"
        case .fps29_97, .fps30:  return "30"
        case .fps50:             return "50"
        case .fps59_94, .fps60:  return "60"
        }
    }
}

// MARK: - IMF Color Encoding (App #2e)

/// Color encoding for App #2e essences. Drives FFmpeg color-tagging flags and the bmx wrap.
enum IMFColorEncoding: String, CaseIterable, Identifiable, Codable, Sendable {
    case rec709 = "Rec. 709 (HD SDR)"
    case rec2020SDR = "Rec. 2020 (UHD SDR)"
    case rec2020PQ = "Rec. 2020 PQ (HDR10)"
    case rec2020HLG = "Rec. 2020 HLG"

    var id: String { rawValue }

    /// FFmpeg `-color_primaries` value.
    var colorPrimaries: String {
        switch self {
        case .rec709: return "bt709"
        case .rec2020SDR, .rec2020PQ, .rec2020HLG: return "bt2020"
        }
    }

    /// FFmpeg `-color_trc` value.
    var colorTRC: String {
        switch self {
        case .rec709: return "bt709"
        case .rec2020SDR: return "bt2020-10"
        case .rec2020PQ: return "smpte2084"
        case .rec2020HLG: return "arib-std-b67"
        }
    }

    /// FFmpeg `-colorspace` (matrix) value.
    var colorSpace: String {
        switch self {
        case .rec709: return "bt709"
        case .rec2020SDR, .rec2020PQ, .rec2020HLG: return "bt2020nc"
        }
    }

    /// Flags to pass to bmx tools (raw2bmx, bmxtranswrap) for IMF wrapping.
    /// `transferCharacteristic == nil` means omit `--transfer-ch` and let bmx default.
    /// Values follow bmx v1.6.2's accepted vocabulary (`bt709`, `bt2020`, `st2084`, `hlg`);
    /// older bmx releases also accepted shorter forms ("709"/"2020"/"smpte2084") but those
    /// were dropped, so use the verbose names.
    var bmxFlags: (colorPrimaries: String, transferCharacteristic: String?, codingEquations: String) {
        switch self {
        case .rec709:     return ("bt709", "bt709", "bt709")
        case .rec2020SDR: return ("bt2020", nil, "bt2020")
        case .rec2020PQ:  return ("bt2020", "st2084", "bt2020")
        case .rec2020HLG: return ("bt2020", "hlg", "bt2020")
        }
    }
}

// MARK: - IMF ProRes Profile (RDD 45)

/// ProRes profiles supported by the RDD 45 exporter. Excludes Proxy / LT / 422 / 422 LT —
/// IMF requires a high-quality master profile.
enum IMFProResProfile: String, CaseIterable, Identifiable, Codable, Sendable {
    case proRes422HQ = "ProRes 422 HQ"
    case proRes4444 = "ProRes 4444"
    case proRes4444XQ = "ProRes 4444 XQ"

    var id: String { rawValue }

    /// FFmpeg `-profile:v` numeric value for `prores_ks`.
    var ffmpegProfile: String {
        switch self {
        case .proRes422HQ:  return "3"
        case .proRes4444:   return "4"
        case .proRes4444XQ: return "5"
        }
    }

    /// Pixel format required for this profile.
    var pixelFormat: String {
        switch self {
        case .proRes422HQ:  return "yuv422p10le"
        case .proRes4444:   return "yuva444p10le"
        case .proRes4444XQ: return "yuva444p10le"
        }
    }
}

// MARK: - IMF Scaling

/// How source video is fitted into the IMF container resolution.
enum IMFScalingMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case fit = "Fit (letterbox/pillarbox)"
    case fill = "Fill (crop to fill)"

    var id: String { rawValue }
}
