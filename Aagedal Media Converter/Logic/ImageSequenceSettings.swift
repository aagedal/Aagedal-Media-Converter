// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Captures encoder, frame naming, and metadata preferences for one export.
struct ImageSequenceSettings: Sendable {
    let format: ImageSequenceFormat
    let jpegQuality: Int
    let numberingPadding: Int
    let metadataSidecarEnabled: Bool
    let metadataSidecarFormat: MetadataSidecarGenerator.SidecarFormat

    init(defaults: UserDefaults = .standard) {
        format = ImageSequenceFormat(rawValue: defaults.string(forKey: AppConstants.imageSequenceExportFormatKey)
            ?? AppConstants.defaultImageSequenceExportFormat) ?? .png
        let quality = defaults.integer(forKey: AppConstants.imageSequenceExportQualityKey)
        jpegQuality = (1...31).contains(quality) ? quality : AppConstants.defaultImageSequenceExportQuality
        let padding = defaults.integer(forKey: AppConstants.imageSequenceNumberingPaddingKey)
        numberingPadding = (1...8).contains(padding) ? padding : AppConstants.defaultImageSequenceNumberingPadding
        metadataSidecarEnabled = defaults.object(forKey: AppConstants.imageSequenceMetadataSidecarEnabledKey) == nil
            ? AppConstants.defaultImageSequenceMetadataSidecarEnabled
            : defaults.bool(forKey: AppConstants.imageSequenceMetadataSidecarEnabledKey)
        metadataSidecarFormat = MetadataSidecarGenerator.SidecarFormat(rawValue:
            defaults.string(forKey: AppConstants.imageSequenceMetadataSidecarFormatKey)
                ?? AppConstants.defaultImageSequenceMetadataSidecarFormat) ?? .markdown
    }

    func outputPattern(baseName: String) -> String {
        "\(baseName)_%0\(numberingPadding)d.\(format.primaryExtension)"
    }

    var ffmpegArguments: [String] {
        var args = ["-hide_banner", "-c:v", format.ffmpegEncoder, "-an"]
        if format == .jpeg {
            args += ["-q:v", "\(jpegQuality)"]
        }
        return args
    }
}
