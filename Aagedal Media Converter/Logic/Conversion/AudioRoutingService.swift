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

/// Service for handling audio routing logic and FFmpeg command generation
enum AudioRoutingService {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "AudioRouting")
    
    /// Fetches detailed audio track information from a media file
    /// - Parameter url: The URL of the media file
    /// - Returns: Array of AudioTrackInfo objects, or empty array if no audio tracks
    static func fetchAudioTrackInfo(for url: URL) async -> [AudioTrackInfo] {
        logger.debug("fetchAudioTrackInfo: ENTRY for \(url.lastPathComponent, privacy: .public) (ext=\(url.pathExtension, privacy: .public))")
        // Use existing FFMPEGProbeService to get basic info, then enhance with VideoMetadata
        guard let basicStreams = await FFMPEGProbeService.fetchAudioStreams(for: url) else {
            logger.warning("Failed to fetch audio streams for \(url.lastPathComponent)")
            return []
        }

        // Try to get richer metadata from VideoMetadataService
        let metadata = try? await BoundedVideoMetadataProbe.metadata(for: url)

        // For MXF (including IMF essences), pull SMPTE 377-4 MCA labels via mxf2raw.
        let mcaLabels: [AudioTrackMCALabels]
        if url.pathExtension.lowercased() == "mxf" {
            logger.info("fetchAudioTrackInfo: requesting MCA labels for \(url.lastPathComponent, privacy: .public)")
            mcaLabels = await BMXService.shared.getAudioTrackLabels(url: url) ?? []
            logger.info("fetchAudioTrackInfo: BMXService returned \(mcaLabels.count) MCA entries")
        } else {
            mcaLabels = []
        }

        var trackInfos: [AudioTrackInfo] = []

        for (position, basicStream) in basicStreams.enumerated() {
            // Use position as the audio-relative index for FFmpeg's -map 0:a:X notation
            // basicStream.index contains absolute stream index (e.g., 0=video, 1-4=audio)
            // but FFmpeg's 0:a:X expects audio-relative indices (0, 1, 2, 3...)
            let audioRelativeIndex = position
            let absoluteStreamIndex = basicStream.index ?? position

            // Try to find matching stream in detailed metadata using absolute index
            let detailedStream = metadata?.audioStreams.first { $0.index == absoluteStreamIndex }

            let mca = matchMCALabels(
                in: mcaLabels,
                position: position,
                channels: basicStream.channels ?? detailedStream?.channels,
                sampleRate: detailedStream?.sampleRate
            )

            let trackInfo = AudioTrackInfo(
                streamIndex: audioRelativeIndex,
                channels: basicStream.channels ?? detailedStream?.channels,
                // Apply the same presentation policy as the metadata panel: the Matroska
                // reader's count-derived layout must not become a known speaker label.
                channelLayout: detailedStream != nil ? detailedStream?.channelLayout
                    : (["mkv", "webm"].contains(url.pathExtension.lowercased()) ? nil : basicStream.channelLayout),
                codec: detailedStream?.codec,
                codecLongName: detailedStream?.codecLongName,
                sampleRate: detailedStream?.sampleRate,
                languageCode: detailedStream?.languageCode,
                title: detailedStream?.title,
                bitRate: detailedStream?.bitRate,
                trackNumber: position + 1,  // 1-based track number
                mcaSoundfieldGroup: mca?.soundfieldGroup,
                mcaAudioElement: mca?.audioElement,
                mcaChannelLabels: (mca?.channelLabels.isEmpty ?? true) ? nil : mca?.channelLabels
            )

            trackInfos.append(trackInfo)
        }

        logger.info("Found \(trackInfos.count) audio tracks in \(url.lastPathComponent)")
        return trackInfos
    }

    /// Aligns mxf2raw's MCA-bearing tracks with FFmpeg's audio-relative streams.
    /// Prefers content-keyed matching on (channels, sampleRate); falls back to positional
    /// alignment when keys disambiguate the same way; returns nil when alignment is ambiguous
    /// so we never poison the routing UI with mislabeled channels.
    private static func matchMCALabels(
        in mcaLabels: [AudioTrackMCALabels],
        position: Int,
        channels: Int?,
        sampleRate: Int?
    ) -> AudioTrackMCALabels? {
        guard !mcaLabels.isEmpty else { return nil }

        // Content-key match by (channels, sampleRate) when both probes agree.
        if let channels, let sampleRate {
            let keyMatches = mcaLabels.filter {
                $0.channelCount == channels && $0.sampleRate == sampleRate
            }
            if keyMatches.count == 1 { return keyMatches[0] }
        }

        // Positional alignment when the count matches and either no content keys disagree
        // at the same position, or content keys agree at this position.
        guard mcaLabels.indices.contains(position) else { return nil }
        let candidate = mcaLabels[position]
        if let channels, let candidateChannels = candidate.channelCount, channels != candidateChannels {
            // Position would mislabel; bail out rather than poison the UI.
            return nil
        }
        return candidate
    }
    
    /// Resolves routing decisions before serializing FFmpeg arguments. Output order,
    /// duplicates, and filter ownership are retained in one immutable value.
    static func makePlan(config: AudioRoutingConfig) -> AudioRoutingPlan {
        let fallback = AudioRoutingPlan.tracks(config.outputTracks.map {
            AudioRoutingPlan.Track(streamIndex: $0.streamIndex, downmixToStereo: false)
        })
        if let operation = config.channelOperation {
            switch operation {
            case .mergeToStereo(let indices):
                guard indices.count >= 2 else { return fallback }
                return .mergeToStereo(streamIndices: indices)
            case .splitToMono(let index):
                guard let track = config.trackInfo(for: index), track.channels == 2 else { return fallback }
                return .splitToMono(streamIndex: index, layout: track.channelLayout ?? "stereo")
            case .swapChannels(let index):
                guard config.trackInfo(for: index)?.channels == 2 else { return fallback }
                return .swapChannels(streamIndex: index)
            case .extractChannel(let index, let channel, _):
                guard let channels = config.trackInfo(for: index)?.channels,
                      channel >= 0, channel < channels else { return fallback }
                return .extractChannel(streamIndex: index, channelIndex: channel)
            }
        }
        return .tracks(config.outputTracks.map {
            AudioRoutingPlan.Track(streamIndex: $0.streamIndex, downmixToStereo: $0.downmixToStereo)
        })
    }

    /// Compatibility boundary for callers assembling the rest of the conversion.
    static func buildFFmpegMapArguments(config: AudioRoutingConfig) -> [String] {
        makePlan(config: config).ffmpegArguments
    }

    /// Validates routing configuration against preset requirements
    /// - Parameters:
    ///   - config: The audio routing configuration
    ///   - preset: The export preset being used
    /// - Returns: Array of warning/info messages (empty if no issues)
    static func validateRoutingConfig(config: AudioRoutingConfig, preset: ExportPreset) -> [String] {
        var messages: [String] = []

        // Check if preset removes all audio
        if !preset.outputsAudioTrack {
            messages.append("Note: \(preset.displayName) preset removes all audio. Routing configuration will not affect output.")
            return messages
        }

        // Check if preset supports audio routing
        if !preset.appliesAudioRouting {
            messages.append("Warning: Audio routing is not compatible with \(preset.displayName) preset. Routing will be ignored.")
            return messages
        }

        // Check for preset-specific audio handling
        if preset == .audioOnly {
            let formatRaw = UserDefaults.standard.string(forKey: AppConstants.audioOnlyFormatKey) ?? AppConstants.defaultAudioOnlyFormat
            let format = AudioOnlyFormat(rawValue: formatRaw) ?? .wav
            if format.supportsSingleStreamOnly && config.outputTrackIndices.count > 1 {
                messages.append("Note: \(format.rawValue) format supports only one audio stream. Multiple tracks will be merged.")
            }
        }

        // Warn if all tracks are removed
        if config.outputTrackIndices.isEmpty {
            messages.append("Warning: No audio tracks selected. Output will have no audio.")
        }

        // Warn about surround audio tracks without downmix
        let surroundWithoutDownmix = config.outputTracks.filter { outputTrack in
            guard let info = config.trackInfo(for: outputTrack.streamIndex) else { return false }
            return info.isSurround && !outputTrack.downmixToStereo
        }

        if !surroundWithoutDownmix.isEmpty {
            let count = surroundWithoutDownmix.count
            let trackWord = count == 1 ? "track has" : "tracks have"
            messages.append("Warning: \(count) \(trackWord) surround audio. Some players (like QuickTime) may not play these correctly. Consider enabling stereo downmix for compatibility.")
        }

        return messages
    }
    
    /// Creates a default routing configuration from audio track info
    /// - Parameter tracks: Array of available audio tracks
    /// - Returns: Default configuration with all tracks in original order
    static func createDefaultConfig(from tracks: [AudioTrackInfo]) -> AudioRoutingConfig {
        AudioRoutingConfig(inputTracks: tracks)
    }
    
    /// Generates a preview of the FFmpeg command for debugging
    /// - Parameter config: The audio routing configuration
    /// - Returns: Human-readable command preview
    static func previewFFmpegCommand(config: AudioRoutingConfig) -> String {
        let mapArgs = buildFFmpegMapArguments(config: config)
        
        var preview = "ffmpeg -i input.mp4"
        
        if !mapArgs.isEmpty {
            preview += " " + mapArgs.joined(separator: " ")
        }
        
        preview += " [other preset arguments] output.mp4"
        
        if let operation = config.channelOperation {
            preview += "\n\n# Active Operation: \(operation.displayDescription)"
        }
        
        return preview
    }
}

/// Typed audio portion of a conversion plan. A filtered plan owns both its graph
/// and output maps, so their ordering cannot diverge during command construction.
enum AudioRoutingPlan: Equatable, Sendable {
    struct Track: Equatable, Sendable {
        let streamIndex: Int
        let downmixToStereo: Bool
    }

    case tracks([Track])
    case mergeToStereo(streamIndices: [Int])
    case splitToMono(streamIndex: Int, layout: String)
    case swapChannels(streamIndex: Int)
    case extractChannel(streamIndex: Int, channelIndex: Int)

    var outputStreamCount: Int {
        switch self {
        case .tracks(let tracks): tracks.count
        case .splitToMono: 2
        case .mergeToStereo, .swapChannels, .extractChannel: 1
        }
    }

    var ffmpegArguments: [String] {
        switch self {
        case .tracks(let tracks):
            guard tracks.contains(where: \.downmixToStereo) else {
                return tracks.flatMap { ["-map", "0:a:\($0.streamIndex)"] }
            }
            let filters = tracks.enumerated().map { index, track in
                let filter = track.downmixToStereo ? "aresample=ochl=stereo" : "anull"
                return "[0:a:\(track.streamIndex)]\(filter)[aout\(index)]"
            }
            return Self.filtered(filters.joined(separator: ";"), outputs: tracks.indices.map { "aout\($0)" })
        case .mergeToStereo(let indices):
            let inputs = indices.map { "[0:a:\($0)]" }.joined()
            let pan = indices.count == 2 ? "pan=stereo|c0<c0+c2|c1<c1+c3" : "pan=stereo|c0<c0|c1<c1"
            return Self.filtered("\(inputs)amerge=inputs=\(indices.count),\(pan)[aout]", outputs: ["aout"])
        case .splitToMono(let index, let layout):
            // Normalize FL/FR to generic mono layouts accepted by AAC encoders.
            let graph = "[0:a:\(index)]channelsplit=channel_layout=\(layout)[splitL][splitR];" +
                "[splitL]aformat=channel_layouts=mono[L];[splitR]aformat=channel_layouts=mono[R]"
            return Self.filtered(graph, outputs: ["L", "R"])
        case .swapChannels(let index):
            return Self.filtered("[0:a:\(index)]pan=stereo|c0=c1|c1=c0[aout]", outputs: ["aout"])
        case .extractChannel(let index, let channel):
            return Self.filtered("[0:a:\(index)]pan=mono|c0=c\(channel)[aout]", outputs: ["aout"])
        }
    }

    private static func filtered(_ graph: String, outputs: [String]) -> [String] {
        ["-filter_complex", graph] + outputs.flatMap { ["-map", "[\($0)]"] }
    }
}
