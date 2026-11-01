// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Sidecar formats that can follow the main file to the upload destination.
enum UploadSidecarKind: String, CaseIterable, Identifiable, Sendable {
    /// Sony `<clip>M01.XML` NonRealTimeMeta; Resolve reads camera, serial and lens from it.
    case cameraMetadata
    /// `.srt` from transcription or OCR.
    case subtitles
    /// Clip-marker EDL written beside merged exports.
    case clipMarkers

    var id: String { rawValue }

    var defaultsKey: String {
        switch self {
        case .cameraMetadata: return AppConstants.uploadCameraMetadataSidecarKey
        case .subtitles: return AppConstants.uploadSubtitleSidecarKey
        case .clipMarkers: return AppConstants.uploadClipMarkerSidecarKey
        }
    }

    var defaultValue: Bool {
        switch self {
        case .cameraMetadata: return AppConstants.uploadCameraMetadataSidecarDefault
        case .subtitles: return AppConstants.uploadSubtitleSidecarDefault
        case .clipMarkers: return AppConstants.uploadClipMarkerSidecarDefault
        }
    }
}

struct UploadSidecarSettings: Equatable, Sendable {
    let enabledKinds: Set<UploadSidecarKind>

    init(enabledKinds: Set<UploadSidecarKind>) {
        self.enabledKinds = enabledKinds
    }

    init(defaults: UserDefaults = .standard) {
        enabledKinds = Set(UploadSidecarKind.allCases.filter {
            defaults.object(forKey: $0.defaultsKey) as? Bool ?? $0.defaultValue
        })
    }

    func includes(_ kind: UploadSidecarKind) -> Bool {
        enabledKinds.contains(kind)
    }
}

enum UploadSidecars {
    /// Sidecars to send after `item.fileToUpload`, in a stable order. Each keeps its local
    /// file name, so names derived from the main file still match at the destination.
    static func files(
        for item: VideoItem,
        settings: UploadSidecarSettings,
        cameraMetadataSidecar: (URL) -> URL? = NativeMXFMerge.existingSidecarURL(for:),
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [URL] {
        guard let mainFile = item.fileToUpload else { return [] }
        var candidates: [URL] = []
        if settings.includes(.cameraMetadata), let xml = cameraMetadataSidecar(mainFile) {
            candidates.append(xml)
        }
        if settings.includes(.clipMarkers), !item.uploadSourceFile {
            candidates += item.outputSidecarURLs.filter { $0.pathExtension.lowercased() == "edl" }
        }
        if settings.includes(.subtitles), let srt = item.subtitleFilePath {
            candidates.append(srt)
        }
        var seen: Set<URL> = [mainFile.standardizedFileURL]
        return candidates.filter { url in
            seen.insert(url.standardizedFileURL).inserted && fileExists(url)
        }
    }

    /// Subtitles are written after the conversion finishes. Hold the output upload until
    /// they are done when the SRT is uploaded too, or when embedding them replaces the
    /// output file that the upload would otherwise be reading.
    static func outputUploadWaitsForSubtitles(
        item: VideoItem,
        settings: UploadSidecarSettings,
        embedSubtitles: Bool
    ) -> Bool {
        item.subtitleEnabled && !item.uploadSourceFile && (settings.includes(.subtitles) || embedSubtitles)
    }
}
