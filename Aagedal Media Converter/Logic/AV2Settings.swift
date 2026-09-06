// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Immutable encoding preferences captured before an AV2 command builder suspends.
/// Passing the same snapshot to multiple builders keeps geometry, bit depth and
/// chunking, container and audio consistent even if Settings changes during conversion.
struct AV2Settings: Sendable {
    let container: AV2Container
    let audioCodec: AV2AudioCodec
    let audioBitrate: AudioBitrate
    let resolutionLimit: CodecResolutionLimit
    let bitDepth: AV2BitDepthOption
    let rateControlMode: AV2RateControlMode
    let quality: Int
    let targetBitrate: Int
    let speed: Int
    let tileColumns: Int
    let tileRows: Int
    let threads: Int
    let parallelChunks: Int

    init(defaults: UserDefaults = .standard) {
        container = AV2Container(rawValue: defaults.string(forKey: AppConstants.av2ContainerKey)
            ?? AppConstants.defaultAV2Container) ?? .ivf
        audioCodec = AV2AudioCodec(rawValue: defaults.string(forKey: AppConstants.av2AudioCodecKey)
            ?? AppConstants.defaultAV2AudioCodec) ?? .aac
        audioBitrate = AudioBitrate(rawValue: defaults.string(forKey: AppConstants.av2AudioBitrateKey)
            ?? AppConstants.defaultAV2AudioBitrate) ?? .k192
        resolutionLimit = CodecResolutionLimit(rawValue: defaults.string(forKey: AppConstants.av2ResolutionLimitKey)
            ?? AppConstants.defaultAV2ResolutionLimit) ?? .unlimited
        bitDepth = AV2BitDepthOption(rawValue: defaults.string(forKey: AppConstants.av2BitDepthKey)
            ?? AppConstants.defaultAV2BitDepth) ?? .auto
        rateControlMode = AV2RateControlMode(rawValue: defaults.string(forKey: AppConstants.av2RateControlModeKey)
            ?? AppConstants.defaultAV2RateControlMode) ?? .constantQuality

        // Zero is a valid saved preference (including automatic threading/chunking
        // and lossless QP); only an absent key uses the original default.
        func integer(_ key: String, fallback: Int) -> Int {
            defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
        }
        quality = integer(AppConstants.av2QualityKey, fallback: AppConstants.defaultAV2Quality)
        targetBitrate = integer(AppConstants.av2TargetBitrateKey, fallback: AppConstants.defaultAV2TargetBitrate)
        speed = integer(AppConstants.av2SpeedKey, fallback: AppConstants.defaultAV2Speed)
        tileColumns = integer(AppConstants.av2TileColumnsKey, fallback: AppConstants.defaultAV2TileColumns)
        tileRows = integer(AppConstants.av2TileRowsKey, fallback: AppConstants.defaultAV2TileRows)
        threads = integer(AppConstants.av2ThreadsKey, fallback: AppConstants.defaultAV2Threads)
        parallelChunks = integer(AppConstants.av2ParallelChunksKey, fallback: AppConstants.defaultAV2ParallelChunks)
    }
}
