// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Merge planning for ConversionManager: building the merge plan, preparing
// trimmed and native-MXF segments, and the merge-preparation subprocesses.

import Foundation
import SwiftUI
import OSLog

extension ConversionManager {
    func buildMergePlan(
        from items: [VideoItem],
        preset: ExportPreset,
        outputFolder: String,
        groupName: String? = nil,
        batchID: UUID
    ) async -> MergePlan? {
        let settings = preparationSettingsProvider(preset)
        guard isMergePreparationActive(batchID),
              case .compatible = await evaluateMergeCompatibility(for: items, preset: preset),
              isMergePreparationActive(batchID) else {
            return nil
        }

        // Rows still waiting for their download have placeholder URLs.
        let waitingItems = items.filter { $0.status == .waiting && !$0.hasPendingDownload }
        guard waitingItems.count >= 2 else { return nil }

        let orderedWaitingItems = waitingItems
        let itemIDs = orderedWaitingItems.map { $0.id }

        let durationLookup = buildDurationLookup(for: orderedWaitingItems, metadata: lastMergeMetadata)
        let generatedVideoRequests = settings.generatedVideo.requests(for: orderedWaitingItems)
        let hasTrims = orderedWaitingItems.contains(where: hasActiveTrim)
        func nativeMXFMergeEligible(allowsTrimmedMerge: Bool) -> Bool {
            guard let first = orderedWaitingItems.first else { return false }
            return NativeMXFMerge.isEligible(
                preset: preset,
                outputExtension: settings.codec?.outputExtension(for: first.url) ?? preset.outputExtension(for: first.url),
                sourceURLs: orderedWaitingItems.map(\.url),
                hasTrims: hasTrims,
                allowsTrimmedMerge: allowsTrimmedMerge,
                hasGeneratedVideo: generatedVideoRequests.waveform != nil || generatedVideoRequests.synthesized != nil,
                audioRoutingCustomized: first.audioRoutingConfig?.isCustomized ?? false,
                hasManualTimecode: { if case .manual = first.timecodeConfig?.mode { return true }; return false }()
            )
        }
        var usesNativeMXFMerge = nativeMXFMergeEligible(allowsTrimmedMerge: settings.nativeMXFTrimmedMerge)
        var mergeNotice: String?
        if hasTrims, !usesNativeMXFMerge, nativeMXFMergeEligible(allowsTrimmedMerge: true) {
            mergeNotice = String(localized: "Camera metadata was not kept because clips are trimmed. Turn on “Keep camera metadata in trimmed MXF merges” in the Encoding Groups settings to keep it.")
        }

        var nativeFrameRanges: [UUID: NativeMXFMerge.FrameRange]?
        var preparedSegments: ([MergeSegment], [URL], Double?)?
        if usesNativeMXFMerge, hasTrims, let firstItem = orderedWaitingItems.first {
            let outputFolderURL = URL(fileURLWithPath: settings.outputDestination.resolveFolder(
                for: firstItem.url, defaultOutputFolder: outputFolder, presetSuffix: settings.fileNameContext.presetSuffix
            ) ?? outputFolder)
            switch await prepareNativeMXFTrimmedSegments(
                from: orderedWaitingItems, durationLookup: durationLookup,
                outputFolderURL: outputFolderURL, batchID: batchID
            ) {
            case .prepared(let segments, let temporaryFiles, let totalDuration, let ranges):
                preparedSegments = (segments, temporaryFiles, totalDuration)
                nativeFrameRanges = ranges
            case .unavailable(let reason):
                usesNativeMXFMerge = false
                mergeNotice = reason
            case .cancelled:
                return nil
            }
        }

        if preparedSegments == nil {
            preparedSegments = await prepareMergeSegments(
                from: orderedWaitingItems,
                durationLookup: durationLookup,
                decodeTrims: preset != .streamCopy && hasTrims,
                batchID: batchID
            )
        }
        guard let (segments, temporaryFiles, totalDuration) = preparedSegments else {
            return nil
        }

        guard let listFileURL = createConcatListFile(for: segments) else {
            cleanupTemporaryFiles(temporaryFiles)
            return nil
        }

        guard let firstItem = orderedWaitingItems.first else { return nil }

        let resolvedOutputFolder = settings.outputDestination.resolveFolder(
            for: firstItem.url, defaultOutputFolder: outputFolder, presetSuffix: settings.fileNameContext.presetSuffix
        ) ?? outputFolder

        // Ensure the output directory exists with proper security-scoped access
        let resolvedOutputFolderURL = URL(fileURLWithPath: resolvedOutputFolder)
        guard ensureDirectoryAccessible(at: resolvedOutputFolderURL) else {
            mergeLogger.error("Failed to access output directory for merge: \(resolvedOutputFolder)")
            cleanupTemporaryFiles(temporaryFiles)
            return nil
        }

        let fileNameSettings = settings.fileName
        let fileNameContext = settings.fileNameContext
        let mergeBaseName: String
        if let name = groupName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty {
            mergeBaseName = FileNameProcessor.processFileName(name, settings: fileNameSettings)
        } else if let override = firstItem.outputFileNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            mergeBaseName = FileNameProcessor.processFileName((override as NSString).deletingPathExtension, settings: fileNameSettings)
        } else {
            let suffixPart = fileNameSettings.includePresetSuffix ? fileNameContext.presetSuffix : ""
            mergeBaseName = FileNameProcessor.processFileName(firstItem.url.deletingPathExtension().lastPathComponent, settings: fileNameSettings)
                + suffixPart
                + "_merge"
        }
        let baseOutputURL = URL(fileURLWithPath: resolvedOutputFolder)
            .appendingPathComponent(mergeBaseName)

        let waveformRequest = generatedVideoRequests.waveform
        let synthesizedVideoRequest = generatedVideoRequests.synthesized

        // Check if any source clip has audio (for post-export verification)
        let sourceHasAudio = orderedWaitingItems.contains { item in
            if let meta = lastMergeMetadata[item.id] {
                return !(meta.audioStreams.isEmpty)
            }
            return false
        }

        let nativeMXFMerge = usesNativeMXFMerge
            ? await makeNativeMXFMergeRequest(
                items: orderedWaitingItems, segments: segments, frameRanges: nativeFrameRanges,
                ignoreTrimOffset: settings.ignoreStitchTimecodeTrimOffset
            )
            : nil
        guard isMergePreparationActive(batchID) else {
            cleanupTemporaryFiles(temporaryFiles)
            return nil
        }

        return MergePlan(
            itemIDs: itemIDs,
            listFileURL: listFileURL,
            outputBaseURL: baseOutputURL,
            outputFolder: outputFolder,
            preset: preset,
            settings: settings,
            comment: firstItem.comment,
            metadataEditorSettings: firstItem.metadataEditorSettings,
            includeDateTag: firstItem.includeDateTag,
            waveformRequest: waveformRequest,
            synthesizedVideoRequest: synthesizedVideoRequest,
            segments: segments,
            temporaryClipURLs: temporaryFiles,
            totalDuration: totalDuration,
            hasExecuted: false,
            sourceHasAudio: sourceHasAudio,
            conformanceTarget: nil,
            nativeMXFMerge: nativeMXFMerge,
            mergeNotice: mergeNotice
        )
    }

    /// Collects the Identification company and merged Sony NonRealTimeMeta for a
    /// bmxtranswrap merge. Frame counts come from the camera XML when present, so the
    /// sidecar Duration matches what bmx writes even when container durations round.
    /// `frameRanges` holds the trim of each clip (by item ID) when the segments are
    /// bmx-trimmed copies; the merged XML then counts only the frames kept.
    /// `ignoreTrimOffset` starts the merged timecode at the first source's own start
    /// instead of its trim-in point, as the FFmpeg merge path does.
    private func makeNativeMXFMergeRequest(
        items: [VideoItem],
        segments: [MergeSegment],
        frameRanges: [UUID: NativeMXFMerge.FrameRange]? = nil,
        ignoreTrimOffset: Bool = false
    ) async -> NativeMXFMergeRequest? {
        guard let first = items.first else { return nil }
        var firstInfo: String?
        for item in items {
            // Trimmed clips were checked before rewrapping. bmx would drop video it can't
            // parse (e.g. DNxHR), so those merges take the FFmpeg path without a bmx pass.
            guard frameRanges == nil || item.id == first.id else { continue }
            let info = await BMXService.shared.getMXFInfo(url: item.url)
            if item.id == first.id { firstInfo = info }
            if frameRanges == nil, let picture = info.flatMap(NativeMXFMerge.pictureTrack(fromMXFInfo:)),
               !NativeMXFMerge.isReadablePicture(essenceType: picture.essenceType) {
                mergeLogger.notice("bmx can't copy the video of \(item.name, privacy: .public); merging with FFmpeg")
                return nil
            }
        }
        var xmlSegments: [NativeMXFMerge.XMLSegment] = []
        for item in items {
            let metadata = lastMergeMetadata[item.id]
            let rate = metadata?.primaryVideoStream?.frameRate?.value ?? 0
            let xml = NativeMXFMerge.loadNonRealTimeMeta(for: item.url)
            let frames = xml.flatMap(NativeMXFMerge.durationFrames(in:)) ?? metadata?.frameCount
                ?? metadata?.duration.map { Int(($0 * rate).rounded()) } ?? 0
            let range = frameRanges?[item.id]
            let start = min(range?.start ?? 0, frames)
            // The timecode starts at the source's own start, so the first clip's LTC does too.
            let timecodeOffset = ignoreTrimOffset && item.id == first.id ? 0 : start
            let kept = min(range?.count ?? frames - start, frames - start)
            xmlSegments.append(NativeMXFMerge.XMLSegment(xml: xml, frameCount: kept, startOffset: timecodeOffset))
        }
        let mergedXML = xmlSegments.contains { $0.xml == nil || $0.frameCount <= 0 }
            ? nil : NativeMXFMerge.mergedNonRealTimeMeta(segments: xmlSegments)
        let company = firstInfo.flatMap(NativeMXFMerge.companyName(fromMXFInfo:))
            ?? (mergedXML != nil ? "Sony" : NativeMXFMerge.fallbackCompanyName)
        let trimsFirstClip = (frameRanges?[first.id]?.start ?? 0) > 0
        return NativeMXFMergeRequest(
            segmentURLs: segments.map(\.preparedURL),
            companyName: company,
            nonRealTimeMetaXML: mergedXML,
            startTimecode: ignoreTrimOffset && trimsFirstClip
                ? firstInfo.flatMap(NativeMXFMerge.startTimecode(fromMXFInfo:)) : nil
        )
    }

    private enum NativeMXFTrimmedPreparation {
        case prepared([MergeSegment], [URL], Double?, [UUID: NativeMXFMerge.FrameRange])
        /// Falls back to the FFmpeg path; the reason is shown on the merged rows.
        case unavailable(String)
        case cancelled
    }

    /// Rewraps every clip, trimmed or not, to a temporary MXF with bmx so all segments
    /// share one descriptor layout and bmx's sequence reader keeps the video track.
    private func prepareNativeMXFTrimmedSegments(
        from items: [VideoItem],
        durationLookup: [UUID: Double],
        outputFolderURL: URL,
        batchID: UUID
    ) async -> NativeMXFTrimmedPreparation {
        let fallback = String(localized: "Merged with FFmpeg instead, without camera metadata.")
        var ranges: [UUID: NativeMXFMerge.FrameRange] = [:]
        var sourceInfos: [UUID: String] = [:]
        var clips: [(fileSize: Int64, keptFraction: Double)] = []
        for item in items {
            guard isMergePreparationActive(batchID) else { return .cancelled }
            guard let info = await BMXService.shared.getMXFInfo(url: item.url),
                  let picture = NativeMXFMerge.pictureTrack(fromMXFInfo: info) else {
                return .unavailable(String(localized: "Could not read the MXF tracks of \(item.name).") + " " + fallback)
            }
            guard NativeMXFMerge.isReadablePicture(essenceType: picture.essenceType) else {
                return .unavailable(String(localized: "bmx can't copy the video format of \(item.name).") + " " + fallback)
            }
            guard NativeMXFMerge.isIntraCoded(essenceType: picture.essenceType) else {
                return .unavailable(String(localized: "\(item.name) uses Long GOP video, which can only be cut on keyframes.") + " " + fallback)
            }
            let trimmed = hasActiveTrim(item)
            guard let range = NativeMXFMerge.frameRange(
                trimStart: trimmed ? item.effectiveTrimStart : nil,
                trimEnd: trimmed ? item.trimEnd : nil,
                editRate: picture.editRate
            ) else {
                return .unavailable(String(localized: "The trim of \(item.name) is shorter than one frame.") + " " + fallback)
            }
            ranges[item.id] = range
            sourceInfos[item.id] = info
            let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? item.size
            let sourceFrames = (durationLookup[item.id] ?? 0) * picture.editRate
            let keptFrames = range.count.map(Double.init) ?? max(sourceFrames - Double(range.start), 0)
            clips.append((size, sourceFrames > 0 ? keptFrames / sourceFrames : 1))
        }

        let temporaryFolder = FileManager.default.temporaryDirectory
        let estimate = NativeMXFMerge.estimatedTemporaryBytes(clips: clips)
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeIdentifierKey]
        let temporaryVolume = try? temporaryFolder.resourceValues(forKeys: keys)
        let outputVolume = try? outputFolderURL.resourceValues(forKeys: keys)
        if let temporaryAvailable = temporaryVolume?.volumeAvailableCapacityForImportantUsage {
            let sameVolume = (temporaryVolume?.volumeIdentifier as? NSObject)
                .map { $0.isEqual(outputVolume?.volumeIdentifier) } ?? true
            if case .insufficient(let available, let required) = NativeMXFMerge.checkSpace(
                temporaryBytes: estimate,
                temporaryAvailable: temporaryAvailable,
                outputAvailable: outputVolume?.volumeAvailableCapacityForImportantUsage ?? .max,
                sameVolume: sameVolume
            ) {
                let formatter = ByteCountFormatter()
                return .unavailable(String(localized: "Keeping camera metadata in this trimmed merge needs about \(formatter.string(fromByteCount: required)) of free space, but only \(formatter.string(fromByteCount: available)) is available.") + " " + fallback)
            }
        }
        mergeLogger.info("Rewrapping \(items.count, privacy: .public) MXF clips for a trimmed merge; estimated temporary space \(estimate, privacy: .public) bytes")

        var segments: [MergeSegment] = []
        var temporaryFiles: [URL] = []
        var totalDuration: Double = 0
        for item in items {
            guard let range = ranges[item.id] else { return .cancelled }
            let tempURL = temporaryFolder.appendingPathComponent("mxf_segment_\(UUID().uuidString).mxf")
            let result = await runMergePreparationBMX(
                inputURL: item.url, outputURL: tempURL,
                arguments: NativeMXFMerge.segmentRewrapArguments(range: range),
                itemID: item.id, batchID: batchID
            )
            guard isMergePreparationActive(batchID), !result.cancelled else {
                cleanupTemporaryFiles(temporaryFiles + [tempURL].filter { FileManager.default.fileExists(atPath: $0.path) })
                return .cancelled
            }
            guard result.success else {
                cleanupTemporaryFiles(temporaryFiles)
                mergeLogger.error("bmx could not rewrap \(item.name, privacy: .public): \(result.stderr, privacy: .public)")
                return .unavailable(String(localized: "bmx could not rewrap \(item.name).") + " " + fallback)
            }
            temporaryFiles.append(tempURL)
            // bmx drops tracks it can't copy; the merge would then check against the copy.
            let segmentInfo = await BMXService.shared.getMXFInfo(url: tempURL)
            guard isMergePreparationActive(batchID) else {
                cleanupTemporaryFiles(temporaryFiles)
                return .cancelled
            }
            let sourceKinds = sourceInfos[item.id].map(NativeMXFMerge.essenceKinds(fromMXFInfo:)) ?? []
            let segmentKinds = segmentInfo.map(NativeMXFMerge.essenceKinds(fromMXFInfo:)) ?? []
            guard !sourceKinds.isEmpty, segmentKinds.sorted() == sourceKinds.sorted() else {
                cleanupTemporaryFiles(temporaryFiles)
                mergeLogger.error("bmx rewrap of \(item.name, privacy: .public) has tracks \(segmentKinds, privacy: .public), source has \(sourceKinds, privacy: .public)")
                return .unavailable(String(localized: "bmx could not copy every track of \(item.name).") + " " + fallback)
            }
            var trimStart = item.trimStart
            var trimEnd = item.trimEnd
            var duration = resolveSegmentDuration(for: item, baseDuration: durationLookup[item.id], hasTrim: hasActiveTrim(item))
            // Describe what the copy really holds if bmx moved a cut.
            if let sourceInfo = sourceInfos[item.id],
               let segmentInfo,
               let editRate = NativeMXFMerge.pictureTrack(fromMXFInfo: segmentInfo)?.editRate {
                let kept = NativeMXFMerge.keptRange(requested: range, sourceInfo: sourceInfo, segmentInfo: segmentInfo)
                ranges[item.id] = kept
                let moved = kept.start != range.start || range.count.map { $0 != kept.count } ?? false
                if moved, let count = kept.count {
                    trimStart = Double(kept.start) / editRate
                    trimEnd = Double(kept.start + count) / editRate
                    duration = Double(count) / editRate
                    mergeLogger.info("\(item.name, privacy: .public): kept frames \(kept.start, privacy: .public)+\(count, privacy: .public) for requested \(range.start, privacy: .public)+\(range.count ?? -1, privacy: .public)")
                }
            }
            totalDuration += duration ?? 0
            segments.append(MergeSegment(
                timelineMarkers: item.timelineMarkers,
                itemID: item.id,
                originalURL: item.url,
                preparedURL: tempURL,
                trimStart: trimStart,
                trimEnd: trimEnd,
                isTemporary: true,
                duration: duration,
                isConformed: false
            ))
        }
        return .prepared(segments, temporaryFiles, totalDuration > 0 ? totalDuration : nil, ranges)
    }

    private func runMergePreparationBMX(
        inputURL: URL,
        outputURL: URL,
        arguments: [String],
        itemID: UUID,
        batchID: UUID
    ) async -> BMXRewrapResult {
        guard isMergePreparationActive(batchID) else { return BMXRewrapResult(success: false, stderr: "", cancelled: true) }
        let operationID = UUID()
        let result = OSAllocatedUnfairLock<BMXRewrapResult?>(initialState: nil)
        // Cancelling this task (see `cancelMergePreparation`) stops bmxtranswrap.
        let task = Task {
            let rewrap = await BMXService.shared.mergeMXFSequence(
                inputURLs: [inputURL], outputURL: outputURL, arguments: arguments,
                operationID: operationID, progress: { _ in }
            )
            result.withLock { $0 = rewrap }
            return rewrap.success
        }
        mergePreparationTask = (operationID, itemID, task)
        _ = await task.value
        if mergePreparationTask?.id == operationID {
            mergePreparationTask = nil
        }
        return result.withLock { $0 } ?? BMXRewrapResult(success: false, stderr: "", cancelled: true)
    }

    private func prepareMergeSegments(
        from items: [VideoItem],
        durationLookup: [UUID: Double],
        decodeTrims: Bool,
        batchID: UUID
    ) async -> ([MergeSegment], [URL], Double?)? {
        var segments: [MergeSegment] = []
        var temporaryFiles: [URL] = []
        var totalDuration: Double = 0

        for item in items {
            guard isMergePreparationActive(batchID) else {
                cleanupTemporaryFiles(temporaryFiles)
                return nil
            }
            let baseDuration = durationLookup[item.id]
            let hasTrim = hasActiveTrim(item)
            let segmentDuration = resolveSegmentDuration(for: item, baseDuration: baseDuration, hasTrim: hasTrim)
            if let segmentDuration {
                totalDuration += segmentDuration
            }

            if hasTrim || decodeTrims {
                guard let trimmedURL = await prepareTrimmedClip(for: item, batchID: batchID, decodeTrim: decodeTrims) else {
                    cleanupTemporaryFiles(temporaryFiles)
                    return nil
                }
                let segment = MergeSegment(
                    timelineMarkers: item.timelineMarkers,
                    itemID: item.id,
                    originalURL: item.url,
                    preparedURL: trimmedURL,
                    trimStart: item.trimStart,
                    trimEnd: item.trimEnd,
                    isTemporary: true,
                    duration: segmentDuration,
                    isConformed: false
                )
                segments.append(segment)
                temporaryFiles.append(trimmedURL)
            } else {
                let segment = MergeSegment(
                    timelineMarkers: item.timelineMarkers,
                    itemID: item.id,
                    originalURL: item.url,
                    preparedURL: item.url,
                    trimStart: item.trimStart,
                    trimEnd: item.trimEnd,
                    isTemporary: false,
                    duration: segmentDuration,
                    isConformed: false
                )
                segments.append(segment)
            }
        }

        let resolvedTotal = totalDuration > 0 ? totalDuration : nil
        return (segments, temporaryFiles, resolvedTotal)
    }

    func buildDurationLookup(for items: [VideoItem], metadata: [UUID: VideoMetadata]) -> [UUID: Double] {
        items.reduce(into: [:]) { result, item in
            if let duration = resolveBaseDuration(for: item, metadata: metadata[item.id]), duration > 0 {
                result[item.id] = duration
            }
        }
    }

    private func resolveBaseDuration(for item: VideoItem, metadata: VideoMetadata?) -> Double? {
        if let metadataDuration = metadata?.duration, metadataDuration > 0 {
            return metadataDuration
        }
        if item.durationSeconds > 0 {
            return item.durationSeconds
        }
        return nil
    }

    func resolveSegmentDuration(for item: VideoItem, baseDuration: Double?, hasTrim: Bool) -> Double? {
        if hasTrim {
            let trimmed = max(item.trimmedDuration, 0)
            if trimmed > 0 {
                return trimmed
            }
        }
        return baseDuration
    }

    func hasActiveTrim(_ item: VideoItem) -> Bool {
        if let trimStart = item.trimStart, trimStart > 0.0005 {
            return true
        }
        if item.trimEnd != nil {
            return true
        }
        return false
    }

    private func prepareTrimmedClip(for item: VideoItem, batchID: UUID, decodeTrim: Bool = false) async -> URL? {
        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else {
            mergeLogger.error("FFmpeg binary not found while preparing trimmed clip for \(item.name, privacy: .public)")
            return nil
        }

        let fileExtension = decodeTrim ? "mkv" : (item.url.pathExtension.isEmpty ? "mp4" : item.url.pathExtension)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trimmed_\(UUID().uuidString).\(fileExtension)")

        let start = max(item.effectiveTrimStart, 0)
        let hasStartTrim = start > 0.0005
        let hasEndTrim = item.trimEnd != nil
        let duration = max(item.effectiveTrimEnd - start, 0)

        if hasEndTrim && duration <= 0.01 {
            mergeLogger.error("Invalid trim duration for \(item.name, privacy: .public). Start=\(start, privacy: .public) end=\(item.effectiveTrimEnd, privacy: .public)")
            return nil
        }

        let isMXF = !decodeTrim && fileExtension.lowercased() == "mxf"
        let avcPicture = isMXF ? await BMXService.shared.getMXFInfo(url: item.url).flatMap(AVCMXFStreamCopy.avcPicture(fromMXFInfo:)) : nil

        var arguments = ["-y"]
        // A millisecond-rounded seek can land just before a fractional-rate
        // keyframe that the timeline snapped to (for example 10/23.976 fps).
        // Stream copy must seek at or just after that point so FFmpeg chooses
        // the intended preceding sync sample rather than the previous GOP.
        let seek = !hasStartTrim ? nil : decodeTrim ? FFMPEGCommandBuilder.ffmpegTimeString(from: start)
            : String(format: "%.6f", ceil(start * 1_000_000) / 1_000_000)
        if let seek {
            arguments.append(contentsOf: ["-ss", seek])
        }

        arguments.append(contentsOf: ["-i", item.url.path])

        // Stream Copy timestamps start at the seek point. Its end cut keeps every
        // picture shown before the requested end (see `StreamCopyEndCut`).
        var endCut = StreamCopyEndCut.Cut.unknown
        if hasEndTrim && !decodeTrim {
            guard let cut = await findStreamCopyEndCut(
                for: item, ffmpegPath: ffmpegPath, seek: seek,
                end: start + duration - (seek.flatMap(Double.init) ?? 0), batchID: batchID
            ) else { return nil }
            endCut = cut
        }
        if hasEndTrim, let keptDuration = endCut.duration(requested: duration) {
            arguments.append(contentsOf: ["-t", FFMPEGCommandBuilder.ffmpegTimeString(from: keptDuration)])
        }

        if decodeTrim {
            // Prepare every segment in the same lossless format, including untrimmed
            // neighbours. Input seeking discards preroll while decoding; the final
            // requested codec is encoded only once, after concatenation.
            arguments.append(contentsOf: [
                "-map", "0:v?", "-map", "0:a?",
                "-c:v", "ffv1", "-level:v", "3", "-c:a", "pcm_f64le",
                "-fps_mode:v", "passthrough"
            ])
        } else {
            // Without -map, FFmpeg keeps one stream per type and drops every audio
            // track after the first. Carry the streams the Stream Copy merge keeps:
            // all video and audio, plus subtitles only where MP4/MOV merges map them.
            // Data streams (tmcd, MXF ANC) are dropped by the merge and can fail here.
            arguments.append(contentsOf: ["-map", "0:v?", "-map", "0:a?"])
            if ["mp4", "mov", "m4v"].contains(fileExtension.lowercased()) {
                arguments.append(contentsOf: ["-map", "0:s?"])
            }
            arguments.append(contentsOf: ["-c", "copy"])
            if let avcPicture {
                arguments.append(contentsOf: AVCMXFStreamCopy.frameRateArguments(editRate: avcPicture.editRate))
            }
        }
        var droppedVideo: [String] = []
        if hasStartTrim && !decodeTrim {
            // Open GOPs can carry leading pictures after the first copied
            // keyframe in decode order, but before it in presentation order.
            // Those pictures depend on the discarded GOP. At a concat join
            // they can decode against the preceding clip and produce corrupt
            // frames. Remove only that leading video preroll; preserve packet
            // contents, subsequent B-frame reordering, and all audio packets.
            droppedVideo.append("not(eq(pts,nopts))*lt(pts,startpts)")
        }
        if let endDrop = endCut.droppedVideo {
            droppedVideo.append(endDrop)
        }
        if !droppedVideo.isEmpty {
            arguments.append(contentsOf: ["-bsf:v", "noise=amount=0:drop='\(droppedVideo.joined(separator: "+"))'"])
        }
        arguments.append(contentsOf: ["-avoid_negative_ts", "make_zero", tempURL.path])

        let success = await runMergePreparationFFmpeg(
            at: ffmpegPath,
            arguments: arguments,
            outputURL: tempURL,
            itemID: item.id,
            batchID: batchID,
            context: "trim \(item.name)"
        )
        guard success else { return nil }
        if avcPicture != nil {
            // FFmpeg can't index Long GOP H.264 in MXF; the concat merge would read
            // this clip with timestamps running backwards. bmx rebuilds the index.
            let rewrapURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("trimmed_\(UUID().uuidString).mxf")
            let result = await runMergePreparationBMX(
                inputURL: tempURL, outputURL: rewrapURL,
                arguments: ["-t", "op1a", "--use-avc-subdesc"],
                itemID: item.id, batchID: batchID
            )
            try? FileManager.default.removeItem(at: tempURL)
            guard result.success, !result.cancelled, isMergePreparationActive(batchID) else {
                if !result.cancelled {
                    mergeLogger.error("bmx could not reindex the trimmed H.264 MXF of \(item.name, privacy: .public): \(result.stderr, privacy: .public)")
                }
                try? FileManager.default.removeItem(at: rewrapURL)
                return nil
            }
            return rewrapURL
        }
        guard hasStartTrim && isMXF else { return tempURL }

        // Dropping leading B-frames leaves MPEG-2 temporal references that FFmpeg's
        // MXF muxer turns into an invalid index. Renumber them, then remux so this
        // clip's own index matches before the concat merge reads its timestamps.
        let renumbered: Bool
        do {
            renumbered = try MXFMPEG2LeadingGOPRenumbering.renumberFirstGOP(at: tempURL)
        } catch {
            mergeLogger.error("Failed to renumber trimmed MPEG-2 pictures for \(item.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
        guard renumbered else { return tempURL }
        let remuxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trimmed_\(UUID().uuidString).mxf")
        let remuxed = await runMergePreparationFFmpeg(
            at: ffmpegPath,
            arguments: ["-y", "-i", tempURL.path, "-map", "0", "-c", "copy", remuxURL.path],
            outputURL: remuxURL,
            itemID: item.id,
            batchID: batchID,
            context: "reindex \(item.name)"
        )
        try? FileManager.default.removeItem(at: tempURL)
        return remuxed ? remuxURL : nil
    }

    /// Lists the trim's video packets and picks the first clean end at or after the
    /// requested one (see `StreamCopyEndCut`). Nil when cancelled.
    private func findStreamCopyEndCut(
        for item: VideoItem, ffmpegPath: String, seek: String?, end: Double, batchID: UUID
    ) async -> StreamCopyEndCut.Cut? {
        let listURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trim_packets_\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: listURL) }
        let listed = await runMergePreparationFFmpeg(
            at: ffmpegPath,
            arguments: StreamCopyEndCut.listingArguments(
                inputURL: item.url, seek: seek.map { ["-ss", $0] } ?? [], end: end, listURL: listURL
            ),
            outputURL: listURL, itemID: item.id, batchID: batchID, context: "list packets of \(item.name)"
        )
        guard isMergePreparationActive(batchID) else { return nil }
        let cut = StreamCopyEndCut.cut(fromListing: listed ? try? String(contentsOf: listURL, encoding: .utf8) : nil, end: end)
        if case .at(let cutEnd, let frame) = cut, cutEnd - end >= frame / 2 {
            mergeLogger.info("\(item.name, privacy: .public): Stream Copy trim ends \(cutEnd - end, privacy: .public) s after the requested end so no kept frame loses a reference")
        }
        return cut
    }

    func runMergePreparationFFmpeg(
        at executablePath: String,
        arguments: [String],
        outputURL: URL,
        itemID: UUID,
        batchID: UUID,
        context: String
    ) async -> Bool {
        guard isMergePreparationActive(batchID) else { return false }
        let operationID = UUID()
        let task = Task {
            await mergePreparationSubprocess.runFFmpeg(
                at: executablePath,
                arguments: arguments,
                outputURL: outputURL,
                context: context
            )
        }
        mergePreparationTask = (operationID, itemID, task)
        let succeeded = await task.value
        if mergePreparationTask?.id == operationID {
            mergePreparationTask = nil
        }
        guard isMergePreparationActive(batchID) else {
            try? FileManager.default.removeItem(at: outputURL)
            return false
        }
        return succeeded
    }

    func cancelMergePreparation() {
        mergePreparationTask?.task.cancel()
        mergePreparationTask = nil
    }

    func cancelMergePreparation(for itemID: UUID) {
        if let scope = mergePreparationScope, scope.itemIDs.contains(itemID) {
            invalidatedMergePreparationBatchIDs.insert(scope.batchID)
            cancelMergePreparation()
        } else if mergePreparationTask?.itemID == itemID {
            cancelMergePreparation()
        }
    }

    func isMergePreparationActive(_ batchID: UUID) -> Bool {
        isBatchActive(batchID) && !invalidatedMergePreparationBatchIDs.contains(batchID)
    }

    func beginMergePreparation(batchID: UUID, items: [VideoItem]) {
        invalidatedMergePreparationBatchIDs.remove(batchID)
        mergePreparationScope = (batchID, Set(items.filter { $0.status == .waiting }.map(\.id)))
    }

    func finishMergePreparation(batchID: UUID) {
        if mergePreparationScope?.batchID == batchID {
            mergePreparationScope = nil
        }
        invalidatedMergePreparationBatchIDs.remove(batchID)
    }

    func cleanupTemporaryFiles(_ urls: [URL]) {
        for url in urls {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                mergeLogger.warning("Failed to remove temporary file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
