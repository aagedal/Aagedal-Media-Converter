// Aagedal VideoLoop Converter 2.0
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
    case custom = "Custom"
    
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
        case .custom:
            return Self.customFileExtension()
        }
    }
    
    var displayName: String {
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
        case .custom:
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
        case .custom:
            return Self.customFileSuffix()
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
            Self.applyMetadataStrategy(to: &args, preserveMetadata: preserveMetadata)
            return args
        case .custom:
            let customArgs = Self.parseCustomCommand(Self.customCommandString())
            return commonArgs + customArgs
        }
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

    private static func customFileSuffix() -> String {
        let stored = UserDefaults.standard.string(forKey: AppConstants.customPresetSuffixKey) ?? "_custom"
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "_custom" : trimmed
    }

    private static func customFileExtension() -> String {
        let stored = UserDefaults.standard.string(forKey: AppConstants.customPresetExtensionKey) ?? "mp4"
        var trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") {
            trimmed.removeFirst()
        }
        trimmed = trimmed.replacingOccurrences(of: " ", with: "")
        return trimmed.isEmpty ? "mp4" : trimmed.lowercased()
    }

    private static func customCommandString() -> String {
        let stored = UserDefaults.standard.string(forKey: AppConstants.customPresetCommandKey) ?? "-c copy"
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "-c copy" : trimmed
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
        var arguments = ["-y", "-i", inputURL.path]
        
        // Get the base arguments for the preset
        var ffmpegArgs = preset.ffmpegArguments
        
        // Replace the placeholder comment with the actual comment if it exists
        if let metadataValueIndex = ffmpegArgs.firstIndex(where: { $0.contains("comment=Date generated:") }) {
            let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
            if includeDateTag {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyyMMdd"
                let currentDateString = dateFormatter.string(from: Date())
                let commentSuffix = trimmedComment.isEmpty ? "" : " | \(trimmedComment)"
                ffmpegArgs[metadataValueIndex] = "comment=Date generated: \(currentDateString)\(commentSuffix)"
            } else {
                if trimmedComment.isEmpty {
                    let metadataKeyIndex = metadataValueIndex - 1
                    ffmpegArgs.remove(at: metadataValueIndex)
                    if metadataKeyIndex >= 0 && metadataKeyIndex < ffmpegArgs.count && ffmpegArgs[metadataKeyIndex] == "-metadata" {
                        ffmpegArgs.remove(at: metadataKeyIndex)
                    }
                } else {
                    ffmpegArgs[metadataValueIndex] = "comment=\(trimmedComment)"
                }
            }
        }
        
        arguments.append(contentsOf: ffmpegArgs)
        arguments.append(outputFileURL.path)
        
        process.arguments = arguments
        
        print("FFmpeg command: \(ffmpegPath) \(arguments.joined(separator: " "))")

        // Only process stderr as that's where FFMPEG sends its progress updates
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe() // Still need to capture stdout to prevent hanging

        let totalDurationBox = DurationBox()
        let errorReadabilityHandler: @Sendable (FileHandle) -> Void = { fileHandle in
            let data = fileHandle.availableData
            if let output = String(data: data, encoding: .utf8), !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Process the output through our handler
                let (newTotalDuration, _) = Self.handleFFMPEGOutput(output, totalDuration: totalDurationBox.value, progressUpdate: progressUpdate)
                if let newTotalDuration = newTotalDuration {
                    totalDurationBox.value = newTotalDuration
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

    private func setCurrentProcess(_ process: Process?) async {
        self.currentProcess = process
    }

    private class DurationBox: @unchecked Sendable {
        var value: Double? = nil
    }
    
    /// Processes FFmpeg output to extract progress and duration information
    /// - Parameters:
    ///   - output: The FFmpeg output string to process
    ///   - totalDuration: The current total duration if already known
    ///   - progressUpdate: Callback to report progress updates
    /// - Returns: A tuple containing the updated total duration (if found) and the current progress
    private static func handleFFMPEGOutput(_ output: String, 
                                         totalDuration: Double?, 
                                         progressUpdate: @escaping @Sendable (Double, String?) -> Void) -> (Double?, (Double, String?)?) {
        var newTotalDuration = totalDuration
        
        // Try to parse the total duration if not already known
        if newTotalDuration == nil, let duration = ParsingUtils.parseDuration(from: output) {
            newTotalDuration = duration
            print("Total Duration: \(duration) seconds")
        }
        
        // Parse and report progress if we have a valid duration
        var progressTuple: (Double, String?)? = nil
        if let progress = ParsingUtils.parseProgress(from: output, totalDuration: newTotalDuration) {
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
