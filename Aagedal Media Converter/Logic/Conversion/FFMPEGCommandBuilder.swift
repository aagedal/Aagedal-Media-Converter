//
//  FFMPEGCommandBuilder.swift
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
import ImageIO
import OSLog

struct FFMPEGCommand {
    let arguments: [String]
    let normalizedTrimStart: Double?
    let normalizedTrimEnd: Double?
    let effectiveDuration: Double?
    var preparationError: String? = nil
    /// Whether the encoded output keeps the input's alpha channel
    /// (set by the native waveform pipeline when transparency was requested).
    var preservesAlpha: Bool = false
    /// Matte sidecar written by this same command (native waveform pipeline).
    var matteOutputURL: URL? = nil
}

/// Resolves the common filter spellings for the primary video stream.
/// FFmpeg uses the last matching option, including when an alias follows -vf.
/// Other indexed streams retain ownership of their own filters.
struct PrimaryVideoFilterPlan: Equatable, Sendable {
    let filterOptionIndex: Int?
    let hasAmbiguousNumericTarget: Bool
    let hasNumericTarget: Bool

    var preparationError: String? {
        guard hasAmbiguousNumericTarget else { return nil }
        return String(localized: "Cannot safely apply video adjustments to numeric filters with this stream mapping. Use -filter:v:0 for video and typed audio filter options, or map individual required streams explicitly.")
    }

    init(arguments: [String]) {
        var filterOptionIndex: Int?
        let outputArgumentsStart = arguments.lastIndex(of: "-i").map { min($0 + 2, arguments.count) } ?? 0
        var filterOptions: Set<String> = ["-vf", "-filter", "-filter:v", "-filter:v:0"]
        let outputIndex = Self.primaryVideoOutputIndex(arguments: arguments, outputArgumentsStart: outputArgumentsStart)
        hasNumericTarget = arguments.indices.contains { index in
            index >= outputArgumentsStart && index + 1 < arguments.count &&
                arguments[index].hasPrefix("-filter:") && Int(arguments[index].dropFirst("-filter:".count)) != nil
        }
        hasAmbiguousNumericTarget = outputIndex == nil && hasNumericTarget
        if let outputIndex {
            filterOptions.insert("-filter:\(outputIndex)")
        }
        for index in arguments.indices where index >= outputArgumentsStart && index + 1 < arguments.count {
            if filterOptions.contains(arguments[index]) {
                filterOptionIndex = index
            }
        }
        // Even a typed alias may be superseded by an unresolved numeric option.
        self.filterOptionIndex = hasAmbiguousNumericTarget ? nil : filterOptionIndex
    }

    /// Numeric filter specifiers address the output order, not the input stream index.
    /// Resolve only map forms with a known preceding stream count. Whole-input maps,
    /// graph labels, removals, and optional preceding streams need stream inventory.
    private static func primaryVideoOutputIndex(arguments: [String], outputArgumentsStart: Int) -> Int? {
        let outputArguments = arguments.dropFirst(outputArgumentsStart)
        guard !outputArguments.contains("-vn"),
              !arguments.contains("-filter_complex"),
              !arguments.contains("-lavfi"),
              !arguments.contains("-filter_complex_script") else { return nil }
        let maps = outputArguments.indices.compactMap { index -> String? in
            guard arguments[index] == "-map", index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard !maps.isEmpty else { return 0 }
        guard !maps.contains(where: { $0.hasPrefix("-") }) else { return nil }
        var outputIndex = 0
        for map in maps {
            let optional = map.hasSuffix("?")
            let components = (optional ? String(map.dropLast()) : map).split(separator: ":", omittingEmptySubsequences: false)
            guard components.count >= 2, let inputIndex = Int(components[0]), inputIndex >= 0 else { return nil }
            let type = components[1]
            guard ["v", "V", "a", "s", "d", "t"].contains(type) else { return nil }
            // Unindexed typed maps may emit several streams; a leading video map
            // still establishes the primary video's output index.
            guard components.count == 2 || (components.count == 3 && Int(components[2]).map { $0 >= 0 } == true) else {
                return nil
            }
            if (type == "a" && outputArguments.contains("-an")) ||
                (type == "s" && outputArguments.contains("-sn")) ||
                (type == "d" && outputArguments.contains("-dn")) {
                continue
            }
            if type == "v" || type == "V" { return optional ? nil : outputIndex }
            guard components.count == 3, !optional else { return nil }
            outputIndex += 1
        }
        return nil
    }
}

/// Resolves the requested interval before probes or generated-video preparation.
/// Invalid endpoints retain the existing normalization policy; a finite, positive
/// end at or before the start is an incompatible interval, not an open-ended export.
struct FFMPEGTrimPlan: Equatable, Sendable {
    let start: Double?
    let end: Double?

    init(start: Double?, end: Double?) {
        self.start = FFMPEGCommandBuilder.normalizedTrimPoint(start)
        self.end = FFMPEGCommandBuilder.normalizedTrimPoint(end)
    }

    var preparationError: String? {
        guard let start, let end, end <= start else { return nil }
        return String(localized: "The end trim must be after the start trim. Adjust the trim range and try again.")
    }

    var seekArguments: [String] {
        start.map { ["-ss", FFMPEGCommandBuilder.ffmpegTimeString(from: $0)] } ?? []
    }

    var durationArguments: [String] {
        guard preparationError == nil else { return [] }
        return FFMPEGCommandBuilder.trimDurationArgument(start: start, end: end) ?? []
    }

    var effectiveDuration: Double? {
        guard preparationError == nil else { return nil }
        return FFMPEGCommandBuilder.calculateEffectiveDuration(trimStart: start, trimEnd: end)
    }
}

/// Keeps probe failure distinct from an explicit request to clear source timecode.
/// Both QuickTime tag locations belong to this plan because either can recreate tmcd.
enum TimecodeMetadataPlan: Equatable, Sendable {
    case unchanged
    case clear
    case set(String)

    init(resolvedValue: String?) {
        self = resolvedValue.flatMap { $0.isEmpty ? nil : $0 }.map(Self.set) ?? .clear
    }

    func apply(to arguments: inout [String], outputArgumentsStart: Int = 0) {
        guard self != .unchanged else { return }
        var index = outputArgumentsStart
        while index + 1 < arguments.count {
            let option = arguments[index]
            if option == "-timecode" ||
                (["-metadata", "-metadata:s:v:0"].contains(option) && arguments[index + 1].hasPrefix("timecode=")) {
                arguments.removeSubrange(index...index + 1)
            } else {
                index += 1
            }
        }
        let value: String
        switch self {
        case .set(let timecode): value = timecode
        case .clear: value = ""
        case .unchanged: return
        }
        arguments += ["-metadata", "timecode=\(value)", "-metadata:s:v:0", "timecode=\(value)"]
    }
}

/// Empty legacy comments retain source metadata. An enabled editor field can
/// explicitly clear the tag; otherwise a composed comment owns the global option.
/// Image outputs leave container metadata untouched.
enum CommentMetadataPlan: Equatable, Sendable {
    case unchanged
    case source
    case set(String)

    init(comment: String, includeDateTag: Bool, date: Date = Date(), settings: CommentSettings, writeEmptyComment: Bool = false) {
        var parts: [String] = []
        if includeDateTag {
            let formatter = DateFormatter()
            formatter.dateFormat = settings.dateFormat
            parts.append("\(settings.dateTagPrefix): \(formatter.string(from: date))")
        }
        let trimmedComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        parts += [settings.prefix, trimmedComment, settings.suffix].filter { !$0.isEmpty }
        self = parts.isEmpty ? (writeEmptyComment ? .set("") : .source) : .set(parts.joined(separator: settings.separator))
    }

    var value: String? {
        if case .set(let value) = self { return value }
        return nil
    }

    func apply(to arguments: inout [String], outputArgumentsStart: Int = 0) {
        guard self != .unchanged else { return }
        var index = outputArgumentsStart
        while index + 1 < arguments.count {
            if arguments[index] == "-metadata", arguments[index + 1].hasPrefix("comment=") {
                arguments.removeSubrange(index...index + 1)
            } else {
                index += 1
            }
        }
        if let value {
            arguments += ["-metadata", "comment=\(value)"]
        }
    }
}

/// Source tags and chapters are distinct from item-authored comment/timecode values.
/// A nil input retains FFmpeg's automatic mapping for presets that historically used it.
/// Custom presets keep ownership of their own mapping and muxer flags.
enum SourceMetadataPlan: Codable, Equatable, Sendable {
    case unchanged
    case preserve(input: Int?)
    case strip

    init(preserveMetadata: Bool, defaultInput: Int? = nil) {
        self = preserveMetadata ? .preserve(input: defaultInput) : .strip
    }

    /// Generated native video is input 0; its actual metadata source is the audio input.
    func usingSourceInput(_ input: Int) -> Self {
        if case .preserve = self { return .preserve(input: input) }
        return self
    }

    func apply(to arguments: inout [String], outputArgumentsStart: Int = 0) {
        guard self != .unchanged else { return }
        var index = outputArgumentsStart
        while index + 1 < arguments.count {
            let option = arguments[index]
            let value = arguments[index + 1]
            let ownsMapping = option == "-map_metadata" || option == "-map_metadata:g" || option == "-map_chapters"
                || (self == .strip && option.hasPrefix("-map_metadata:"))
            let ownsEncoderClear = ["-metadata:s:v:0", "-metadata:s:a:0"].contains(option) && value == "encoder="
            if ownsMapping || ownsEncoderClear {
                arguments.removeSubrange(index...index + 1)
            } else if option == "-fflags", value.contains("+bitexact") {
                // Remove only the flag this policy injects, preserving unrelated flags
                // and the order of separate flag operations supplied by the caller.
                let remaining = value.replacingOccurrences(of: "+bitexact", with: "")
                if remaining.isEmpty {
                    arguments.removeSubrange(index...index + 1)
                } else {
                    arguments[index + 1] = remaining
                    index += 2
                }
            } else {
                index += 1
            }
        }
        switch self {
        case .preserve(let input):
            if let input {
                arguments += ["-map_metadata", String(input), "-map_chapters", String(input)]
            }
        case .strip:
            arguments += ["-map_metadata", "-1", "-map_chapters", "-1"]
            // Append after every caller-supplied -fflags operation: an earlier
            // +bitexact can otherwise be reset by a later absolute flag value.
            arguments += ["-fflags", "+bitexact", "-metadata:s:v:0", "encoder=", "-metadata:s:a:0", "encoder="]
        case .unchanged:
            break
        }
    }
}

/// Renders item metadata after preset and additional output arguments are assembled.
struct OutputMetadataPlan: Equatable, Sendable {
    let source: SourceMetadataPlan
    let comment: CommentMetadataPlan
    let timecode: TimecodeMetadataPlan

    func apply(to arguments: inout [String], outputArgumentsStart: Int = 0, outputExtension: String? = nil) {
        source.apply(to: &arguments, outputArgumentsStart: outputArgumentsStart)
        if case .preserve = source, ["mp4", "mov", "m4v", "m4a"].contains(outputExtension?.lowercased() ?? "") {
            // The default MOV muxer drops description and source URL tags; MP4
            // also drops nonstandard tags such as PURL. Keep them independent of
            // an authored comment, and retain any other configured movflags.
            arguments += ["-movflags", "+use_metadata_tags"]
        }
        comment.apply(to: &arguments, outputArgumentsStart: outputArgumentsStart)
        timecode.apply(to: &arguments, outputArgumentsStart: outputArgumentsStart)
    }
}

struct WaveformVideoRequest: Sendable {
    let width: Int
    let height: Int
    let backgroundHex: String
    let foregroundHex: String
    let normalizeAudio: Bool
    let style: WaveformStyle
    let frameRate: Double
    let renderingEngine: WaveformRenderingEngine
    let swiftStyle: SwiftWaveformStyle
    let bandCount: Int
    let frequencyDistribution: FrequencyDistribution
    let foregroundGradientEnabled: Bool
    let foregroundGradientEndHex: String
    let backgroundGradientEnabled: Bool
    let backgroundGradientEndHex: String
    let waveformOpacity: Double
    /// Render over a transparent background when the output format can carry alpha
    /// (native Swift renderer only). Otherwise the background color is used.
    var transparentBackground: Bool = false

    var resolutionString: String {
        "\(width)x\(height)"
    }

    var backgroundFFmpegColor: String {
        "0x" + backgroundHex
    }

    var foregroundFFmpegColor: String {
        "0x" + foregroundHex
    }
}

struct SynthesizedVideoRequest: Sendable {
    let width: Int
    let height: Int
    let backgroundHex: String
    let frameRate: Double
    let includeAudio: Bool

    var backgroundFFmpegColor: String {
        "0x" + backgroundHex
    }
}

enum FFMPEGCommandBuilder {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "WaveformCommand")
    static func buildCommand(
        inputURL: URL,
        outputFileURL: URL,
        preset: ExportPreset,
        dcpSettings: DCPSettings? = nil,
        imfSettings: IMFSettings? = nil,
        audioOnlySettings: AudioOnlySettings? = nil,
        imageSequenceSettings: ImageSequenceSettings? = nil,
        codecSettings: CodecExportSettings? = nil,
        commentSettings: CommentSettings? = nil,
        subtitleSettings: SubtitleExportSettings? = nil,
        comment: String,
        writeEmptyComment: Bool = false,
        includeDateTag: Bool,
        trimStart: Double?,
        trimEnd: Double?,
        audioRoutingConfig: AudioRoutingConfig? = nil,
        cropConfig: CropConfig? = nil,
        timecodeConfig: TimecodeConfig? = nil,
        timecodeTrimStart: Double? = nil,
        sourceMetadata: VideoMetadata? = nil,
        waveformRequest: WaveformVideoRequest? = nil,
        synthesizedVideoRequest: SynthesizedVideoRequest? = nil,
        synthesizedVideoDuration: Double? = nil,
        synthesizedVideoUsesSourceMetadataDuration: Bool = true,
        visualSourceURL: URL? = nil,
        customInputArguments: [String]? = nil,
        additionalOutputArguments: [String]? = nil,
        chapterMetadataURL: URL? = nil,
        chapterMetadataTitles: [String] = [],
        isMuted: Bool = false,
        durationProvider: @Sendable (URL) async -> Double? = { url in
            await FFMPEGProbeService.getVideoDuration(for: url)
        }
    ) async -> FFMPEGCommand {
        let trimPlan = FFMPEGTrimPlan(start: trimStart, end: trimEnd)
        let normalizedTrimStart = trimPlan.start
        let normalizedTrimEnd = trimPlan.end
        if let preparationError = trimPlan.preparationError {
            return FFMPEGCommand(
                arguments: [], normalizedTrimStart: normalizedTrimStart,
                normalizedTrimEnd: normalizedTrimEnd, effectiveDuration: nil,
                preparationError: preparationError
            )
        }

        let capturedDCPSettings = preset == .dcp ? (dcpSettings ?? DCPSettings()) : nil
        let capturedIMFSettings = (preset == .imfJ2K || preset == .imfProRes) ? (imfSettings ?? IMFSettings()) : nil
        let capturedAudioOnlySettings = preset == .audioOnly ? (audioOnlySettings ?? AudioOnlySettings()) : nil
        let capturedImageSequenceSettings = preset == .imageSequence ? (imageSequenceSettings ?? ImageSequenceSettings()) : nil
        let capturedCodecSettings = codecSettings ?? CodecExportSettings(preset: preset)
        let capturedCommentSettings = commentSettings ?? CommentSettings()
        if let dcpError = capturedDCPSettings?.configurationError {
            return FFMPEGCommand(
                arguments: [], normalizedTrimStart: normalizedTrimStart,
                normalizedTrimEnd: normalizedTrimEnd, effectiveDuration: nil,
                preparationError: dcpError
            )
        }
        let capturedSubtitleSettings = subtitleSettings ?? SubtitleExportSettings()
        var arguments = ["-y", "-nostdin", "-progress", "pipe:2"]

        let commentPlan: CommentMetadataPlan = preset == .imageSequence ? .unchanged : CommentMetadataPlan(
            comment: comment, includeDateTag: includeDateTag, settings: capturedCommentSettings, writeEmptyComment: writeEmptyComment
        )
        let metadataPlan = OutputMetadataPlan(
            source: capturedAudioOnlySettings?.sourceMetadataPlan ?? capturedCodecSettings?.sourceMetadataPlan ?? .unchanged,
            comment: commentPlan,
            timecode: await configuredTimecodePlan(
                preset: preset, inputURL: inputURL, timecodeConfig: timecodeConfig,
                sourceMetadata: sourceMetadata, trimStart: timecodeTrimStart ?? normalizedTrimStart
            )
        )

        let inputPlan = FFMPEGInputPlan(inputURL: inputURL, customArguments: customInputArguments)
        let presetArguments = capturedDCPSettings?.ffmpegArguments
            ?? capturedIMFSettings?.ffmpegArguments(application: preset == .imfJ2K ? .app2e : .rdd45)
            ?? capturedImageSequenceSettings?.ffmpegArguments
            ?? capturedAudioOnlySettings?.ffmpegArguments
            ?? capturedCodecSettings?.ffmpegArguments
            ?? preset.ffmpegArguments
        let hasNumericFilters = PrimaryVideoFilterPlan(arguments: presetArguments + (additionalOutputArguments ?? [])).hasNumericTarget
        let changesAudioMapping = audioRoutingConfig != nil && preset.outputsAudioTrack &&
            (capturedCodecSettings?.appliesAudioRouting ?? preset.appliesAudioRouting)
        let changesOutputMapping = (additionalOutputArguments ?? []).contains {
            ["-map", "-an", "-vn", "-sn", "-dn", "-filter_complex", "-lavfi", "-filter_complex_script"].contains($0)
        }
        // Numeric filters follow the final output order. Do not interpret them
        // against preset maps that a later app-owned transformation will replace.
        if hasNumericFilters && (changesAudioMapping || isMuted || inputPlan.isImageSequence ||
            waveformRequest != nil || synthesizedVideoRequest != nil || changesOutputMapping) {
            return FFMPEGCommand(
                arguments: [], normalizedTrimStart: normalizedTrimStart,
                normalizedTrimEnd: normalizedTrimEnd, effectiveDuration: nil,
                preparationError: String(localized: "Numeric filters cannot be combined with automatic stream mapping changes. Use -filter:v:0 for video and typed audio filter options before enabling audio routing, mute, or generated video.")
            )
        }
        // DCP hints apply only to the ordinary file source, before its input boundary.
        let fileInputOptions = preset == .dcp ? [
            "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"
        ] : []
        arguments += inputPlan.arguments(seek: trimPlan.seekArguments, fileOptions: fileInputOptions)

        var chapterInputIndex: Int?
        if let chapterMetadataURL, waveformRequest == nil, synthesizedVideoRequest == nil {
            chapterInputIndex = arguments.filter { $0 == "-i" }.count
            arguments += ["-f", "ffmetadata", "-i", chapterMetadataURL.path]
        }
        let outputArgumentsStart = arguments.count

        if let waveformRequest {
            let includeAudioOutput = preset.outputsAudioTrack
            logger.debug("Building waveform command with request: width=\(waveformRequest.width), height=\(waveformRequest.height), background=\(waveformRequest.backgroundHex, privacy: .public), foreground=\(waveformRequest.foregroundHex, privacy: .public), normalize=\(waveformRequest.normalizeAudio), style=\(waveformRequest.style.rawValue, privacy: .public)")
            arguments.append(contentsOf: trimPlan.durationArguments)

            arguments.append(contentsOf: waveformCommandArguments(for: waveformRequest, includeAudioOutput: includeAudioOutput, audioRoutingConfig: audioRoutingConfig))

            var ffmpegArgs = presetArguments
            await adjustArgumentsForInput(
                preset: preset,
                audioOnlySettings: capturedAudioOnlySettings,
                codecSettings: capturedCodecSettings,
                inputURL: inputURL,
                ffmpegArgs: &ffmpegArgs,
                trimStart: normalizedTrimStart,
                trimEnd: normalizedTrimEnd,
                sourceMetadata: sourceMetadata
            )
            await adjustDeinterlaceFilter(
                inputURL: inputURL,
                ffmpegArgs: &ffmpegArgs,
                sourceMetadata: sourceMetadata
            )
            sanitizeArgumentsForCustomVideoPipeline(&ffmpegArgs)
            if !includeAudioOutput {
                removeArgumentPair("-map", value: "[audout]", from: &arguments)
            }
            arguments.append(contentsOf: ffmpegArgs)
            if capturedDCPSettings != nil {
                applyDCPColorConversion(to: &arguments)
            }

            if let additionalOutputArguments {
                arguments.append(contentsOf: additionalOutputArguments)
            }
            metadataPlan.apply(to: &arguments, outputArgumentsStart: outputArgumentsStart, outputExtension: outputFileURL.pathExtension)
            logger.debug("Waveform ffmpeg arguments: \(arguments.joined(separator: " "), privacy: .public)")
            arguments.append(outputFileURL.path)

            let effectiveDuration = trimPlan.effectiveDuration

            return FFMPEGCommand(
                arguments: arguments,
                normalizedTrimStart: normalizedTrimStart,
                normalizedTrimEnd: normalizedTrimEnd,
                effectiveDuration: effectiveDuration
            )
        } else if let synthesizedVideoRequest {
            logger.debug("Building synthesized video command with request: width=\(synthesizedVideoRequest.width), height=\(synthesizedVideoRequest.height), background=\(synthesizedVideoRequest.backgroundHex, privacy: .public), frameRate=\(synthesizedVideoRequest.frameRate)")
            arguments.append(contentsOf: trimPlan.durationArguments)

            arguments.append(contentsOf: synthesizedVideoCommandArguments(for: synthesizedVideoRequest))

            var ffmpegArgs = presetArguments
            await adjustArgumentsForInput(
                preset: preset,
                audioOnlySettings: capturedAudioOnlySettings,
                codecSettings: capturedCodecSettings,
                inputURL: inputURL,
                ffmpegArgs: &ffmpegArgs,
                trimStart: normalizedTrimStart,
                trimEnd: normalizedTrimEnd,
                sourceMetadata: sourceMetadata
            )
            await adjustDeinterlaceFilter(
                inputURL: inputURL,
                ffmpegArgs: &ffmpegArgs,
                sourceMetadata: sourceMetadata
            )
            sanitizeArgumentsForCustomVideoPipeline(&ffmpegArgs)
            if !synthesizedVideoRequest.includeAudio || isMuted {
                removeArgumentPair("-map", value: "0:a?", from: &arguments)
                applyMute(to: &ffmpegArgs)
            } else {
                removeArgumentPair("-an", value: nil, from: &ffmpegArgs)
                if let audioRoutingConfig, preset.outputsAudioTrack,
                   (capturedCodecSettings?.appliesAudioRouting ?? preset.appliesAudioRouting),
                   audioRoutingConfig.isCustomized || !audioRoutingConfig.outputTracks.isEmpty {
                    // The generated video already owns its map; routed audio replaces the
                    // automatic source-audio map instead of adding another copy of it.
                    removeArgumentPair("-map", value: "0:a?", from: &arguments)
                    applyAudioRouting(
                        config: audioRoutingConfig, to: &ffmpegArgs, addVideoMap: false,
                        codecOverrides: preset.supportsPerTrackAudioEncoding
                    )
                    if AudioRoutingService.makePlan(config: audioRoutingConfig).outputStreamCount == 0 {
                        applyMute(to: &ffmpegArgs)
                    }
                }
            }

            // A silent color source has no finite mapped stream for -shortest to follow.
            // Resolve an explicit output duration before allowing the encoder to launch.
            var effectiveDuration = trimPlan.effectiveDuration
            if ffmpegArgs.contains("-an") {
                if effectiveDuration == nil {
                    if let synthesizedVideoDuration, synthesizedVideoDuration.isFinite, synthesizedVideoDuration > 0 {
                        // The caller's hint describes the already prepared/trimmed output.
                        effectiveDuration = synthesizedVideoDuration
                    } else {
                        let sourceDuration: Double?
                        if synthesizedVideoUsesSourceMetadataDuration,
                           let duration = sourceMetadata?.duration, duration.isFinite, duration > 0 {
                            sourceDuration = duration
                        } else {
                            sourceDuration = await durationProvider(inputURL)
                        }
                        effectiveDuration = sourceDuration.map { $0 - (normalizedTrimStart ?? 0) }
                    }
                }
                guard let duration = effectiveDuration, duration.isFinite, duration > 0 else {
                    return FFMPEGCommand(
                        arguments: [], normalizedTrimStart: normalizedTrimStart,
                        normalizedTrimEnd: normalizedTrimEnd, effectiveDuration: nil,
                        preparationError: "Cannot determine a positive duration for silent generated video. Set an end trim and try again."
                    )
                }
            }


            arguments.append(contentsOf: ffmpegArgs)
            if capturedDCPSettings != nil {
                applyDCPColorConversion(to: &arguments)
            }

            if let additionalOutputArguments {
                arguments.append(contentsOf: additionalOutputArguments)
            }
            if ffmpegArgs.contains("-an"), let effectiveDuration {
                arguments.append(contentsOf: ["-t", ffmpegTimeString(from: effectiveDuration)])
            }
            metadataPlan.apply(to: &arguments, outputArgumentsStart: outputArgumentsStart, outputExtension: outputFileURL.pathExtension)
            logger.debug("Synthesized video ffmpeg arguments: \(arguments.joined(separator: " "), privacy: .public)")
            arguments.append(outputFileURL.path)

            return FFMPEGCommand(
                arguments: arguments,
                normalizedTrimStart: normalizedTrimStart,
                normalizedTrimEnd: normalizedTrimEnd,
                effectiveDuration: effectiveDuration
            )
        }

        var ffmpegArgs = presetArguments

        // Image sequence inputs (via customInputArguments): the inputURL is a directory
        // so skip audio probing. If no associated audio, strip audio args entirely.
        // If associated audio exists (two -i flags), remap audio from the second input.
        let isImageSequenceInput = inputPlan.isImageSequence
        if isImageSequenceInput {
            if inputPlan.companionAudioPath != nil {
                // Has associated audio as second input - remap audio from input 1
                remapAudioForImageSequence(from: &ffmpegArgs)
            } else {
                stripAudioArguments(from: &ffmpegArgs)
            }
        }

        if !isImageSequenceInput {
            await adjustArgumentsForInput(
                preset: preset,
                audioOnlySettings: capturedAudioOnlySettings,
                codecSettings: capturedCodecSettings,
                inputURL: inputURL,
                ffmpegArgs: &ffmpegArgs,
                trimStart: normalizedTrimStart,
                trimEnd: normalizedTrimEnd,
                sourceMetadata: sourceMetadata
            )
            await adjustDeinterlaceFilter(
                inputURL: inputURL,
                ffmpegArgs: &ffmpegArgs,
                sourceMetadata: sourceMetadata
            )

            // Filter out unsupported audio codecs (e.g., APAC spatial audio from iPhone)
            // Skip for stream copy (which doesn't decode) and when audio routing is applied (has its own mapping)
            if preset != .streamCopy && (audioRoutingConfig == nil || !(capturedCodecSettings?.appliesAudioRouting ?? preset.appliesAudioRouting)) {
                await filterUnsupportedAudioStreams(inputURL: inputURL, ffmpegArgs: &ffmpegArgs)
            }
        }

        // Keep the alpha channel of alpha sources when exporting to ProRes 4444 / XQ.
        // Other formats keep their configured pixel format.
        if visualSourceURL == nil, isAlphaCapableProRes(ffmpegArgs),
           isImageSequenceInput ? inputPlan.imageSequenceHasAlpha : sourceMetadata?.videoStreams.first?.hasAlpha == true {
            enableAlphaOutput(in: &ffmpegArgs)
        }

        // Apply crop to video filter if configured and preset supports it
        if let cropConfig = cropConfig,
           cropConfig.isActive,
           preset.outputsVisualFrames,
           (capturedCodecSettings?.appliesCrop ?? preset.appliesCrop) {
            if let preparationError = PrimaryVideoFilterPlan(arguments: ffmpegArgs).preparationError {
                return FFMPEGCommand(
                    arguments: [], normalizedTrimStart: normalizedTrimStart,
                    normalizedTrimEnd: normalizedTrimEnd, effectiveDuration: nil,
                    preparationError: preparationError
                )
            }
            guard let geometry = await sourceGeometry(
                for: visualSourceURL ?? inputURL,
                sourceMetadata: visualSourceURL == nil ? sourceMetadata : nil
            ) else {
                return FFMPEGCommand(
                    arguments: [], normalizedTrimStart: normalizedTrimStart,
                    normalizedTrimEnd: normalizedTrimEnd, effectiveDuration: nil,
                    preparationError: "The crop geometry is invalid for this source."
                )
            }
            let width = geometry.width
            let height = geometry.height

            // Calculate effective Pixel Aspect Ratio (PAR)
            // We use a robust detection strategy:
            // 1. Calculate PAR derived from DAR (Display Aspect Ratio). This is usually the ground truth for playback.
            // 2. Check explicit PAR from metadata.
            // 3. If explicit PAR exists and is 'close' to DAR-derived PAR (within 5%), use explicit PAR (it's likely more precise).
            // 4. If explicit PAR contradicts DAR (e.g. PAR=1 vs DAR=16:9 for 1440 width), use DAR-derived PAR.
            // 5. Default to 1.0.
            let effectivePAR: Double
            let darValues = geometry.displayAspectRatio
            let parValues = geometry.pixelAspectRatio

            if let dar = darValues, dar > 0, height > 0 {
                let resolutionAspect = Double(width) / Double(height)
                let derivedPAR = dar / resolutionAspect

                if let par = parValues, par > 0 {
                    // Check consistency
                    if abs(derivedPAR - par) < 0.05 {
                        effectivePAR = par // Consistent, use explicit
                    } else {
                        effectivePAR = derivedPAR // Contradiction, trust DAR (Container)
                    }
                } else {
                    effectivePAR = derivedPAR
                }
            } else if let par = parValues, par > 0 {
                effectivePAR = par
            } else {
                effectivePAR = 1.0
            }

            guard applyCropToVideoFilter(
                &ffmpegArgs,
                cropConfig: cropConfig,
                sourceWidth: width,
                sourceHeight: height,
                pixelAspectRatio: effectivePAR
            ) else {
                return FFMPEGCommand(
                    arguments: [], normalizedTrimStart: normalizedTrimStart,
                    normalizedTrimEnd: normalizedTrimEnd, effectiveDuration: nil,
                    preparationError: "The crop geometry is invalid for this source."
                )
            }
        }

        // Only remove video arguments for audio-only exports. Image sequences do not contain an
        // embedded video track, but still require their visual codec and filter arguments.
        if !preset.outputsVisualFrames {
            removeVideoArguments(from: &ffmpegArgs)
        }
        
        // Apply audio routing configuration if provided and preset supports audio and audio routing
        // Skip for image sequence inputs (no audio streams)
        // Stream copy routes after its container-specific map adjustment below.
        let streamCopyAudioRouting: AudioRoutingConfig?
        if !isImageSequenceInput, let audioRoutingConfig, preset.outputsAudioTrack, (capturedCodecSettings?.appliesAudioRouting ?? preset.appliesAudioRouting) {
            if preset == .streamCopy {
                streamCopyAudioRouting = audioRoutingConfig
            } else {
                applyAudioRouting(
                    config: audioRoutingConfig, to: &ffmpegArgs,
                    codecOverrides: preset.supportsPerTrackAudioEncoding
                )
                streamCopyAudioRouting = nil
            }
        } else {
            streamCopyAudioRouting = nil
        }

        // Apply mute if requested - removes all audio from output
        // Never apply mute for stream copy — it contradicts verbatim copying of all streams
        if isMuted && preset == .streamCopy {
            logger.warning("Mute requested with stream copy preset — ignoring to preserve all streams")
        } else if isMuted {
            applyMute(to: &ffmpegArgs)
        }


        if preset == .streamCopy {
            adjustStreamCopyArguments(inputURL: inputURL, outputURL: outputFileURL, ffmpegArgs: &ffmpegArgs)
            // An untouched route keeps the verbatim `-map 0` copy of every stream.
            if let streamCopyAudioRouting, streamCopyAudioRouting.isCustomized {
                applyStreamCopyAudioRouting(config: streamCopyAudioRouting, to: &ffmpegArgs)
            }
        }

        arguments.append(contentsOf: trimPlan.durationArguments)

        arguments.append(contentsOf: ffmpegArgs)

        // Map subtitle streams if the user has enabled subtitle preservation.
        // Unsupported outputs (image sequences, DCP/IMF MXF, animated stills, etc.)
        // must not receive subtitle codec arguments because FFmpeg rejects them.
        if preset != .streamCopy && preset.outputsVideoTrack {
            arguments.append(contentsOf: subtitleArguments(
                keepSubtitles: capturedSubtitleSettings.keepSubtitles,
                outputExtension: outputFileURL.pathExtension
            ))
        }

        // For MOV/QuickTime files with stream copy, add movflags to preserve vendor-specific metadata
        // This is critical for ProRes RAW files to preserve white balance and camera metadata
        if preset == .streamCopy {
            let inputExtension = inputURL.pathExtension.lowercased()
            let outputExtension = outputFileURL.pathExtension.lowercased()
            if (inputExtension == "mov" || outputExtension == "mov") {
                // Add use_metadata_tags to preserve custom QuickTime atoms (com.apple.*, com.atomos.*, org.smpte.*)
                arguments.append(contentsOf: ["-movflags", "use_metadata_tags"])
            }

            // FFmpeg automatically follows each copied stream's metadata through
            // seeking. A broad -map_metadata:s 0:s would copy the first stream's
            // tags onto every output stream, replacing track titles and languages.
        }

        if let additionalOutputArguments {
            arguments.append(contentsOf: additionalOutputArguments)
        }
        metadataPlan.apply(to: &arguments, outputArgumentsStart: outputArgumentsStart, outputExtension: outputFileURL.pathExtension)
        // Appended after the metadata policy, which removes earlier per-stream
        // -map_metadata options that the attachment tag restore depends on.
        if preset != .streamCopy && preset.outputsVideoTrack {
            arguments.append(contentsOf: await subtitleAttachmentArguments(
                keepSubtitles: capturedSubtitleSettings.keepSubtitles,
                outputExtension: outputFileURL.pathExtension,
                outputArguments: arguments.dropFirst(outputArgumentsStart),
                inputURL: inputURL,
                sourceMetadata: sourceMetadata
            ))
        }
        // These chapters are explicitly authored by the stitching workflow and
        // must survive the preset's policy for inherited source metadata.
        if let chapterInputIndex {
            arguments += ["-map_chapters", String(chapterInputIndex)]
            // Metadata stripping disables automatic chapter title copying.
            // Explicit assignments are applied after FFmpeg creates the chapters.
            for (index, title) in chapterMetadataTitles.enumerated() {
                arguments += ["-metadata:c:\(index)", "title=\(title)"]
            }
        }
        if !isImageSequenceInput, visualSourceURL == nil, customInputArguments == nil,
           UntaggedColorPlan.appliesTo(preset),
           let stream = sourceMetadata?.primaryVideoStream,
           let geometry = await sourceGeometry(for: inputURL, sourceMetadata: sourceMetadata, probeMetadataIfNeeded: false),
           let plan = UntaggedColorPlan(
               sourceColorSpace: stream.colorSpace,
               sourcePixelFormat: stream.pixelFormat,
               sourceCodec: stream.codec,
               sourceTransfer: stream.colorTransfer,
               sourcePrimaries: stream.colorPrimaries,
               sourceWidth: geometry.width,
               sourceHeight: geometry.height,
               sourceCodedWidth: stream.width,
               sourceCodedHeight: stream.height,
               sourcePixelAspectRatio: geometry.pixelAspectRatio ?? 1,
               arguments: arguments
           ) {
            plan.apply(to: &arguments, inputPath: inputURL.path)
        }
        arguments.append(outputFileURL.path)

        let effectiveDuration = trimPlan.effectiveDuration

        return FFMPEGCommand(
            arguments: arguments,
            normalizedTrimStart: normalizedTrimStart,
            normalizedTrimEnd: normalizedTrimEnd,
            effectiveDuration: effectiveDuration
        )
    }
}

extension FFMPEGCommandBuilder {
    /// Frame geometry as FFmpeg's filters see it. FFmpeg autorotates before filtering, so a
    /// portrait phone clip stored as 1920x1080 with a -90° display matrix filters as 1080x1920.
    struct SourceGeometry {
        let width: Int
        let height: Int
        let pixelAspectRatio: Double?
        let displayAspectRatio: Double?

        init(width: Int, height: Int, pixelAspectRatio: Double?, displayAspectRatio: Double?) {
            self.width = width
            self.height = height
            self.pixelAspectRatio = pixelAspectRatio
            self.displayAspectRatio = displayAspectRatio
        }

        init?(stream: VideoMetadata.VideoStream) {
            guard let width = stream.orientedWidth, let height = stream.orientedHeight else { return nil }
            self.init(
                width: width,
                height: height,
                pixelAspectRatio: stream.orientedPixelAspectRatio,
                displayAspectRatio: stream.displayAspectRatio?.doubleValue
            )
        }
    }

    /// Resolve crop geometry from request metadata, a timed-media probe, or a still image.
    /// Image-sequence requests point this at their first frame because their primary input URL
    /// is the containing directory and cannot be probed as media.
    static func sourceGeometry(
        for sourceURL: URL,
        sourceMetadata: VideoMetadata?,
        probeMetadataIfNeeded: Bool = true
    ) async -> SourceGeometry? {
        if let stream = sourceMetadata?.primaryVideoStream,
           let geometry = SourceGeometry(stream: stream) {
            return geometry
        }

        if probeMetadataIfNeeded,
           let metadata = try? await BoundedVideoMetadataProbe.metadata(for: sourceURL),
           let stream = metadata.primaryVideoStream,
           let geometry = SourceGeometry(stream: stream) {
            return geometry
        }

        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0 else {
            return nil
        }

        return SourceGeometry(
            width: width,
            height: height,
            pixelAspectRatio: 1,
            displayAspectRatio: Double(width) / Double(height)
        )
    }

    /// Returns subtitle mapping arguments only for containers supported by the
    /// preservation setting. Matroska can copy subtitle streams verbatim, while
    /// MP4 and MOV require text subtitles to be encoded as `mov_text`.
    static func subtitleArguments(keepSubtitles: Bool, outputExtension: String) -> [String] {
        SubtitleMappingPlan(
            keepSubtitles: keepSubtitles,
            outputExtension: outputExtension
        ).arguments
    }

    /// Font attachments accompanying copied Matroska subtitles. The source is
    /// probed only when metadata stripping requires the attachment count.
    static func subtitleAttachmentArguments(
        keepSubtitles: Bool,
        outputExtension: String,
        outputArguments: some Collection<String>,
        inputURL: URL,
        sourceMetadata: VideoMetadata?
    ) async -> [String] {
        let subtitlePlan = SubtitleMappingPlan(keepSubtitles: keepSubtitles, outputExtension: outputExtension)
        guard subtitlePlan == .copy else { return [] }
        let stripsStreamMetadata = SubtitleAttachmentPlan.stripsStreamMetadata(outputArguments)
        var attachmentCount = sourceMetadata?.attachmentStreamCount
        if stripsStreamMetadata, sourceMetadata == nil {
            attachmentCount = try? await BoundedVideoMetadataProbe.metadata(for: inputURL).attachmentStreamCount
        }
        return SubtitleAttachmentPlan(
            subtitlePlan: subtitlePlan,
            stripsStreamMetadata: stripsStreamMetadata,
            attachmentCount: attachmentCount
        ).arguments
    }

    static func normalizedTrimPoint(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return max(value, 0)
    }

    static func ffmpegTimeString(from seconds: Double) -> String {
        String(format: "%.3f", seconds)
    }

    static func trimDurationArgument(start: Double?, end: Double?) -> [String]? {
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

    static func calculateEffectiveDuration(trimStart: Double?, trimEnd: Double?) -> Double? {
        if let start = trimStart, let end = trimEnd {
            return max(end - start, 0)
        } else if let end = trimEnd {
            return end
        }
        return nil
    }
    
    /// Builds audio routing filter segments for waveform video generation
    /// - Parameter config: The audio routing configuration
    /// - Returns: Tuple of (filter segments, output label for routed audio)
    private static func buildAudioRoutingFilters(config: AudioRoutingConfig) -> (segments: [String], outputLabel: String) {
        // Check if we need channel operations (filter_complex)
        if let operation = config.channelOperation {
            let outputLabel = "arouted"
            let filterSegment: String
            
            switch operation {
            case .mergeToStereo(let trackIndices):
                guard trackIndices.count >= 2 else {
                    // Fallback to simple track selection
                    return buildSimpleTrackRoutingFilters(config: config)
                }
                
                let inputs = trackIndices.map { "[0:a:\($0)]" }.joined()
                if trackIndices.count == 2 {
                    // Simple stereo merge: combine two mono tracks
                    filterSegment = "\(inputs)amerge=inputs=2,pan=stereo|c0<c0+c2|c1<c1+c3[\(outputLabel)]"
                } else {
                    // Multiple tracks: merge all into multi-channel, then downmix to stereo
                    filterSegment = "\(inputs)amerge=inputs=\(trackIndices.count),pan=stereo|c0<c0|c1<c1[\(outputLabel)]"
                }
                
            case .splitToMono(let trackIndex):
                // For waveform video, we need to merge split channels back to visualize
                // Split then immediately merge them back to stereo for visualization
                filterSegment = "[0:a:\(trackIndex)]channelsplit=channel_layout=stereo[L][R];[L][R]amerge=inputs=2,pan=stereo|c0<c0+c2|c1<c1+c3[\(outputLabel)]"
                
            case .swapChannels(let trackIndex):
                filterSegment = "[0:a:\(trackIndex)]pan=stereo|c0=c1|c1=c0[\(outputLabel)]"
                
            case .extractChannel(let trackIndex, let channelIndex, _):
                // Extract channel but convert to mono for visualization
                filterSegment = "[0:a:\(trackIndex)]pan=mono|c0=c\(channelIndex)[\(outputLabel)]"
            }
            
            return ([filterSegment], outputLabel)
        } else {
            // Simple track selection without channel operations
            return buildSimpleTrackRoutingFilters(config: config)
        }
    }
    
    /// Builds simple track selection filters for waveform video
    private static func buildSimpleTrackRoutingFilters(config: AudioRoutingConfig) -> (segments: [String], outputLabel: String) {
        if config.outputTrackIndices.count == 1 {
            // Single track: use directly
            let trackIndex = config.outputTrackIndices[0]
            return ([], "0:a:\(trackIndex)")
        } else if config.outputTrackIndices.count > 1 {
            // Multiple tracks: merge them for visualization
            let outputLabel = "arouted"
            let inputs = config.outputTrackIndices.map { "[0:a:\($0)]" }.joined()
            let filterSegment = "\(inputs)amerge=inputs=\(config.outputTrackIndices.count),pan=stereo|c0<c0|c1<c1[\(outputLabel)]"
            return ([filterSegment], outputLabel)
        } else {
            // No tracks selected: fallback to all audio
            return ([], "0:a")
        }
    }

    static func waveformFilterGraph(for request: WaveformVideoRequest, includeAudioSplit: Bool, audioRoutingConfig: AudioRoutingConfig? = nil) -> (filterComplex: String, videoMap: String, audioMap: String?) {
        let finalWidth = evenDimension(max(request.width, 2))
        let finalHeight = evenDimension(max(request.height, 2))
        let resolution = "\(finalWidth)x\(finalHeight)"
        let background = request.backgroundFFmpegColor
        let foreground = request.foregroundFFmpegColor
        let frameRateValue = max(1, Int(round(request.frameRate)))

        let channelLayout = request.style == .circle ? "mono" : "stereo"
        // Resample to 48kHz for broadcast format compatibility (MXF requires 48kHz)
        var audioFilters = ["aresample=48000", "aformat=channel_layouts=\(channelLayout)"]
        if request.normalizeAudio {
            audioFilters.append("dynaudnorm=f=250:g=30:p=0.9")
        }

        if request.style == .lines {
            audioFilters.append("compand")
        }

        let audioProcessing = audioFilters.joined(separator: ",")
        let waveInputLabel = includeAudioSplit ? "wavesrc" : "audproc"

        var segments: [String] = []
        
        // Apply audio routing if configured
        let audioInputLabel: String
        if let routingConfig = audioRoutingConfig {
            // Generate audio routing filters
            let (routingSegments, routingOutputLabel) = buildAudioRoutingFilters(config: routingConfig)
            segments.append(contentsOf: routingSegments)
            audioInputLabel = routingOutputLabel
        } else {
            // Default: use all audio from input
            audioInputLabel = "0:a"
        }
        
        var audioSegment = "[\(audioInputLabel)]\(audioProcessing)"
        if includeAudioSplit {
            audioSegment += ",asplit=2[\(waveInputLabel)][audout]"
        } else {
            audioSegment += "[\(waveInputLabel)]"
        }
        segments.append(audioSegment)

        segments.append("color=c=\(background):s=\(resolution):d=1[bg]")

        switch request.style {
        case .circle:
            let showwavesArgs = "showwaves=s=\(resolution):mode=cline:draw=full:split_channels=0:colors=\(foreground):rate=\(frameRateValue)"
            let polarExpression = "mod(W/PI*(PI+atan2(H/2-Y,X-W/2)),W)"
            let radiusExpression = "H-2*hypot(H/2-Y,X-W/2)"
            segments.append("[\(waveInputLabel)]\(showwavesArgs)[wave_linear]")
            segments.append("[wave_linear]geq='p(\(polarExpression),\(radiusExpression))':a='alpha(\(polarExpression),\(radiusExpression))'[wave]")
        case .linear:
            let waveformFilter = "showwaves=s=\(resolution):mode=cline:draw=scale:scale=sqrt:split_channels=0:colors=\(foreground):rate=\(frameRateValue)"
            segments.append("[\(waveInputLabel)]\(waveformFilter)[wave]")
        case .lines:
            let waveformFilter = "showwaves=s=\(resolution):mode=p2p:draw=full:scale=sqrt:split_channels=0:colors=\(foreground):rate=\(frameRateValue)"
            segments.append("[\(waveInputLabel)]\(waveformFilter)[wave]")
        case .fisheye:
            let showwavesArgs = "showwaves=s=\(resolution):mode=cline:rate=\(frameRateValue):colors=\(foreground):draw=scale"
            let fisheyeArgs = "v360=input=fisheye:output=equirect:interp=lanczos:w=\(finalWidth):h=\(finalHeight):ih_fov=360:iv_fov=180"
            segments.append("[\(waveInputLabel)]\(showwavesArgs)[wave_linear]")
            segments.append("[wave_linear]\(fisheyeArgs)[wave]")
        case .spectrogram:
            let spectrumArgs = "showspectrum=mode=separate:color=intensity:scale=log:slide=scroll:s=\(resolution):overlap=0.75"
            segments.append("[\(waveInputLabel)]\(spectrumArgs)[wave]")
        }

        segments.append("[bg][wave]overlay=format=auto[outv]")

        let filterComplex = segments.joined(separator: ";")
        let audioMap = includeAudioSplit ? "[audout]" : nil
        return (filterComplex, "[outv]", audioMap)
    }

    static func waveformCommandArguments(for request: WaveformVideoRequest, includeAudioOutput: Bool, audioRoutingConfig: AudioRoutingConfig? = nil) -> [String] {
        let components = waveformFilterGraph(for: request, includeAudioSplit: includeAudioOutput, audioRoutingConfig: audioRoutingConfig)

        var arguments: [String] = [
            "-filter_complex", components.filterComplex,
            "-map", components.videoMap
        ]

        if includeAudioOutput, let audioMap = components.audioMap {
            arguments.append(contentsOf: ["-map", audioMap])
        }

        if request.frameRate.isFinite, request.frameRate > 0 {
            let sanitizedFrameRate = formattedFrameRateString(from: request.frameRate)
            arguments.append(contentsOf: ["-r", sanitizedFrameRate])
        }

        arguments.append("-shortest")

        return arguments
    }

    // MARK: - Native Waveform Encoding Command (Swift renderer → rawvideo pipe)

    /// Builds an FFmpeg command that reads raw BGRA video frames from stdin (pipe:0)
    /// and audio from the original file, then encodes using the given preset.
    /// Used when the Swift native waveform renderer provides video frames.
    static func nativeWaveformEncodingCommand(
        audioInputURL: URL,
        outputFileURL: URL,
        preset: ExportPreset,
        dcpSettings: DCPSettings? = nil,
        imfSettings: IMFSettings? = nil,
        audioOnlySettings: AudioOnlySettings? = nil,
        imageSequenceSettings: ImageSequenceSettings? = nil,
        codecSettings: CodecExportSettings? = nil,
        commentSettings: CommentSettings? = nil,
        width: Int,
        height: Int,
        frameRate: Double,
        audioRoutingConfig: AudioRoutingConfig? = nil,
        trimStart: Double?,
        trimEnd: Double?,
        isMuted: Bool = false,
        comment: String = "",
        writeEmptyComment: Bool = false,
        includeDateTag: Bool = true,
        additionalOutputArguments: [String]? = nil,
        transparentBackground: Bool = false,
        matteOutputURL: URL? = nil
    ) async -> FFMPEGCommand {
        let trimPlan = FFMPEGTrimPlan(start: trimStart, end: trimEnd)
        let normalizedTrimStart = trimPlan.start
        let normalizedTrimEnd = trimPlan.end
        if let preparationError = trimPlan.preparationError {
            return FFMPEGCommand(
                arguments: [], normalizedTrimStart: normalizedTrimStart,
                normalizedTrimEnd: normalizedTrimEnd, effectiveDuration: nil,
                preparationError: preparationError
            )
        }

        let capturedDCPSettings = preset == .dcp ? (dcpSettings ?? DCPSettings()) : nil
        let capturedIMFSettings = (preset == .imfJ2K || preset == .imfProRes) ? (imfSettings ?? IMFSettings()) : nil
        let capturedAudioOnlySettings = preset == .audioOnly ? (audioOnlySettings ?? AudioOnlySettings()) : nil
        let capturedImageSequenceSettings = preset == .imageSequence ? (imageSequenceSettings ?? ImageSequenceSettings()) : nil
        let capturedCodecSettings = codecSettings ?? CodecExportSettings(preset: preset)
        let capturedCommentSettings = commentSettings ?? CommentSettings()
        if let dcpError = capturedDCPSettings?.configurationError {
            return FFMPEGCommand(
                arguments: [], normalizedTrimStart: normalizedTrimStart,
                normalizedTrimEnd: normalizedTrimEnd, effectiveDuration: nil,
                preparationError: dcpError
            )
        }
        let commentPlan: CommentMetadataPlan = preset == .imageSequence ? .unchanged : CommentMetadataPlan(
            comment: comment, includeDateTag: includeDateTag, settings: capturedCommentSettings, writeEmptyComment: writeEmptyComment
        )
        let metadataPlan = OutputMetadataPlan(
            source: (capturedAudioOnlySettings?.sourceMetadataPlan ?? capturedCodecSettings?.sourceMetadataPlan ?? .unchanged)
                .usingSourceInput(1),
            comment: commentPlan, timecode: .unchanged
        )
        let finalWidth = evenDimension(max(width, 2))
        let finalHeight = evenDimension(max(height, 2))
        let resolution = "\(finalWidth)x\(finalHeight)"
        let fpsString = formattedFrameRateString(from: frameRate)

        var arguments = ["-y", "-nostdin", "-progress", "pipe:2"]

        // Input 0: raw BGRA video from stdin pipe
        arguments.append(contentsOf: [
            "-f", "rawvideo",
            "-pix_fmt", "bgra",
            "-s", resolution,
            "-r", fpsString,
            "-i", "pipe:0"
        ])

        // Input 1: original audio file (with optional seek)
        arguments.append(contentsOf: trimPlan.seekArguments)
        arguments.append(contentsOf: ["-i", audioInputURL.path])
        let outputArgumentsStart = arguments.count

        // Duration limit
        arguments.append(contentsOf: trimPlan.durationArguments)

        // Map video from pipe, audio from file
        arguments.append(contentsOf: ["-map", "0:v", "-map", "1:a"])

        // Preset encoding arguments (sanitized for our custom video pipeline)
        var ffmpegArgs = capturedDCPSettings?.ffmpegArguments
            ?? capturedIMFSettings?.ffmpegArguments(application: preset == .imfJ2K ? .app2e : .rdd45)
            ?? capturedImageSequenceSettings?.ffmpegArguments
            ?? capturedAudioOnlySettings?.ffmpegArguments
            ?? capturedCodecSettings?.ffmpegArguments
            ?? preset.ffmpegArguments
        await adjustArgumentsForInput(preset: preset, audioOnlySettings: capturedAudioOnlySettings, codecSettings: capturedCodecSettings, inputURL: audioInputURL, ffmpegArgs: &ffmpegArgs, trimStart: normalizedTrimStart, trimEnd: normalizedTrimEnd)
        sanitizeArgumentsForCustomVideoPipeline(&ffmpegArgs)
        if capturedDCPSettings != nil {
            // The piped frames are already container-sized; only the X′Y′Z′ conversion remains.
            ffmpegArgs += ["-vf", DCPColorConversion.filterChain]
        }
        // Transparency is only honoured when the chosen encoder can carry alpha;
        // the renderer falls back to the opaque background otherwise.
        let preservesAlpha = transparentBackground && capturedDCPSettings == nil
            && enableAlphaOutput(in: &ffmpegArgs)
        // Otherwise a transparent waveform can still be delivered as fill + matte: the
        // rendered alpha is split off into a second output with the same video encoder.
        let writesMatte = transparentBackground && !preservesAlpha && matteOutputURL != nil
            && capturedDCPSettings == nil && preset.supportsMatteSidecar
        if writesMatte {
            arguments.insert(contentsOf: [
                "-filter_complex", "[0:v]split=2[wavefill][wavemattesrc];[wavemattesrc]alphaextract[wavematte]",
            ], at: outputArgumentsStart)
            if let mapIndex = arguments.indices.first(where: {
                arguments[$0] == "-map" && $0 + 1 < arguments.count && arguments[$0 + 1] == "0:v"
            }) {
                arguments[mapIndex + 1] = "[wavefill]"
            }
        }
        let matteEncoderArguments = writesMatte ? matteSidecarOutputOptions(from: ffmpegArgs) : []

        // Audio routing uses input index 1 (the audio file)
        if !isMuted, let audioRoutingConfig, preset.outputsAudioTrack,
           (capturedCodecSettings?.appliesAudioRouting ?? preset.appliesAudioRouting),
           audioRoutingConfig.isCustomized || !audioRoutingConfig.outputTracks.isEmpty {
            removeArgumentPair("-map", value: "1:a", from: &arguments)
            applyAudioRoutingForNativePipeline(
                config: audioRoutingConfig, to: &ffmpegArgs,
                codecOverrides: preset.supportsPerTrackAudioEncoding
            )
            if AudioRoutingService.makePlan(config: audioRoutingConfig).outputStreamCount == 0 {
                applyMute(to: &ffmpegArgs)
            }
        }

        if isMuted {
            applyMute(to: &ffmpegArgs)
            // Remove the audio map we added above
            removeArgumentPair("-map", value: "1:a", from: &arguments)
        }

        arguments.append(contentsOf: ffmpegArgs)

        if let additionalOutputArguments {
            arguments.append(contentsOf: additionalOutputArguments)
        }

        // Use -shortest so video stops when audio ends (or vice versa)
        arguments.append("-shortest")

        metadataPlan.apply(to: &arguments, outputArgumentsStart: outputArgumentsStart, outputExtension: outputFileURL.pathExtension)
        arguments.append(outputFileURL.path)

        if writesMatte, let matteOutputURL {
            arguments += ["-map", "[wavematte]"] + trimPlan.durationArguments + matteEncoderArguments
            arguments += ["-an", "-sn", "-dn", matteOutputURL.path]
        }

        let effectiveDuration = trimPlan.effectiveDuration

        return FFMPEGCommand(
            arguments: arguments,
            normalizedTrimStart: normalizedTrimStart,
            normalizedTrimEnd: normalizedTrimEnd,
            effectiveDuration: effectiveDuration,
            preservesAlpha: preservesAlpha,
            matteOutputURL: writesMatte ? matteOutputURL : nil
        )
    }

    // MARK: - Alpha Output

    /// Encoders that keep the alpha channel of BGRA input when no `-pix_fmt` is
    /// forced (verified against the bundled FFmpeg). MJPEG is the notable exception.
    static let alphaPreservingDefaultEncoders: Set<String> = [
        "png", "apng", "tiff", "exr", "dpx", "bmp", "targa", "sgi",
        "libjxl", "libopenjpeg", "ffv1", "qtrle",
    ]

    /// ProRes profile names (VideoToolbox and prores_ks spellings) that carry alpha.
    private static let alphaProResProfiles: Set<String> = ["4444", "xq", "4444xq", "4", "5"]
    private static let videoCodecKeys: Set<String> = ["-c:v", "-vcodec", "-codec:v", "-c:v:0", "-codec:v:0"]
    private static let videoProfileKeys: Set<String> = ["-profile:v", "-profile:v:0"]
    private static let pixelFormatKeys: Set<String> = ["-pix_fmt", "-pix_fmt:v", "-pix_fmt:v:0"]

    /// Index of the value following the last occurrence of any of `keys`.
    private static func lastValueIndex(for keys: Set<String>, in args: [String]) -> Int? {
        guard let index = args.indices.last(where: { keys.contains(args[$0]) }),
              index + 1 < args.count else { return nil }
        return index + 1
    }

    /// Whether an FFmpeg pixel format name includes an alpha channel.
    static func pixelFormatHasAlpha(_ pixelFormat: String) -> Bool {
        let format = pixelFormat.lowercased()
        if format.hasPrefix("yuva") || format.hasPrefix("gbrap") || format.hasPrefix("ya")
            || format.hasPrefix("ayuv") { return true }
        return ["rgba", "bgra", "argb", "abgr"].contains { format.contains($0) }
    }

    /// Whether the arguments encode ProRes with a 4444 / 4444 XQ profile.
    static func isAlphaCapableProRes(_ ffmpegArgs: [String]) -> Bool {
        guard let encoder = lastValueIndex(for: videoCodecKeys, in: ffmpegArgs).map({ ffmpegArgs[$0].lowercased() }),
              encoder.hasPrefix("prores"),
              let profile = lastValueIndex(for: videoProfileKeys, in: ffmpegArgs).map({ ffmpegArgs[$0].lowercased() })
        else { return false }
        return alphaProResProfiles.contains(profile)
    }

    /// Makes the output keep an alpha channel when the encoder can carry one.
    /// ProRes 4444 / 4444 XQ is switched to `yuva444p10le`, because the presets force
    /// a 4:2:2 format that silently drops alpha. Returns whether the output will
    /// contain alpha.
    @discardableResult
    static func enableAlphaOutput(in ffmpegArgs: inout [String]) -> Bool {
        let pixelFormatIndex = lastValueIndex(for: pixelFormatKeys, in: ffmpegArgs)
        if isAlphaCapableProRes(ffmpegArgs) {
            if let pixelFormatIndex {
                ffmpegArgs[pixelFormatIndex] = "yuva444p10le"
            } else {
                ffmpegArgs += ["-pix_fmt", "yuva444p10le"]
            }
            return true
        }
        if let pixelFormatIndex {
            return pixelFormatHasAlpha(ffmpegArgs[pixelFormatIndex])
        }
        let encoder = lastValueIndex(for: videoCodecKeys, in: ffmpegArgs).map { ffmpegArgs[$0].lowercased() }
        return encoder.map(alphaPreservingDefaultEncoders.contains) ?? false
    }

    // MARK: - Matte Sidecar

    /// `clip.mp4` → `clip_matte.mp4`, next to the main output.
    static func matteSidecarURL(for outputURL: URL) -> URL {
        let base = outputURL.deletingPathExtension().lastPathComponent + "_matte"
        let directory = outputURL.deletingLastPathComponent()
        return outputURL.pathExtension.isEmpty
            ? directory.appendingPathComponent(base)
            : directory.appendingPathComponent(base).appendingPathExtension(outputURL.pathExtension)
    }

    /// Index where output options start (just past the last `-i <input>`).
    private static func outputOptionsStart(in arguments: [String]) -> Int {
        arguments.lastIndex(of: "-i").map { min($0 + 2, arguments.count) } ?? 0
    }

    /// Whether a finished command's output keeps an alpha channel. Only output options
    /// are inspected, so a rawvideo `-pix_fmt bgra` input does not count.
    static func outputKeepsAlpha(_ arguments: [String]) -> Bool {
        var outputOptions = Array(arguments[outputOptionsStart(in: arguments)...].dropLast())
        return enableAlphaOutput(in: &outputOptions)
    }

    /// Value-less options removed from the matte output (re-added explicitly where needed).
    private static let matteStrippedFlags: Set<String> = ["-an", "-sn", "-dn", "-vn", "-shortest"]
    /// Options (with one value) that belong to audio, subtitles, data, attachments,
    /// stream mapping or metadata — none of which the matte carries.
    private static let matteStrippedOptions: Set<String> = [
        "-map", "-acodec", "-scodec", "-dcodec", "-ab", "-aq", "-ar", "-ac", "-af",
        "-sample_fmt", "-channel_layout", "-ch_layout", "-attach", "-filter_complex", "-lavfi",
        "-filter_complex_script", "-progress", "-aframes",
    ]

    /// Output options of the main file reduced to the video encoder settings, so the
    /// matte is encoded exactly like the main video (same codec, profile, bitrate,
    /// pixel format, container options, frame rate and video filters).
    static func matteSidecarOutputOptions(from outputOptions: [String]) -> [String] {
        var result: [String] = []
        var index = 0
        while index < outputOptions.count {
            let option = outputOptions[index]
            if matteStrippedFlags.contains(option) {
                index += 1
                continue
            }
            let specifiers = option.split(separator: ":").dropFirst()
            let targetsOtherStream = specifiers.contains { ["a", "s", "d", "t"].contains($0) }
            if option.hasPrefix("-") && index + 1 < outputOptions.count,
               matteStrippedOptions.contains(option) || targetsOtherStream
                || option.hasPrefix("-map_") || option.hasPrefix("-metadata") || option.hasPrefix("-disposition") {
                index += 2
                continue
            }
            result.append(option)
            index += 1
        }
        return result
    }

    /// Pins a 16-bit alpha format first: FFmpeg cannot negotiate formats for `alphaextract`
    /// directly after `scale` (the presets' desqueeze/resize), and 16 bits keep 10/12-bit alpha.
    static let matteExtractionFilter = "format=yuva444p16le,alphaextract"

    /// Second-pass FFmpeg arguments that re-read the source with the main command's
    /// inputs, trim and video filters, append `alphaextract`, and encode the result with
    /// the main video encoder. Returns nil when the main video is produced by a complex
    /// filter graph (the matte could not be guaranteed to line up).
    static func sourceMatteArguments(fromMainArguments arguments: [String], matteOutputURL: URL) -> [String]? {
        guard arguments.count > 1 else { return nil }
        let outputStart = outputOptionsStart(in: arguments)
        let inputs = arguments[..<outputStart]
        let outputOptions = Array(arguments[outputStart...].dropLast())
        let usesVideoGraph = zip(arguments, arguments.dropFirst()).contains { option, value in
            ["-filter_complex", "-lavfi"].contains(option)
                && (value.contains("[0:v") || value.contains("[0]") || value.contains("[0:0]"))
        }
        guard !usesVideoGraph, !arguments.contains("-filter_complex_script") else { return nil }

        // Drop the progress reporter (the matte pass is a quiet post-processing step) and
        // any audio filter graphs, whose outputs would be left unconnected.
        var globalsAndInputs: [String] = []
        var index = inputs.startIndex
        while index < inputs.endIndex {
            if ["-progress", "-filter_complex", "-lavfi"].contains(inputs[index]), index + 1 < inputs.endIndex {
                index += 2
                continue
            }
            globalsAndInputs.append(inputs[index])
            index += 1
        }

        var matteOptions = matteSidecarOutputOptions(from: outputOptions)
        let candidate = globalsAndInputs + matteOptions
        if let filterIndex = PrimaryVideoFilterPlan(arguments: candidate).filterOptionIndex,
           filterIndex >= globalsAndInputs.count, filterIndex + 1 < candidate.count {
            let optionIndex = filterIndex - globalsAndInputs.count
            let chain = matteOptions[optionIndex + 1]
            matteOptions[optionIndex + 1] = chain.isEmpty ? matteExtractionFilter : chain + "," + matteExtractionFilter
        } else {
            matteOptions += ["-vf", matteExtractionFilter]
        }
        return ["-nostats", "-loglevel", "error"] + globalsAndInputs + ["-map", "0:v:0"] + matteOptions
            + ["-an", "-sn", "-dn", matteOutputURL.path]
    }

    /// Applies audio routing for the native waveform pipeline where audio is input 1.
    /// Rewrites `0:a:X` references to `1:a:X` in the routing arguments.
    private static func applyAudioRoutingForNativePipeline(
        config: AudioRoutingConfig,
        to ffmpegArgs: inout [String],
        codecOverrides: Bool
    ) {
        // Get the standard audio routing arguments (which use 0:a:X)
        let standardArgs = AudioRoutingService.buildFFmpegMapArguments(config: config)

        // Rewrite input references from 0:a to 1:a for our two-input pipeline
        var rewrittenArgs: [String] = []
        for arg in standardArgs {
            var modified = arg
            // Replace [0:a:N] with [1:a:N] in filter_complex strings
            modified = modified.replacingOccurrences(of: "[0:a:", with: "[1:a:")
            modified = modified.replacingOccurrences(of: "[0:a]", with: "[1:a]")
            // Replace bare 0:a:N and 0:a in -map values
            if modified.hasPrefix("0:a") {
                modified = "1" + modified.dropFirst(1)
            }
            rewrittenArgs.append(modified)
        }

        // Remove existing audio maps from our arguments
        var index = 0
        while index < ffmpegArgs.count {
            if ffmpegArgs[index] == "-map",
               index + 1 < ffmpegArgs.count,
               (ffmpegArgs[index + 1].hasPrefix("1:a") || ffmpegArgs[index + 1] == "1:a" || ffmpegArgs[index + 1] == "1:a?") {
                ffmpegArgs.remove(at: index)
                ffmpegArgs.remove(at: index)
                continue
            }
            index += 1
        }

        // Check if routing uses filter_complex
        if rewrittenArgs.contains("-filter_complex") {
            // Insert at beginning of ffmpegArgs
            ffmpegArgs.insert(contentsOf: rewrittenArgs, at: 0)
        } else {
            // Simple map arguments — append them
            ffmpegArgs.append(contentsOf: rewrittenArgs)
        }

        if codecOverrides {
            // Output-stream specifiers are input-agnostic, so no rewrite is needed.
            ffmpegArgs.append(contentsOf: AudioRoutingService.makePlan(config: config).codecArguments(passthroughByDefault: false))
        }
    }

    private static func formattedFrameRateString(from value: Double) -> String {
        guard value.isFinite, value > 0 else { return "1" }

        let rounded = round(value * 1000) / 1000
        if abs(rounded.rounded() - rounded) < 0.001 {
            return String(Int(rounded.rounded()))
        }

        var string = String(format: "%.3f", rounded)
        while string.last == "0" {
            string.removeLast()
        }
        if string.last == "." {
            string.removeLast()
        }

        return string.isEmpty ? "1" : string
    }

    static func evenDimension(_ value: Int) -> Int {
        value % 2 == 0 ? value : value + 1
    }

    static func commentMetadataValue(
        comment: String,
        includeDateTag: Bool,
        date: Date = Date(),
        settings: CommentSettings = CommentSettings()
    ) -> String? {
        CommentMetadataPlan(comment: comment, includeDateTag: includeDateTag, date: date, settings: settings).value
    }

    static func applyCommentMetadata(
        to ffmpegArgs: inout [String], comment: String, includeDateTag: Bool,
        settings: CommentSettings = CommentSettings()
    ) {
        CommentMetadataPlan(comment: comment, includeDateTag: includeDateTag, settings: settings).apply(to: &ffmpegArgs)
    }

    static func applyTimecode(
        _ ffmpegArgs: inout [String],
        timecodeConfig: TimecodeConfig,
        sourceMetadata: VideoMetadata?,
        trimStart: Double?
    ) async {
        let timecodeValue = resolvedTimecode(
            timecodeConfig: timecodeConfig,
            sourceMetadata: sourceMetadata,
            trimStart: trimStart
        )

        TimecodeMetadataPlan(resolvedValue: timecodeValue).apply(to: &ffmpegArgs)
    }

    /// Resolves a configured timecode without assuming an FFmpeg output. The AV2
    /// Matroska path uses the same policy when writing native container tags.
    static func resolvedTimecode(
        timecodeConfig: TimecodeConfig,
        sourceMetadata: VideoMetadata?,
        trimStart: Double?
    ) -> String? {
        switch timecodeConfig.mode {
        case .preserveSource:
            if let sourceTimecode = sourceMetadata?.timecode,
               let trimOffset = trimStart,
               trimOffset > 0,
               let frameRate = sourceMetadata?.primaryVideoStream?.frameRate?.value {
                return offsetTimecode(sourceTimecode, bySeconds: trimOffset, frameRate: frameRate)
            }
            return sourceMetadata?.timecode
        case .manual(let timecode):
            return timecode.isEmpty ? nil : timecode
        }
    }

    /// Applies an already-resolved per-item timecode choice. Video items receive
    /// their global default when they are created, so nil here means the user
    /// explicitly disabled timecode and must not reload settings. Manual values
    /// do not require source metadata; preservation probes only when needed.
    static func applyConfiguredTimecode(
        _ ffmpegArgs: inout [String],
        preset: ExportPreset,
        inputURL: URL,
        timecodeConfig: TimecodeConfig?,
        sourceMetadata knownSourceMetadata: VideoMetadata? = nil,
        trimStart: Double?
    ) async {
        let plan = await configuredTimecodePlan(
            preset: preset, inputURL: inputURL, timecodeConfig: timecodeConfig,
            sourceMetadata: knownSourceMetadata, trimStart: trimStart
        )
        plan.apply(to: &ffmpegArgs)
    }

    static func configuredTimecodePlan(
        preset: ExportPreset,
        inputURL: URL,
        timecodeConfig: TimecodeConfig?,
        sourceMetadata knownSourceMetadata: VideoMetadata? = nil,
        trimStart: Double?,
        metadataProvider: @Sendable (URL) async -> VideoMetadata? = {
            try? await BoundedVideoMetadataProbe.metadata(for: $0)
        }
    ) async -> TimecodeMetadataPlan {
        guard preset.outputsVideoTrack else {
            return .unchanged
        }

        guard let timecodeConfig, timecodeConfig.isActive else {
            return .clear
        }

        let sourceMetadata: VideoMetadata?
        switch timecodeConfig.mode {
        case .preserveSource:
            if let knownSourceMetadata {
                sourceMetadata = knownSourceMetadata
            } else if let probedMetadata = await metadataProvider(inputURL) {
                sourceMetadata = probedMetadata
            } else {
                // Preserve FFmpeg's source metadata mapping when the in-process
                // probe fails instead of interpreting a probe failure as an
                // explicit request to remove timecode.
                return .unchanged
            }
        case .manual:
            sourceMetadata = nil
        }

        return TimecodeMetadataPlan(resolvedValue: resolvedTimecode(
            timecodeConfig: timecodeConfig,
            sourceMetadata: sourceMetadata,
            trimStart: trimStart
        ))
    }

    /// Offsets a timecode string by a given number of seconds
    /// - Parameters:
    ///   - timecode: Source timecode in format HH:MM:SS:FF or HH:MM:SS;FF
    ///   - seconds: Number of seconds to offset
    ///   - frameRate: Frame rate of the video
    /// - Returns: Offset timecode string, or original if parsing fails
    static func offsetTimecode(_ timecode: String, bySeconds seconds: Double, frameRate: Double) -> String {
        // Parse timecode components
        let components = timecode.split(whereSeparator: { $0 == ":" || $0 == ";" })

        guard components.count == 4,
              let hours = Int(components[0]),
              let minutes = Int(components[1]),
              let secs = Int(components[2]),
              let frames = Int(components[3]) else {
            logger.warning("Failed to parse timecode: \(timecode, privacy: .public)")
            return timecode
        }

        // Timecode labels count at the nominal integer rate even when their media
        // timestamps use a fractional NTSC rate. Guard very-low/invalid rates so
        // the modulo operations below can never divide by zero.
        guard frameRate.isFinite, frameRate.rounded() >= 1,
              frameRate.rounded() < Double(Int.max / 86_400),
              seconds.isFinite else {
            logger.warning("Cannot offset timecode at invalid frame rate: \(frameRate, privacy: .public)")
            return timecode
        }
        let nominalFPS = Int(frameRate.rounded())
        guard hours >= 0, (0..<60).contains(minutes), (0..<60).contains(secs),
              (0..<nominalFPS).contains(frames) else { return timecode }

        let isDropFrame = timecode.contains(";") && isSupportedDropFrameRate(frameRate)
        let droppedFramesPerMinute = nominalFPS == 60 ? 4 : 2

        // Convert timecode to total frames
        var totalFrames = hours
        for (factor, component) in [(60, minutes), (60, secs), (nominalFPS, frames)] {
            let product = totalFrames.multipliedReportingOverflow(by: factor)
            let sum = product.partialValue.addingReportingOverflow(component)
            guard !product.overflow, !sum.overflow else { return timecode }
            totalFrames = sum.partialValue
        }

        if isDropFrame {
            let totalMinutes = hours * 60 + minutes
            let skippedLabels = droppedFramesPerMinute * (totalMinutes - totalMinutes / 10)
            totalFrames -= skippedLabels
        }

        // Add offset in frames (round to nearest frame to avoid off-by-one errors)
        let roundedOffset = round(seconds * frameRate)
        guard roundedOffset.isFinite, roundedOffset >= Double(Int.min),
              roundedOffset < Double(Int.max) else { return timecode }
        let addition = totalFrames.addingReportingOverflow(Int(roundedOffset))
        guard !addition.overflow else { return timecode }
        totalFrames = addition.partialValue

        // Ensure non-negative
        totalFrames = max(0, totalFrames)

        if isDropFrame {
            totalFrames = dropFrameLabelFrame(
                forAbsoluteFrame: totalFrames,
                nominalFPS: nominalFPS,
                droppedFramesPerMinute: droppedFramesPerMinute
            )
        }

        // Convert back to timecode components
        let newFrames = totalFrames % nominalFPS
        var remainingFrames = totalFrames / nominalFPS

        let newSeconds = remainingFrames % 60
        remainingFrames /= 60

        let newMinutes = remainingFrames % 60
        remainingFrames /= 60

        let newHours = remainingFrames % 24

        // Preserve the separator (: for non-drop-frame, ; for drop-frame)
        let separator = timecode.contains(";") ? ";" : ":"

        // Build new timecode
        let offsetTimecode = String(format: "%02d:%02d:%02d%@%02d",
                                    newHours,
                                    newMinutes,
                                    newSeconds,
                                    separator,
                                    newFrames)

        logger.debug("Offset timecode from \(timecode, privacy: .public) to \(offsetTimecode, privacy: .public) (offset: \(seconds, privacy: .public)s at \(frameRate, privacy: .public)fps)")

        return offsetTimecode
    }

    private static func isSupportedDropFrameRate(_ frameRate: Double) -> Bool {
        abs(frameRate - (30_000.0 / 1_001.0)) < 0.01 ||
            abs(frameRate - (60_000.0 / 1_001.0)) < 0.01
    }

    /// Converts a zero-based absolute frame count into its drop-frame label frame.
    /// Drop-frame timecode skips two labels per minute at 29.97 fps (four at
    /// 59.94), except every tenth minute. The media frames themselves are not
    /// dropped; only their displayed labels are discontinuous.
    private static func dropFrameLabelFrame(
        forAbsoluteFrame absoluteFrame: Int,
        nominalFPS: Int,
        droppedFramesPerMinute: Int
    ) -> Int {
        let framesPerMinute = nominalFPS * 60 - droppedFramesPerMinute
        let framesPerTenMinutes = nominalFPS * 60 * 10 - droppedFramesPerMinute * 9
        let framesPerHour = framesPerTenMinutes * 6
        let framesPerDay = framesPerHour * 24
        let wrappedFrame = absoluteFrame % framesPerDay
        let completeTenMinuteBlocks = wrappedFrame / framesPerTenMinutes
        let remainder = wrappedFrame % framesPerTenMinutes

        var skippedLabels = droppedFramesPerMinute * 9 * completeTenMinuteBlocks
        if remainder > droppedFramesPerMinute {
            skippedLabels += droppedFramesPerMinute * ((remainder - droppedFramesPerMinute) / framesPerMinute)
        }

        return wrappedFrame + skippedLabels
    }

    /// Replaces generic `-map 0:a` with explicit mapping of only decodable audio streams.
    /// This filters out unsupported codecs like Apple's APAC spatial audio.
    static func filterUnsupportedAudioStreams(
        inputURL: URL,
        ffmpegArgs: inout [String]
    ) async {
        // Check if we have a generic audio map that needs filtering
        guard ffmpegArgs.contains(where: { $0 == "-map" }),
              let mapIndex = ffmpegArgs.firstIndex(of: "-map"),
              mapIndex + 1 < ffmpegArgs.count else {
            return
        }

        // Find all audio map arguments
        var audioMapIndices: [(index: Int, value: String)] = []
        for i in 0..<ffmpegArgs.count - 1 {
            if ffmpegArgs[i] == "-map" {
                let value = ffmpegArgs[i + 1]
                if value == "0:a" || value == "0:a?" {
                    audioMapIndices.append((i, value))
                }
            }
        }

        // If no generic audio maps, nothing to filter
        guard !audioMapIndices.isEmpty else { return }

        // Fetch audio streams to check codec support
        guard let audioStreams = await FFMPEGProbeService.fetchAudioStreams(for: inputURL),
              !audioStreams.isEmpty else {
            return
        }

        // Check if all streams are decodable - if so, no need to change anything
        let decodableStreams = audioStreams.filter { $0.isDecodable }
        if decodableStreams.count == audioStreams.count {
            return // All streams are decodable, keep original mapping
        }

        // Log which streams are being filtered
        let skippedStreams = audioStreams.filter { !$0.isDecodable }
        for stream in skippedStreams {
            logger.info("Skipping unsupported audio stream index \(stream.index ?? -1) with codec '\(stream.codecName ?? "unknown", privacy: .public)'")
        }

        // If no decodable streams, remove audio mapping entirely
        if decodableStreams.isEmpty {
            // Remove all generic audio maps and replace with -an if preset expects audio
            for (mapIdx, _) in audioMapIndices.reversed() {
                ffmpegArgs.remove(at: mapIdx + 1)
                ffmpegArgs.remove(at: mapIdx)
            }
            // Also remove audio codec settings if present
            removeArgumentPair("-c:a", value: nil, from: &ffmpegArgs)
            removeArgumentPair("-b:a", value: nil, from: &ffmpegArgs)
            if !ffmpegArgs.contains("-an") {
                ffmpegArgs.append("-an")
            }
            logger.warning("No decodable audio streams found, disabling audio output")
            return
        }

        // Replace generic audio maps with explicit stream indices
        // Process in reverse order to maintain correct indices during removal
        for (mapIdx, _) in audioMapIndices.reversed() {
            ffmpegArgs.remove(at: mapIdx + 1)
            ffmpegArgs.remove(at: mapIdx)
        }

        // Build position-based indices for decodable streams
        // Audio stream positions are 0-based within audio streams (0:a:0, 0:a:1, etc.)
        var audioPosition = 0
        var decodablePositions: [Int] = []
        for stream in audioStreams {
            if stream.isDecodable {
                decodablePositions.append(audioPosition)
            }
            audioPosition += 1
        }

        // Find where to insert the new audio maps (after video map if present)
        var insertionIndex = 0
        for (idx, arg) in ffmpegArgs.enumerated() {
            if arg == "-map", idx + 1 < ffmpegArgs.count, ffmpegArgs[idx + 1].hasPrefix("0:v") {
                insertionIndex = idx + 2
                break
            }
        }

        // Insert explicit audio stream maps
        var offset = 0
        for position in decodablePositions {
            ffmpegArgs.insert("-map", at: insertionIndex + offset)
            ffmpegArgs.insert("0:a:\(position)", at: insertionIndex + offset + 1)
            offset += 2
        }

        logger.info("Filtered audio streams: mapping only decodable streams \(decodablePositions)")
    }

    static func adjustArgumentsForInput(
        preset: ExportPreset,
        audioOnlySettings: AudioOnlySettings? = nil,
        codecSettings: CodecExportSettings? = nil,
        inputURL: URL,
        ffmpegArgs: inout [String],
        trimStart: Double? = nil,
        trimEnd: Double? = nil,
        sourceMetadata: VideoMetadata? = nil,
        audioStreamProvider: @Sendable (URL) async -> [FFMPEGProbeService.AudioStreamInfo]? = { url in
            await FFMPEGProbeService.fetchAudioStreams(for: url)
        }
    ) async {
        // Handle AVC-Intra mono channel splitting
        if preset == .tvAVCIntra {
            let targetChannelCount = (codecSettings ?? CodecExportSettings(preset: preset))?.avcIntraAudioChannels?.count ?? 8
            // Calculate effective duration for silent streams
            let effectiveDuration = await calculateEffectiveDurationForAudio(
                inputURL: inputURL,
                trimStart: trimStart,
                trimEnd: trimEnd,
                sourceMetadata: sourceMetadata
            )
            await adjustAVCIntraAudio(
                inputURL: inputURL, ffmpegArgs: &ffmpegArgs, duration: effectiveDuration,
                targetChannelCount: targetChannelCount, audioStreamProvider: audioStreamProvider
            )
            return
        }

        guard preset == .audioOnly else { return }
        let format = (audioOnlySettings ?? AudioOnlySettings()).format
        guard format.supportsSingleStreamOnly else { return }
        guard let audioStreams = await audioStreamProvider(inputURL),
              audioStreams.count > 1 else {
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

    /// Calculate the effective duration for audio streams, considering trim points
    private static func calculateEffectiveDurationForAudio(
        inputURL: URL,
        trimStart: Double?,
        trimEnd: Double?,
        sourceMetadata: VideoMetadata?
    ) async -> Double? {
        // If we have both trim points, use the difference
        if let start = trimStart, let end = trimEnd {
            return end - start
        }

        // Try to get the file's total duration
        let resolvedMetadata: VideoMetadata?
        if let sourceMetadata {
            resolvedMetadata = sourceMetadata
        } else {
            resolvedMetadata = try? await BoundedVideoMetadataProbe.metadata(for: inputURL)
        }
        if let totalDuration = resolvedMetadata?.duration {
            if let start = trimStart {
                return totalDuration - start
            } else if let end = trimEnd {
                return end
            } else {
                return totalDuration
            }
        }

        return nil
    }

    /// Adjusts audio arguments for AVC-Intra preset to create separate mono streams
    /// Input stereo tracks are split into individual mono streams for MXF broadcast delivery
    private static func adjustAVCIntraAudio(
        inputURL: URL,
        ffmpegArgs: inout [String],
        duration: Double?,
        targetChannelCount: Int,
        audioStreamProvider: @Sendable (URL) async -> [FFMPEGProbeService.AudioStreamInfo]?
    ) async {
        // Format duration for anullsrc (add small buffer to ensure it's long enough)
        let durationStr: String
        if let dur = duration {
            durationStr = String(format: "%.3f", dur + 1.0) // Add 1 second buffer
        } else {
            durationStr = "3600" // Default to 1 hour if unknown
        }

        // Fetch audio stream info from input and filter to only decodable streams
        let allAudioStreams = await audioStreamProvider(inputURL) ?? []
        let audioStreams = allAudioStreams.filter { $0.isDecodable }

        // Log filtered streams
        let skippedStreams = allAudioStreams.filter { !$0.isDecodable }
        for stream in skippedStreams {
            logger.info("AVC-Intra: Skipping unsupported audio stream index \(stream.index ?? -1) with codec '\(stream.codecName ?? "unknown", privacy: .public)'")
        }

        // Remove existing audio mapping arguments
        removeArgumentPair("-map", value: "0:a?", from: &ffmpegArgs)
        removeArgumentPair("-ac", value: nil, from: &ffmpegArgs)

        // If no decodable audio streams, create silent mono streams
        // Use a single aevalsrc source with asplit to minimize independent audio generators
        // aevalsrc generates samples on-demand, which helps with MXF muxer synchronization
        guard !audioStreams.isEmpty else {
            var filterParts: [String] = []
            var silentMaps: [String] = []

            // Create single silent source using aevalsrc (generates silence on-demand)
            filterParts.append("aevalsrc=0:c=mono:s=48000:d=\(durationStr)[silentsrc]")

            if targetChannelCount == 1 {
                // Just one channel needed
                silentMaps.append(contentsOf: ["-map", "[silentsrc]"])
            } else {
                // Split into multiple channels
                var splitOutputs: [String] = []
                for i in 0..<targetChannelCount {
                    splitOutputs.append("[silent\(i)]")
                }
                filterParts.append("[silentsrc]asplit=\(targetChannelCount)\(splitOutputs.joined())")
                for i in 0..<targetChannelCount {
                    silentMaps.append(contentsOf: ["-map", "[silent\(i)]"])
                }
            }

            let filterGraph = filterParts.joined(separator: ";")
            ffmpegArgs.append(contentsOf: ["-filter_complex", filterGraph])
            ffmpegArgs.append(contentsOf: silentMaps)
            // Add -shortest to stop when video ends
            ffmpegArgs.append("-shortest")
            return
        }

        // Build filter graph to split all audio streams into mono channels
        // Important: Use original audio stream positions for FFmpeg's 0:a:X notation
        var filterParts: [String] = []
        var monoOutputs: [String] = []
        var outputIndex = 0

        for (audioPosition, stream) in allAudioStreams.enumerated() {
            // Skip unsupported streams
            guard stream.isDecodable else { continue }

            let channels = stream.channels ?? 2

            if channels == 1 {
                // Mono stream - use directly but ensure consistent format
                let outputLabel = "mono\(outputIndex)"
                filterParts.append("[0:a:\(audioPosition)]aformat=sample_fmts=s32:sample_rates=48000:channel_layouts=mono[\(outputLabel)]")
                monoOutputs.append(outputLabel)
                outputIndex += 1
            } else {
                // Generate output labels for each channel
                var channelLabels: [String] = []
                for ch in 0..<channels {
                    channelLabels.append("s\(audioPosition)c\(ch)")
                }
                let outputLabelsStr = channelLabels.map { "[\($0)]" }.joined()

                // Extract by channel index: a count-derived speaker layout can reorder,
                // remix, or silence channels before channelsplit sees the input.
                filterParts.append("[0:a:\(audioPosition)]asplit=\(channels)\(outputLabelsStr)")

                // Add format filter for each split channel to ensure consistent output
                for (channel, label) in channelLabels.enumerated() {
                    let formattedLabel = "mono\(outputIndex)"
                    filterParts.append("[\(label)]pan=mono|c0=c\(channel),aformat=sample_fmts=s32:sample_rates=48000:channel_layouts=mono[\(formattedLabel)]")
                    monoOutputs.append(formattedLabel)
                    outputIndex += 1
                }
            }
        }

        // Determine how many channels we actually have vs need
        let availableChannels = monoOutputs.count

        // Add silent streams if we need more channels than available
        // Instead of anullsrc (which causes buffer deadlocks with MXF),
        // derive silent channels from existing audio using volume=0 and asplit
        if availableChannels < targetChannelCount && availableChannels > 0 {
            let silentChannelsNeeded = targetChannelCount - availableChannels

            // Use the first mono output as the template for silent channels
            // We need to split it first: one copy for actual output, one for silent derivation
            let templateLabel = monoOutputs[0]
            let templateForOutput = "\(templateLabel)_out"
            let templateForSilent = "\(templateLabel)_silent"

            // Split the template into two: one for output, one for silent channel derivation
            filterParts.append("[\(templateLabel)]asplit=2[\(templateForOutput)][\(templateForSilent)]")

            // Update monoOutputs to use the split output version
            monoOutputs[0] = templateForOutput

            // Generate labels for all silent outputs
            var silentLabels: [String] = []
            for i in 0..<silentChannelsNeeded {
                silentLabels.append("silent\(availableChannels + i)")
            }

            // Create silent version and split into required number of channels
            if silentChannelsNeeded == 1 {
                // Just one silent channel needed - apply volume=0 directly
                filterParts.append("[\(templateForSilent)]volume=0[\(silentLabels[0])]")
            } else {
                // Multiple silent channels - silence first, then split
                let silentBaseLabel = "silentbase"
                filterParts.append("[\(templateForSilent)]volume=0[\(silentBaseLabel)]")
                let splitOutputs = silentLabels.map { "[\($0)]" }.joined()
                filterParts.append("[\(silentBaseLabel)]asplit=\(silentChannelsNeeded)\(splitOutputs)")
            }

            monoOutputs.append(contentsOf: silentLabels)
        }

        // Truncate if we have more channels than needed
        let finalOutputs = Array(monoOutputs.prefix(targetChannelCount))

        // Build final filter graph
        let filterGraph = filterParts.joined(separator: ";")

        // Build map arguments for each mono output
        var mapArgs: [String] = []
        for output in finalOutputs {
            mapArgs.append(contentsOf: ["-map", "[\(output)]"])
        }

        // Add to ffmpeg arguments
        ffmpegArgs.append(contentsOf: ["-filter_complex", filterGraph])
        ffmpegArgs.append(contentsOf: mapArgs)
    }

    /// Remaps audio from the second FFmpeg input (index 1) for image sequences with associated audio.
    /// Changes `-map 0:a` to `-map 1:a` so audio comes from the audio file, not the image sequence.
    static func remapAudioForImageSequence(from args: inout [String]) {
        var index = 0
        while index < args.count {
            if args[index] == "-map", index + 1 < args.count {
                let value = args[index + 1]
                // Remap any 0:a reference to 1:a (audio from second input)
                if value == "0:a" {
                    args[index + 1] = "1:a"
                } else if value == "0:a?" {
                    args[index + 1] = "1:a?"
                } else if value.hasPrefix("0:a:") {
                    args[index + 1] = "1:a:" + value.dropFirst(4)
                }
            }
            index += 1
        }
    }

    /// Strips all audio-related arguments from FFmpeg args.
    /// Used for image sequence inputs which have no audio streams.
    static func stripAudioArguments(from args: inout [String]) {
        // Remove audio stream mappings: -map 0:a, -map 0:a?, -map 0:a:N
        var index = 0
        while index < args.count {
            if args[index] == "-map", index + 1 < args.count {
                let value = args[index + 1]
                if value.hasPrefix("0:a") {
                    args.remove(at: index)
                    args.remove(at: index)
                    continue
                }
            }
            index += 1
        }
        // Remove audio codec and bitrate settings
        removeArgumentPair("-c:a", value: nil, from: &args)
        removeArgumentPair("-b:a", value: nil, from: &args)
        removeArgumentPair("-ac", value: nil, from: &args)
        // Add -an to explicitly disable audio output
        if !args.contains("-an") {
            args.append("-an")
        }
    }

    static func removeArgumentPair(_ key: String, value: String?, from args: inout [String]) {
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

    private static func removeStandaloneArgument(_ key: String, from args: inout [String]) {
        var index = 0
        while index < args.count {
            if args[index] == key {
                args.remove(at: index)
                continue
            }
            index += 1
        }
    }

    static func adjustDeinterlaceFilter(
        inputURL: URL,
        ffmpegArgs: inout [String],
        sourceMetadata: VideoMetadata? = nil,
        metadataTimeout: Duration = BoundedVideoMetadataProbe.defaultTimeout,
        metadataProbe: @escaping @Sendable (URL) async throws -> VideoMetadata = {
            try await VideoMetadataService.shared.metadata(for: $0)
        }
    ) async {
        // Only proceed if a video filter graph exists
        guard let vfIndex = PrimaryVideoFilterPlan(arguments: ffmpegArgs).filterOptionIndex else {
            return
        }

        let metadata: VideoMetadata?
        if let sourceMetadata {
            metadata = sourceMetadata
        } else {
            metadata = try? await BoundedVideoMetadataProbe.metadata(
                for: inputURL,
                timeout: metadataTimeout,
                probe: metadataProbe
            )
        }

        let isInterlaced: Bool
        if let metadata {
            isInterlaced = metadata.primaryVideoStream?.isInterlaced ?? false
        } else {
            isInterlaced = false
        }

        // Only rewrite whole stages owned by built-in presets. User expressions and
        // explicitly configured deinterlacers retain their original text and behavior.
        guard var stages = splitVideoFilterStages(ffmpegArgs[vfIndex + 1]) else { return }
        let isBuiltIn: (String) -> Bool = { $0 == "yadif" || $0 == "yadif=0" }
        if isInterlaced {
            let bwdifFilter = "bwdif=mode=send_field:parity=auto:deint=all"
            if stages.contains(where: isBuiltIn) {
                stages = stages.map { isBuiltIn($0) ? bwdifFilter : $0 }
            } else if !stages.contains(where: { stage in
                let name = stage.trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "=", maxSplits: 1).first?
                    .split(separator: "@", maxSplits: 1).first
                return name == "yadif" || name == "bwdif"
            }) {
                stages.insert(bwdifFilter, at: 0)
            }
        } else {
            stages.removeAll(where: isBuiltIn)
        }
        // Keep an explicit no-op when removal empties the effective chain; dropping
        // the option would reactivate an earlier filter override.
        ffmpegArgs[vfIndex + 1] = stages.isEmpty ? "null" : stages.joined(separator: ",")
    }

    private static func adjustStreamCopyArguments(
        inputURL: URL,
        outputURL: URL,
        ffmpegArgs: inout [String]
    ) {
        let outputExtension = outputURL.pathExtension.lowercased()
        let effectiveExtension = outputExtension.isEmpty ? inputURL.pathExtension.lowercased() : outputExtension
        let restrictedContainers: Set<String> = ["mp4", "mov", "m4v", "m4a"]

        guard restrictedContainers.contains(effectiveExtension) else { return }

        // MP4/MOV containers can fail on unknown/data streams; map only known types.
        removeArgumentPair("-map", value: nil, from: &ffmpegArgs)
        removeStandaloneArgument("-copy_unknown", from: &ffmpegArgs)

        var mapArgs: [String] = ["-map", "0:v?"]
        if !ffmpegArgs.contains("-an") {
            mapArgs.append(contentsOf: ["-map", "0:a?"])
        }
        mapArgs.append(contentsOf: ["-map", "0:s?"])
        ffmpegArgs.append(contentsOf: mapArgs)
    }

    /// Generated-video pipelines replace the preset's -vf with their own filter_complex, so
    /// the DCP X′Y′Z′ conversion is appended to that graph and the video map redirected to it.
    private static func applyDCPColorConversion(to arguments: inout [String]) {
        guard let graphIndex = arguments.firstIndex(of: "-filter_complex"),
              graphIndex + 1 < arguments.count else { return }
        let graph = arguments[graphIndex + 1]
        let generatedVideoLabels: Set<String> = ["[outv]", "[synth_v]"]
        guard let mapIndex = arguments.indices.first(where: { index in
            index > graphIndex && index + 1 < arguments.count && arguments[index] == "-map"
                && generatedVideoLabels.contains(arguments[index + 1])
        }) else { return }
        let videoLabel = arguments[mapIndex + 1]
        arguments[graphIndex + 1] = graph + ";\(videoLabel)\(DCPColorConversion.filterChain)[dcp_xyz]"
        arguments[mapIndex + 1] = "[dcp_xyz]"
    }

    private static func sanitizeArgumentsForCustomVideoPipeline(_ ffmpegArgs: inout [String]) {
        removeArgumentPair("-vf", value: nil, from: &ffmpegArgs)
        removeArgumentPair("-map", value: nil, from: &ffmpegArgs)
        // Remove any preset-added filter_complex (e.g., AVC-Intra mono channel splitting)
        // since waveform/synthesized video pipelines have their own filter_complex
        removeArgumentPair("-filter_complex", value: nil, from: &ffmpegArgs)
    }
    
    /// Removes video-related arguments for audio-only encoding
    private static func removeVideoArguments(from ffmpegArgs: inout [String]) {
        // Remove video codec arguments
        removeArgumentPair("-c:v", value: nil, from: &ffmpegArgs)
        removeArgumentPair("-pix_fmt", value: nil, from: &ffmpegArgs)
        removeArgumentPair("-b:v", value: nil, from: &ffmpegArgs)
        removeArgumentPair("-profile:v", value: nil, from: &ffmpegArgs)
        removeArgumentPair("-tag:v", value: nil, from: &ffmpegArgs)
        
        // Remove video filter arguments
        removeArgumentPair("-vf", value: nil, from: &ffmpegArgs)
        
        // Remove video mapping (this is the key one causing the error)
        var index = 0
        while index < ffmpegArgs.count {
            if ffmpegArgs[index] == "-map",
               index + 1 < ffmpegArgs.count,
               ffmpegArgs[index + 1].contains("0:v") {
                ffmpegArgs.remove(at: index)
                ffmpegArgs.remove(at: index)
                continue
            }
            index += 1
        }
        
        // Remove metadata for video streams
        var metadataIndex = 0
        while metadataIndex < ffmpegArgs.count {
            if ffmpegArgs[metadataIndex] == "-metadata:s:v:0",
               metadataIndex + 1 < ffmpegArgs.count {
                ffmpegArgs.remove(at: metadataIndex)
                ffmpegArgs.remove(at: metadataIndex)
                continue
            }
            metadataIndex += 1
        }
    }

    /// Applies mute by removing all audio arguments and ensuring -an flag is present
    private static func applyMute(to ffmpegArgs: inout [String]) {
        // Remove audio codec arguments
        removeArgumentPair("-c:a", value: nil, from: &ffmpegArgs)
        removeArgumentPair("-b:a", value: nil, from: &ffmpegArgs)
        removeArgumentPair("-ac", value: nil, from: &ffmpegArgs)

        // Remove audio mapping
        var index = 0
        while index < ffmpegArgs.count {
            if ffmpegArgs[index] == "-map",
               index + 1 < ffmpegArgs.count,
               (ffmpegArgs[index + 1].contains("0:a") || ffmpegArgs[index + 1] == "[aout]" || ffmpegArgs[index + 1] == "[audout]") {
                ffmpegArgs.remove(at: index)
                ffmpegArgs.remove(at: index)
                continue
            }
            index += 1
        }

        // Remove audio filter_complex if present and audio-only
        removeArgumentPair("-filter_complex", value: nil, from: &ffmpegArgs)

        // Remove audio metadata
        var metadataIndex = 0
        while metadataIndex < ffmpegArgs.count {
            if ffmpegArgs[metadataIndex] == "-metadata:s:a:0",
               metadataIndex + 1 < ffmpegArgs.count {
                ffmpegArgs.remove(at: metadataIndex)
                ffmpegArgs.remove(at: metadataIndex)
                continue
            }
            metadataIndex += 1
        }

        // Ensure -an flag is present
        if !ffmpegArgs.contains("-an") {
            ffmpegArgs.append("-an")
        }
    }

    /// Applies audio routing configuration by replacing preset's audio map arguments
    /// with custom track selection, ordering, or channel-level operations
    /// Stream copy keeps every non-audio stream from `-map 0` (or the MP4/MOV
    /// subset), drops the source audio, and maps the routed tracks. Tracks without
    /// a codec override inherit `-c copy`; filtered or AAC tracks get `-c:a:N`.
    static func applyStreamCopyAudioRouting(config: AudioRoutingConfig, to ffmpegArgs: inout [String]) {
        let plan = AudioRoutingService.makePlan(config: config)
        removeArgumentPair("-map", value: "0:a?", from: &ffmpegArgs)
        if ffmpegArgs.indices.contains(where: { ffmpegArgs[$0] == "-map" && ffmpegArgs.indices.contains($0 + 1) && ffmpegArgs[$0 + 1] == "0" }) {
            ffmpegArgs += ["-map", "-0:a?"]
        }
        let routedArgs = plan.mappingArguments(passthroughByDefault: true) + plan.codecArguments(passthroughByDefault: true)
        ffmpegArgs += routedArgs
        logger.debug("Applied stream copy audio routing: \(routedArgs.joined(separator: " "))")
    }

    static func applyAudioRouting(
        config: AudioRoutingConfig,
        to ffmpegArgs: inout [String],
        addVideoMap: Bool = true,
        codecOverrides: Bool = false
    ) {
        // Check if there's already a video map - if not, we need to add one
        let hasVideoMap = ffmpegArgs.indices.contains { index in
            ffmpegArgs[index] == "-map"
                && ffmpegArgs.indices.contains(index + 1)
                && ffmpegArgs[index + 1].hasPrefix("0:v")
        }

        // Remove all existing audio mapping arguments from preset
        removeArgumentPair("-map", value: "0:a", from: &ffmpegArgs)
        removeArgumentPair("-map", value: "0:a?", from: &ffmpegArgs)

        // Also remove indexed audio maps if present (0:a:0, 0:a:1, etc.)
        var index = 0
        while index < ffmpegArgs.count {
            if ffmpegArgs[index] == "-map",
               index + 1 < ffmpegArgs.count,
               (ffmpegArgs[index + 1].hasPrefix("0:a:") || ffmpegArgs[index + 1] == "0:a" || ffmpegArgs[index + 1] == "0:a?") {
                ffmpegArgs.remove(at: index)
                ffmpegArgs.remove(at: index)
                continue
            }
            index += 1
        }

        // Ensure video is mapped if not already present
        if addVideoMap && !hasVideoMap {
            // Insert -map 0:v:0 at the beginning (first video stream only to avoid cover art issues)
            ffmpegArgs.insert(contentsOf: ["-map", "0:v:0"], at: 0)
            logger.debug("Added video mapping for audio routing")
        }

        // Generate custom audio arguments (either simple -map or filter_complex)
        let plan = AudioRoutingService.makePlan(config: config)
        let customAudioArgs = plan.ffmpegArguments

        // Check if we're using filter_complex (channel operations)
        if customAudioArgs.contains("-filter_complex") {
            // Remove any existing audio-only filter_complex
            var filterComplexIndex = 0
            while filterComplexIndex < ffmpegArgs.count {
                if ffmpegArgs[filterComplexIndex] == "-filter_complex" {
                    if filterComplexIndex + 1 < ffmpegArgs.count {
                        let filterContent = ffmpegArgs[filterComplexIndex + 1]
                        // Simple heuristic: if it contains audio operations, remove it
                        if filterContent.contains("[aout]") || filterContent.contains("amerge") ||
                           filterContent.contains("channelsplit") || filterContent.contains("pan=") {
                            ffmpegArgs.remove(at: filterComplexIndex)
                            if filterComplexIndex < ffmpegArgs.count {
                                ffmpegArgs.remove(at: filterComplexIndex)
                            }
                            continue
                        }
                    }
                }
                filterComplexIndex += 1
            }

            // Insert filter_complex at the beginning (after input arguments)
            ffmpegArgs.insert(contentsOf: customAudioArgs, at: 0)
            logger.debug("Applied audio routing with filter_complex: \(customAudioArgs.joined(separator: " "))")
        } else {
            // Simple -map arguments: insert after video map if present
            var insertionIndex = 0
            for (idx, arg) in ffmpegArgs.enumerated() {
                if arg == "-map", idx + 1 < ffmpegArgs.count, ffmpegArgs[idx + 1].hasPrefix("0:v") {
                    insertionIndex = idx + 2
                    break
                }
            }

            ffmpegArgs.insert(contentsOf: customAudioArgs, at: insertionIndex)
            logger.debug("Applied audio routing with simple maps: \(customAudioArgs.joined(separator: " "))")
        }

        // Per-stream codec overrides must follow the preset's -c:a / -b:a to take effect.
        if codecOverrides {
            ffmpegArgs.append(contentsOf: plan.codecArguments(passthroughByDefault: false))
        }
    }
    
    private static func synthesizedVideoCommandArguments(for request: SynthesizedVideoRequest) -> [String] {
        let finalWidth = evenDimension(max(request.width, 2))
        let finalHeight = evenDimension(max(request.height, 2))
        let resolution = "\(finalWidth)x\(finalHeight)"
        let frameRateValue = formattedFrameRateString(from: request.frameRate)
        let filterGraph = "color=c=\(request.backgroundFFmpegColor):s=\(resolution):r=\(frameRateValue),format=yuv420p[synth_v]"

        var arguments: [String] = ["-filter_complex", filterGraph, "-map", "[synth_v]"]

        if request.includeAudio {
            arguments.append(contentsOf: ["-map", "0:a?"])
        }

        arguments.append("-shortest")
        return arguments
    }

    /// Applies crop filter to video filter chain
    /// - If the chain contains a DAR-based desqueeze (e.g. scale='trunc(ih*dar...)',setsar=1/1),
    ///   it is replaced with crop plus explicit square-pixel normalization when PAR is known.
    /// - Otherwise, crop is inserted after setsar and before any final scale when possible.
    @discardableResult
    static func applyCropToVideoFilter(
        _ ffmpegArgs: inout [String],
        cropConfig: CropConfig,
        sourceWidth: Int,
        sourceHeight: Int,
        pixelAspectRatio: Double?
    ) -> Bool {
        // Don't apply crop to stream copy preset
        if let codecIndex = ffmpegArgs.lastIndex(of: "-c:v"),
           codecIndex + 1 < ffmpegArgs.count, ffmpegArgs[codecIndex + 1] == "copy" {
            logger.debug("Skipping crop for stream copy preset")
            return true
        }

        guard cropConfig.isActive else {
            logger.debug("Skipping inactive crop config")
            return true
        }

        guard !PrimaryVideoFilterPlan(arguments: ffmpegArgs).hasAmbiguousNumericTarget else { return false }

        // Resolve before mutating arguments: invalid crops must not leave an empty -vf.
        guard let geometry = CropGeometryPlan(
            config: cropConfig, sourceWidth: sourceWidth, sourceHeight: sourceHeight
        ) else { return false }
        var cropFilter = geometry.filter
        let hasKnownPixelAspectRatio = pixelAspectRatio.map { $0.isFinite && $0 > 0 } ?? false
        let needsAnamorphicNormalization = pixelAspectRatio.map { abs($0 - 1.0) > 0.01 } ?? false
        if let par = pixelAspectRatio, hasKnownPixelAspectRatio, needsAnamorphicNormalization {
            guard let dimensions = CropGeometryPlan.squarePixelDimensions(
                width: geometry.rect.width, height: geometry.rect.height, pixelAspectRatio: par,
                roundWidthUp: true
            ) else { return false }
            cropFilter += ",scale=\(dimensions.width):\(dimensions.height),setsar=1/1"
        }
        let vfIndex = PrimaryVideoFilterPlan(arguments: ffmpegArgs).filterOptionIndex
        let filterChain = vfIndex.flatMap { $0 + 1 < ffmpegArgs.count ? ffmpegArgs[$0 + 1] : nil } ?? ""
        var plan = CropVideoFilterPlan(filterChain)
        plan.insertCrop(
            cropFilter,
            hasKnownPixelAspectRatio: hasKnownPixelAspectRatio,
            includesSquarePixelNormalization: needsAnamorphicNormalization && hasKnownPixelAspectRatio
        )
        if let vfIndex, vfIndex + 1 < ffmpegArgs.count {
            ffmpegArgs[vfIndex + 1] = plan.rendered
        } else if let vfIndex {
            ffmpegArgs.insert(plan.rendered, at: vfIndex + 1)
        } else {
            ffmpegArgs += ["-vf", plan.rendered]
        }
        logger.info("Applied crop to video filter chain: \(plan.rendered, privacy: .public)")
        return true
    }

    /// Splits a linear FFmpeg filter chain without treating quoted or escaped commas
    /// as stage boundaries. Incomplete expressions remain opaque to automatic edits.
    fileprivate static func splitVideoFilterStages(_ chain: String) -> [String]? {
        var segments: [String] = []
        var start = chain.startIndex
        var quoted = false
        var escaped = false
        for index in chain.indices {
            let character = chain[index]
            if escaped {
                escaped = false
            } else if character == "'" {
                quoted.toggle()
            } else if character == "\\" && !quoted {
                escaped = true
            } else if character == "," && !quoted {
                segments.append(String(chain[start..<index]))
                start = chain.index(after: index)
            }
        }
        guard !quoted && !escaped else { return nil }
        if !chain.isEmpty { segments.append(String(chain[start...])) }
        return segments
    }

    /// Orders crop relative to the app's geometry stages without interpreting custom filter values.
    /// Keep raw stage text: commas and stage-like strings inside quotes or escapes belong to the
    /// custom filter, and must never become insertion points or replacement boundaries.
    private struct CropVideoFilterPlan {
        private enum Stage {
            case displayNormalization(String)
            case squarePixelAspect(String)
            case outputScale(String)
            case custom(String)

            init(_ raw: String) {
                switch raw {
                case "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2'",
                     "scale=trunc(ih*dar/2)*2:trunc(ih/2)*2":
                    self = .displayNormalization(raw)
                case "setsar=1/1":
                    self = .squarePixelAspect(raw)
                default:
                    self = raw.hasPrefix("scale=w=") ? .outputScale(raw) : .custom(raw)
                }
            }

            var raw: String {
                switch self {
                case .displayNormalization(let raw), .squarePixelAspect(let raw),
                     .outputScale(let raw), .custom(let raw):
                    return raw
                }
            }
        }

        private var stages: [Stage]

        init(_ chain: String) {
            if let segments = FFMPEGCommandBuilder.splitVideoFilterStages(chain) {
                stages = segments.map(Stage.init)
            } else {
                stages = [.custom(chain)]
            }
        }

        mutating func insertCrop(
            _ crop: String,
            hasKnownPixelAspectRatio: Bool,
            includesSquarePixelNormalization: Bool
        ) {
            if let index = stages.firstIndex(where: {
                if case .displayNormalization = $0 { return true }
                return false
            }) {
                // Only replace the exact adjacent pair emitted by built-in presets. Searching
                // forward for SAR could otherwise delete intervening custom filters.
                if hasKnownPixelAspectRatio, index + 1 < stages.count,
                   case .squarePixelAspect = stages[index + 1] {
                    let replacement = includesSquarePixelNormalization ? crop : "\(crop),setsar=1/1"
                    stages.replaceSubrange(index...index + 1, with: [.custom(replacement)])
                } else {
                    stages.insert(.custom(crop), at: index)
                }
            } else if let index = stages.firstIndex(where: {
                if case .outputScale = $0 { return true }
                return false
            }) {
                stages.insert(.custom(crop), at: index)
            } else if let index = stages.firstIndex(where: {
                if case .squarePixelAspect = $0 { return true }
                return false
            }) {
                stages.insert(.custom(crop), at: index + 1)
            } else {
                stages.insert(.custom(crop), at: 0)
            }
        }

        var rendered: String { stages.map(\.raw).joined(separator: ",") }
    }

    // MARK: - Conformance Merge Encoding

    /// Maps a codec name to an FFmpeg encoder name. Accepts ffprobe names and the
    /// FourCC-style names SwiftMediaMetadata reports (e.g. `avc1` for XAVC MXF).
    static func ffmpegVideoEncoder(for codec: String) -> String? {
        switch codec.lowercased() {
        case "h264", "avc", "avc1", "avc3":
            return "libx264"
        case "hevc", "h265", "hvc1", "hev1":
            return "libx265"
        case "prores", "apch", "apcn", "apcs", "apco", "ap4h", "ap4x":
            return "prores_ks"
        case "av1", "av01":       return "libsvtav1"
        case "mpeg2video":        return "mpeg2video"
        case "vp9":               return "libvpx-vp9"
        case "dnxhd":             return "dnxhd"
        case "mjpeg":             return "mjpeg"
        default:                  return nil
        }
    }

    /// Maps an audio codec name (from ffprobe) to an FFmpeg encoder name.
    static func ffmpegAudioEncoder(for codec: String) -> String? {
        switch codec.lowercased() {
        case "aac":               return "aac"
        case "pcm_s16le":         return "pcm_s16le"
        case "pcm_s16be":         return "pcm_s16be"
        case "pcm_s24le":         return "pcm_s24le"
        case "pcm_s24be":         return "pcm_s24be"
        case "pcm_s32le":         return "pcm_s32le"
        case "pcm_s32be":         return "pcm_s32be"
        case "pcm_f32le":         return "pcm_f32le"
        case "mp3", "mp3float":   return "libmp3lame"
        case "flac":              return "flac"
        case "opus":              return "libopus"
        case "vorbis":            return "libvorbis"
        case "ac3":               return "ac3"
        case "eac3":              return "eac3"
        default:                  return nil
        }
    }

    /// Builds FFmpeg arguments to re-encode a clip to match a conformance target format.
    /// Used in the first pass of a two-pass conformance merge.
    static func buildConformanceArguments(
        inputURL: URL,
        outputURL: URL,
        target: ConversionManager.ConformanceTarget,
        trimStart: Double? = nil,
        trimEnd: Double? = nil
    ) -> [String] {
        var args: [String] = ["-y", "-nostdin", "-progress", "pipe:2", "-hide_banner"]

        // Trim start (fast seek before input)
        if let ss = trimStart, ss > 0 {
            args += ["-ss", String(format: "%.6f", ss)]
        }

        // Input
        args += ["-i", inputURL.path]

        // Trim duration
        if let end = trimEnd {
            let start = trimStart ?? 0
            let duration = end - start
            if duration > 0 {
                args += ["-t", String(format: "%.6f", duration)]
            }
        }

        // Video encoding
        if let encoder = ffmpegVideoEncoder(for: target.videoCodec) {
            args += ["-c:v", encoder]

            // Scale to exact target resolution with square pixels
            args += ["-vf", "scale=\(target.width):\(target.height),setsar=1/1"]

            // Frame rate
            if let fr = target.frameRate {
                args += ["-r", String(format: "%.3f", fr)]
            }

            // Pixel format
            if let pf = target.pixelFormat {
                args += ["-pix_fmt", pf]
            }

            // Encoder-specific quality settings
            switch encoder {
            case "libx264":
                args += ["-crf", "18", "-preset", "medium"]
                // The High profile is 8-bit 4:2:0 only; let libx264 pick High 10 /
                // 4:2:2 / 4:4:4 for other pixel formats (e.g. XAVC yuv422p10le).
                if target.pixelFormat.map({ ["yuv420p", "yuvj420p", "nv12"].contains($0) }) ?? true {
                    args += ["-profile:v", "high"]
                }
            case "libx265":
                args += ["-crf", "18", "-preset", "medium"]
            case "prores_ks":
                args += ["-profile:v", "3"] // ProRes HQ
            case "libsvtav1":
                args += ["-crf", "18", "-preset", "6"]
            default:
                break
            }

            // Interlaced output
            if target.isInterlaced {
                args += ["-flags", "+ilme+ildct"]
            }
        } else {
            // Unknown codec — try copy, will fail at concat if format truly differs
            args += ["-c:v", "copy"]
        }

        // Audio encoding
        if let audioCodec = target.audioCodec, let audioEncoder = ffmpegAudioEncoder(for: audioCodec) {
            args += ["-c:a", audioEncoder]
            if let sr = target.audioSampleRate {
                args += ["-ar", "\(sr)"]
            }
            if let ch = target.audioChannels {
                args += ["-ac", "\(ch)"]
            }
            // Bitrate for lossy codecs
            switch audioEncoder {
            case "aac":       args += ["-b:a", "320k"]
            case "libmp3lame": args += ["-b:a", "320k"]
            case "libopus":   args += ["-b:a", "256k"]
            default: break
            }
        } else if target.audioCodec == nil {
            // Reference has no audio — strip audio
            args += ["-an"]
        } else {
            // Unknown audio codec — try copy
            args += ["-c:a", "copy"]
        }

        // Stream mapping
        args += ["-map", "0:v:0", "-map", "0:a?"]

        // Metadata stripping (conformance temps don't need metadata)
        args += ["-map_metadata", "-1", "-map_chapters", "-1"]

        // Timestamp handling
        args += ["-avoid_negative_ts", "make_zero"]

        // Output
        args.append(outputURL.path)

        return args
    }

}

/// Untagged YUV video is read by players as BT.601 below HD and BT.709 from HD up
/// (mpv's `mp_csp_guess_colorspace`; QuickTime and browsers guess the same way).
/// Scaling across that line without a conversion makes the same pixel values decode
/// to different colours. When the source has no matrix tag and the output changes
/// class, this tags the input with the standard players assume for it and the output
/// as BT.709. FFmpeg's filter negotiation then converts SD → HD to BT.709; HD → SD
/// keeps its BT.709 pixels and gains the tag.
///
/// The output size is only predicted for the filters the app generates. Anything
/// else (custom filters, explicit colour options) leaves the command unchanged.
struct UntaggedColorPlan: Equatable, Sendable {
    let inputOptions: [String]
    let outputOptions: [String]

    static func appliesTo(_ preset: ExportPreset) -> Bool {
        switch preset {
        case .dcp, .imfJ2K, .imfProRes, .streamCopy, .imageSequence, .animatedStill, .audioOnly, .av2:
            return false
        default:
            return preset.outputsVideoTrack
        }
    }

    /// HDR or wide-gamut sources must not be retagged as BT.709 SDR.
    static func isSDR(transfer: String?, primaries: String?) -> Bool {
        let sdrTransfers: Set<String> = ["bt709", "smpte170m", "bt470bg", "bt470m", "gamma22", "gamma28", "bt601", "iec61966-2-1", "unknown", "unspecified"]
        if let transfer, !sdrTransfers.contains(transfer) { return false }
        if let primaries, ["bt2020", "smpte431", "smpte432"].contains(primaries) { return false }
        return true
    }

    /// The class players assume for untagged video of this pixel size.
    static func isHD(width: Int, height: Int) -> Bool {
        width >= 1280 || height > 576
    }

    init?(
        sourceColorSpace: String?,
        sourcePixelFormat: String?,
        sourceCodec: String? = nil,
        sourceTransfer: String? = nil,
        sourcePrimaries: String? = nil,
        sourceWidth: Int,
        sourceHeight: Int,
        sourceCodedWidth: Int? = nil,
        sourceCodedHeight: Int? = nil,
        sourcePixelAspectRatio: Double,
        arguments: [String]
    ) {
        guard sourceColorSpace == nil,
              Self.isSDR(transfer: sourceTransfer?.lowercased(), primaries: sourcePrimaries?.lowercased()),
              Self.isYUV(pixelFormat: sourcePixelFormat?.lowercased(), codec: sourceCodec?.lowercased()),
              sourceWidth > 0, sourceHeight > 0,
              !arguments.contains(where: Self.colorOptions.contains),
              !arguments.contains("-s"),
              !arguments.contains("-filter_complex"), !arguments.contains("-lavfi"),
              !arguments.contains("-filter_complex_script") else { return nil }

        // No primary video filter means the output keeps the source size.
        guard let filterIndex = PrimaryVideoFilterPlan(arguments: arguments).filterOptionIndex,
              filterIndex + 1 < arguments.count,
              let output = Self.predictedOutputSize(
                  filterChain: arguments[filterIndex + 1],
                  width: sourceWidth, height: sourceHeight, pixelAspectRatio: sourcePixelAspectRatio
              ) else { return nil }

        // Players classify the decoded picture, before rotation; the output has rotation baked in.
        let codedWidth = sourceCodedWidth ?? sourceWidth
        let codedHeight = sourceCodedHeight ?? sourceHeight
        let sourceIsHD = Self.isHD(width: codedWidth, height: codedHeight)
        guard sourceIsHD != Self.isHD(width: output.width, height: output.height) else { return nil }

        if sourceIsHD {
            inputOptions = ["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]
        } else {
            // 625-line sources use EBU primaries; everything else SD uses SMPTE C.
            let standard = codedHeight == 576 ? "bt470bg" : "smpte170m"
            inputOptions = ["-colorspace", standard, "-color_primaries", standard, "-color_trc", "bt709"]
        }
        // Primaries are not converted, so they keep following the frames' tag.
        outputOptions = ["-colorspace", "bt709", "-color_trc", "bt709"]
    }

    /// Inserts the hints before the source's `-i` and the tags at the end of the output options.
    func apply(to arguments: inout [String], inputPath: String) {
        guard let inputIndex = arguments.indices.first(where: {
            arguments[$0] == "-i" && $0 + 1 < arguments.count && arguments[$0 + 1] == inputPath
        }) else { return }
        arguments.append(contentsOf: outputOptions)
        arguments.insert(contentsOf: inputOptions, at: inputIndex)
    }

    private static let colorOptions: Set<String> = [
        "-colorspace", "-color_primaries", "-color_trc", "-color_range",
        "-colorspace:v", "-color_primaries:v", "-color_trc:v",
    ]

    /// Codecs that store RGB, for sources whose pixel format the metadata reader didn't report.
    private static let rgbCodecs: Set<String> = [
        "png", "qtrle", "rle ", "r210", "r10k", "gif", "bmp", "tiff", "dpx", "exr", "rgba", "raw ",
    ]

    private static func isYUV(pixelFormat: String?, codec: String?) -> Bool {
        guard let pixelFormat else { return codec.map { !rgbCodecs.contains($0) } ?? false }
        return pixelFormat.hasPrefix("yuv") || pixelFormat.hasPrefix("nv") || pixelFormat.hasPrefix("p0")
            || pixelFormat.hasPrefix("p2") || pixelFormat.hasPrefix("p4") || pixelFormat.hasPrefix("uyvy")
            || pixelFormat.hasPrefix("yuyv") || pixelFormat.hasPrefix("v210")
    }

    /// Filters that leave the frame size alone.
    private static let sizeNeutralFilters: Set<String> = [
        "fps", "format", "setfield", "fieldorder", "yadif", "bwdif", "setpts", "null",
        "interlace", "hqdn3d", "setdar",
    ]

    /// Output pixel size of a linear chain of app-generated filters, or nil when any
    /// stage is not understood.
    static func predictedOutputSize(
        filterChain: String, width: Int, height: Int, pixelAspectRatio: Double
    ) -> (width: Int, height: Int)? {
        guard let stages = FFMPEGCommandBuilder.splitVideoFilterStages(filterChain) else { return nil }
        var w = Double(width), h = Double(height)
        var sar = pixelAspectRatio > 0 && pixelAspectRatio.isFinite ? pixelAspectRatio : 1
        func even(_ value: Double) -> Double { (value / 2).rounded(.down) * 2 }

        for raw in stages {
            let stage = raw.trimmingCharacters(in: .whitespaces)
            let name = stage.split(separator: "=", maxSplits: 1).first.map(String.init) ?? stage
            let value = stage.contains("=") ? String(stage.drop(while: { $0 != "=" }).dropFirst()) : ""
            switch name {
            case _ where sizeNeutralFilters.contains(name):
                continue
            case "setsar":
                guard value == "1/1" || value == "1" else { return nil }
                sar = 1
            case "scale" where value == "'trunc(ih*dar/2)*2:trunc(ih/2)*2'" || value == "trunc(ih*dar/2)*2:trunc(ih/2)*2":
                let dar = w * sar / h
                w = even(h * dar)
                h = even(h)
            case "scale" where value.hasPrefix("w='if(lte(iw,ih),"):
                // Short-edge target: scale=w='if(lte(iw,ih),N,-2)':h='if(lte(iw,ih),-2,N)'
                let digits = value.dropFirst("w='if(lte(iw,ih),".count).prefix(while: \.isNumber)
                guard let edge = Double(digits), edge > 0 else { return nil }
                if w <= h {
                    (w, h) = (edge, even(h * edge / w))
                } else {
                    (w, h) = (even(w * edge / h), edge)
                }
            case "scale", "pad", "crop":
                let fields = value.split(separator: ":").map(String.init)
                guard fields.count >= 2, let targetW = Double(fields[0]), let targetH = Double(fields[1]),
                      targetW > 0, targetH > 0 else { return nil }
                if name == "scale", let mode = fields.dropFirst(2).first(where: { $0.hasPrefix("force_original_aspect_ratio=") }) {
                    let factor = mode.hasSuffix("=decrease") ? min(targetW / w, targetH / h)
                        : mode.hasSuffix("=increase") ? max(targetW / w, targetH / h) : nil
                    guard let factor else { return nil }
                    (w, h) = ((w * factor).rounded(), (h * factor).rounded())
                } else {
                    guard fields.dropFirst(2).allSatisfy({ name != "scale" || $0.hasPrefix("flags=") }) else { return nil }
                    (w, h) = (targetW, targetH)
                }
            default:
                return nil
            }
        }
        return (Int(w), Int(h))
    }
}
