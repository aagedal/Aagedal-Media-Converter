// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Immutable H.264, HEVC or AV1 export preferences, resolved before asynchronous work.
/// Derived command arguments intentionally retain the existing preset codec policy.
struct CodecExportSettings: Sendable {
    let container: CodecContainer
    let resolutionLimit: CodecResolutionLimit
    let ffmpegArguments: [String]

    init?(preset: ExportPreset, defaults: UserDefaults = .standard) {
        let containerKey: String
        let defaultContainer: String
        let resolutionKey: String
        let defaultResolution: String
        switch preset {
        case .h264:
            containerKey = AppConstants.h264ContainerKey
            defaultContainer = AppConstants.defaultH264Container
            resolutionKey = AppConstants.h264ResolutionLimitKey
            defaultResolution = AppConstants.defaultH264ResolutionLimit
        case .h265:
            containerKey = AppConstants.h265ContainerKey
            defaultContainer = AppConstants.defaultH265Container
            resolutionKey = AppConstants.h265ResolutionLimitKey
            defaultResolution = AppConstants.defaultH265ResolutionLimit
        case .av1:
            containerKey = AppConstants.av1ContainerKey
            defaultContainer = AppConstants.defaultAV1Container
            resolutionKey = AppConstants.av1ResolutionLimitKey
            defaultResolution = AppConstants.defaultAV1ResolutionLimit
        default:
            return nil
        }
        container = CodecContainer(rawValue: defaults.string(forKey: containerKey) ?? defaultContainer) ?? .mp4
        resolutionLimit = CodecResolutionLimit(rawValue: defaults.string(forKey: resolutionKey) ?? defaultResolution) ?? .unlimited
        ffmpegArguments = preset.codecFFmpegArguments(
            defaults: defaults, capturedContainer: container, capturedResolution: resolutionLimit
        )
    }
}
