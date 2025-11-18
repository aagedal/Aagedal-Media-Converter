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
import OSLog

struct FFMPEGCommand {
    let arguments: [String]
    let normalizedTrimStart: Double?
    let normalizedTrimEnd: Double?
    let effectiveDuration: Double?
}

struct WaveformVideoRequest {
    let width: Int
    let height: Int
    let backgroundHex: String
    let foregroundHex: String
    let normalizeAudio: Bool
    let style: WaveformStyle
    let frameRate: Double

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

enum FFMPEGCommandBuilder {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "WaveformCommand")
    static func buildCommand(
        inputURL: URL,
        outputFileURL: URL,
        preset: ExportPreset,
        comment: String,
        includeDateTag: Bool,
        trimStart: Double?,
        trimEnd: Double?,
        waveformRequest: WaveformVideoRequest? = nil,
        customInputArguments: [String]? = nil,
        additionalOutputArguments: [String]? = nil
    ) async -> FFMPEGCommand {
        var arguments = ["-y"]

        let normalizedTrimStart = normalizedTrimPoint(trimStart)
        let normalizedTrimEnd = normalizedTrimPoint(trimEnd)

        if let normalizedTrimStart {
            arguments.append(contentsOf: ["-ss", ffmpegTimeString(from: normalizedTrimStart)])
        }

        if let customInputArguments {
            arguments.append(contentsOf: customInputArguments)
        } else {
            arguments.append(contentsOf: ["-i", inputURL.path])
        }

        if let waveformRequest {
            logger.debug("Building waveform command with request: width=\(waveformRequest.width), height=\(waveformRequest.height), background=\(waveformRequest.backgroundHex, privacy: .public), foreground=\(waveformRequest.foregroundHex, privacy: .public), normalize=\(waveformRequest.normalizeAudio), style=\(waveformRequest.style.rawValue, privacy: .public)")
            if let durationArgument = trimDurationArgument(start: normalizedTrimStart, end: normalizedTrimEnd) {
                arguments.append(contentsOf: durationArgument)
            }

            arguments.append(contentsOf: waveformCommandArguments(for: waveformRequest))
            if let additionalOutputArguments {
                arguments.append(contentsOf: additionalOutputArguments)
            }
            logger.debug("Waveform ffmpeg arguments: \(arguments.joined(separator: " "), privacy: .public)")
            arguments.append(outputFileURL.path)

            let effectiveDuration = calculateEffectiveDuration(trimStart: normalizedTrimStart, trimEnd: normalizedTrimEnd)

            return FFMPEGCommand(
                arguments: arguments,
                normalizedTrimStart: normalizedTrimStart,
                normalizedTrimEnd: normalizedTrimEnd,
                effectiveDuration: effectiveDuration
            )
        }

        var ffmpegArgs = preset.ffmpegArguments
        await adjustArgumentsForInput(preset: preset, inputURL: inputURL, ffmpegArgs: &ffmpegArgs)
        await adjustDeinterlaceFilter(inputURL: inputURL, ffmpegArgs: &ffmpegArgs)

        applyCommentMetadata(
            to: &ffmpegArgs,
            comment: comment,
            includeDateTag: includeDateTag
        )

        if let durationArgument = trimDurationArgument(start: normalizedTrimStart, end: normalizedTrimEnd) {
            arguments.append(contentsOf: durationArgument)
        }

        arguments.append(contentsOf: ffmpegArgs)
        if let additionalOutputArguments {
            arguments.append(contentsOf: additionalOutputArguments)
        }
        arguments.append(outputFileURL.path)

        let effectiveDuration = calculateEffectiveDuration(trimStart: normalizedTrimStart, trimEnd: normalizedTrimEnd)

        return FFMPEGCommand(
            arguments: arguments,
            normalizedTrimStart: normalizedTrimStart,
            normalizedTrimEnd: normalizedTrimEnd,
            effectiveDuration: effectiveDuration
        )
    }
}

extension FFMPEGCommandBuilder {
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

    static func waveformFilterGraph(for request: WaveformVideoRequest, includeAudioSplit: Bool) -> (filterComplex: String, videoMap: String, audioMap: String?) {
        let finalWidth = evenDimension(max(request.width, 2))
        let finalHeight = evenDimension(max(request.height, 2))
        let resolution = "\(finalWidth)x\(finalHeight)"
        let background = request.backgroundFFmpegColor
        let foreground = request.foregroundFFmpegColor
        let frameRateValue = max(1, Int(round(request.frameRate)))

        let channelLayout = request.style == .circle ? "mono" : "stereo"
        var audioFilters = ["aformat=channel_layouts=\(channelLayout)"]
        if request.normalizeAudio {
            audioFilters.append("dynaudnorm=f=250:g=30:p=0.9")
        }

        if request.style == .compressed {
            audioFilters.append("compand")
        }

        let audioProcessing = audioFilters.joined(separator: ",")
        let waveInputLabel = includeAudioSplit ? "wavesrc" : "audproc"

        var segments: [String] = []
        var audioSegment = "[0:a]\(audioProcessing)"
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
        case .compressed:
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

    static func waveformCommandArguments(for request: WaveformVideoRequest) -> [String] {
        let components = waveformFilterGraph(for: request, includeAudioSplit: true)

        var arguments: [String] = [
            "-filter_complex", components.filterComplex,
            "-map", components.videoMap
        ]

        if let audioMap = components.audioMap {
            arguments.append(contentsOf: ["-map", audioMap])
        }

        if request.frameRate.isFinite, request.frameRate > 0 {
            let sanitizedFrameRate = formattedFrameRateString(from: request.frameRate)
            arguments.append(contentsOf: ["-r", sanitizedFrameRate])
        }

        arguments.append("-shortest")

        return arguments
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

    static func applyCommentMetadata(to ffmpegArgs: inout [String], comment: String, includeDateTag: Bool) {
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

        if let metadataValueIndex = ffmpegArgs.firstIndex(where: { $0.contains("comment=Date generated:") }) {
            if let commentMetadataValue {
                ffmpegArgs[metadataValueIndex] = commentMetadataValue
            } else {
                let metadataKeyIndex = metadataValueIndex - 1
                ffmpegArgs.remove(at: metadataValueIndex)
                if metadataKeyIndex >= 0,
                   metadataKeyIndex < ffmpegArgs.count,
                   ffmpegArgs[metadataKeyIndex] == "-metadata" {
                    ffmpegArgs.remove(at: metadataKeyIndex)
                }
            }
        } else if let commentMetadataValue {
            var hasCommentMetadata = false
            var metadataScanIndex = 0
            while metadataScanIndex < ffmpegArgs.count - 1 {
                if ffmpegArgs[metadataScanIndex] == "-metadata",
                   ffmpegArgs[metadataScanIndex + 1].hasPrefix("comment=") {
                    hasCommentMetadata = true
                    break
                }
                metadataScanIndex += 1
            }
            if !hasCommentMetadata {
                ffmpegArgs.append(contentsOf: ["-metadata", commentMetadataValue])
            }
        }
    }

    static func adjustArgumentsForInput(
        preset: ExportPreset,
        inputURL: URL,
        ffmpegArgs: inout [String]
    ) async {
        guard preset == .audioUncompressedWAV else { return }
        guard let audioStreams = await FFMPEGProbeService.fetchAudioStreams(for: inputURL),
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

    static func adjustDeinterlaceFilter(
        inputURL: URL,
        ffmpegArgs: inout [String]
    ) async {
        // Only proceed if a video filter graph exists
        guard let vfIndex = ffmpegArgs.firstIndex(of: "-vf"), vfIndex + 1 < ffmpegArgs.count else {
            return
        }

        let isInterlaced: Bool
        if let metadata = try? await VideoMetadataService.shared.metadata(for: inputURL) {
            isInterlaced = metadata.videoStream?.isInterlaced ?? false
        } else {
            isInterlaced = false
        }

        var filters = ffmpegArgs[vfIndex + 1]

        if isInterlaced {
            let bwdifFilter = "bwdif=mode=send_field:parity=auto:deint=all"
            // Replace yadif with bwdif, or insert bwdif at the start if yadif is absent
            if filters.contains("yadif") {
                // Replace common forms of yadif invocation
                filters = filters.replacingOccurrences(of: "yadif=0", with: bwdifFilter)
                filters = filters.replacingOccurrences(of: "yadif", with: bwdifFilter)
            } else {
                // Prepend bwdif to existing chain
                if filters.isEmpty {
                    filters = bwdifFilter
                } else {
                    filters = bwdifFilter + "," + filters
                }
            }
        } else {
            // Progressive source: remove any yadif occurrences entirely
            let patterns = [
                "yadif=0,",
                ",yadif=0",
                "yadif=0",
                "yadif,",
                ",yadif",
                "yadif"
            ]
            for p in patterns {
                filters = filters.replacingOccurrences(of: p, with: "")
            }
            // Clean up any accidental leading/trailing commas and whitespace
            filters = filters.trimmingCharacters(in: .whitespacesAndNewlines)
            while filters.hasPrefix(",") { filters.removeFirst() }
            while filters.hasSuffix(",") { filters.removeLast() }
        }

        ffmpegArgs[vfIndex + 1] = filters
    }
}
