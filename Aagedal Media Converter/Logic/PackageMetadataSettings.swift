// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Remembered content kinds captured before package request preparation suspends.
/// Explicit per-item metadata always wins over remembered editor preferences.
struct PackageMetadataSettings: Sendable {
    let dcpContentKind: DCPContentKind
    let imfContentKind: IMFContentKind

    init(defaults: UserDefaults = .standard) {
        dcpContentKind = defaults.string(forKey: AppConstants.lastDCPContentKindKey)
            .flatMap(DCPContentKind.init(rawValue:)) ?? .feature
        imfContentKind = defaults.string(forKey: AppConstants.lastIMFContentKindKey)
            .flatMap(IMFContentKind.init(rawValue:)) ?? .feature
    }

    func resolveDCPMetadata(_ stored: DCPItemMetadata?, inputURL: URL) -> DCPItemMetadata {
        var metadata = stored ?? DCPItemMetadata(contentKind: dcpContentKind)
        if metadata.contentTitleText.isEmpty {
            metadata.contentTitleText = inputURL.deletingPathExtension().lastPathComponent
        }
        return metadata
    }

    func resolveIMFMetadata(_ stored: IMFItemMetadata?, inputURL: URL) -> IMFItemMetadata {
        var metadata = stored ?? IMFItemMetadata(contentKind: imfContentKind)
        if metadata.contentTitleText.isEmpty {
            metadata.contentTitleText = inputURL.deletingPathExtension().lastPathComponent
        }
        return metadata
    }
}
