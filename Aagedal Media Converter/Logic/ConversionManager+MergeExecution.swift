// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Running a prepared merge plan through FFmpeg and publishing its result.

import Foundation
import SwiftUI
import OSLog

extension ConversionManager {
    func executeMergePlan(droppedFiles: Binding<[VideoItem]>, batchID: UUID) async {
        guard activeBatchID == batchID, let plan = mergePlan else { return }

        let callbackOwnership = self.callbackOwnership
        let inputItems = plan.itemIDs.compactMap { id in
            droppedFiles.wrappedValue.first(where: { $0.id == id && $0.status == .waiting })
        }

        guard inputItems.count == plan.itemIDs.count else {
            cleanupMergeArtifacts(for: plan)
            mergePlan = nil
            await convertNextFile(
                droppedFiles: droppedFiles,
                outputFolder: plan.outputFolder,
                preset: plan.preset,
                batchID: batchID
            )
            return
        }

        let previousSubtitleOperations = inputItems.flatMap { item in
            Set([followUpOwnership[item.id]?.value?.id, item.subtitleOperationID].compactMap { $0 })
                .map { (item.id, $0) }
        }
        let mergeFollowUpOwnership = Dictionary(uniqueKeysWithValues: inputItems.map {
            ($0.id, beginFollowUpOwnership(for: $0.id))
        })
        for item in inputItems {
            await UploadManager.shared.cancelUploadBeforeConversion(itemID: item.id)
            guard isBatchActive(batchID) else { return }
        }
        for (itemID, operationID) in previousSubtitleOperations {
            await cancelPreviousSubtitleOperation(itemID: itemID, operationID: operationID)
            guard isBatchActive(batchID) else { return }
        }

        let didBegin = await MainActor.run {
            guard callbackOwnership.isActive else { return false }
            let indices = ConversionQueueState.callbackIndices(
                for: inputItems, in: droppedFiles.wrappedValue, status: .waiting
            )
            guard indices.count == inputItems.count else { return false }
            for index in indices {
                droppedFiles.wrappedValue[index].status = .converting
                droppedFiles.wrappedValue[index].progress = 0
                droppedFiles.wrappedValue[index].eta = nil
            }
            return true
        }
        guard isBatchActive(batchID) else { return }
        guard didBegin, let primaryInput = inputItems.first else {
            cleanupMergeArtifacts(for: plan)
            mergePlan = nil
            await convertNextFile(
                droppedFiles: droppedFiles,
                outputFolder: plan.outputFolder,
                preset: plan.preset,
                batchID: batchID
            )
            return
        }

        let av2Settings = plan.settings.av2
        let dcpSettings = plan.settings.dcp
        let imfSettings = plan.settings.imf
        let audioOnlySettings = plan.settings.audioOnly
        let codecSettings = plan.settings.codec
        let outputExtension = av2Settings?.container.fileExtension
            ?? audioOnlySettings?.format.fileExtension
            ?? codecSettings?.outputExtension(for: plan.segments.first?.originalURL)
            ?? plan.preset.outputExtension(for: plan.segments.first?.originalURL)
        var cutMarkers: [StitchCutMarker] = []
        var markerWarning: String?
        var chapterMetadataURL: URL?
        var chapterMetadataTitles: [String] = []
        if plan.settings.exportStitchMarkers {
            do {
                var media: [StitchMarkerMedia] = []
                var sourceTimecodes: [String?] = []
                var sourceHasChapters = false
                for segment in plan.segments {
                    var prepared = try await StitchMarkerMedia.read(segment.preparedURL)
                    guard isBatchActive(batchID) else { return }
                    sourceHasChapters = sourceHasChapters || prepared.hasChapterMetadata
                    var original = prepared
                    if segment.isTemporary {
                        original = try await StitchMarkerMedia.read(segment.originalURL)
                        guard isBatchActive(batchID) else { return }
                        sourceHasChapters = sourceHasChapters || original.hasChapterMetadata
                        if prepared.chapters.isEmpty, !original.chapters.isEmpty {
                            prepared = StitchMarkerMedia(
                                duration: prepared.duration, frameRate: prepared.frameRate, timecode: prepared.timecode,
                                chapters: StitchMarkerExport.retainedChapters(original.chapters,
                                    trimStart: segment.trimStart ?? 0, duration: prepared.duration),
                                hasChapterMetadata: original.hasChapterMetadata)
                        }
                    }
                    sourceTimecodes.append(StitchMarkerExport.sourceTimecode(original, trimStart: segment.trimStart ?? 0))
                    media.append(prepared)
                }
                cutMarkers = try StitchMarkerExport.cuts(
                    names: plan.segments.map { $0.originalURL.lastPathComponent },
                    durations: media.map(\.duration), sourceTimecodes: sourceTimecodes
                )
                var noteMarkers: [StitchCutMarker] = []
                var markerOffset = 0.0
                for (segment, source) in zip(plan.segments, media) {
                    noteMarkers += StitchMarkerExport.notes(segment.timelineMarkers,
                        trimStart: segment.trimStart ?? 0, trimEnd: segment.trimEnd,
                        duration: source.duration, offset: markerOffset)
                    markerOffset += source.duration
                }
                cutMarkers = StitchMarkerExport.chapters(from: cutMarkers + noteMarkers)
                // Pin concat's scheduling to the same measured segment durations
                // used for marker placement, including Stream Copy trim preroll.
                let concat = zip(plan.segments, media).map { segment, source in
                    let path = segment.preparedURL.path.replacingOccurrences(of: "'", with: "'\\''")
                    return "file '\(path)'\nduration \(FFMPEGCommandBuilder.ffmpegTimeString(from: source.duration))"
                }.joined(separator: "\n")
                try concat.write(to: plan.listFileURL, atomically: true, encoding: .utf8)
                if StitchMarkerExport.supportedChapterExtensions.contains(outputExtension.lowercased()),
                   plan.waveformRequest == nil, plan.synthesizedVideoRequest == nil {
                    let replace = sourceHasChapters ? await StitchMarkerExport.shouldReplaceExistingChapters() : true
                    guard isBatchActive(batchID) else { return }
                    let preserved = StitchMarkerExport.concatenateChapters(media)
                    let chapters = replace ? cutMarkers : StitchMarkerExport.chapters(from: preserved + noteMarkers)
                    if sourceHasChapters && !replace && preserved.isEmpty {
                        throw NSError(domain: "StitchMarkers", code: 1, userInfo: [NSLocalizedDescriptionKey:
                            "Existing chapter metadata could not be preserved after preparation. Automatic chapter replacement was skipped."])
                    }
                    let text = try StitchMarkerExport.chapterMetadata(chapters)
                    let url = plan.listFileURL.deletingPathExtension().appendingPathExtension("ffmetadata")
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    chapterMetadataURL = url
                    chapterMetadataTitles = chapters.map { $0.title.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ") }
                }
            } catch {
                markerWarning = "Clip markers: " + error.localizedDescription
            }
        }
        let resolvedOutput = OSAllocatedUnfairLock(initialState: plan.outputBaseURL.appendingPathExtension(outputExtension))
        let nativeMergeFellBack = OSAllocatedUnfairLock(initialState: false)

        let customInputs = ["-f", "concat", "-safe", "0", "-i", plan.listFileURL.path]

        let mergeOutputArguments: [String]? = plan.preset == .streamCopy ? [
            "-map", "-0:d?",
            "-map", "-0:t?",
            "-ignore_unknown"
        ] : nil

        // For merges, always use the first clip's timecode as the master
        // If no timecode config is set, create one with preserveSource mode
        let mergeTimecodeConfig: TimecodeConfig? = {
            if let existing = primaryInput.timecodeConfig {
                return existing
            }
            // Auto-create a preserveSource config for merges to use first clip as master
            return TimecodeConfig(mode: .preserveSource)
        }()

        // For merges, use the first clip's audio routing as the master
        // This applies the same audio routing to the entire concatenated stream
        let mergeAudioRoutingConfig = primaryInput.audioRoutingConfig

        // For merges, use the first clip's crop settings as the master
        // The crop filter will apply to the entire concatenated stream
        // Note: Crop requires re-encoding and won't work with Stream Copy preset
        let mergeCropConfig = primaryInput.cropConfig

        let mergeRequest = ConversionRequest(
            inputURL: primaryInput.url,
            outputURL: plan.outputBaseURL,
            preset: plan.preset,
            outputURLResolved: { url in resolvedOutput.withLock { $0 = url } },
            nativeMXFMergeFellBack: { nativeMergeFellBack.withLock { $0 = true } },
            chapterMetadataURL: chapterMetadataURL,
            chapterMetadataTitles: chapterMetadataTitles,
            comment: plan.comment,
            metadataEditorSettings: plan.metadataEditorSettings,
            includeDateTag: plan.includeDateTag,
            expectedDuration: plan.totalDuration,
            videoFrameRate: primaryInput.metadata?.primaryVideoStream?.frameRate?.value,
            audioRoutingConfig: mergeAudioRoutingConfig,
            cropConfig: mergeCropConfig,
            timecodeConfig: mergeTimecodeConfig,
            // The media is already trimmed in the prepared segments. Offset only
            // the preserved metadata, without trimming the concatenated input again.
            timecodeTrimStart: plan.settings.ignoreStitchTimecodeTrimOffset ? 0 : primaryInput.effectiveTrimStart,
            isMuted: plan.preset == .streamCopy ? false : primaryInput.isMuted,
            waveformRequest: plan.waveformRequest,
            synthesizedVideoRequest: plan.synthesizedVideoRequest,
            waveformBackgroundImageURL: primaryInput.waveformBackgroundImageURL,
            customInputArguments: customInputs,
            additionalOutputArguments: mergeOutputArguments,
            nativeMXFMerge: plan.nativeMXFMerge
        )

        // Throttle UI updates to ~4 Hz to avoid SwiftUI re-render storms during encoding
        let mergeUIThrottle = OSAllocatedUnfairLock(initialState: Date.distantPast)
        let capturedMarkers = cutMarkers
        let capturedMarkerWarning = markerWarning
        let capturedChapterURL = chapterMetadataURL
        await ffmpegConverter.convert(
            request: mergeRequest,
            av2Settings: av2Settings,
            dcpSettings: dcpSettings,
            imfSettings: imfSettings,
            audioOnlySettings: audioOnlySettings,
            imageSequenceSettings: plan.settings.imageSequence,
            codecSettings: codecSettings,
            subtitleSettings: plan.settings.subtitles,
            commentSettings: plan.settings.comment,
            progressUpdate: { progress, status in
                let now = Date()
                let shouldUpdate = mergeUIThrottle.withLock { last -> Bool in
                    guard progress < 1.0 else { return true }
                    guard now.timeIntervalSince(last) >= 0.25 else { return false }
                    last = now
                    return true
                }
                guard shouldUpdate else { return }
                let isDuration = progressIsDuration(status)
                Task { @MainActor in
                    ConversionQueueState.applyProgress(
                        progress, message: status, isDuration: isDuration,
                        for: inputItems, ownership: callbackOwnership,
                        in: &droppedFiles.wrappedValue
                    )
                }
            },
            completion: { [weak self] success, errorReason in
                Task { [weak self] in
                    guard let self else { return }
                    await self.handleMergeCompletion(
                        plan: plan,
                        outputExtension: outputExtension,
                        resolvedOutputURL: resolvedOutput.withLock { $0 },
                        nativeMergeFellBack: nativeMergeFellBack.withLock { $0 },
                        cutMarkers: capturedMarkers,
                        markerWarning: capturedMarkerWarning,
                        chapterMetadataURL: capturedChapterURL,
                        inputItems: inputItems,
                        callbackOwnership: callbackOwnership,
                        followUpOwnership: mergeFollowUpOwnership,
                        success: success,
                        errorReason: errorReason,
                        droppedFiles: droppedFiles,
                        batchID: batchID
                    )
                }
            }
        )
    }

    func createConcatListFile(for segments: [MergeSegment]) -> URL? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("concat_\(UUID().uuidString).txt")
        let content = segments.map { segment -> String in
            let escapedPath = segment.preparedURL.path.replacingOccurrences(of: "'", with: "'\\''")
            return "file '\(escapedPath)'"
        }.joined(separator: "\n")

        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            return nil
        }
    }

    func cleanupMergeArtifacts(for plan: MergePlan) {
        try? FileManager.default.removeItem(at: plan.listFileURL.deletingPathExtension().appendingPathExtension("ffmetadata"))
        do {
            try FileManager.default.removeItem(at: plan.listFileURL)
        } catch {
            mergeLogger.warning("Failed to remove concat list file \(plan.listFileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        cleanupTemporaryFiles(plan.temporaryClipURLs)
    }

    private func handleMergeCompletion(
        plan: MergePlan,
        outputExtension: String,
        resolvedOutputURL: URL,
        nativeMergeFellBack: Bool,
        cutMarkers: [StitchCutMarker],
        markerWarning: String?,
        chapterMetadataURL: URL?,
        inputItems: [VideoItem],
        callbackOwnership: ConversionCallbackOwnership,
        followUpOwnership: [UUID: ConversionCallbackOwnership],
        success: Bool,
        errorReason: String?,
        droppedFiles: Binding<[VideoItem]>,
        batchID: UUID
    ) async {
        defer { if let chapterMetadataURL { try? FileManager.default.removeItem(at: chapterMetadataURL) } }
        guard isBatchActive(batchID) else { return }

        let finalURL = resolvedOutputURL
        var exportWarning = markerWarning
        var edlURL: URL?
        if success, !cutMarkers.isEmpty {
            do {
                let output = try await StitchMarkerMedia.read(finalURL)
                guard isBatchActive(batchID) else { return }
                guard let rate = output.frameRate else { throw StitchMarkerError.invalidRate }
                let text = try StitchMarkerExport.resolveEDL(title: finalURL.lastPathComponent + " Timeline Markers",
                                                            markers: try StitchMarkerExport.coalescedForEDL(cutMarkers, frameRate: rate), frameRate: rate, startTimecode: output.timecode)
                let access = SecurityScopedBookmarkManager.shared.startAccessing(url: finalURL.deletingLastPathComponent())
                defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
                edlURL = try StitchMarkerExport.writeEDL(text, alongside: finalURL)
            } catch { exportWarning = "Clip markers: " + error.localizedDescription }
        }
        if success, let exportWarning {
            mergeLogger.warning("\(exportWarning, privacy: .public)")
            await StitchMarkerExport.presentWarning(exportWarning, outputURL: finalURL)
        }
        let fallbackNotice = nativeMergeFellBack
            ? String(localized: "bmx couldn't merge the MXF clips, so they were merged with FFmpeg and camera metadata was not kept.")
            : nil
        let mergeNotice = success ? plan.mergeNotice ?? fallbackNotice : nil
        if let mergeNotice { mergeLogger.notice("\(mergeNotice, privacy: .public)") }
        let warnings = [exportWarning, mergeNotice].compactMap { $0 }
        let completedWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")

        // Capture file size - try with security-scoped access
        var outputFileSizeBytes: Int64?
        if success {
            let outputFolderURL = finalURL.deletingLastPathComponent()
            let access = SecurityScopedBookmarkManager.shared.startAccessing(url: outputFolderURL)
            defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
            if let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path),
               let fileSize = attrs[.size] as? Int64 {
                outputFileSizeBytes = fileSize
            }
        }

        await MainActor.run {
            guard callbackOwnership.isActive else { return }
            for index in ConversionQueueState.callbackIndices(for: inputItems, in: droppedFiles.wrappedValue) {
                if droppedFiles.wrappedValue[index].status == .converting {
                    droppedFiles.wrappedValue[index].status = success ? .done : .failed
                    droppedFiles.wrappedValue[index].progress = success ? 1.0 : 0.0
                    droppedFiles.wrappedValue[index].outputURL = success ? finalURL : nil
                    droppedFiles.wrappedValue[index].outputSidecarURLs = success ? [edlURL].compactMap { $0 } : []
                    droppedFiles.wrappedValue[index].outputFileSizeBytes = outputFileSizeBytes
                    droppedFiles.wrappedValue[index].conversionError = success ? completedWarning : errorReason
                    droppedFiles.wrappedValue[index].eta = nil
                    droppedFiles.wrappedValue[index].statusMessage = nil
                }
            }
        }

        guard isBatchActive(batchID) else { return }
        let indices = ConversionQueueState.callbackIndices(
            for: inputItems, in: droppedFiles.wrappedValue, status: .done
        ).filter { droppedFiles.wrappedValue[$0].outputURL == finalURL }
        let completedItems = indices.map { droppedFiles.wrappedValue[$0] }
        let followUps = completedItems.compactMap { item -> ConversionFollowUp? in
            guard let ownership = followUpOwnership[item.id] else { return nil }
            return ConversionFollowUp(item: item, ownership: ownership)
        }

        // Post-export verification: check output has expected streams
        if success, plan.sourceHasAudio {
            Task {
                if let result = await FFMPEGProbeService.verifyOutputStreams(for: finalURL) {
                    if result.audioStreamCount == 0 {
                        mergeLogger.error("POST-EXPORT WARNING: Source clips had audio but output '\(finalURL.lastPathComponent, privacy: .public)' has no audio streams")
                        await MainActor.run {
                            if let firstIdx = followUps.lazy.compactMap({
                                $0.index(in: droppedFiles.wrappedValue)
                            }).first {
                                droppedFiles.wrappedValue[firstIdx].conversionError =
                                    "Warning: Audio missing in output. Source clips had audio but the merged file has none."
                            }
                        }
                    }
                }
            }
        }

        // Trigger upload for merged output (upload once since all items share the same file)
        if let itemID = ConversionUploadFollowUp.itemID(
            afterSuccess: success, mergedIndices: indices, items: droppedFiles.wrappedValue
        ) {
            if let followUp = followUps.first(where: { $0.itemID == itemID }) {
                Task { @MainActor in
                    guard let index = followUp.index(in: droppedFiles.wrappedValue),
                          ConversionUploadFollowUp.itemID(afterSuccess: true, item: droppedFiles.wrappedValue[index]) != nil else { return }
                    UploadManager.shared.startUpload(itemID: itemID)
                }
            }
        }

        // Trigger analytics for merged output (once since all items share the same file).
        // Merge always uses .streamCopy, so the resolver is a no-op for this path today —
        // we route through it anyway to avoid a regression if merge ever produces packages.
        if success,
           let firstAnalyticsIdx = indices.first(where: { droppedFiles.wrappedValue[$0].analyticsEnabled }),
           let outputURL = droppedFiles.wrappedValue[firstAnalyticsIdx].outputURL,
           let followUp = followUps.first(where: { $0.itemID == droppedFiles.wrappedValue[firstAnalyticsIdx].id }) {
            let itemID = droppedFiles.wrappedValue[firstAnalyticsIdx].id
            let sourceURL = droppedFiles.wrappedValue[firstAnalyticsIdx].url
            await MainActor.run {
                followUp.reserveAnalytics(in: &droppedFiles.wrappedValue)
            }
            if let analyticsURL = self.resolveAnalyticsSourceURL(for: outputURL, preset: plan.preset) {
                Task {
                    await self.runAnalytics(
                        for: itemID,
                        sourceURL: sourceURL,
                        encodedURL: analyticsURL,
                        followUp: followUp,
                        droppedFiles: droppedFiles
                    )
                }
            } else {
                await MainActor.run {
                    if let idx = followUp.analyticsIndex(in: droppedFiles.wrappedValue) {
                        droppedFiles.wrappedValue[idx].analyticsStatus = .failed("Could not locate wrapped video essence in package")
                        droppedFiles.wrappedValue[idx].analyticsOperationID = nil
                    }
                }
            }
        }

        guard isBatchActive(batchID) else { return }
        cleanupMergeArtifacts(for: plan)
        mergePlan = nil

        if isConverting, activeBatchID == batchID {
            await convertNextFile(
                droppedFiles: droppedFiles,
                outputFolder: plan.outputFolder,
                preset: plan.preset,
                batchID: batchID
            )
        }

        Task { @MainActor in
            if success {
                SoundManager.shared.playSuccess()
            } else {
                SoundManager.shared.playError()
            }
        }
    }
}
