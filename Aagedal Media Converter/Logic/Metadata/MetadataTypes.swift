// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct MetadataEditorField: Codable, Equatable, Sendable {
    var value: String = ""
    var isEnabled: Bool = true
}

/// Per-item values captured with a conversion. Disabled fields follow the
/// general source-preservation policy; enabled empty fields explicitly clear tags.
struct MetadataEditorSettings: Codable, Equatable, Sendable {
    /// Missing in older snapshots, which retain their enabled editor behavior.
    var isEnabled: Bool? = true
    var isActive: Bool { isEnabled != false }
    var writesComment: Bool { isActive && comment.isEnabled }
    var comment = MetadataEditorField()
    var description = MetadataEditorField()
    var title = MetadataEditorField()
    var artist = MetadataEditorField()
    var sourceURL: String?

    init(comment: String = "", description: String = "", title: String = "", artist: String = "", sourceURL: String? = nil) {
        self.comment.value = comment
        self.description.value = description
        self.title.value = title
        self.artist.value = artist
        self.sourceURL = sourceURL
    }

    var outputArguments: [String] {
        guard isActive else { return [] }
        var arguments: [String] = []
        for (name, field) in [("description", description), ("title", title), ("artist", artist)] where field.isEnabled {
            arguments += ["-metadata", "\(name)=\(field.value)"]
        }
        if description.isEnabled {
            arguments += ["-metadata", "synopsis=\(description.value)"]
        }
        if let sourceURL { arguments += ["-metadata", "purl=\(sourceURL)"] }
        return arguments
    }
}

/// C2PA (Content Authenticity) metadata extracted from a video container.
struct C2PAMetadata: Codable, Sendable, Equatable {
    let hasContentCredentials: Bool
    let hasSignature: Bool
    let actionsAction: String?
    let actionsDigitalSourceType: String?
    let claimGenerator: String?
    let claimGeneratorInfoName: String?
    let manifestStore: String?
    let assertions: [String]?

    static let empty = C2PAMetadata(
        hasContentCredentials: false,
        hasSignature: false,
        actionsAction: nil,
        actionsDigitalSourceType: nil,
        claimGenerator: nil,
        claimGeneratorInfoName: nil,
        manifestStore: nil,
        assertions: nil
    )
}

/// Camera/clip metadata from Sony NonRealTimeMeta XML (embedded or sidecar).
struct CameraMetadata: Codable, Sendable, Equatable {
    let deviceManufacturer: String?
    let deviceModelName: String?
    let deviceSerialNumber: String?
    let lensModelName: String?
    let timeZone: String?
    let captureGammaEquation: String?
    let recordingModeType: String?
    let captureFps: String?
    /// Clip creation date as reported by the camera (distinct from container or
    /// filesystem dates — this is the camera's own clock at the time of capture).
    let creationDate: Date?
    /// Paired `<Meta name="..." content="..."/>` entries from Sony NRT
    /// `<UserDescriptiveMetadata>` (e.g. user-supplied Creator / Description / Location).
    let userDescriptiveMetadata: [UserMetadataEntry]?

    static let empty = CameraMetadata(
        deviceManufacturer: nil,
        deviceModelName: nil,
        deviceSerialNumber: nil,
        lensModelName: nil,
        timeZone: nil,
        captureGammaEquation: nil,
        recordingModeType: nil,
        captureFps: nil,
        creationDate: nil,
        userDescriptiveMetadata: nil
    )

    /// Whether any camera metadata fields have values
    var hasAnyData: Bool {
        deviceManufacturer != nil ||
        deviceModelName != nil ||
        deviceSerialNumber != nil ||
        lensModelName != nil ||
        timeZone != nil ||
        captureGammaEquation != nil ||
        recordingModeType != nil ||
        captureFps != nil ||
        creationDate != nil ||
        (userDescriptiveMetadata?.isEmpty == false)
    }
}

/// Provenance-tagged timecode value. Containers can embed timecode in multiple
/// independent places (QuickTime tmcd track, QT udta, XMP, MXF packages, Sony NRT);
/// keeping each surface separate lets a reviewer spot disagreements.
struct TimecodeEntry: Codable, Sendable, Equatable, Identifiable {
    let value: String
    let source: TimecodeSource
    let frameRate: Double?

    var id: String { "\(source.rawValue):\(value)" }
}

enum TimecodeSource: String, Codable, Sendable, Equatable {
    case tmcdTrack
    case quicktimeUdta
    case xmpDM
    case xmpDMAlt
    case mxfMaterialPackage
    case mxfFilePackage
    case sonyNRT
    case redR3D

    /// Human-readable label for UI display.
    var label: String {
        switch self {
        case .tmcdTrack: return "QuickTime Timecode Track"
        case .quicktimeUdta: return "QuickTime User Data"
        case .xmpDM: return "XMP Start"
        case .xmpDMAlt: return "XMP Alternate"
        case .mxfMaterialPackage: return "MXF Material Package"
        case .mxfFilePackage: return "MXF File Package"
        case .sonyNRT: return "Sony NRT"
        case .redR3D: return "RED R3D"
        }
    }
}

/// A single `<Meta name="..." content="..."/>` entry from Sony NRT
/// `<UserDescriptiveMetadata>`.
struct UserMetadataEntry: Codable, Sendable, Equatable {
    let name: String
    let content: String
}

/// A chapter marker read from a media file's container metadata.
struct Chapter: Identifiable, Equatable, Sendable {
    let id: Int
    let start: Double
    let end: Double
    let title: String?

    var duration: Double { max(0, end - start) }

    /// Fallback label when the container has no explicit title.
    func displayTitle(fallbackIndex: Int) -> String {
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        return "Chapter \(fallbackIndex)"
    }
}
