// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Runs QTGMC as a decode → Metal → encode pipeline:
//
//   ffmpeg (decoder) --Y4M--> QTGMCFrameTransform (Metal) --Y4M--> ffmpeg (encoder)
//
// The encoder reads the deinterlaced video from the pipe (input 0) and everything
// else (audio, subtitles, data, metadata) from the original file (input 1).

import Foundation
import Metal
import OSLog

/// Arguments and settings for one QTGMC export.
struct QTGMCPipelinePlan: Equatable, Sendable {
    /// Exactly the stage `FFMPEGCommandBuilder.adjustDeinterlaceFilter` inserts.
    static let builtInDeinterlaceStage = "bwdif=mode=send_field:parity=auto:deint=all"
    static let pipeInput = ["-f", "yuv4mpegpipe", "-i", "pipe:0"]
    /// Frames decoded before the trim start so the first output field has temporal context.
    static let maxPrerollFrames = 3

    let decoderArguments: [String]
    /// Custom input arguments for the encoder command (pipe first, then the source).
    let encoderInputArguments: [String]
    let decoderPixelFormat: String
    let topFieldFirst: Bool
    let doubleRate: Bool
    let parameters: QTGMCParameters
    /// Output frames produced from the pre-roll, dropped before the encoder sees them.
    let droppedOutputFrames: Int

    /// Returns nil when the source cannot use the QTGMC pipeline (bwdif is used instead).
    init?(
        inputURL: URL,
        stream: VideoMetadata.VideoStream?,
        trimStart: Double?,
        trimEnd: Double?,
        settings: DeinterlacerSettings
    ) {
        guard settings.usesQTGMC,
              let stream, stream.isInterlaced == true, !stream.hasAlpha,
              let width = stream.width, let height = stream.height, width >= 16, height >= 16,
              let frameRate = stream.frameRate?.value, frameRate.isFinite, frameRate > 0 else { return nil }

        // The source input seeks to the millisecond-rounded trim start (as the command
        // builder writes it); the decoder starts exactly `prerollFrames` frames earlier.
        let start = trimStart.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            .flatMap { Double(FFMPEGCommandBuilder.ffmpegTimeString(from: $0)) }
            .flatMap { $0 > 0 ? $0 : nil }
        let prerollFrames = start.map { min(Self.maxPrerollFrames, Int(($0 * frameRate + 1e-6).rounded(.down))) } ?? 0
        let decoderSeek = (start ?? 0) - Double(prerollFrames) / frameRate
        let pixelFormat = Self.decoderPixelFormat(chromaSubsampling: stream.chromaSubsampling, bitDepth: stream.bitDepth)

        var decoder = ["-hide_banner", "-nostdin", "-loglevel", "error"]
        if decoderSeek > 0.000_000_5 {
            decoder += ["-ss", String(format: "%.6f", decoderSeek)]
        }
        decoder += ["-i", inputURL.path]
        if let end = trimEnd, end.isFinite, end > (start ?? 0) {
            // Decode a few frames past the end so the last fields have look-ahead.
            let duration = end - (start ?? 0) + Double(prerollFrames + Self.maxPrerollFrames + 1) / frameRate
            decoder += ["-t", FFMPEGCommandBuilder.ffmpegTimeString(from: duration)]
        }
        decoder += ["-map", "0:v:0", "-an", "-sn", "-dn",
                    "-pix_fmt", pixelFormat, "-strict", "-1", "-f", "yuv4mpegpipe", "pipe:1"]

        var encoderInput: [String] = []
        for (option, value) in [("-color_primaries", stream.colorPrimaries),
                                ("-color_trc", stream.colorTransfer),
                                ("-colorspace", stream.colorSpace)] {
            if let value, Self.isSafeOptionValue(value) {
                encoderInput += [option, value]
            }
        }
        encoderInput += Self.pipeInput
        if let start {
            encoderInput += ["-ss", FFMPEGCommandBuilder.ffmpegTimeString(from: start)]
        }
        encoderInput += ["-i", inputURL.path]

        decoderArguments = decoder
        encoderInputArguments = encoderInput
        decoderPixelFormat = pixelFormat
        topFieldFirst = stream.fieldOrder != "bb"
        doubleRate = settings.doubleRate
        parameters = settings.qtgmcParameters
        droppedOutputFrames = prerollFrames * (settings.doubleRate ? 2 : 1)
    }

    /// The bundled NNEDI3 weights, when this Mac can run the Metal pipeline.
    static func availableWeightsURL(bundle: Bundle = .main) -> URL? {
        guard MTLCreateSystemDefaultDevice() != nil else { return nil }
        return QTGMCNNEDIWeights.bundledURL(in: bundle)
    }

    /// Planar YUV at the source's chroma layout and depth, which Y4M can carry.
    static func decoderPixelFormat(chromaSubsampling: String?, bitDepth: Int?) -> String {
        let depth = bitDepth ?? 8
        let suffix: String
        switch depth {
        case ...8: suffix = ""
        case 9...10: suffix = "10le"
        case 11...12: suffix = "12le"
        default: suffix = "16le"
        }
        switch chromaSubsampling {
        case "4:2:0": return "yuv420p" + suffix
        case "4:4:4": return "yuv444p" + suffix
        case "4:1:1" where suffix.isEmpty: return "yuv411p"
        default: return "yuv422p" + suffix
        }
    }

    private static func isSafeOptionValue(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Adapts a command built with `encoderInputArguments` as its custom input. Returns
    /// nil when the command does not contain the app's own deinterlacer, i.e. this
    /// export would not deinterlace and should run without QTGMC.
    static func encoderArguments(fromBuilt arguments: [String]) -> [String]? {
        guard let pipeIndex = indexOfSequence(pipeInput, in: arguments) else { return nil }
        var arguments = arguments

        // The command builder seeks every custom input; the pipe already starts at the
        // trim point, so drop the seek that precedes it.
        var index = pipeIndex - 1
        while index >= 0, arguments[index] != "-i" {
            if arguments[index] == "-ss", index + 1 < pipeIndex {
                arguments.removeSubrange(index...index + 1)
                break
            }
            index -= 1
        }

        var removedDeinterlacer = false
        let filterOptions: Set<String> = ["-vf", "-filter:v", "-filter:v:0", "-filter_complex", "-lavfi"]
        index = 0
        while index + 1 < arguments.count {
            let option = arguments[index]
            if filterOptions.contains(option) {
                let (graph, removed) = removingBuiltInDeinterlacer(from: arguments[index + 1])
                if removed {
                    arguments[index + 1] = graph
                    removedDeinterlacer = true
                }
                index += 2
            } else {
                index += 1
            }
        }
        guard removedDeinterlacer, let pipeStart = indexOfSequence(pipeInput, in: arguments) else { return nil }
        return redirectingSourceReferences(arguments, after: pipeStart + pipeInput.count)
    }

    static func removingBuiltInDeinterlacer(from graph: String) -> (String, Bool) {
        let stage = builtInDeinterlaceStage
        guard graph.contains(stage) else { return (graph, false) }
        var result = graph
            .replacingOccurrences(of: stage + ",", with: "")
            .replacingOccurrences(of: "," + stage, with: "")
        if result.contains(stage) {
            result = result.replacingOccurrences(of: stage, with: "null")
        }
        return (result, true)
    }

    /// Points stream, metadata and filter-graph references at the original file
    /// (input 1); video stays on the pipe (input 0).
    static func redirectingSourceReferences(_ arguments: [String], after outputStart: Int) -> [String] {
        var output: [String] = []
        var hasMetadataMap = false
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard index >= outputStart, index + 1 < arguments.count else {
                output.append(option)
                index += 1
                continue
            }
            let value = arguments[index + 1]
            switch option {
            case "-map":
                output += redirectedMaps(value)
            case _ where option == "-map_chapters" || option.hasPrefix("-map_metadata"):
                if option.hasPrefix("-map_metadata") { hasMetadataMap = true }
                output += [option, redirectedInputReference(value)]
            case "-filter_complex", "-lavfi", "-af", "-vf", _ where option.hasPrefix("-filter:"):
                output += [option, redirectedGraph(value)]
            default:
                output.append(option)
                index += 1
                continue
            }
            index += 2
        }
        if !hasMetadataMap, let last = output.last {
            // Global metadata otherwise comes from the first input, the pipe.
            output.removeLast()
            output += ["-map_metadata", "1", last]
        }
        return output
    }

    private static func redirectedMaps(_ value: String) -> [String] {
        if value == "0" || value == "0?" {
            return ["-map", "0:v:0", "-map", "1", "-map", "-1:v"]
        }
        if value.hasPrefix("0:v") || value.hasPrefix("-0:v") || value.hasPrefix("[") {
            return ["-map", value]
        }
        if value.hasPrefix("0:") { return ["-map", "1:" + value.dropFirst(2)] }
        if value.hasPrefix("-0:") { return ["-map", "-1:" + value.dropFirst(3)] }
        return ["-map", value]
    }

    private static func redirectedInputReference(_ value: String) -> String {
        if value == "0" { return "1" }
        if value.hasPrefix("0:") { return "1:" + value.dropFirst(2) }
        return value
    }

    private static func redirectedGraph(_ graph: String) -> String {
        var result = graph
        for kind in ["a", "s", "d", "t"] {
            result = result.replacingOccurrences(of: "[0:\(kind)", with: "[1:\(kind)")
        }
        return result
    }

    private static func indexOfSequence(_ sequence: [String], in arguments: [String]) -> Int? {
        guard arguments.count >= sequence.count else { return nil }
        for start in 0...(arguments.count - sequence.count)
        where Array(arguments[start..<(start + sequence.count)]) == sequence {
            return start
        }
        return nil
    }
}

/// Converts the decoder's Y4M stream into the deinterlaced Y4M stream the encoder
/// reads. Runs on the pipeline's producer-output callback, one chunk at a time.
final class QTGMCFrameTransform: SubprocessPipelineTransform, @unchecked Sendable {
    enum TransformError: Error, LocalizedError {
        case noVideo
        case unsupportedFormat(String)

        var errorDescription: String? {
            switch self {
            case .noVideo:
                return "The decoder produced no video frames for QTGMC"
            case .unsupportedFormat(let tag):
                return "QTGMC cannot process \(tag) video"
            }
        }
    }

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "QTGMC")

    private let plan: QTGMCPipelinePlan
    private let weightsURL: URL
    private let makeDeinterlacer: (Y4MFormat, Bool, QTGMCPipelinePlan, URL) throws -> any QTGMCDeinterlacing
    private let lock = NSLock()
    private var reader = Y4MReader()
    private var deinterlacer: (any QTGMCDeinterlacing)?
    private var framesToDrop: Int
    private var writtenFrames = 0
    private var failure: String?

    init(
        plan: QTGMCPipelinePlan,
        weightsURL: URL,
        makeDeinterlacer: @escaping (Y4MFormat, Bool, QTGMCPipelinePlan, URL) throws -> any QTGMCDeinterlacing = QTGMCFrameTransform.makeMetalDeinterlacer
    ) {
        self.plan = plan
        self.weightsURL = weightsURL
        self.makeDeinterlacer = makeDeinterlacer
        framesToDrop = plan.droppedOutputFrames
    }

    static func makeMetalDeinterlacer(
        format: Y4MFormat, topFieldFirst: Bool, plan: QTGMCPipelinePlan, weightsURL: URL
    ) throws -> any QTGMCDeinterlacing {
        let parameters = plan.parameters
        let weights = try QTGMCNNEDIWeights.load(
            from: weightsURL,
            neighbourhood: parameters.neighbourhood,
            neurons: parameters.neurons,
            qualityPasses: parameters.nnediQualityPasses
        )
        return try QTGMCMetalDeinterlacer(
            format: format, topFieldFirst: topFieldFirst, doubleRate: plan.doubleRate,
            parameters: parameters, weights: weights
        )
    }

    /// Why processing failed, as opposed to the encoder closing its input early
    /// (which is expected when it stops at the trim end).
    var failureReason: String? {
        lock.withLock { failure }
    }

    func process(_ data: Data, into output: SubprocessStandardInputWriter) throws {
        try lock.withLock {
            try recordingFailures {
                try reader.consume(data) { format, frame in
                    let deinterlacing = try engine(for: format, output: output)
                    try write(try deinterlacing.process(frame: frame), to: output)
                }
            }
        }
    }

    func finish(into output: SubprocessStandardInputWriter) throws {
        try lock.withLock {
            try recordingFailures {
                guard let deinterlacer else { throw TransformError.noVideo }
                try write(try deinterlacer.finish(), to: output)
            }
            Self.logger.info("QTGMC wrote \(self.writtenFrames) frames")
        }
    }

    private struct OutputClosed: Error {
        let underlying: Error
    }

    private func recordingFailures(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch let closed as OutputClosed {
            throw closed.underlying
        } catch {
            if failure == nil { failure = error.localizedDescription }
            throw error
        }
    }

    private func engine(for format: Y4MFormat, output: SubprocessStandardInputWriter) throws -> any QTGMCDeinterlacing {
        if let deinterlacer { return deinterlacer }
        let topFieldFirst: Bool
        switch format.interlacing {
        case .topFieldFirst: topFieldFirst = true
        case .bottomFieldFirst: topFieldFirst = false
        case .progressive, .mixed: topFieldFirst = plan.topFieldFirst
        }
        let created = try makeDeinterlacer(format, topFieldFirst, plan, weightsURL)
        deinterlacer = created
        let header = format.headerLine(progressiveAtRateMultiplier: plan.doubleRate ? 2 : 1)
        do {
            try output.write(Data(header.utf8))
        } catch {
            throw OutputClosed(underlying: error)
        }
        Self.logger.info("QTGMC \(format.width)x\(format.height) \(format.colorSpaceTag, privacy: .public) \(topFieldFirst ? "TFF" : "BFF", privacy: .public), \(self.plan.doubleRate ? "double" : "single", privacy: .public) rate")
        return created
    }

    private func write(_ frames: [Data], to output: SubprocessStandardInputWriter) throws {
        for frame in frames {
            if framesToDrop > 0 {
                framesToDrop -= 1
                continue
            }
            var chunk = Y4MWriter.frameMarker
            chunk.append(frame)
            do {
                try output.write(chunk)
            } catch {
                throw OutputClosed(underlying: error)
            }
            writtenFrames += 1
        }
    }
}

/// The frame-processing surface of `QTGMCMetalDeinterlacer`, replaceable in tests.
protocol QTGMCDeinterlacing: AnyObject {
    func process(frame: UnsafeRawBufferPointer) throws -> [Data]
    func finish() throws -> [Data]
}

extension QTGMCMetalDeinterlacer: QTGMCDeinterlacing {}
