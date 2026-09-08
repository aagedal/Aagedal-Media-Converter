// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Keeps the output container, encoder, and stream layout consistent throughout an export.
struct AudioOnlySettings: Sendable {
    let format: AudioOnlyFormat
    let bitDepth: AudioOnlyBitDepth
    let aacBitrate: AudioBitrate
    let mp4Codec: AudioOnlyMP4Codec
    let mp4Bitrate: AudioBitrate
    let preserveMetadata: Bool

    init(defaults: UserDefaults = .standard) {
        format = AudioOnlyFormat(rawValue: defaults.string(forKey: AppConstants.audioOnlyFormatKey)
            ?? AppConstants.defaultAudioOnlyFormat) ?? .wav
        bitDepth = AudioOnlyBitDepth(rawValue: defaults.string(forKey: AppConstants.audioOnlyBitDepthKey)
            ?? AppConstants.defaultAudioOnlyBitDepth) ?? .pcm24
        aacBitrate = AudioBitrate(rawValue: defaults.string(forKey: AppConstants.audioOnlyAACBitrateKey)
            ?? AppConstants.defaultAudioOnlyAACBitrate) ?? .k192
        mp4Codec = AudioOnlyMP4Codec(rawValue: defaults.string(forKey: AppConstants.audioOnlyMP4CodecKey)
            ?? AppConstants.defaultAudioOnlyMP4Codec) ?? .aac
        mp4Bitrate = AudioBitrate(rawValue: defaults.string(forKey: AppConstants.audioOnlyMP4BitrateKey)
            ?? AppConstants.defaultAudioOnlyMP4Bitrate) ?? .k192
        preserveMetadata = defaults.bool(forKey: AppConstants.preserveMetadataPreferenceKey)
    }

    var ffmpegArguments: [String] {
        var args = ["-hide_banner", "-vn", "-map", "0:a"]
        switch format {
        case .wav:
            args += ["-rf64", "auto", "-c:a", bitDepth.ffmpegCodec]
        case .aac:
            args += ["-c:a", "aac", "-b:a", aacBitrate.ffmpegValue, "-movflags", "+faststart"]
        case .mp4:
            args += ["-c:a", mp4Codec.ffmpegCodec]
            if mp4Codec.requiresBitrate {
                args += ["-b:a", mp4Bitrate.ffmpegValue]
            }
            args += ["-movflags", "+faststart"]
        case .flac:
            args += ["-c:a", "flac"]
        }
        ExportPreset.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata)
        return args
    }
}
