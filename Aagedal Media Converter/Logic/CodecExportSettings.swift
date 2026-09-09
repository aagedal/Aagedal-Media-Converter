// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Immutable codec, broadcast, proxy, animated-still, Stream Copy, and custom export preferences, resolved before asynchronous work.
/// Derived command arguments intentionally retain the existing preset codec policy.
struct CodecExportSettings: Sendable {
    let fileNameContext: FileNameTemplateContext
    let container: CodecContainer?
    let fileExtension: String
    let avcIntraMCADefaults: AVCIntraMCADefaults?
    let streamCopyContainer: StreamCopyContainer?
    let appliesCrop: Bool
    let appliesAudioRouting: Bool
    let avcIntraAudioChannels: AVCIntraAudioChannels?
    let resolutionLimit: CodecResolutionLimit?
    let ffmpegArguments: [String]
    let sourceMetadataPlan: SourceMetadataPlan

    init?(preset: ExportPreset, defaults: UserDefaults = .standard) {
        fileNameContext = FileNameTemplateContext(preset: preset, defaults: defaults)
        if preset.customSlotIndex != nil {
            sourceMetadataPlan = .unchanged
        } else {
            sourceMetadataPlan = SourceMetadataPlan(
                preserveMetadata: defaults.bool(forKey: AppConstants.preserveMetadataPreferenceKey),
                defaultInput: [.videoLoop, .animatedStill].contains(preset) ? nil : 0
            )
        }
        avcIntraMCADefaults = preset == .tvAVCIntra ? AVCIntraMCADefaults(defaults: defaults) : nil
        streamCopyContainer = preset == .streamCopy ? StreamCopyContainer(
            rawValue: defaults.string(forKey: AppConstants.streamCopyContainerKey)
                ?? AppConstants.defaultStreamCopyContainer
        ) ?? .keepCurrent : nil
        if let slot = preset.customSlotIndex {
            appliesCrop = defaults.bool(forKey: AppConstants.customPresetApplyCropKey(for: slot))
            appliesAudioRouting = defaults.bool(forKey: AppConstants.customPresetApplyAudioRoutingKey(for: slot))
        } else {
            appliesCrop = preset.appliesCrop
            appliesAudioRouting = preset.appliesAudioRouting
        }
        avcIntraAudioChannels = preset == .tvAVCIntra ? AVCIntraAudioChannels(
            rawValue: defaults.string(forKey: AppConstants.avcIntraAudioChannelsKey)
                ?? AppConstants.defaultAVCIntraAudioChannels
        ) ?? .ch8 : nil
        let containerKey: String
        let defaultContainer: String
        let resolutionKey: String
        let defaultResolution: String
        switch preset {
        case .streamCopy:
            fileExtension = streamCopyContainer?.fileExtension ?? "mp4"
            container = streamCopyContainer?.fileExtension.flatMap { CodecContainer(rawValue: $0.uppercased()) }
            resolutionLimit = nil
            ffmpegArguments = preset.codecFFmpegArguments(defaults: defaults)
            return
        case .custom1, .custom2, .custom3, .custom4, .custom5, .custom6, .custom7, .custom8, .custom9, .custom10:
            guard let slot = preset.customSlotIndex else { return nil }
            fileExtension = ExportPreset.customFileExtension(for: slot, defaults: defaults)
            container = CodecContainer(rawValue: fileExtension.uppercased())
            resolutionLimit = nil
            ffmpegArguments = preset.codecFFmpegArguments(defaults: defaults)
            return
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

    /// Stream Copy's Keep Current policy is source-dependent; all other extensions are fixed.
    func outputExtension(for sourceURL: URL?) -> String {
        if streamCopyContainer == .keepCurrent, let sourceExtension = sourceURL?.pathExtension,
           !sourceExtension.isEmpty {
            return sourceExtension.lowercased()
        }
        return fileExtension
    }
}
