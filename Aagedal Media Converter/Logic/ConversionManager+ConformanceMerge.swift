// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Conformance merge: re-encoding mismatched clips to a shared target before merging.

import Foundation
import SwiftUI
import OSLog

extension ConversionManager {
    // MARK: - Conformance Merge

    /// Re-encodes a single clip to match the conformance target format.
    private func prepareConformedClip(
        for item: VideoItem,
        target: ConformanceTarget,
        batchID: UUID
    ) async -> URL? {
        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else {
            mergeLogger.error("FFmpeg binary not found while preparing conformed clip for \(item.name, privacy: .public)")
            return nil
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("conformed_\(UUID().uuidString).\(target.containerExtension)")

        let arguments = FFMPEGCommandBuilder.buildConformanceArguments(
            inputURL: item.url,
            outputURL: tempURL,
            target: target,
            trimStart: item.trimStart,
            trimEnd: item.trimEnd
        )

        mergeLogger.info("Conforming \(item.name, privacy: .public) to \(target.formatSummary, privacy: .public)")
        let success = await runMergePreparationFFmpeg(
            at: ffmpegPath,
            arguments: arguments,
            outputURL: tempURL,
            itemID: item.id,
            batchID: batchID,
            context: "conform \(item.name)"
        )
        if success {
            return tempURL
        } else {
            try? FileManager.default.removeItem(at: tempURL)
            return nil
        }
    }

    /// Prepares merge segments with conformance re-encoding for mismatched clips.
    private func prepareConformanceMergeSegments(
        from items: [VideoItem],
        durationLookup: [UUID: Double],
        target: ConformanceTarget,
        metadata: [UUID: VideoMetadata],
        batchID: UUID,
        statusUpdate: @MainActor @Sendable (String) -> Void
    ) async -> ([MergeSegment], [URL], Double?)? {
        var segments: [MergeSegment] = []
        var temporaryFiles: [URL] = []
        var totalDuration: Double = 0

        for (index, item) in items.enumerated() {
            guard !Task.isCancelled, isMergePreparationActive(batchID) else {
                cleanupTemporaryFiles(temporaryFiles)
                return nil
            }

            let segmentDuration = resolveSegmentDuration(
                for: item, baseDuration: durationLookup[item.id], hasTrim: hasActiveTrim(item)
            ) ?? item.durationSeconds
            totalDuration += segmentDuration

            // Check if this item matches the reference format
            let analysis = ConversionManager.analyzeConformance(
                items: [item],
                referenceItemID: target.referenceItemID,
                metadata: metadata
            ).first

            let needsConformance = analysis?.needsConformance ?? true

            if needsConformance || hasActiveTrim(item) {
                // Decode trimmed clips too, so the requested cut survives conformance.
                // Re-encode to match reference (trim applied in same pass)
                await statusUpdate("Conforming clip \(index + 1) of \(items.count): \(item.name)")
                guard let conformedURL = await prepareConformedClip(
                    for: item,
                    target: target,
                    batchID: batchID
                ) else {
                    cleanupTemporaryFiles(temporaryFiles)
                    return nil
                }
                segments.append(MergeSegment(
                    timelineMarkers: item.timelineMarkers,
                    itemID: item.id, originalURL: item.url, preparedURL: conformedURL,
                    trimStart: item.trimStart, trimEnd: item.trimEnd,
                    isTemporary: true, duration: segmentDuration, isConformed: true
                ))
                temporaryFiles.append(conformedURL)
            } else {
                // Already matches, no trim — use original
                segments.append(MergeSegment(
                    timelineMarkers: item.timelineMarkers,
                    itemID: item.id, originalURL: item.url, preparedURL: item.url,
                    trimStart: nil, trimEnd: nil,
                    isTemporary: false, duration: segmentDuration, isConformed: false
                ))
            }
        }

        return (segments, temporaryFiles, totalDuration)
    }

    /// Builds a conformance merge plan where mismatched clips are re-encoded to match the reference.
    func buildConformanceMergePlan(
        from items: [VideoItem],
        metadata: [UUID: VideoMetadata],
        referenceItemID: UUID,
        outputFolder: String,
        groupName: String? = nil,
        batchID: UUID,
        statusUpdate: @MainActor @Sendable (String) -> Void
    ) async -> MergePlan? {
        let settings = preparationSettingsProvider(.streamCopy)
        guard isMergePreparationActive(batchID) else { return nil }
        let waitingItems = items.filter { $0.status == .waiting }
        guard waitingItems.count >= 2 else { return nil }

        guard let refMeta = metadata[referenceItemID],
              let refItem = waitingItems.first(where: { $0.id == referenceItemID }) else {
            mergeLogger.error("Conformance reference item not found")
            return nil
        }

        guard var target = ConformanceTarget.from(metadata: refMeta, url: refItem.url) else {
            mergeLogger.error("Failed to build conformance target from reference metadata")
            return nil
        }
        // Fix the referenceItemID (factory uses UUID() placeholder)
        target = ConformanceTarget(
            referenceItemID: referenceItemID,
            referenceURL: target.referenceURL,
            videoCodec: target.videoCodec,
            width: target.width, height: target.height,
            frameRate: target.frameRate,
            pixelFormat: target.pixelFormat,
            pixelAspectRatio: target.pixelAspectRatio,
            isInterlaced: target.isInterlaced,
            audioCodec: target.audioCodec,
            audioChannels: target.audioChannels,
            audioSampleRate: target.audioSampleRate,
            containerExtension: target.containerExtension
        )

        // Check that the reference codec is encodable
        if FFMPEGCommandBuilder.ffmpegVideoEncoder(for: target.videoCodec) == nil {
            mergeLogger.error("Cannot encode to codec '\(target.videoCodec, privacy: .public)' — unsupported for conformance")
            return nil
        }

        let orderedWaitingItems = waitingItems
        let itemIDs = orderedWaitingItems.map { $0.id }
        let durationLookup = buildDurationLookup(for: orderedWaitingItems, metadata: metadata)

        guard let (segments, temporaryFiles, totalDuration) = await prepareConformanceMergeSegments(
            from: orderedWaitingItems,
            durationLookup: durationLookup,
            target: target,
            metadata: metadata,
            batchID: batchID,
            statusUpdate: statusUpdate
        ) else {
            return nil
        }

        guard let listFileURL = createConcatListFile(for: segments) else {
            cleanupTemporaryFiles(temporaryFiles)
            return nil
        }

        let firstItem = orderedWaitingItems[0]
        let baseName = groupName ?? firstItem.comment
        let resolvedOutputFolder: String
        if let url = URL(string: outputFolder) {
            resolvedOutputFolder = url.path
        } else {
            resolvedOutputFolder = outputFolder
        }

        let outputBaseName = FileNameProcessor.processFileName(baseName.isEmpty ? firstItem.name : baseName, settings: settings.fileName)
        let baseOutputURL = URL(fileURLWithPath: resolvedOutputFolder).appendingPathComponent(outputBaseName)

        let sourceHasAudio = target.audioCodec != nil

        return MergePlan(
            itemIDs: itemIDs,
            listFileURL: listFileURL,
            outputBaseURL: baseOutputURL,
            outputFolder: outputFolder,
            preset: .streamCopy, // Concat pass always uses stream copy
            settings: settings,
            comment: firstItem.comment,
            metadataEditorSettings: firstItem.metadataEditorSettings,
            includeDateTag: firstItem.includeDateTag,
            waveformRequest: nil,
            synthesizedVideoRequest: nil,
            segments: segments,
            temporaryClipURLs: temporaryFiles,
            totalDuration: totalDuration,
            hasExecuted: false,
            sourceHasAudio: sourceHasAudio,
            conformanceTarget: target
        )
    }
}
