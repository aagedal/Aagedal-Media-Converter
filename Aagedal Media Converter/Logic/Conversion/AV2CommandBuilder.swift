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

/// Builds the command pair(s) for the experimental AV2 export path.
///
/// AV2 is not supported by FFmpeg, so encoding runs as a two-process pipe:
///   ffmpeg (decode → y4m on stdout)  │  avmenc (y4m on stdin → .ivf)
///
/// `avmenc` requires the frame dimensions up front (it does not parse the y4m
/// header when reading from a pipe), so the final output width/height are
/// computed here and baked into an explicit `scale=W:H` on the ffmpeg side.
/// Because ffmpeg is forced to emit exactly those dimensions, the number handed
/// to `avmenc -w/-h` is guaranteed to match the frames it receives.
///
/// Two modes:
/// - ``build(inputURL:outputURL:trimStart:trimEnd:cropConfig:visualSourceURL:customInputArguments:expectedDuration:videoFrameRate:)`` —
///   the single-process encode (tile threading only), including virtual FFmpeg inputs.
/// - ``buildSegments(inputURL:trimStart:trimEnd:cropConfig:visualSourceURL:customInputArguments:expectedDuration:videoFrameRate:)`` — splits the source into one
///   frame-range chunk per CPU core and emits an independent ffmpeg│avmenc command per chunk,
///   to be encoded in parallel and joined with ``IVFConcatenator``. This is the dominant speed
///   lever: AVM's intra-frame (tile/row) threading scales poorly, whereas independent chunks
///   scale near-linearly with core count *and* compress better (no tile boundaries).
enum AV2CommandBuilder {

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "AV2CommandBuilder")

    enum MetadataSource: Sendable {
        case probeIfNeeded
        case resolved(VideoMetadata?)
    }

    struct AV2Command: Sendable {
        /// ffmpeg arguments that decode/trim/scale the source and write y4m to stdout (`pipe:1`).
        let ffmpegArguments: [String]
        /// avmenc arguments that read y4m from stdin (`-`) and write the `.ivf` output.
        let avmencArguments: [String]
        let outputWidth: Int
        let outputHeight: Int
        /// Trim-aware duration used to drive the progress parser. nil if unknown.
        let effectiveDuration: Double?
        /// Source frame rate used by the progress parser. nil if unknown.
        let frameRate: Double?
    }

    /// One parallel chunk: an independent ffmpeg│avmenc pair encoding `frameCount` frames
    /// starting at the chunk's offset, written to `outputURL` (a temp `.ivf`).
    struct AV2SegmentCommand: Sendable {
        let index: Int
        let ffmpegArguments: [String]
        let avmencArguments: [String]
        let outputURL: URL
        let frameCount: Int
    }

    /// The full plan for a chunked encode: the per-chunk commands plus shared geometry and the
    /// proposed scratch directory. Planning does not create it; execution creates and owns it.
    struct AV2SegmentPlan: Sendable {
        let segments: [AV2SegmentCommand]
        let segmentDirectory: URL
        let outputWidth: Int
        let outputHeight: Int
        let bitDepth: Int
        let totalFrames: Int
        let effectiveDuration: Double?
        let frameRate: Double?
    }

    /// Settings + geometry shared by the single-process and chunked builders. Computing this once
    /// guarantees the two paths produce byte-identical scaling, bit depth and rate-control choices.
    private struct Resolved {
        let finalW: Int
        let finalH: Int
        let bitDepth: Int
        let rateMode: AV2RateControlMode
        let qp: Int
        let targetBitrate: Int
        let speed: Int
        let threads: Int
        let autoTileColumns: Int
        let autoTileRows: Int
        let fpsNum: Int?
        let fpsDen: Int?
        let frameRate: Double?
        let effectiveDuration: Double?
        let videoFilter: String
        let pixFmt: String
    }

    // MARK: - Single-process build

    /// Builds the single-process AV2 command pair. Returns nil if the source dimensions cannot be
    /// determined (in which case avmenc cannot be configured and the caller should fail).
    static func build(
        inputURL: URL,
        outputURL: URL,
        trimStart: Double?,
        trimEnd: Double?,
        cropConfig: CropConfig?,
        visualSourceURL: URL? = nil,
        customInputArguments: [String]? = nil,
        expectedDuration: Double? = nil,
        videoFrameRate: Double? = nil,
        metadataSource: MetadataSource = .probeIfNeeded,
        settings: AV2Settings = AV2Settings()
    ) async -> AV2Command? {
        guard let r = await resolve(
            inputURL: inputURL,
            trimStart: trimStart,
            trimEnd: trimEnd,
            cropConfig: cropConfig,
            visualSourceURL: visualSourceURL,
            customInputArguments: customInputArguments,
            expectedDuration: expectedDuration,
            videoFrameRate: videoFrameRate,
            metadataSource: metadataSource,
            settings: settings
        ) else {
            return nil
        }

        // MARK: ffmpeg decode → y4m
        var ffmpeg: [String] = ["-y", "-nostdin", "-progress", "pipe:2", "-hide_banner"]
        if let trimStart, trimStart > 0 {
            ffmpeg += ["-ss", String(format: "%.6f", trimStart)]
        }
        appendInputArguments(customInputArguments, inputURL: inputURL, to: &ffmpeg)
        if let trimStart, let trimEnd, trimEnd > trimStart {
            ffmpeg += ["-t", String(format: "%.6f", trimEnd - trimStart)]
        } else if let trimEnd, trimEnd > 0, trimStart == nil {
            ffmpeg += ["-t", String(format: "%.6f", trimEnd)]
        }
        ffmpeg += ["-map", "0:v:0", "-an", "-sn", "-dn"]
        ffmpeg += ["-vf", r.videoFilter]
        ffmpeg += ["-pix_fmt", r.pixFmt]
        ffmpeg += ["-f", "yuv4mpegpipe", "-strict", "-1", "pipe:1"]

        // MARK: avmenc encode
        var avmenc = baseAvmencArguments(r)
        switch r.rateMode {
        case .constantQuality:
            avmenc += ["--end-usage=q", "--qp=\(clampQP(r.qp))"]
        case .targetBitrate:
            avmenc += ["--end-usage=vbr", "--target-bitrate=\(max(1, r.targetBitrate))"]
        }
        avmenc += ["--cpu-used=\(r.speed)"]
        avmenc += ["-t", "\(r.threads)"]
        // The .mkv muxer assigns one presentation timestamp per IVF frame record, so the bitstream
        // must have one record per displayed frame. By default avmenc uses alt-ref/lag frames, which
        // makes records ≠ displayed frames with non-sequential timestamps — disable it for muxing.
        if AV2Container.current == .mkv { avmenc += ["--lag-in-frames=0"] }
        if r.autoTileColumns > 0 { avmenc += ["--tile-columns=\(r.autoTileColumns)"] }
        if r.autoTileRows > 0 { avmenc += ["--tile-rows=\(r.autoTileRows)"] }
        avmenc += ["-o", outputURL.path, "-"]

        logger.info("AV2 dims \(r.finalW)x\(r.finalH), \(r.bitDepth)-bit, mode=\(r.rateMode.rawValue, privacy: .public)")

        return AV2Command(
            ffmpegArguments: ffmpeg,
            avmencArguments: avmenc,
            outputWidth: r.finalW,
            outputHeight: r.finalH,
            effectiveDuration: r.effectiveDuration,
            frameRate: r.frameRate
        )
    }

    // MARK: - Chunked build

    /// Builds a parallel-chunk plan, or returns nil to signal "use the single-process path"
    /// (because the source frame count is unknown, the user disabled chunking, the encode is in
    /// VBR mode — where rate control cannot span chunk boundaries — or the clip is too short to
    /// usefully split). When non-nil the plan always contains ≥ 2 segments.
    static func buildSegments(
        inputURL: URL,
        trimStart: Double?,
        trimEnd: Double?,
        cropConfig: CropConfig?,
        visualSourceURL: URL? = nil,
        customInputArguments: [String]? = nil,
        expectedDuration: Double? = nil,
        videoFrameRate: Double? = nil,
        metadataSource: MetadataSource = .probeIfNeeded,
        settings: AV2Settings = AV2Settings()
    ) async -> AV2SegmentPlan? {
        // Seeking each worker independently is not yet validated for concat/image2 demuxers.
        // Keep virtual inputs on the correct single-process path until their segment boundaries
        // have generated-media coverage.
        guard customInputArguments == nil else { return nil }
        guard let r = await resolve(
            inputURL: inputURL,
            trimStart: trimStart,
            trimEnd: trimEnd,
            cropConfig: cropConfig,
            visualSourceURL: visualSourceURL,
            customInputArguments: customInputArguments,
            expectedDuration: expectedDuration,
            videoFrameRate: videoFrameRate,
            metadataSource: metadataSource,
            settings: settings
        ) else {
            return nil
        }
        guard let frameRate = r.frameRate, frameRate > 0,
              let duration = r.effectiveDuration, duration > 0 else {
            return nil // can't partition without a frame count
        }
        let totalFrames = max(1, Int((duration * frameRate).rounded()))

        let hint = settings.parallelChunks
        let chunkCount = resolvedChunkCount(totalFrames: totalFrames, hint: hint, rateMode: r.rateMode)
        guard chunkCount > 1 else { return nil }

        let cores = ProcessInfo.processInfo.activeProcessorCount
        // When there are fewer chunks than cores, let each worker use the leftover cores via avmenc's
        // row-based multithreading (--row-mt is on by default) so the machine stays saturated.
        let threadsPerWorker = max(1, cores / chunkCount)

        let base = totalFrames / chunkCount
        let remainder = totalFrames % chunkCount
        let trimBase = trimStart ?? 0

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("av2chunks_\(UUID().uuidString)", isDirectory: true)

        var segments: [AV2SegmentCommand] = []
        var startFrame = 0
        for i in 0..<chunkCount {
            let count = base + (i < remainder ? 1 : 0)
            let startSec = trimBase + Double(startFrame) / frameRate
            let segURL = dir.appendingPathComponent(String(format: "seg_%04d.ivf", i))

            // ffmpeg: accurate input-seek to this chunk's first frame, then bound output to exactly
            // `count` frames with -frames:v (the most reliable boundary). Each chunk's avmenc forces
            // a key frame at its first input frame, so the chunks stay independently decodable.
            var ff: [String] = ["-y", "-nostdin", "-progress", "pipe:2", "-hide_banner"]
            if startSec > 0 { ff += ["-ss", String(format: "%.6f", startSec)] }
            appendInputArguments(customInputArguments, inputURL: inputURL, to: &ff)
            ff += ["-frames:v", "\(count)"]
            ff += ["-map", "0:v:0", "-an", "-sn", "-dn"]
            ff += ["-vf", r.videoFilter]
            ff += ["-pix_fmt", r.pixFmt]
            ff += ["-f", "yuv4mpegpipe", "-strict", "-1", "pipe:1"]

            // avmenc: constant-quality only (VBR was filtered out above). No tile args — chunking
            // supplies the cross-core parallelism, and an untiled encode compresses better.
            var av = baseAvmencArguments(r)
            av += ["--end-usage=q", "--qp=\(clampQP(r.qp))"]
            av += ["--cpu-used=\(r.speed)"]
            av += ["-t", "\(threadsPerWorker)"]
            // 1 IVF record per displayed frame for correct Matroska timing (see build()).
            if AV2Container.current == .mkv { av += ["--lag-in-frames=0"] }
            av += ["--limit=\(count)"]
            av += ["-o", segURL.path, "-"]

            segments.append(AV2SegmentCommand(
                index: i,
                ffmpegArguments: ff,
                avmencArguments: av,
                outputURL: segURL,
                frameCount: count
            ))
            startFrame += count
        }

        logger.info("AV2 chunked: \(chunkCount) segments × ~\(base) frames, \(threadsPerWorker) thread(s) each, \(r.finalW)x\(r.finalH) \(r.bitDepth)-bit")

        return AV2SegmentPlan(
            segments: segments,
            segmentDirectory: dir,
            outputWidth: r.finalW,
            outputHeight: r.finalH,
            bitDepth: r.bitDepth,
            totalFrames: totalFrames,
            effectiveDuration: r.effectiveDuration,
            frameRate: r.frameRate
        )
    }

    /// Resolves the bit depth (8 or 10) that the encode will use, mirroring `build()`/`buildSegments()`.
    /// Used by the `.mkv` muxer to configure the avmenc `--webm` probe that harvests the AV2
    /// `CodecPrivate` (which encodes the bit-depth flags, so it must match the real stream).
    static func resolvedBitDepth(
        inputURL: URL,
        trimStart: Double?,
        trimEnd: Double?,
        cropConfig: CropConfig?,
        visualSourceURL: URL? = nil,
        metadataSource: MetadataSource = .probeIfNeeded,
        settings: AV2Settings = AV2Settings()
    ) async -> Int? {
        await resolve(
            inputURL: inputURL,
            trimStart: trimStart,
            trimEnd: trimEnd,
            cropConfig: cropConfig,
            visualSourceURL: visualSourceURL,
            customInputArguments: nil,
            expectedDuration: nil,
            videoFrameRate: nil,
            metadataSource: metadataSource,
            settings: settings
        )?.bitDepth
    }

    /// Resolves how many parallel chunks to use. `hint` is the user setting (0 = auto = one per
    /// core, 1 = single-process, N = explicit). VBR is forced to a single chunk because independent
    /// VBR encoders can't share a bitrate budget across boundaries.
    static func resolvedChunkCount(totalFrames: Int, hint: Int, rateMode: AV2RateControlMode) -> Int {
        if rateMode == .targetBitrate { return 1 }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let requested = hint <= 0 ? cores : hint
        // Don't fragment into pathologically tiny chunks (each adds a key frame → size/efficiency cost).
        let minFramesPerChunk = 24
        let maxByFrames = max(1, totalFrames / minFramesPerChunk)
        return max(1, min(requested, maxByFrames, totalFrames))
    }

    // MARK: - Shared avmenc prefix

    /// The avmenc arguments common to every encode (container, geometry, bit depth, chroma, fps).
    /// Rate control, speed, threads, tiling and output are appended per-mode by the callers.
    private static func baseAvmencArguments(_ r: Resolved) -> [String] {
        var avmenc: [String] = ["--ivf", "-w", "\(r.finalW)", "-h", "\(r.finalH)"]
        avmenc += ["-b", "\(r.bitDepth)", "--input-bit-depth=\(r.bitDepth)", "--i420"]
        if let n = r.fpsNum, let d = r.fpsDen, n > 0, d > 0 {
            // y4m carries fps, but avmenc won't read the header from a pipe — pass it explicitly
            // so the IVF timebase/framerate is correct.
            avmenc += ["--fps=\(n)/\(d)"]
        }
        return avmenc
    }

    // MARK: - Shared resolution

    private static func resolve(
        inputURL: URL,
        trimStart: Double?,
        trimEnd: Double?,
        cropConfig: CropConfig?,
        visualSourceURL: URL?,
        customInputArguments: [String]?,
        expectedDuration: Double?,
        videoFrameRate: Double?,
        metadataSource: MetadataSource,
        settings: AV2Settings
    ) async -> Resolved? {
        let metadataURL = visualSourceURL ?? inputURL
        let metadata: VideoMetadata? = switch metadataSource {
        case .probeIfNeeded:
            try? await BoundedVideoMetadataProbe.metadata(for: metadataURL)
        case .resolved(let metadata):
            metadata
        }
        let stream = metadata?.primaryVideoStream
        guard let geometry = await FFMPEGCommandBuilder.sourceGeometry(
            for: metadataURL,
            sourceMetadata: metadata,
            probeMetadataIfNeeded: false
        ) else {
            logger.error("AV2: could not determine source dimensions for \(metadataURL.lastPathComponent, privacy: .public)")
            return nil
        }
        let srcW = geometry.width
        let srcH = geometry.height

        let dar = geometry.displayAspectRatio
        let par = geometry.pixelAspectRatio
        let customFrameRate = frameRateArgument(in: customInputArguments)
        let resolvedFrameRate = VideoMetadata.FrameRate(double: videoFrameRate)
            ?? customFrameRate
            ?? stream?.frameRate
        let frameRate = resolvedFrameRate?.value

        // Effective PAR (mirrors FFMPEGCommandBuilder's DAR-priority logic).
        let effectivePAR: Double
        if let dar, dar > 0 {
            let resolutionAspect = Double(srcW) / Double(srcH)
            let derivedPAR = dar / resolutionAspect
            if let par, par > 0 {
                effectivePAR = abs(derivedPAR - par) < 0.05 ? par : derivedPAR
            } else {
                effectivePAR = derivedPAR
            }
        } else if let par, par > 0 {
            effectivePAR = par
        } else {
            effectivePAR = 1.0
        }

        // Compute final (square-pixel) output dimensions.
        let cropActive = (cropConfig?.isActive ?? false)
        let basePxW: Int
        let basePxH: Int
        if cropActive, let cropConfig {
            let rect = cropConfig.pixelRect(sourceWidth: srcW, sourceHeight: srcH).evenDimensions()
            basePxW = rect.width
            basePxH = rect.height
        } else {
            basePxW = srcW
            basePxH = srcH
        }

        var finalW = evenDimension(Double(basePxW) * effectivePAR)
        var finalH = evenDimension(Double(basePxH))

        if let maxShortEdge = settings.resolutionLimit.maxHeight {
            let shortEdge = min(finalW, finalH)
            if shortEdge > maxShortEdge {
                let factor = Double(maxShortEdge) / Double(shortEdge)
                finalW = evenDimension(Double(finalW) * factor)
                finalH = evenDimension(Double(finalH) * factor)
            }
        }

        // Resolve settings.
        let bitDepth = settings.bitDepth.resolved(sourceBitDepth: stream?.bitDepth)
        let rateMode = settings.rateControlMode
        let qp = settings.quality
        let targetBitrate = settings.targetBitrate
        let speed = settings.speed
        let tileColumns = settings.tileColumns
        let tileRows = settings.tileRows
        let threadsSetting = settings.threads
        let threads = threadsSetting > 0 ? threadsSetting : ProcessInfo.processInfo.activeProcessorCount

        // Effective duration (trim-aware) for progress + chunk partitioning. Resolve the source
        // duration first so start-only trims subtract their skipped prefix instead of planning the
        // full source again (which can send the final chunks past EOF).
        let sourceDuration: Double?
        if let expectedDuration, expectedDuration >= 0 {
            sourceDuration = expectedDuration
        } else if let streamDuration = stream?.duration {
            sourceDuration = streamDuration
        } else if visualSourceURL == nil {
            sourceDuration = await FFMPEGProbeService.getVideoDuration(for: inputURL)
        } else {
            sourceDuration = nil
        }
        let effectiveDuration = resolvedEffectiveDuration(
            sourceDuration: sourceDuration,
            trimStart: trimStart,
            trimEnd: trimEnd
        )

        // Auto-tiling for the single-process path (chunked omits tiles entirely).
        let autoTileColumns = tileColumns > 0 ? tileColumns : autoTileLog2(finalW, maxLog2: 3)
        let autoTileRows = tileRows > 0 ? tileRows : autoTileLog2(finalH, maxLog2: 2)

        // Video filter chain: crop (optional) then an explicit forced scale so the emitted frame
        // size exactly equals avmenc's -w/-h.
        var videoFilter = "scale=\(finalW):\(finalH),setsar=1"
        if cropActive, let cropConfig,
           let cropFilter = CropService.buildCropFilter(config: cropConfig, sourceWidth: srcW, sourceHeight: srcH) {
            videoFilter = "\(cropFilter),scale=\(finalW):\(finalH),setsar=1"
        }

        return Resolved(
            finalW: finalW,
            finalH: finalH,
            bitDepth: bitDepth,
            rateMode: rateMode,
            qp: qp,
            targetBitrate: targetBitrate,
            speed: min(max(speed, 0), 9),
            threads: max(1, threads),
            autoTileColumns: autoTileColumns,
            autoTileRows: autoTileRows,
            fpsNum: resolvedFrameRate.flatMap { $0.numerator > 0 ? $0.numerator : nil },
            fpsDen: resolvedFrameRate.flatMap { $0.denominator > 0 ? $0.denominator : nil },
            frameRate: frameRate,
            effectiveDuration: effectiveDuration,
            videoFilter: videoFilter,
            pixFmt: bitDepth >= 10 ? "yuv420p10le" : "yuv420p"
        )
    }

    // MARK: - Helpers

    private static func appendInputArguments(
        _ customInputArguments: [String]?,
        inputURL: URL,
        to arguments: inout [String]
    ) {
        if let customInputArguments {
            arguments.append(contentsOf: customInputArguments)
        } else {
            arguments.append(contentsOf: ["-i", inputURL.path])
        }
    }

    private static func frameRateArgument(in arguments: [String]?) -> VideoMetadata.FrameRate? {
        guard let arguments,
              let index = arguments.firstIndex(of: "-framerate"),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return VideoMetadata.FrameRate(frameRateString: arguments[index + 1])
    }

    /// Mirrors FFmpeg's trim arguments while keeping progress and chunk planning inside the
    /// source's available duration. An invalid/non-increasing end behaves like a start-only trim,
    /// matching the command builder's omission of `-t` in that case.
    static func resolvedEffectiveDuration(
        sourceDuration: Double?,
        trimStart: Double?,
        trimEnd: Double?
    ) -> Double? {
        let start = max(0, trimStart ?? 0)

        if let trimEnd, trimEnd > start {
            let effectiveEnd = sourceDuration.map { min(trimEnd, max(0, $0)) } ?? trimEnd
            return max(0, effectiveEnd - start)
        }

        guard let sourceDuration else { return nil }
        return max(0, sourceDuration - start)
    }

    /// Rounds to the nearest even integer (codec requirement), with a floor of 2.
    private static func evenDimension(_ value: Double) -> Int {
        let rounded = Int(value.rounded())
        let even = (rounded / 2) * 2
        return max(2, even)
    }

    /// Chooses an automatic tile count (as a log2 exponent) for one axis, large enough to spread
    /// work across cores while keeping each tile at least ~256 px on that axis. Capped at `maxLog2`.
    private static func autoTileLog2(_ dimension: Int, maxLog2: Int) -> Int {
        var log2 = 0
        while log2 < maxLog2 && (dimension >> (log2 + 1)) >= 256 {
            log2 += 1
        }
        return log2
    }

    /// avmenc `--qp` accepts [0, 255]; keep the user value in range.
    private static func clampQP(_ qp: Int) -> Int {
        min(max(qp, 0), 255)
    }

}
