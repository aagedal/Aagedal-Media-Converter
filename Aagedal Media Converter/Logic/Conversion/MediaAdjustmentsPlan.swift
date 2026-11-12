// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

/// Turns `MediaAdjustments` into FFmpeg filters and rewrites a built command's
/// output options to carry them. Pure functions; `FFMPEGCommandBuilder` decides
/// when they apply.
enum MediaAdjustmentsPlan {
    /// Picture subtitle codecs libass cannot render. These need OCR to SRT first.
    static let bitmapSubtitleCodecs: Set<String> = [
        "hdmv_pgs_subtitle", "pgs", "pgssub", "dvd_subtitle", "dvdsub", "vobsub",
        "dvb_subtitle", "dvbsub", "xsub", "dvb_teletext",
    ]

    /// Subtitle formats that carry their own styling, which must not be overridden.
    private static let styledSubtitleFormats: Set<String> = ["ass", "ssa"]

    static let supportedSubtitleFileExtensions = ["srt", "ass", "ssa", "vtt"]

    // MARK: - Video

    /// Filters in the order they must run: rotation and flips on the cropped
    /// picture, subtitles drawn upright on the source timeline, then speed and
    /// fades on the output timeline.
    static func videoFilterStages(
        for adjustments: MediaAdjustments,
        inputURL: URL,
        trimStart: Double?,
        outputDuration: Double?,
        sourceSubtitleCodecs: [String?]
    ) -> Result<[String], AdjustmentError> {
        var stages: [String] = []
        switch adjustments.rotation {
        case .none: break
        case .clockwise90: stages.append("transpose=clock")
        case .counterClockwise90: stages.append("transpose=cclock")
        case .rotate180: stages += ["hflip", "vflip"]
        }
        if adjustments.flipHorizontal { stages.append("hflip") }
        if adjustments.flipVertical { stages.append("vflip") }

        if let subtitles = adjustments.burnInSubtitles {
            switch subtitleFilter(for: subtitles, inputURL: inputURL, sourceSubtitleCodecs: sourceSubtitleCodecs) {
            case .failure(let error): return .failure(error)
            case .success(let filter):
                // An input seek restarts frame timestamps at zero, while cues keep
                // source times. Shift into source time for the subtitles only.
                if let trimStart, trimStart > 0 {
                    let offset = number(trimStart)
                    stages += ["setpts=PTS+\(offset)/TB", filter, "setpts=PTS-STARTPTS"]
                } else {
                    stages.append(filter)
                }
            }
        }

        if adjustments.changesSpeed {
            stages.append("setpts=(PTS-STARTPTS)/\(number(adjustments.speed))")
        }
        if adjustments.videoFadeIn > 0 {
            stages.append("fade=t=in:st=0:d=\(number(adjustments.videoFadeIn))")
        }
        if adjustments.videoFadeOut > 0 {
            guard let outputDuration, outputDuration > 0 else { return .failure(.unknownDuration) }
            let fade = min(adjustments.videoFadeOut, outputDuration)
            stages.append("fade=t=out:st=\(number(max(0, outputDuration - fade))):d=\(number(fade))")
        }
        return .success(stages)
    }

    static func subtitleFilter(
        for subtitles: MediaAdjustments.BurnInSubtitles,
        inputURL: URL,
        sourceSubtitleCodecs: [String?]
    ) -> Result<String, AdjustmentError> {
        let path: String
        var streamIndex: Int?
        let keepsOwnStyle: Bool
        switch subtitles.source {
        case .embedded(let index):
            guard sourceSubtitleCodecs.indices.contains(index) else { return .failure(.missingSubtitleStream) }
            let codec = sourceSubtitleCodecs[index]?.lowercased() ?? ""
            guard !bitmapSubtitleCodecs.contains(codec) else { return .failure(.bitmapSubtitles) }
            path = inputURL.path
            streamIndex = index
            keepsOwnStyle = styledSubtitleFormats.contains(codec)
        case .file(let filePath):
            guard FileManager.default.isReadableFile(atPath: filePath) else { return .failure(.missingSubtitleFile) }
            path = filePath
            keepsOwnStyle = styledSubtitleFormats.contains(URL(fileURLWithPath: filePath).pathExtension.lowercased())
        }
        var options = ["filename=\(escapeFilterOptionValue(path))"]
        if let streamIndex { options.append("si=\(streamIndex)") }
        if !keepsOwnStyle { options.append("force_style=\(escapeFilterOptionValue(subtitles.forceStyle))") }
        return .success("subtitles=" + options.joined(separator: ":"))
    }

    /// Inserts the stages into the primary video filter chain. Returns false when the
    /// preset's filter options cannot be resolved unambiguously.
    static func insertVideoStages(_ stages: [String], into ffmpegArgs: inout [String]) -> Bool {
        guard !stages.isEmpty else { return true }
        let filterPlan = PrimaryVideoFilterPlan(arguments: ffmpegArgs)
        guard !filterPlan.hasAmbiguousNumericTarget else { return false }
        guard let index = filterPlan.filterOptionIndex, index + 1 < ffmpegArgs.count,
              !ffmpegArgs[index + 1].isEmpty else {
            if let index = filterPlan.filterOptionIndex, index + 1 >= ffmpegArgs.count {
                ffmpegArgs.append(stages.joined(separator: ","))
            } else if let index = filterPlan.filterOptionIndex {
                ffmpegArgs[index + 1] = stages.joined(separator: ",")
            } else {
                ffmpegArgs += ["-vf", stages.joined(separator: ",")]
            }
            return true
        }
        ffmpegArgs[index + 1] = insert(stages, intoChain: ffmpegArgs[index + 1])
        return true
    }

    /// Places the stages after crop (and its square-pixel normalization) and after
    /// deinterlacing, but ahead of the preset's scaling and interlacing, so a rotated
    /// picture is still fitted to the preset's frame size.
    static func insert(_ stages: [String], intoChain chain: String) -> String {
        guard !chain.contains(";"), !chain.contains("["),
              let segments = FFMPEGCommandBuilder.splitVideoFilterStages(chain) else {
            // A labelled graph or unparsable chain: run first, on the decoded picture.
            return (stages + [chain]).joined(separator: ",")
        }
        func name(_ stage: String) -> String {
            String(stage.prefix { $0 != "=" }).trimmingCharacters(in: .whitespaces)
        }
        var insertion = 0
        for (index, stage) in segments.enumerated() where ["yadif", "bwdif"].contains(name(stage)) {
            insertion = max(insertion, index + 1)
        }
        if let cropIndex = segments.lastIndex(where: { name($0) == "crop" }) {
            var end = cropIndex + 1
            if end + 1 < segments.count, name(segments[end]) == "scale", segments[end + 1] == "setsar=1/1" {
                end += 2
            } else if end < segments.count, segments[end] == "setsar=1/1" {
                end += 1
            }
            insertion = max(insertion, end)
        }
        var result = segments
        result.insert(contentsOf: stages, at: insertion)
        return result.joined(separator: ",")
    }

    // MARK: - Audio

    struct AudioChainContext: Equatable, Sendable {
        var outputDuration: Double?
        var sampleRate: Int
        /// Pads and trims to the output duration, for offset or replaced audio.
        var fitsToDuration: Bool
    }

    /// One audio track's filter chain, or nil when it needs none. Without a
    /// measurement the loudnorm stage prints the first-pass statistics.
    static func audioFilterChain(
        for adjustments: MediaAdjustments,
        loudness: LoudnessNormalizationSettings?,
        measurement: LoudnormMeasurement?,
        context: AudioChainContext
    ) -> Result<String?, AdjustmentError> {
        var filters: [String] = []
        if adjustments.audioOffset > 0.0001 {
            let milliseconds = Int((adjustments.audioOffset * 1000).rounded())
            filters.append("adelay=delays=\(milliseconds):all=1")
        } else if adjustments.audioOffset < -0.0001 {
            filters += ["atrim=start=\(number(-adjustments.audioOffset))", "asetpts=PTS-STARTPTS"]
        }
        if adjustments.changesSpeed {
            filters += atempoStages(for: adjustments.speed)
        }
        if context.fitsToDuration {
            guard let duration = context.outputDuration, duration > 0 else { return .failure(.unknownDuration) }
            filters += ["apad", "atrim=duration=\(number(duration))"]
        }
        if adjustments.changesVolume, let gain = adjustments.audioGain {
            // Before loudnorm, which would re-target the level anyway, and before the fades.
            filters.append("volume=\(number(gain))dB")
        }
        if let loudness {
            filters.append(loudnormFilter(settings: loudness, measurement: measurement))
            // loudnorm resamples to 192 kHz internally; return to the delivery rate.
            filters.append("aresample=\(context.sampleRate)")
        }
        if adjustments.audioFadeIn > 0 {
            filters.append("afade=t=in:st=0:d=\(number(adjustments.audioFadeIn))")
        }
        if adjustments.audioFadeOut > 0 {
            guard let duration = context.outputDuration, duration > 0 else { return .failure(.unknownDuration) }
            let fade = min(adjustments.audioFadeOut, duration)
            filters.append("afade=t=out:st=\(number(max(0, duration - fade))):d=\(number(fade))")
        }
        return .success(filters.isEmpty ? nil : filters.joined(separator: ","))
    }

    /// atempo is cleanest within 0.5–2, so larger changes chain several stages.
    static func atempoStages(for speed: Double) -> [String] {
        var remaining = speed
        var stages: [String] = []
        while remaining > 2.0001 {
            stages.append("atempo=2")
            remaining /= 2
        }
        while remaining < 0.4999 {
            stages.append("atempo=0.5")
            remaining /= 0.5
        }
        if abs(remaining - 1) > 0.0001 { stages.append("atempo=\(number(remaining))") }
        return stages
    }

    static func loudnormFilter(settings: LoudnessNormalizationSettings, measurement: LoudnormMeasurement?) -> String {
        var options = [
            "I=\(number(settings.integrated))",
            "TP=\(number(settings.truePeak))",
            "LRA=\(number(settings.clampedLoudnessRange))",
        ]
        if let measurement {
            options += [
                "measured_I=\(measurement.inputIntegrated)",
                "measured_TP=\(measurement.inputTruePeak)",
                "measured_LRA=\(measurement.inputLoudnessRange)",
                "measured_thresh=\(measurement.inputThreshold)",
                "offset=\(measurement.targetOffset)",
                "linear=true",
                "print_format=summary",
            ]
        } else {
            options.append("print_format=json")
        }
        return "loudnorm=" + options.joined(separator: ":")
    }

    /// Where the audio chains run.
    enum AudioChainPlacement: Equatable, Sendable {
        /// On every output track (the default; measures what is delivered).
        case outputs
        /// On each source track before routing, for presets that split tracks into
        /// mono channels, which must not be normalized one channel at a time.
        case sources
    }

    /// Points the audio at another input: every `0:a` map and graph pad moves to `inputIndex`.
    static func redirectSourceAudio(to inputIndex: Int, in ffmpegArgs: inout [String]) {
        for index in ffmpegArgs.indices where index > 0 {
            let option = ffmpegArgs[index - 1]
            let value = ffmpegArgs[index]
            if option == "-map", value.hasPrefix("0:a") {
                ffmpegArgs[index] = "\(inputIndex)" + value.dropFirst()
            } else if ["-filter_complex", "-lavfi"].contains(option) {
                ffmpegArgs[index] = value.replacingOccurrences(of: "[0:a", with: "[\(inputIndex):a")
            }
        }
    }

    /// Rewrites audio maps so every audio output runs through its chain. Generic
    /// maps are expanded with `audioStreamCount`; filter graph outputs are extended.
    /// Returns the number of chains it placed, in graph order, or an error.
    static func applyAudioChains(
        to ffmpegArgs: inout [String],
        placement: AudioChainPlacement,
        defaultAudioInput: Int = 0,
        audioStreamCount: (Int) -> Int,
        chain: (Int) -> String
    ) -> Result<Int, AdjustmentError> {
        guard !ffmpegArgs.contains("-an") else { return .success(0) }
        if ffmpegArgs.indices.contains(where: { index in
            index + 1 < ffmpegArgs.count && ["-c:a", "-acodec", "-c", "-codec"].contains(ffmpegArgs[index])
                && ffmpegArgs[index + 1] == "copy"
        }) || ffmpegArgs.indices.contains(where: { index in
            index + 1 < ffmpegArgs.count && ffmpegArgs[index].hasPrefix("-c:a:") && ffmpegArgs[index + 1] == "copy"
        }) {
            return .failure(.copiedAudio)
        }

        // Presets without maps rely on automatic stream selection, which any filter graph disables.
        if !ffmpegArgs.contains("-map") {
            var maps: [String] = []
            if !ffmpegArgs.contains("-vn") { maps += ["-map", "0:v:0?"] }
            if audioStreamCount(defaultAudioInput) > 0 { maps += ["-map", "\(defaultAudioInput):a:0"] }
            ffmpegArgs.insert(contentsOf: maps, at: 0)
        }
        expandGenericAudioMaps(in: &ffmpegArgs, audioStreamCount: audioStreamCount)

        switch placement {
        case .outputs: return .success(applyOutputChains(to: &ffmpegArgs, chain: chain))
        case .sources: return .success(applySourceChains(to: &ffmpegArgs, chain: chain))
        }
    }

    private static func isSourceAudioReference(_ value: String) -> Bool {
        let trimmed = value.hasSuffix("?") ? String(value.dropLast()) : value
        let components = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        return components.count == 3 && Int(components[0]) != nil && components[1] == "a" && Int(components[2]) != nil
    }

    private static func expandGenericAudioMaps(in ffmpegArgs: inout [String], audioStreamCount: (Int) -> Int) {
        var index = 0
        while index + 1 < ffmpegArgs.count {
            guard ffmpegArgs[index] == "-map" else { index += 1; continue }
            let value = ffmpegArgs[index + 1]
            let trimmed = value.hasSuffix("?") ? String(value.dropLast()) : value
            let components = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            if components.count == 2, let input = Int(components[0]), components[1] == "a" {
                let expanded = (0..<audioStreamCount(input)).flatMap { ["-map", "\(input):a:\($0)"] }
                ffmpegArgs.replaceSubrange(index...index + 1, with: expanded)
                index += expanded.count
                continue
            }
            if trimmed.hasSuffix("?"), isSourceAudioReference(value) {
                // Optional indexed maps must exist to feed a graph; drop those that do not.
                let parts = trimmed.split(separator: ":")
                if let input = Int(parts[0]), let stream = Int(parts[2]), stream >= audioStreamCount(input) {
                    ffmpegArgs.removeSubrange(index...index + 1)
                    continue
                }
                ffmpegArgs[index + 1] = trimmed
            }
            index += 2
        }
    }

    private static func graphIndex(in ffmpegArgs: [String]) -> Int? {
        ffmpegArgs.indices.last { $0 + 1 < ffmpegArgs.count && ffmpegArgs[$0] == "-filter_complex" }
    }

    private static func appendGraph(_ segments: [String], to ffmpegArgs: inout [String]) {
        guard !segments.isEmpty else { return }
        if let index = graphIndex(in: ffmpegArgs) {
            ffmpegArgs[index + 1] += ";" + segments.joined(separator: ";")
        } else {
            ffmpegArgs.insert(contentsOf: ["-filter_complex", segments.joined(separator: ";")], at: 0)
        }
    }

    private static func applyOutputChains(to ffmpegArgs: inout [String], chain: (Int) -> String) -> Int {
        var segments: [String] = []
        var outputIndex = 0
        var index = 0
        while index + 1 < ffmpegArgs.count {
            defer { index += 1 }
            guard ffmpegArgs[index] == "-map" else { continue }
            let value = ffmpegArgs[index + 1]
            let source: String
            if value.hasPrefix("["), value.hasSuffix("]") {
                // In the ordinary conversion path video is filtered with -vf, so every
                // mapped graph output is audio.
                source = value
            } else if isSourceAudioReference(value) {
                source = "[\(value)]"
            } else {
                continue
            }
            let label = "afx\(outputIndex)"
            segments.append("\(source)\(chain(outputIndex))[\(label)]")
            ffmpegArgs[index + 1] = "[\(label)]"
            outputIndex += 1
        }
        appendGraph(segments, to: &ffmpegArgs)
        return outputIndex
    }

    private static func applySourceChains(to ffmpegArgs: inout [String], chain: (Int) -> String) -> Int {
        // Collect each source audio pad's uses, in a stable order.
        let pattern = /\[(\d+):a:(\d+)\]/
        var uses: [String: Int] = [:]
        var order: [String] = []
        func note(_ reference: String) {
            if uses[reference] == nil { order.append(reference) }
            uses[reference, default: 0] += 1
        }
        let graph = graphIndex(in: ffmpegArgs)
        if let graph {
            for match in ffmpegArgs[graph + 1].matches(of: pattern) {
                note("\(match.output.1):a:\(match.output.2)")
            }
        }
        for index in ffmpegArgs.indices where index > 0 && ffmpegArgs[index - 1] == "-map" {
            if isSourceAudioReference(ffmpegArgs[index]) { note(ffmpegArgs[index]) }
        }
        guard !order.isEmpty else { return 0 }

        var segments: [String] = []
        var labels: [String: [String]] = [:]
        for (position, reference) in order.enumerated() {
            let count = uses[reference] ?? 1
            let names = (0..<count).map { "asrc\(position)_\($0)" }
            labels[reference] = names
            let split = count > 1 ? ",asplit=\(count)" : ""
            segments.append("[\(reference)]\(chain(position))\(split)" + names.map { "[\($0)]" }.joined())
        }
        var nextUse: [String: Int] = [:]
        func take(_ reference: String) -> String {
            let use = nextUse[reference, default: 0]
            nextUse[reference] = use + 1
            return labels[reference]?[use] ?? reference
        }
        if let graph {
            var rewritten = ""
            var remainder = Substring(ffmpegArgs[graph + 1])
            while let match = remainder.firstMatch(of: pattern) {
                rewritten += remainder[remainder.startIndex..<match.range.lowerBound]
                rewritten += "[\(take("\(match.output.1):a:\(match.output.2)"))]"
                remainder = remainder[match.range.upperBound...]
            }
            rewritten += remainder
            ffmpegArgs[graph + 1] = segments.joined(separator: ";") + ";" + rewritten
        }
        for index in ffmpegArgs.indices where index > 0 && ffmpegArgs[index - 1] == "-map" {
            if isSourceAudioReference(ffmpegArgs[index]) {
                ffmpegArgs[index] = "[\(take(ffmpegArgs[index]))]"
            }
        }
        if graph == nil { appendGraph(segments, to: &ffmpegArgs) }
        return order.count
    }

    // MARK: - Loudness measurement

    /// A decode-only pass over the same inputs, trim and audio graph that prints
    /// each loudnorm instance's statistics. Video and other streams are dropped.
    static func loudnessMeasurementArguments(from arguments: [String], outputArgumentsStart: Int) -> [String]? {
        guard outputArgumentsStart <= arguments.count else { return nil }
        let output = Array(arguments[outputArgumentsStart...])
        guard let graph = graphIndex(in: output) else { return nil }
        var result = Array(arguments[..<outputArgumentsStart])
        if let durationIndex = output.firstIndex(of: "-t"), durationIndex + 1 < output.count {
            result += ["-t", output[durationIndex + 1]]
        }
        result += ["-filter_complex", output[graph + 1]]
        for index in output.indices where index > 0 && output[index - 1] == "-map" {
            let value = output[index]
            if (value.hasPrefix("[") && value.hasSuffix("]")) || isSourceAudioReference(value) {
                result += ["-map", value]
            }
        }
        result += ["-vn", "-sn", "-dn", "-f", "null", "-"]
        return result
    }

    /// Reads loudnorm's JSON blocks, ordered by their position in the filter graph
    /// (FFmpeg names instances `Parsed_loudnorm_<index>`; they finish in any order).
    static func parseLoudnormMeasurements(from log: String) -> [LoudnormMeasurement] {
        let header = /\[Parsed_loudnorm_(\d+) @ [^\]]*\]\s*\{/
        var found: [(Int, LoudnormMeasurement)] = []
        var remainder = Substring(log)
        while let match = remainder.firstMatch(of: header) {
            let afterBrace = remainder[match.range.upperBound...]
            guard let close = afterBrace.firstIndex(of: "}"), let position = Int(match.output.1) else { break }
            let body = "{" + afterBrace[..<close] + "}"
            remainder = afterBrace[afterBrace.index(after: close)...]
            guard let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let integrated = object["input_i"] as? String,
                  let truePeak = object["input_tp"] as? String,
                  let range = object["input_lra"] as? String,
                  let threshold = object["input_thresh"] as? String,
                  let offset = object["target_offset"] as? String else { continue }
            found.append((position, LoudnormMeasurement(
                inputIntegrated: integrated, inputTruePeak: truePeak, inputLoudnessRange: range,
                inputThreshold: threshold, targetOffset: offset
            )))
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Silence measures -inf, which loudnorm cannot take as a measured value.
    static func measurementIsUsable(_ measurement: LoudnormMeasurement) -> Bool {
        [measurement.inputIntegrated, measurement.inputTruePeak, measurement.inputLoudnessRange,
         measurement.inputThreshold, measurement.targetOffset].allSatisfy { Double($0)?.isFinite == true }
    }

    // MARK: - Helpers

    static func number(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    /// FFmpeg parses filter arguments twice: as an option list, then as a filtergraph.
    static func escapeFilterOptionValue(_ value: String) -> String {
        func escape(_ input: String, specials: Set<Character>) -> String {
            var result = ""
            for character in input {
                if character == "\\" || character == "'" || specials.contains(character) {
                    result.append("\\")
                }
                result.append(character)
            }
            return result
        }
        return escape(escape(value, specials: [":"]), specials: ["[", "]", ",", ";"])
    }

    enum AdjustmentError: Error, Equatable, Sendable {
        case unsupportedOutput(String)
        case unknownDuration
        case copiedAudio
        case bitmapSubtitles
        case missingSubtitleStream
        case missingSubtitleFile
        case missingReplacementAudio
        case replacementAudioWithoutTracks
        case ambiguousVideoFilters
        case measurementFailed

        var message: String {
            switch self {
            case .unsupportedOutput(let reason):
                return reason
            case .unknownDuration:
                return String(localized: "Cannot determine the duration needed for the fade, offset or replacement audio. Set an end trim and try again.")
            case .copiedAudio:
                return String(localized: "Audio adjustments and loudness normalization need re-encoded audio. Change tracks set to Copy in Audio Routing and try again.")
            case .bitmapSubtitles:
                return String(localized: "Picture-based subtitles (PGS, DVD or DVB) cannot be burned in directly. Convert them to SRT with subtitle OCR first, then burn in the SRT file.")
            case .missingSubtitleStream:
                return String(localized: "The selected subtitle track no longer exists in the source.")
            case .missingSubtitleFile:
                return String(localized: "The subtitle file to burn in cannot be read.")
            case .missingReplacementAudio:
                return String(localized: "The replacement audio file cannot be read.")
            case .replacementAudioWithoutTracks:
                return String(localized: "The replacement audio file has no audio tracks.")
            case .ambiguousVideoFilters:
                return String(localized: "Cannot safely apply video adjustments to numeric filters with this stream mapping. Use -filter:v:0 for video and typed audio filter options, or map individual required streams explicitly.")
            case .measurementFailed:
                return String(localized: "Loudness measurement failed, so the audio could not be normalized.")
            }
        }
    }
}
