// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Experimental AV2 export: muxing the encoded `.ivf` and its audio into Matroska,
// plus the avm helper runs and AV2 source detection.

import Foundation
import OSLog

extension FFMPEGConverter {
    // MARK: - AV2 → Matroska (.mkv) muxing

    /// Wraps an already-encoded AV2 `.ivf` plus the source audio into a `.mkv` using the in-app
    /// ``MatroskaMuxer`` (FFmpeg cannot write AV2). The AV2 `CodecPrivate` is harvested from a tiny
    /// `avmenc --webm` probe; routed audio is re-encoded to AAC or Opus and packetised in-app.
    /// A source with no selected audio yields a valid video-only `.mkv`; failures while processing
    /// selected audio fail the conversion so routing choices are never silently discarded.
    func muxAV2ToMatroska(
        conversionID: UUID,
        videoIvfURL: URL,
        sourceURL: URL,
        customInputArguments: [String]?,
        isMuted: Bool,
        audioRoutingConfig: AudioRoutingConfig?,
        comment: String,
        metadataEditorSettings: MetadataEditorSettings?,
        includeDateTag: Bool,
        commentSettings: CommentSettings,
        timecodeConfig: TimecodeConfig?,
        timecodeTrimStart: Double?,
        sourceMetadata knownSourceMetadata: VideoMetadata?,
        trimStart: Double?,
        trimEnd: Double?,
        bitDepth: Int,
        keyframeIndices: [Int],
        outputURL: URL,
        ffmpegPath: String,
        avmencPath: String,
        settings: AV2Settings,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void
    ) async -> (Bool, String?) {
        guard activeConversionID == conversionID else {
            return (false, "Conversion cancelled")
        }
        guard let ivfHeader = IVFHeaderParser.parse(url: videoIvfURL), ivfHeader.isAV2 else {
            return (false, "AV2 muxing: the encoded bitstream is not a valid AV2 IVF")
        }
        let width = ivfHeader.width
        let height = ivfHeader.height
        let fpsNum = ivfHeader.fpsNumerator > 0 ? ivfHeader.fpsNumerator : 24
        let fpsDen = ivfHeader.fpsDenominator > 0 ? ivfHeader.fpsDenominator : 1

        progressUpdate(0.99, "Muxing AV2 + audio…")

        // 1. Harvest the authoritative V_AV2 CodecPrivate (level/bit-depth depend on the config).
        let codecPrivate = await harvestAV2CodecPrivate(
            width: width, height: height, bitDepth: bitDepth,
            fpsNum: fpsNum, fpsDen: fpsDen, ffmpegPath: ffmpegPath, avmencPath: avmencPath
        )
        if codecPrivate == nil {
            Self.logger.warning("AV2 muxing: failed to harvest CodecPrivate; writing track without it")
        }
        guard activeConversionID == conversionID else {
            return (false, "Conversion cancelled")
        }

        // Video payloads stay in the IVF file. The muxer indexes record offsets and
        // copies bytes in bounded buffers after routed audio has been prepared.
        // 3. Extract + parse routed audio. A video-only .mkv is fine only when audio is absent,
        // muted, or explicitly removed by the routing configuration.
        var audioTracks: [MatroskaMuxer.AudioTrack] = []
        if let audioInput = Self.av2MuxAudioInput(
            inputURL: sourceURL,
            customInputArguments: customInputArguments,
            isMuted: isMuted
        ) {
            switch await extractAudioTracksForAV2Mux(
                conversionID: conversionID,
                source: audioInput,
                audioRoutingConfig: audioRoutingConfig,
                trimStart: trimStart,
                trimEnd: trimEnd,
                ffmpegPath: ffmpegPath,
                settings: settings
            ) {
            case .noAudio:
                break
            case .tracks(let extractedTracks):
                audioTracks = extractedTracks
            case .failed(let reason):
                return (false, "AV2 audio routing failed: \(reason)")
            case .cancelled:
                return (false, "Conversion cancelled")
            }
        }
        guard activeConversionID == conversionID else {
            return (false, "Conversion cancelled")
        }

        // 4. Resolve global/container metadata. Raw IVF cannot carry these tags;
        // the Matroska path keeps the same comment/date and timecode policy as
        // ordinary FFmpeg-backed exports.
        let sourceMetadata: VideoMetadata?
        if knownSourceMetadata == nil, timecodeConfig?.mode == .preserveSource || settings.preserveMetadata == true {
            sourceMetadata = try? await BoundedVideoMetadataProbe.metadata(for: sourceURL)
        } else {
            sourceMetadata = knownSourceMetadata
        }
        guard activeConversionID == conversionID else {
            return (false, "Conversion cancelled")
        }
        let timecode = timecodeConfig.flatMap {
            FFMPEGCommandBuilder.resolvedTimecode(
                timecodeConfig: $0,
                sourceMetadata: sourceMetadata,
                trimStart: timecodeTrimStart ?? trimStart
            )
        }
        let inheritedText = settings.preserveMetadata == true ? sourceMetadata : nil
        let composedComment = FFMPEGCommandBuilder.commentMetadataValue(comment: comment, includeDateTag: includeDateTag, settings: commentSettings)
        let editor = metadataEditorSettings.flatMap { $0.isActive ? $0 : nil }
        let metadata = MatroskaMuxer.Metadata(
            comment: editor?.writesComment == true ? composedComment : composedComment ?? inheritedText?.comment,
            timecode: timecode,
            description: editor.flatMap { $0.description.isEnabled ? $0.description.value : nil } ?? inheritedText?.description,
            title: editor.flatMap { $0.title.isEnabled ? $0.title.value : nil } ?? inheritedText?.title,
            artist: editor.flatMap { $0.artist.isEnabled ? $0.artist.value : nil } ?? inheritedText?.artist,
            sourceURL: editor?.sourceURL ?? inheritedText?.sourceURL
        )

        // 5. Write the Matroska file.
        let video = MatroskaMuxer.VideoTrackInfo(
            codecID: "V_AV2", codecPrivate: codecPrivate,
            width: width, height: height, fpsNumerator: fpsNum, fpsDenominator: fpsDen
        )
        do {
            let routedAudio = audioTracks
            try await runAV2FileWork {
                try MatroskaMuxer.write(
                    to: outputURL,
                    video: video,
                    videoIVFURL: videoIvfURL,
                    keyframeIndices: keyframeIndices,
                    audioTracks: routedAudio,
                    metadata: metadata
                )
            }
        } catch {
            return (false, "AV2 muxing failed: \(error.localizedDescription)")
        }
        if let validationError = Self.validateOutputFile(at: outputURL) {
            return (false, validationError)
        }
        let audioFrameCount = audioTracks.reduce(0) { $0 + $1.frames.count }
        Self.logger.info("AV2 mux complete: streamed video + \(audioFrameCount) audio frames across \(audioTracks.count) tracks → \(outputURL.lastPathComponent, privacy: .public)")
        return (true, nil)
    }

    /// Encodes a single black frame at the exact geometry/depth/fps to learn the authoritative
    /// AV2 `CodecPrivate` from `avmenc --webm` (the field is config-dependent, not content-dependent).
    private func harvestAV2CodecPrivate(
        width: Int, height: Int, bitDepth: Int, fpsNum: Int, fpsDen: Int,
        ffmpegPath: String, avmencPath: String
    ) async -> Data? {
        let dir = FileManager.default.temporaryDirectory
        let y4m = dir.appendingPathComponent("av2probe_\(UUID().uuidString).y4m")
        let webm = dir.appendingPathComponent("av2probe_\(UUID().uuidString).webm")
        defer {
            Self.cleanupTempFile(at: y4m, label: "AV2 probe y4m")
            Self.cleanupTempFile(at: webm, label: "AV2 probe webm")
        }
        let pix = bitDepth >= 10 ? "yuv420p10le" : "yuv420p"
        let ff = ["-y", "-nostdin", "-hide_banner", "-f", "lavfi",
                  "-i", "color=c=black:s=\(width)x\(height):r=\(fpsNum)/\(fpsDen)",
                  "-frames:v", "1", "-pix_fmt", pix, "-f", "yuv4mpegpipe", "-strict", "-1", y4m.path]
        guard case .success = await runTrackedAV2Helper(
            ffmpegPath,
            ff,
            timeout: Self.av2ProbeHelperTimeout
        ), Self.fileHasContent(at: y4m) else { return nil }
        let av = ["--webm", "-w", "\(width)", "-h", "\(height)", "-b", "\(bitDepth)",
                  "--input-bit-depth=\(bitDepth)", "--i420", "--fps=\(fpsNum)/\(fpsDen)",
                  "--end-usage=q", "--qp=110", "--cpu-used=9", "--limit=1", "-o", webm.path, y4m.path]
        guard case .success = await runTrackedAV2Helper(
            avmencPath,
            av,
            timeout: Self.av2ProbeHelperTimeout
        ), Self.fileHasContent(at: webm) else { return nil }
        return Self.extractMatroskaCodecPrivate(fromWebM: webm)
    }

    /// Re-encodes the routed source audio to the configured codec (AAC or Opus), preserving the
    /// selected order and duplicate tracks. FFmpeg first writes an audio-only Matroska file so a
    /// single filter graph can produce every requested stream; each stream is then copied to an
    /// elementary file for the existing AAC/Opus packet parsers.
    static func av2MuxAudioInput(
        inputURL: URL,
        customInputArguments: [String]?,
        isMuted: Bool
    ) -> PackageAudioInput? {
        guard !isMuted else { return nil }
        let source = packageAudioInput(inputURL: inputURL, customInputArguments: customInputArguments)
        return source.arguments.isEmpty ? nil : source
    }

    private static func av2HelperSensitiveValues(for source: PackageAudioInput) -> Set<String> {
        var values = Set(source.arguments.filter { $0.hasPrefix("/") })
        if let probeURL = source.probeURL {
            values.insert(probeURL.path)
        }

        guard source.arguments.contains("concat") else { return values }
        for index in source.arguments.indices where source.arguments[index] == "-i" {
            guard source.arguments.indices.contains(index + 1) else { continue }
            let listPath = source.arguments[index + 1]
            guard let contents = try? String(contentsOfFile: listPath, encoding: .utf8) else {
                continue
            }
            for line in contents.split(whereSeparator: \.isNewline) {
                guard line.hasPrefix("file '"), line.hasSuffix("'") else { continue }
                let encodedPath = line.dropFirst(6).dropLast()
                let path = encodedPath.replacingOccurrences(of: "'\\''", with: "'")
                if path.hasPrefix("/") {
                    values.insert(path)
                }
            }
        }
        return values
    }

    enum AV2MuxAudioExtractionResult: Sendable {
        case noAudio
        case tracks([MatroskaMuxer.AudioTrack])
        case failed(String)
        case cancelled
    }

    func extractAudioTracksForAV2Mux(
        conversionID: UUID? = nil,
        source: PackageAudioInput,
        audioRoutingConfig: AudioRoutingConfig?,
        trimStart: Double?,
        trimEnd: Double?,
        ffmpegPath: String,
        settings: AV2Settings = AV2Settings(),
        audioStreamProvider: @escaping @Sendable (URL) async -> [FFMPEGProbeService.AudioStreamInfo]? = {
            await FFMPEGProbeService.fetchAudioStreams(for: $0)
        }
    ) async -> AV2MuxAudioExtractionResult {
        let trim = AV2TrimPlan(start: trimStart, end: trimEnd)
        if let preparationError = trim.preparationError { return .failed(preparationError) }

        func operationIsCurrent() -> Bool {
            guard !Task.isCancelled else { return false }
            guard let conversionID else { return true }
            return activeConversionID == conversionID
        }

        guard operationIsCurrent() else { return .cancelled }
        let codec = settings.audioCodec
        let bitrate = settings.audioBitrate.ffmpegValue
        let defaultAudioStreamIndices: [Int]
        if audioRoutingConfig != nil {
            defaultAudioStreamIndices = []
        } else if let probeURL = source.probeURL {
            guard let streams = await audioStreamProvider(probeURL) else {
                guard operationIsCurrent() else { return .cancelled }
                return .failed("Could not inspect the source audio streams")
            }
            guard operationIsCurrent() else { return .cancelled }
            if streams.isEmpty && source.assumesSingleAudioStreamIfProbeUnavailable {
                defaultAudioStreamIndices = [0]
            } else {
                defaultAudioStreamIndices = streams.enumerated().compactMap { offset, stream in
                    stream.isDecodable ? offset : nil
                }
            }
        } else {
            defaultAudioStreamIndices = []
        }
        let routingArguments = Self.av2MuxAudioRoutingArguments(
            inputIndex: source.ffmpegInputIndex,
            audioRoutingConfig: audioRoutingConfig,
            defaultAudioStreamIndices: defaultAudioStreamIndices
        )
        let plannedTrackCount = routingArguments.indices.reduce(into: 0) { count, index in
            if routingArguments[index] == "-map", routingArguments.indices.contains(index + 1) {
                count += 1
            }
        }
        guard plannedTrackCount > 0 else { return .noAudio }
        guard operationIsCurrent() else { return .cancelled }

        let sourceSensitiveValues = Self.av2HelperSensitiveValues(for: source)

        let routedAudioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("av2audio_routed_\(UUID().uuidString).mkv")
        defer { Self.cleanupTempFile(at: routedAudioURL, label: "AV2 routed audio") }

        var args = ["-y", "-nostdin", "-hide_banner"]
        args += trim.inputArguments
        args += source.arguments
        args += trim.outputArguments
        args += ["-vn"]
        args += routingArguments
        // Keep the source timeline relative to the picture/trim origin. Otherwise the audio-only
        // muxer shifts every stream to hide encoder preroll, changing audio/video synchronization.
        args += ["-c:a", codec.ffmpegEncoder, "-b:a", bitrate, "-avoid_negative_ts", "disabled", "-f", "matroska", routedAudioURL.path]
        switch await runTrackedAV2Helper(
            ffmpegPath,
            args,
            timeout: Self.av2AudioHelperTimeout,
            additionalSensitiveValues: sourceSensitiveValues
        ) {
        case .success:
            guard Self.fileHasContent(at: routedAudioURL) else {
                return .failed("FFmpeg did not produce the routed audio output")
            }
        case .failed(let reason):
            return .failed("FFmpeg could not encode the selected audio tracks: \(reason)")
        case .cancelled:
            return .cancelled
        }
        guard operationIsCurrent() else { return .cancelled }
        guard let routedStreams = await audioStreamProvider(routedAudioURL),
              !routedStreams.isEmpty else {
            guard operationIsCurrent() else { return .cancelled }
            return .failed("Could not inspect the routed audio output")
        }
        guard operationIsCurrent() else { return .cancelled }
        guard routedStreams.count == plannedTrackCount else {
            return .failed("Expected \(plannedTrackCount) routed audio tracks, but FFmpeg produced \(routedStreams.count)")
        }

        let opusPadding: [[Int64]]?
        if codec == .opus {
            guard let routedData = try? Data(contentsOf: routedAudioURL, options: .mappedIfSafe),
                  let padding = AV2AudioPacketTiming.discardPadding(inMatroska: routedData),
                  padding.count == plannedTrackCount else {
                return .failed("Could not preserve Opus encoder padding from the routed audio output")
            }
            opusPadding = padding
        } else {
            opusPadding = nil
        }

        var tracks: [MatroskaMuxer.AudioTrack] = []
        for trackIndex in routedStreams.indices {
            guard operationIsCurrent() else { return .cancelled }
            let elementaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("av2audio_\(UUID().uuidString).\(codec.intermediateExtension)")
            defer { Self.cleanupTempFile(at: elementaryURL, label: "AV2 mux audio track") }
            let timingURL = elementaryURL.appendingPathExtension("framecrc")
            defer { Self.cleanupTempFile(at: timingURL, label: "AV2 mux audio timing") }
            var extractionArguments = [
                "-y", "-nostdin", "-hide_banner", "-copyts", "-i", routedAudioURL.path,
                "-map", "0:a:\(trackIndex)", "-vn", "-c:a", "copy"
            ]
            extractionArguments += codec == .opus ? ["-f", "ogg"] : ["-f", "adts"]
            extractionArguments += [elementaryURL.path]
            // A second copy output records packet PTS in the same extraction pass. Elementary
            // AAC/Ogg files alone cannot carry the source-track offset or internal timestamp gaps.
            extractionArguments += [
                "-map", "0:a:\(trackIndex)", "-vn", "-c:a", "copy",
                "-avoid_negative_ts", "disabled", "-f", "framecrc", timingURL.path
            ]
            let extractionResult = await runTrackedAV2Helper(
                ffmpegPath,
                extractionArguments,
                timeout: Self.av2AudioHelperTimeout,
                additionalSensitiveValues: sourceSensitiveValues
            )
            if case .cancelled = extractionResult {
                return .cancelled
            }
            guard case .success = extractionResult,
                  Self.fileHasContent(at: elementaryURL),
                  let parsedTrack = Self.parseAV2MuxAudioTrack(elementaryURL, codec: codec),
                  let manifest = try? String(contentsOf: timingURL, encoding: .utf8),
                  let track = AV2AudioPacketTiming.applying(
                    manifest: manifest, to: parsedTrack, discardPaddingNanoseconds: opusPadding?[trackIndex]
                  ) else {
                if case .failed(let reason) = extractionResult {
                    return .failed("Could not packetize routed audio track \(trackIndex + 1): \(reason)")
                }
                return .failed("Could not packetize routed audio track \(trackIndex + 1)")
            }
            tracks.append(track)
        }
        return .tracks(tracks)
    }

    static func av2MuxAudioRoutingArguments(
        inputIndex: Int,
        audioRoutingConfig: AudioRoutingConfig?,
        defaultAudioStreamIndices: [Int]
    ) -> [String] {
        guard let audioRoutingConfig else {
            return defaultAudioStreamIndices.flatMap { ["-map", "\(inputIndex):a:\($0)"] }
        }

        let arguments = AudioRoutingService.buildFFmpegMapArguments(config: audioRoutingConfig)
        let inputPlaceholder = "{av2-audio-input}"
        return arguments.map { argument in
            argument
                .replacingOccurrences(of: "[0:a:", with: "[\(inputPlaceholder):a:")
                .replacingOccurrences(of: "0:a:", with: "\(inputIndex):a:")
                .replacingOccurrences(of: inputPlaceholder, with: String(inputIndex))
        }
    }

    private static func parseAV2MuxAudioTrack(
        _ url: URL,
        codec: AV2AudioCodec
    ) -> MatroskaMuxer.AudioTrack? {
        switch codec {
        case .aac:
            guard let parsed = parseADTS(url) else { return nil }
            let info = MatroskaMuxer.AudioTrackInfo(codecID: "A_AAC", codecPrivate: parsed.asc, sampleRate: parsed.sampleRate, channels: parsed.channels)
            return MatroskaMuxer.AudioTrack(
                info: info,
                frames: parsed.frames.map { MatroskaMuxer.AudioFrame(data: $0, durationSamples: 1024) }
            )
        case .opus:
            guard let parsed = parseOggOpus(url) else { return nil }
            // Opus always runs on a 48 kHz timestamp clock in Matroska. CodecDelay carries the
            // encoder pre-skip; SeekPreRoll is the standard 80 ms.
            let codecDelayNs = Int64((Double(parsed.preSkip) * 1_000_000_000.0 / 48000.0).rounded())
            let info = MatroskaMuxer.AudioTrackInfo(
                codecID: "A_OPUS", codecPrivate: parsed.codecPrivate, sampleRate: 48000, channels: parsed.channels,
                codecDelayNs: codecDelayNs, seekPreRollNs: 80_000_000
            )
            return MatroskaMuxer.AudioTrack(info: info, frames: parsed.frames)
        }
    }

    /// Parses an Ogg-Opus stream into Opus packets (with per-packet sample durations from each TOC
    /// byte), plus the `OpusHead` CodecPrivate, pre-skip and channel count from the identification
    /// header. Reassembles packets across Ogg segment/page boundaries.
    private static func parseOggOpus(_ url: URL) -> (frames: [MatroskaMuxer.AudioFrame], codecPrivate: Data, preSkip: Int, channels: Int)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)
        var packets: [[UInt8]] = []
        var partial: [UInt8] = []
        var off = 0
        while off + 27 <= bytes.count {
            guard bytes[off] == 0x4F, bytes[off + 1] == 0x67, bytes[off + 2] == 0x67, bytes[off + 3] == 0x53 else { break } // "OggS"
            let nsegs = Int(bytes[off + 26])
            let segStart = off + 27
            guard segStart + nsegs <= bytes.count else { break }
            let segTable = Array(bytes[segStart..<(segStart + nsegs)])
            var bi = segStart + nsegs
            let bodyLen = segTable.reduce(0) { $0 + Int($1) }
            guard bi + bodyLen <= bytes.count else { break }
            for lace in segTable {
                let len = Int(lace)
                partial.append(contentsOf: bytes[bi..<(bi + len)])
                bi += len
                if lace < 255 { packets.append(partial); partial = [] } // packet boundary
            }
            off = bi
        }
        // packet 0 = OpusHead, packet 1 = OpusTags, packets 2… = audio
        guard packets.count >= 3, packets[0].starts(with: Array("OpusHead".utf8)) else { return nil }
        let head = packets[0]
        let channels = head.count > 9 ? Int(head[9]) : 2
        let preSkip = head.count > 11 ? Int(head[10]) | (Int(head[11]) << 8) : 0
        let frames = packets[2...].map { MatroskaMuxer.AudioFrame(data: Data($0), durationSamples: opusPacketSamples($0)) }
        guard !frames.isEmpty else { return nil }
        return (frames, Data(head), preSkip, channels)
    }

    /// Number of 48 kHz samples a single Opus packet decodes to, from its TOC byte (and, for
    /// code 3, the following frame-count byte).
    private static func opusPacketSamples(_ packet: [UInt8]) -> Int {
        guard let toc = packet.first else { return 960 }
        // Frame size (samples @ 48 kHz) indexed by the 5-bit config (TOC >> 3).
        let frameSizes = [
            480, 960, 1920, 2880,   // 0–3   SILK NB  10/20/40/60 ms
            480, 960, 1920, 2880,   // 4–7   SILK MB
            480, 960, 1920, 2880,   // 8–11  SILK WB
            480, 960,               // 12–13 Hybrid SWB 10/20 ms
            480, 960,               // 14–15 Hybrid FB  10/20 ms
            120, 240, 480, 960,     // 16–19 CELT NB  2.5/5/10/20 ms
            120, 240, 480, 960,     // 20–23 CELT WB
            120, 240, 480, 960,     // 24–27 CELT SWB
            120, 240, 480, 960,     // 28–31 CELT FB
        ]
        let config = Int(toc >> 3)
        let frameSize = config < frameSizes.count ? frameSizes[config] : 960
        let code = Int(toc & 0x03)
        var frameCount = 1
        switch code {
        case 0: frameCount = 1
        case 1, 2: frameCount = 2
        case 3: frameCount = packet.count > 1 ? Int(packet[1] & 0x3F) : 1
        default: frameCount = 1
        }
        return frameSize * max(1, frameCount)
    }

    /// Runs a one-shot AV2 helper through the shared subprocess boundary. The actor-owned task
    /// keeps row cancellation and conversion supersession connected to the runner even though
    /// the outer conversion task itself is not cancelled by `ConversionManager`.
    private func runTrackedAV2Helper(
        _ path: String,
        _ arguments: [String],
        timeout: Duration,
        additionalSensitiveValues: Set<String> = []
    ) async -> AV2HelperRunResult {
        let taskID = UUID()
        let runner = subprocessRunner
        let task = Task {
            await Self.$runningSubprocessID.withValue(taskID) {
                await Self.runAV2Helper(
                    executablePath: path,
                    arguments: arguments,
                    timeout: timeout,
                    additionalSensitiveValues: additionalSensitiveValues,
                    subprocessRunner: runner
                )
            }
        }
        currentAV2HelperTask?.cancel()
        currentAV2HelperTask = task
        currentAV2HelperTaskID = taskID

        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        let resolvedResult: AV2HelperRunResult = if task.isCancelled || Task.isCancelled {
            .cancelled
        } else {
            result
        }
        if currentAV2HelperTaskID == taskID {
            currentAV2HelperTask = nil
            currentAV2HelperTaskID = nil
        }
        return resolvedResult
    }

    static func runAV2Helper(
        executablePath: String,
        arguments: [String],
        timeout: Duration,
        additionalSensitiveValues: Set<String> = [],
        subprocessRunner: any SubprocessRunning = SubprocessRunner()
    ) async -> AV2HelperRunResult {
        let privateValues = Set(
            arguments.filter { $0.hasPrefix("/") } + [executablePath]
        ).union(additionalSensitiveValues)
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: executablePath),
            arguments: arguments,
            timeout: timeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: av2HelperDiagnosticCaptureLimit,
            sensitiveValues: privateValues
        )

        func failureReason(_ base: String, diagnostic: String = "") -> String {
            let safeDiagnostic = request.redactedDiagnostic(diagnostic)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return safeDiagnostic.isEmpty ? base : "\(base): \(safeDiagnostic)"
        }

        do {
            let result = try await subprocessRunner.run(request)
            guard result.succeeded else {
                return .failed(reason: failureReason(
                    "tool exited with status \(result.terminationStatus)",
                    diagnostic: result.standardErrorText
                ))
            }
            return .success
        } catch is CancellationError {
            return .cancelled
        } catch SubprocessRunnerError.timedOut(_, let result) {
            return .failed(reason: failureReason(
                "tool timed out",
                diagnostic: result.standardErrorText
            ))
        } catch {
            return .failed(reason: failureReason(
                "failed to start tool",
                diagnostic: error.localizedDescription
            ))
        }
    }

    /// Scans an avmenc-written WebM for the `V_AV2` track's `CodecPrivate` (`0x63A2`) payload.
    private static func extractMatroskaCodecPrivate(fromWebM url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let needle = Data("V_AV2".utf8)
        guard let r = data.range(of: needle) else { return nil }
        // Find the CodecPrivate element id (0x63 0xA2) shortly after the CodecID value.
        var i = r.upperBound
        let limit = min(data.count - 1, i + 16)
        var found = -1
        while i < limit {
            if data[i] == 0x63 && data[i + 1] == 0xA2 { found = i; break }
            i += 1
        }
        guard found >= 0 else { return nil }
        let sizeIdx = found + 2
        guard sizeIdx < data.count else { return nil }
        // Decode the size VINT (CodecPrivate is tiny, but parse it properly).
        let first = data[sizeIdx]
        var marker: UInt8 = 0x80
        var len = 1
        while marker != 0 && (first & marker) == 0 { marker >>= 1; len += 1 }
        guard marker != 0, sizeIdx + len <= data.count else { return nil }
        var value = UInt64(first & (marker &- 1))
        for k in 1..<len { value = (value << 8) | UInt64(data[sizeIdx + k]) }
        let payloadStart = sizeIdx + len
        guard value > 0, value < 256, payloadStart + Int(value) <= data.count else { return nil }
        return data.subdata(in: payloadStart..<(payloadStart + Int(value)))
    }

    static func adtsChannelCount(forConfiguration configuration: UInt8) -> Int? {
        AV2AACParser.channelCount(forConfiguration: configuration)
    }

    private static func parseADTS(_ url: URL) -> (frames: [Data], asc: Data, sampleRate: Double, channels: Int)? {
        guard let data = try? Data(contentsOf: url), let track = AV2AACParser.parse(data) else { return nil }
        return (track.frames, track.audioSpecificConfig, track.sampleRate, track.channels)
    }

    /// Returns true if a Matroska/WebM file carries an AV2 video track (CodecID `V_AV2`). Scans the
    /// file head, where the Tracks element lives, so it's cheap and won't false-positive on normal
    /// `.mkv` files. Used to route AV2-in-Matroska sources through the avmdec decode front-end.
    static func matroskaContainsAV2(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_000_000) else { return false }
        return data.range(of: Data("V_AV2".utf8)) != nil
    }

    /// Rewrites `-map 0:a…` / `-map 0:s…` to input 1 (leaving `-map 0:v…` on input 0). Used when an
    /// AV2 Matroska source is decoded via avmdec on input 0 (video) with the original file added as
    /// input 1 (audio/subtitles).
    static func redirectAudioSubtitleMapsToSecondInput(_ args: [String]) -> [String] {
        var out = args
        var i = 0
        while i + 1 < out.count {
            if out[i] == "-map" {
                let value = out[i + 1]
                if value.hasPrefix("0:a") || value.hasPrefix("0:s") {
                    out[i + 1] = "1:" + value.dropFirst(2)
                }
            }
            i += 1
        }
        return out
    }
}
