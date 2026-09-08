// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Immutable codec, broadcast, proxy, and animated-still export preferences, resolved before asynchronous work.
/// Derived command arguments intentionally retain the existing preset codec policy.
struct CodecExportSettings: Sendable {
    let container: CodecContainer?
    let fileExtension: String
    let avcIntraAudioChannels: AVCIntraAudioChannels?
    let resolutionLimit: CodecResolutionLimit?
    let ffmpegArguments: [String]

    init?(preset: ExportPreset, defaults: UserDefaults = .standard) {
        avcIntraAudioChannels = preset == .tvAVCIntra ? AVCIntraAudioChannels(
            rawValue: defaults.string(forKey: AppConstants.avcIntraAudioChannelsKey)
                ?? AppConstants.defaultAVCIntraAudioChannels
        ) ?? .ch8 : nil
        let containerKey: String
        let defaultContainer: String
        let resolutionKey: String
        let defaultResolution: String
        switch preset {
        case .prores, .videoLoop, .videoLoopWithSound:
            container = preset == .prores ? .mov : .mp4
            fileExtension = preset == .prores ? "mov" : "mp4"
            resolutionLimit = preset == .prores ? .unlimited : .r1080
            ffmpegArguments = preset.codecFFmpegArguments(defaults: defaults)
            return
        case .tvHEVC, .tvAVCIntra, .proxy, .animatedStill:
            switch preset {
            case .tvHEVC:
                fileExtension = "mov"
            case .tvAVCIntra:
                fileExtension = "mxf"
            case .proxy:
                let codec = ProxyCodec(rawValue: defaults.string(forKey: AppConstants.proxyCodecKey)
                    ?? AppConstants.defaultProxyCodec) ?? .hevc
                fileExtension = codec.fileExtension
            default:
                let format = AnimatedStillFormat(rawValue: defaults.string(forKey: AppConstants.animatedStillFormatKey)
                    ?? AppConstants.defaultAnimatedStillFormat) ?? .avif
                fileExtension = format.fileExtension
            }
            container = CodecContainer(rawValue: fileExtension.uppercased())
            // Broadcast/proxy filters carry their own resolution policy in the arguments.
            resolutionLimit = nil
            ffmpegArguments = preset.codecFFmpegArguments(defaults: defaults)
            return
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
        let resolvedContainer = CodecContainer(rawValue: defaults.string(forKey: containerKey) ?? defaultContainer) ?? .mp4
        container = resolvedContainer
        fileExtension = resolvedContainer.fileExtension
        resolutionLimit = CodecResolutionLimit(rawValue: defaults.string(forKey: resolutionKey) ?? defaultResolution) ?? .unlimited
        ffmpegArguments = preset.codecFFmpegArguments(
            defaults: defaults, capturedContainer: container, capturedResolution: resolutionLimit
        )
    }
}
