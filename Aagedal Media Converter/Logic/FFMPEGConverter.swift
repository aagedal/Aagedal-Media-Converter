// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import OSLog

enum ExportPreset: String, CaseIterable, Identifiable {
    case videoLoop = "VideoLoop"
    case videoLoopWithAudio = "VideoLoop w/Audio"
    case tvQualityHD = "TV — HD"
    case tvQuality4K = "TV — 4K"
    case prores = "ProRes"
    case animatedAVIF = "Animated AVIF"
    case hevcProxy1080p = "HEVC Proxy"
    case audioUncompressedWAV = "Audio only WAV (all channels)"
    case audioStereoAAC = "Audio only AAC (stereo downmix)"
    case custom1 = "Custom"
    case custom2 = "Custom 2"
    case custom3 = "Custom 3"
    
    var id: String { self.rawValue }
    
    var fileExtension: String {
        switch self {
        case .videoLoop, .videoLoopWithAudio:
            return "mp4"
        case .tvQualityHD, .tvQuality4K, .prores, .hevcProxy1080p:
            return "mov"
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
    
    var displayName: String {
        if let slot = customSlotIndex {
            return Self.customDisplayName(for: slot)
        }
        return self.rawValue
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
        let currentDateString = dateFormatter.string(from: Date())

        
        let commonArgs = [
            "-hide_banner",
        ]

        let preserveMetadata = UserDefaults.standard.bool(forKey: AppConstants.preserveMetadataPreferenceKey)

        switch self {
        case .videoLoop:
            var args = commonArgs + [
                "-bitexact",
                "-bsf:v", "filter_units=remove_types=6",

                // TODO: Implement UI text box for user comment to be added to the comment metadata.
                "-metadata", "comment=Date generated: \(currentDateString) ADD USER COMMENT HERE",
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
                "-vf", "yadif=0,scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),1080,-2)':h='if(lte(iw,ih),-2,1080)'"
            ]
            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata)
            return args
            
        case .videoLoopWithAudio:
            var args = commonArgs + [
                "-bitexact",
                "-bsf:v", "filter_units=remove_types=6",

                // TODO: Implement UI text box for user comment to be added to the comment metadata.
                "-metadata", "comment=Date generated: \(currentDateString) ADD USER COMMENT HERE",
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
                "-vf", "yadif=0,scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),1080,-2)':h='if(lte(iw,ih),-2,1080)'"
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
                "-crf", "33", "-an",
                "-vf", "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),720,-2)':h='if(lte(iw,ih),-2,720)'"
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
                "-map", "0:a",
            ]
            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata, defaultMap: "0")
            return args
        case .prores:
            var args = commonArgs + [
                "-pix_fmt", "yuv422p10le",
                "-vcodec", "prores_videotoolbox",
                "-profile:v", "standard",
                "-c:a", "pcm_s24le",
                "-map", "0:v",
                "-map", "0:a",
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
    
    var isCustom: Bool {
        customSlotIndex != nil
    }

    private static func applyMetadataStrategy(to args: inout [String], preserveMetadata: Bool, defaultMap: String = "-1") {
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
                let hasValue = value == nil || (index + 1 < args.count && args[index + 1] == value!)
                if hasValue {
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
        if trimPrefixIfPresent(trimmed, prefix: "C1:") || trimPrefixIfPresent(trimmed, prefix: "C2:") || trimPrefixIfPresent(trimmed, prefix: "C3:") {
            let noPrefix = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
        var quote: Character? = nil
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

actor FFMPEGConverter {
    private var currentProcess: Process?

    /// Converts a video file using the specified export preset
    /// - Parameters:
    ///   - inputURL: The source video file URL
    ///   - outputURL: The destination URL (without extension)
    ///   - preset: The export preset to use
    ///   - comment: The comment to be added to the metadata
    ///   - progressUpdate: Callback for progress updates (progress: Double, status: String?)
    ///   - completion: Callback for completion (success: Bool)
    func convert(
        inputURL: URL,
        outputURL: URL,
        preset: ExportPreset = .videoLoop,
        comment: String = "",
        includeDateTag: Bool = true,
        trimStart: Double? = nil,
        trimEnd: Double? = nil,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void,
        completion: @escaping @Sendable (Bool) -> Void
    ) async {
        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            print("FFMPEG binary not found in bundle")
            completion(false)
            return
        }

        // Ensure output directory exists
        let fileManager = FileManager.default
        let outputDir = outputURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            print("Failed to create output directory: \(error)")
            completion(false)
            return
        }

        // Add file extension based on preset
        let outputFileURL = outputURL.appendingPathExtension(preset.fileExtension)
        
        // Remove existing file if it exists
        if fileManager.fileExists(atPath: outputFileURL.path) {
            do {
                try fileManager.removeItem(at: outputFileURL)
            } catch {
                print("Failed to remove existing file: \(error)")
                completion(false)
                return
            }
        }

        let process = Process()
        await setCurrentProcess(process)
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        
        // Build FFmpeg arguments
        var arguments = ["-y"]

        let normalizedTrimStart = Self.normalizedTrimPoint(trimStart)
        let normalizedTrimEnd = Self.normalizedTrimPoint(trimEnd)

        if let normalizedTrimStart {
            arguments.append(contentsOf: ["-ss", Self.ffmpegTimeString(from: normalizedTrimStart)])
        }

        arguments.append(contentsOf: ["-i", inputURL.path])
        
        // Get the base arguments for the preset
        var ffmpegArgs = preset.ffmpegArguments

        await Self.adjustArgumentsForInput(preset: preset, inputURL: inputURL, ffmpegArgs: &ffmpegArgs)
        
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let commentMetadataValue: String? = {
            if includeDateTag {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyyMMdd"
                let currentDateString = dateFormatter.string(from: Date())
                let commentSuffix = trimmedComment.isEmpty ? "" : " | \(trimmedComment)"
                return "comment=Date generated: \(currentDateString)\(commentSuffix)"
            } else if !trimmedComment.isEmpty {
                return "comment=\(trimmedComment)"
            } else {
                return nil
            }
        }()
        
        // Replace the placeholder comment with the actual comment if it exists
        if let metadataValueIndex = ffmpegArgs.firstIndex(where: { $0.contains("comment=Date generated:") }) {
            if let commentMetadataValue {
                ffmpegArgs[metadataValueIndex] = commentMetadataValue
            } else {
                let metadataKeyIndex = metadataValueIndex - 1
                ffmpegArgs.remove(at: metadataValueIndex)
                if metadataKeyIndex >= 0 && metadataKeyIndex < ffmpegArgs.count && ffmpegArgs[metadataKeyIndex] == "-metadata" {
                    ffmpegArgs.remove(at: metadataKeyIndex)
                }
            }
        }

        // Ensure comment metadata is present for presets without placeholders (e.g., hardware encoders)
        var hasCommentMetadata = false
        var metadataScanIndex = 0
        while metadataScanIndex < ffmpegArgs.count - 1 {
            if ffmpegArgs[metadataScanIndex] == "-metadata" && ffmpegArgs[metadataScanIndex + 1].hasPrefix("comment=") {
                hasCommentMetadata = true
                break
            }
            metadataScanIndex += 1
        }
        if !hasCommentMetadata, let commentMetadataValue {
            ffmpegArgs.append(contentsOf: ["-metadata", commentMetadataValue])
        }
        
        if let durationArgument = Self.trimDurationArgument(start: normalizedTrimStart, end: normalizedTrimEnd) {
            arguments.append(contentsOf: durationArgument)
        }

        arguments.append(contentsOf: ffmpegArgs)
        arguments.append(outputFileURL.path)
        
        process.arguments = arguments
        
        print("FFmpeg command: \(ffmpegPath) \(arguments.joined(separator: " "))")

        // Only process stderr as that's where FFMPEG sends its progress updates
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe() // Still need to capture stdout to prevent hanging

        // Calculate the effective duration for progress/ETA (trimmed duration if applicable)
        let effectiveDuration: Double? = {
            if let start = normalizedTrimStart, let end = normalizedTrimEnd {
                return max(end - start, 0)
            } else if let end = normalizedTrimEnd {
                return end
            }
            return nil
        }()
        
        let totalDurationBox = DurationBox()
        let effectiveDurationBox = DurationBox()
        effectiveDurationBox.value = effectiveDuration
        
        let errorReadabilityHandler: @Sendable (FileHandle) -> Void = { fileHandle in
            let data = fileHandle.availableData
            if let output = String(data: data, encoding: .utf8), !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Process the output through our handler
                let (newTotalDuration, _) = Self.handleFFMPEGOutput(
                    output, 
                    totalDuration: totalDurationBox.value, 
                    effectiveDuration: effectiveDurationBox.value,
                    progressUpdate: progressUpdate
                )
                if let newTotalDuration = newTotalDuration {
                    totalDurationBox.value = newTotalDuration
                    // Set effective duration if not already set
                    if effectiveDurationBox.value == nil {
                        effectiveDurationBox.value = newTotalDuration
                    }
                }
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = errorReadabilityHandler

        process.terminationHandler = { [weak self] _ in
            Task { [weak self] in
                await self?.setCurrentProcess(nil)
                let success = process.terminationStatus == 0
                completion(success)
            }
        }

        do {
            try process.run()
        } catch {
            print("Failed to run process: \(error)")
            completion(false)
        }
    }

    func cancelConversion() async {
        currentProcess?.terminate()
        await setCurrentProcess(nil)
    }

    private static func normalizedTrimPoint(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return max(value, 0)
    }

    private static func trimDurationArgument(start: Double?, end: Double?) -> [String]? {
        switch (start, end) {
        case let (nil, .some(endSeconds)) where endSeconds > 0:
            return ["-to", ffmpegTimeString(from: endSeconds)]
        case let (.some(startSeconds), .some(endSeconds)):
            let duration = max(endSeconds - startSeconds, 0)
            guard duration > 0 else { return nil }
            return ["-t", ffmpegTimeString(from: duration)]
        default:
            return nil
        }
    }

    private static func ffmpegTimeString(from seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    private func setCurrentProcess(_ process: Process?) async {
        self.currentProcess = process
    }

    private class DurationBox: @unchecked Sendable {
        var value: Double? = nil
    }

    private struct AudioStreamInfo: Decodable {
        let index: Int?
        let channels: Int?
        let channelLayout: String?

        private enum CodingKeys: String, CodingKey {
            case index
            case channels
            case channelLayout = "channel_layout"
        }
    }

    private struct FFProbeStreamsResponse: Decodable {
        let streams: [AudioStreamInfo]
    }

    private static func adjustArgumentsForInput(preset: ExportPreset, inputURL: URL, ffmpegArgs: inout [String]) async {
        guard preset == .audioUncompressedWAV else { return }
        guard let ffprobePath = Bundle.main.path(forResource: "ffprobe", ofType: nil) else { return }

        guard let audioStreams = await fetchAudioStreams(ffprobePath: ffprobePath, url: inputURL), audioStreams.count > 1 else {
            return
        }

        removeArgumentPair("-map", value: "0:a", from: &ffmpegArgs)

        let totalChannels = audioStreams.compactMap { $0.channels }.reduce(0, +)
        let filterInputs = audioStreams.indices.map { "[0:a:\($0)]" }.joined()
        let filterGraph = "\(filterInputs)amerge=inputs=\(audioStreams.count)[aout]"

        ffmpegArgs.append(contentsOf: ["-filter_complex", filterGraph, "-map", "[aout]"])

        if totalChannels > 0 {
            ffmpegArgs.append(contentsOf: ["-ac", "\(totalChannels)"])
        }
    }

    private static func fetchAudioStreams(ffprobePath: String, url: URL) async -> [AudioStreamInfo]? {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "error",
            "-select_streams", "a",
            "-show_entries", "stream=index,channels,channel_layout",
            "-of", "json",
            url.path
        ]
        process.standardOutput = pipe

        do {
            let timeout: TimeInterval = 5.0

            try process.run()

            let outputData = try await withThrowingTaskGroup(of: Data.self) { group -> Data? in
                group.addTask {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.terminate()
                    return data
                }

                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    process.terminate()
                    throw NSError(domain: "com.aagedal.videoconverter.ffprobe", code: -2, userInfo: [NSLocalizedDescriptionKey: "FFprobe audio stream timeout"])
                }

                let result = try await group.next()!
                group.cancelAll()
                return result
            }

            guard let outputData, !outputData.isEmpty else {
                Logger().warning("FFprobe returned no audio stream data for \(url.lastPathComponent)")
                return []
            }

            do {
                let response = try JSONDecoder().decode(FFProbeStreamsResponse.self, from: outputData)
                Logger().debug("FFprobe audio streams for \(url.lastPathComponent): \(response.streams.map { $0.channels ?? 0 })")
                return response.streams
            } catch {
                Logger().error("Failed to decode FFprobe audio stream data for \(url.lastPathComponent): \(error.localizedDescription)")
                return nil
            }
        } catch {
            Logger().error("FFprobe audio stream extraction failed for \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    private static func removeArgumentPair(_ key: String, value: String?, from args: inout [String]) {
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
    
    /// Processes FFmpeg output to extract progress and duration information
    /// - Parameters:
    ///   - output: The FFmpeg output string to process
    ///   - totalDuration: The current total duration if already known
    ///   - effectiveDuration: The effective duration for ETA calculation (trimmed duration if applicable)
    ///   - progressUpdate: Callback to report progress updates
    /// - Returns: A tuple containing the updated total duration (if found) and the current progress
    private static func handleFFMPEGOutput(_ output: String, 
                                         totalDuration: Double?,
                                         effectiveDuration: Double?,
                                         progressUpdate: @escaping @Sendable (Double, String?) -> Void) -> (Double?, (Double, String?)?) {
        var newTotalDuration = totalDuration
        
        // Try to parse the total duration if not already known
        if newTotalDuration == nil, let duration = ParsingUtils.parseDuration(from: output) {
            newTotalDuration = duration
            print("Total Duration: \(duration) seconds")
        }
        
        // Use effective duration for progress calculation, fallback to total duration
        let durationForProgress = effectiveDuration ?? newTotalDuration
        
        // Parse and report progress if we have a valid duration
        var progressTuple: (Double, String?)? = nil
        if let progress = ParsingUtils.parseProgress(from: output, totalDuration: durationForProgress) {
            // Update progress on the main thread
            Task { @MainActor in
                progressUpdate(progress.0, progress.1)
                print("Progress: \(Int(progress.0 * 100))% ETA: \(progress.1 ?? "N/A")")
            }
            progressTuple = progress
        }
        
        return (newTotalDuration, progressTuple)
    }
    
    /// Gets the duration of a video file using ffprobe
    /// - Parameter url: URL of the video file
    /// - Returns: Duration in seconds, or nil if unable to determine
    static func getVideoDuration(url: URL) async -> Double? {
        // First check if ffprobe is available
        guard let ffprobePath = Bundle.main.path(forResource: "ffprobe", ofType: nil) else {
            Logger().info("FFprobe not found in bundle, will use AVFoundation for duration extraction")
            return nil
        }
        
        Logger().info("Attempting to get duration using ffprobe for: \(url.lastPathComponent)")
        return await getDurationUsingFFprobe(ffprobePath: ffprobePath, url: url)
    }
    
    /// Gets the duration using ffprobe
    /// - Parameters:
    ///   - ffprobePath: Path to the ffprobe binary
    ///   - url: URL of the video file
    /// - Returns: Duration in seconds, or nil if unable to determine
    private static func getDurationUsingFFprobe(ffprobePath: String, url: URL) async -> Double? {
        let process = Process()
        let pipe = Pipe()
        
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path
        ]
        process.standardOutput = pipe
        
        do {
            // Set a timeout for the process (5 seconds)
            let timeout: TimeInterval = 5.0
            
            try process.run()
            
            // Read the output asynchronously with timeout
            let output = try await withThrowingTaskGroup(of: Data.self) { group -> String? in
                group.addTask {
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.terminate() // Ensure process is terminated
                    return data
                }
                
                // Add a timeout task
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    process.terminate() // Terminate if timeout
                    throw NSError(domain: "com.aagedal.videoconverter.ffprobe", code: -1, 
                                userInfo: [NSLocalizedDescriptionKey: "FFprobe timeout"])
                }
                
                // Wait for the first task to complete
                let result = try await group.next()!
                group.cancelAll()
                return String(data: result, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            
            if let output = output {
                Logger().info("FFprobe raw output: \"\(output)\"")
                if let duration = Double(output) {
                    Logger().info("Successfully parsed duration from ffprobe: \(duration) seconds")
                    return duration
                } else {
                    Logger().error("Failed to convert ffprobe output to Double: \"\(output)\"")
                }
            }
            
            Logger().error("Failed to parse duration from ffprobe output")
            return nil
            
        } catch {
            Logger().error("FFprobe process failed: \(error.localizedDescription)")
            return nil
        }
    }
}
