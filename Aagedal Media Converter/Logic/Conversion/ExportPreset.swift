//
//  ExportPreset.swift
//  Aagedal Media Converter
//
//  Created by Truls Aagedal on 09/11/2025.
//

// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import CoreGraphics

enum ProResProfile: String, CaseIterable, Identifiable {
    case proxy = "Proxy"
    case lt = "LT"
    case standard = "422"
    case hq = "HQ"
    case fourFourFourFour = "4444"
    case fourFourFourFourXQ = "4444 XQ"
    
    var id: String { rawValue }
    
    var ffmpegProfileName: String {
        switch self {
        case .proxy: return "proxy"
        case .lt: return "lt"
        case .standard: return "standard"
        case .hq: return "hq"
        case .fourFourFourFour: return "4444"
        case .fourFourFourFourXQ: return "xq"
        }
    }
}

enum ExportPreset: String, CaseIterable, Identifiable {
    case videoLoop = "VideoLoop"
    case videoLoopWithAudio = "VideoLoop w/Audio"
    case tvQualityHD = "TV — HD"
    case tvQuality4K = "TV — 4K"
    case prores = "ProRes"
    case streamCopy = "Stream Copy"
    case animatedAVIF = "Animated AVIF"
    case hevcProxy1080p = "HEVC Proxy"
    case audioUncompressedWAV = "Audio only WAV (all channels)"
    case audioStereoAAC = "Audio only AAC (stereo downmix)"
    case custom1 = "Custom"
    case custom2 = "Custom 2"
    case custom3 = "Custom 3"
    
    var id: String { rawValue }
    
    var fileExtension: String {
        switch self {
        case .videoLoop, .videoLoopWithAudio:
            return "mp4"
        case .prores, .tvQualityHD, .tvQuality4K, .hevcProxy1080p:
            return "mov"
        case .streamCopy:
            return "mp4"
        case .animatedAVIF:
            return "avif"
        case .audioUncompressedWAV:
            return "wav"
        case .audioStereoAAC:
            return "m4a"
        case .custom1, .custom2, .custom3:
            guard let slot = customSlotIndex else { return "mp4" }
            return Self.customFileExtension(for: slot)
        }
    }

    func outputExtension(for sourceURL: URL?) -> String {
        guard self == .streamCopy else {
            return fileExtension
        }

        if let ext = sourceURL?.pathExtension, !ext.isEmpty {
            return ext.lowercased()
        }

        return fileExtension
    }
    
    var displayName: String {
        if let slot = customSlotIndex {
            return Self.customDisplayName(for: slot)
        }
        return rawValue
    }
    
    var description: String {
        switch self {
        case .videoLoop:
            return NSLocalizedString("PRESET_VIDEO_LOOP_DESCRIPTION", comment: "Description for VideoLoop preset")
        case .videoLoopWithAudio:
            return NSLocalizedString("PRESET_VIDEO_LOOP_WITH_AUDIO_DESCRIPTION", comment: "Description for VideoLoop with Audio preset")
        case .tvQualityHD:
            return NSLocalizedString("PRESET_TV_QUALITY_HD_DESCRIPTION", comment: "Description for TV Quality HD preset")
        case .tvQuality4K:
            return NSLocalizedString("PRESET_TV_QUALITY_4K_DESCRIPTION", comment: "Description for TV Quality 4K preset")
        case .prores:
            return NSLocalizedString("PRESET_PRORES_DESCRIPTION", comment: "Description for ProRes preset")
        case .streamCopy:
            return NSLocalizedString("PRESET_STREAM_COPY_DESCRIPTION", comment: "Description for Stream Copy preset")
        case .animatedAVIF:
            return NSLocalizedString("PRESET_ANIMATED_AVIF_DESCRIPTION", comment: "Description for Animated AVIF preset")
        case .hevcProxy1080p:
            return NSLocalizedString("PRESET_HEVC_PROXY_DESCRIPTION", comment: "Description for HECV Proxy 1080p preset")
        case .audioUncompressedWAV:
            return NSLocalizedString("PRESET_AUDIO_WAV_DESCRIPTION", comment: "Description for Audio WAV preset")
        case .audioStereoAAC:
            return NSLocalizedString("PRESET_AUDIO_AAC_STEREO_DESCRIPTION", comment: "Description for Audio AAC Stereo preset")
        case .custom1, .custom2, .custom3:
            return NSLocalizedString("PRESET_CUSTOM_DESCRIPTION", comment: "Description for Custom preset")
        }
    }
    
    var fileSuffix: String {
        switch self {
        case .videoLoop:
            return "_loop"
        case .videoLoopWithAudio:
            return "_loop_audio"
        case .tvQualityHD:
            return "_tv_hd"
        case .tvQuality4K:
            return "_tv_4k"
        case .prores:
            return "_prores"
        case .streamCopy:
            return "_copy"
        case .animatedAVIF:
            return "_avif"
        case .hevcProxy1080p:
            return "_proxy_1080p"
        case .audioUncompressedWAV:
            return "_audio_wav"
        case .audioStereoAAC:
            return "_audio_aac"
        case .custom1, .custom2, .custom3:
            guard let slot = customSlotIndex else { return "_custom" }
            return Self.customFileSuffix(for: slot)
        }
    }
    
    var ffmpegArguments: [String] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        
        let commonArgs = ["-hide_banner"]
        let preserveMetadata = UserDefaults.standard.bool(forKey: AppConstants.preserveMetadataPreferenceKey)
        
        switch self {
        case .videoLoop:
            var args = commonArgs + [
                "-bitexact",
                "-bsf:v", "filter_units=remove_types=6",
                "-pix_fmt", "yuv420p",
                "-vcodec", "libx264",
                "-movflags", "+faststart",
                "-preset", "veryslow",
                "-crf", "23",
                "-minrate", "3000k",
                "-maxrate", "9000k",
                "-bufsize", "18000k",
                "-profile:v", "main",
                "-level:v", "4.0",
                "-an",
                "-vf", "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),1080,-2)':h='if(lte(iw,ih),-2,1080)'"
            ]
            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata)
            return args
        case .videoLoopWithAudio:
            var args = commonArgs + [
                "-bitexact",
                "-bsf:v", "filter_units=remove_types=6",
                "-pix_fmt", "yuv420p",
                "-vcodec", "libx264",
                "-movflags", "+faststart",
                "-preset", "veryslow",
                "-crf", "23",
                "-minrate", "3000k",
                "-maxrate", "9000k",
                "-bufsize", "18000k",
                "-profile:v", "main",
                "-level:v", "4.0",
                "-c:a", "aac",
                "-b:a", "192k",
                "-vf", "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),1080,-2)':h='if(lte(iw,ih),-2,1080)'"
            ]
            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata)
            return args
        case .tvQualityHD:
            var args = commonArgs + [
                "-pix_fmt", "p010le",
                "-c:v", "hevc_videotoolbox",
                "-b:v", "18M",
                "-profile:v", "main10",
                "-tag:v", "hvc1",
                "-c:a", "pcm_s24le",
                "-map", "0:v",
                "-map", "0:a",
                "-vf", "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),1080,-2)':h='if(lte(iw,ih),-2,1080)'"
            ]
            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata, defaultMap: "0")
            return args
        case .tvQuality4K:
            var args = commonArgs + [
                "-pix_fmt", "p010le",
                "-c:v", "hevc_videotoolbox",
                "-b:v", "60M",
                "-profile:v", "main10",
                "-tag:v", "hvc1",
                "-c:a", "pcm_s24le",
                "-map", "0:v",
                "-map", "0:a",
                "-vf", "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),2160,-2)':h='if(lte(iw,ih),-2,2160)'"
            ]
            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata, defaultMap: "0")
            return args
        case .animatedAVIF:
            var args = commonArgs + [
                "-pix_fmt", "p010le",
                "-vcodec", "libsvtav1",
                "-preset", "6",
                "-crf", "28", "-an",
                "-vf", "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),900,-2)':h='if(lte(iw,ih),-2,900)'"
            ]
            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata)
            return args
        case .hevcProxy1080p:
            var args = commonArgs + [
                "-pix_fmt", "p010le",
                "-c:v", "hevc_videotoolbox",
                "-b:v", "6M",
                "-profile:v", "main10",
                "-tag:v", "hvc1",
                "-vf", "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),1080,-2)':h='if(lte(iw,ih),-2,1080)'",
                "-map", "0:v",
                "-c:a", "pcm_s24le",
                "-map", "0:a"
            ]
            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata, defaultMap: "0")
            return args
        case .prores:
            let profileRaw = UserDefaults.standard.string(forKey: AppConstants.proResProfileKey) ?? ProResProfile.standard.rawValue
            let profile = ProResProfile(rawValue: profileRaw) ?? .standard
            
            var args = commonArgs + [
                "-pix_fmt", "yuv422p10le",
                "-vcodec", "prores_videotoolbox",
                "-profile:v", profile.ffmpegProfileName,
                "-c:a", "pcm_s24le",
                "-map", "0:v",
                "-map", "0:a"
            ]
            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata, defaultMap: "0")
            return args
        case .streamCopy:
            var args = commonArgs + [
                "-map", "0",
                "-c", "copy",
            ]
            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata, defaultMap: "0")
            return args
        case .audioUncompressedWAV:
            var args = commonArgs + [
                "-vn",
                "-map", "0:a",
                "-rf64", "auto",
                "-c:a", "pcm_s24le"
            ]
            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata)
            return args
        case .audioStereoAAC:
            var args = commonArgs + [
                "-vn",
                "-map", "0:a",
                "-ac", "2",
                "-c:a", "aac",
                "-b:a", "192k",
                "-movflags", "+faststart"
            ]
            ExportPreset.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata)
            return args
        case .custom1, .custom2, .custom3:
            guard let slot = customSlotIndex else { return commonArgs }
            let customArgs = ExportPreset.parseCustomCommand(ExportPreset.customCommandString(for: slot))
            return commonArgs + customArgs
        }
    }
    
    var customSlotIndex: Int? {
        switch self {
        case .custom1: return 0
        case .custom2: return 1
        case .custom3: return 2
        default: return nil
        }
    }
    
    var isCustom: Bool { customSlotIndex != nil }
}

extension ExportPreset {
    /// Indicates whether this preset is expected to output a video track even if the source lacks one.
    var outputsVideoTrack: Bool {
        switch self {
        case .audioUncompressedWAV, .audioStereoAAC:
            return false
        case .streamCopy:
            return false
        default:
            return true
        }
    }

    /// Indicates whether this preset is expected to output an audio track.
    var outputsAudioTrack: Bool {
        switch self {
        case .videoLoop, .animatedAVIF:
            return false
        case .audioUncompressedWAV, .audioStereoAAC:
            return true
        case .streamCopy:
            return true
        default:
            return true
        }
    }

    /// Optional per-preset override for waveform/padded video resolution.
    var waveformResolutionOverride: CGSize? {
        switch self {
        case .tvQuality4K:
            return CGSize(width: 3840, height: 2160)
        case .tvQualityHD, .hevcProxy1080p:
            return CGSize(width: 1920, height: 1080)
        default:
            return nil
        }
    }

    func resolvedWaveformResolution(defaultResolution: CGSize) -> CGSize {
        waveformResolutionOverride ?? defaultResolution
    }
}

// MARK: - Helpers

extension ExportPreset {
    static func applyMetadataStrategy(to args: inout [String], preserveMetadata: Bool, defaultMap: String = "-1") {
        removeArgumentPair("-map_metadata", from: &args)
        removeArgumentPair("-map_chapters", from: &args)
        removeArgumentPair("-metadata", value: "encoder=' '", from: &args)
        removeArgumentPair("-metadata:s:v:0", value: "encoder=' '", from: &args)
        
        if preserveMetadata {
            if defaultMap != "-1" {
                appendArgumentPair("-map_metadata", value: defaultMap, to: &args)
                appendArgumentPair("-map_chapters", value: defaultMap, to: &args)
            }
        } else {
            appendArgumentPair("-map_metadata", value: "-1", to: &args)
            appendArgumentPair("-map_chapters", value: "-1", to: &args)
            appendArgumentPair("-metadata", value: "encoder=' '", to: &args)
            appendArgumentPair("-metadata:s:v:0", value: "encoder=' '", to: &args)
        }
    }
    
    private static func removeArgumentPair(_ key: String, value: String? = nil, from args: inout [String]) {
        var index = 0
        while index < args.count {
            if args[index] == key {
                if let value {
                    if index + 1 < args.count, args[index + 1] == value {
                        args.remove(at: index)
                        args.remove(at: index)
                        continue
                    }
                } else {
                    args.remove(at: index)
                    if index < args.count {
                        args.remove(at: index)
                    }
                    continue
                }
            }
            index += 1
        }
    }
    
    private static func appendArgumentPair(_ key: String, value: String, to args: inout [String]) {
        var index = 0
        while index < args.count - 1 {
            if args[index] == key && args[index + 1] == value {
                return
            }
            index += 1
        }
        args.append(contentsOf: [key, value])
    }
    
    private static func customDisplayName(for slot: Int) -> String {
        let defaults = UserDefaults.standard
        let nameKeys = [
            AppConstants.customPreset1NameKey,
            AppConstants.customPreset2NameKey,
            AppConstants.customPreset3NameKey
        ]
        let prefixes = AppConstants.customPresetPrefixes
        let fallbackSuffixes = AppConstants.defaultCustomPresetNameSuffixes
        let prefix = slot < prefixes.count ? prefixes[slot] : "C\(slot + 1):"
        let fallbackSuffix = slot < fallbackSuffixes.count ? fallbackSuffixes[slot] : "Custom Preset"
        let nameKey = slot < nameKeys.count ? nameKeys[slot] : nil
        let storedSuffix = nameKey.flatMap { defaults.string(forKey: $0) }
        let sanitizedSuffix = sanitizeCustomNameSuffix(storedSuffix, fallback: fallbackSuffix)
        return "\(prefix) \(sanitizedSuffix)"
    }
    
    private static func sanitizeCustomNameSuffix(_ value: String?, fallback: String) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        if trimPrefixIfPresent(trimmed, prefix: "C1:") ||
            trimPrefixIfPresent(trimmed, prefix: "C2:") ||
            trimPrefixIfPresent(trimmed, prefix: "C3:") {
            let noPrefix = trimmed
                .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return noPrefix.isEmpty ? fallback : noPrefix
        }
        return trimmed
    }
    
    private static func trimPrefixIfPresent(_ value: String, prefix: String) -> Bool {
        value.lowercased().hasPrefix(prefix.lowercased())
    }
    
    private static func customFileSuffix(for slot: Int) -> String {
        let defaults = UserDefaults.standard
        let keys = [
            AppConstants.customPreset1SuffixKey,
            AppConstants.customPreset2SuffixKey,
            AppConstants.customPreset3SuffixKey
        ]
        let fallback = slot < AppConstants.defaultCustomPresetSuffixes.count ? AppConstants.defaultCustomPresetSuffixes[slot] : "_c\(slot + 1)"
        let key = slot < keys.count ? keys[slot] : nil
        let stored = key.flatMap { defaults.string(forKey: $0) } ?? fallback
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : (trimmed.hasPrefix("_") ? trimmed : "_" + trimmed)
    }
    
    private static func customFileExtension(for slot: Int) -> String {
        let defaults = UserDefaults.standard
        let keys = [
            AppConstants.customPreset1ExtensionKey,
            AppConstants.customPreset2ExtensionKey,
            AppConstants.customPreset3ExtensionKey
        ]
        let fallback = slot < AppConstants.defaultCustomPresetExtensions.count ? AppConstants.defaultCustomPresetExtensions[slot] : "mp4"
        let key = slot < keys.count ? keys[slot] : nil
        var stored = key.flatMap { defaults.string(forKey: $0) } ?? fallback
        stored = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if stored.hasPrefix(".") {
            stored.removeFirst()
        }
        stored = stored.replacingOccurrences(of: " ", with: "")
        return stored.isEmpty ? fallback : stored.lowercased()
    }
    
    private static func customCommandString(for slot: Int) -> String {
        let defaults = UserDefaults.standard
        let keys = [
            AppConstants.customPreset1CommandKey,
            AppConstants.customPreset2CommandKey,
            AppConstants.customPreset3CommandKey
        ]
        let fallback = slot < AppConstants.defaultCustomPresetCommands.count ? AppConstants.defaultCustomPresetCommands[slot] : "-c copy"
        let key = slot < keys.count ? keys[slot] : nil
        let stored = key.flatMap { defaults.string(forKey: $0) } ?? fallback
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
    
    private static func parseCustomCommand(_ command: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?
        var isEscaping = false
        
        for char in command {
            if isEscaping {
                current.append(char)
                isEscaping = false
                continue
            }
            
            if char == "\\" {
                isEscaping = true
                continue
            }
            
            if char == "\"" || char == "'" {
                if quote == char {
                    quote = nil
                } else if quote == nil {
                    quote = char
                } else {
                    current.append(char)
                }
                continue
            }
            
            if char.isWhitespace && quote == nil {
                if !current.isEmpty {
                    args.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        
        if !current.isEmpty {
            args.append(current)
        }
        
        return args
    }
}

