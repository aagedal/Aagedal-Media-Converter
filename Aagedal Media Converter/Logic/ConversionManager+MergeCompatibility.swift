// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Merge compatibility checks and conformance analysis facades.

import Foundation
import OSLog

extension ConversionManager {
    func evaluateMergeCompatibility(
        for items: [VideoItem],
        preset: ExportPreset,
        metadataTimeout: Duration = BoundedVideoMetadataProbe.defaultTimeout,
        metadataProbe: @escaping @Sendable (URL) async throws -> VideoMetadata = {
            try await VideoMetadataService.shared.metadata(for: $0)
        }
    ) async -> MergeCompatibilityResult {
        lastMergeMetadata = [:]
        let waitingItems = MergeCompatibilityPolicy.eligibleItems(items)
        mergeLogger.debug("Evaluating merge compatibility for \(waitingItems.count) waiting clips")
        guard waitingItems.count >= 2 else {
            mergeLogger.debug("Merge incompatible: insufficient items (\(waitingItems.count))")
            return .insufficientItems(waitingItems.count)
        }

        var resolvedMetadata: [UUID: VideoMetadata] = [:]
        for item in waitingItems {
            if Task.isCancelled { return .cancelled }

            if let metadata = item.metadata {
                resolvedMetadata[item.id] = metadata
                continue
            }

            do {
                let metadata = try await BoundedVideoMetadataProbe.metadata(
                    for: item.url,
                    timeout: metadataTimeout,
                    probe: metadataProbe
                )
                resolvedMetadata[item.id] = metadata
            } catch is CancellationError {
                return .cancelled
            } catch {
                mergeLogger.debug("Merge incompatible: metadata unavailable for \(item.name, privacy: .public) – \(error.localizedDescription, privacy: .public)")
                return .metadataUnavailable(item)
            }
        }

        // Populate metadata early so it's available even when clips are incompatible
        // (needed for conformance merge reference picker in the UI)
        lastMergeMetadata = resolvedMetadata

        logMetadataSummary(for: waitingItems, metadata: resolvedMetadata)
        let result = MergeCompatibilityPolicy.checkMergeCompatibility(
            items: waitingItems,
            metadata: resolvedMetadata
        )
        mergeLogger.debug("Merge compatibility: \(result.tooltip, privacy: .public)")
        return result
    }

    private func logMetadataSummary(for items: [VideoItem], metadata: [UUID: VideoMetadata]) {
        for item in items {
            guard let data = metadata[item.id] else { continue }
            let video = data.primaryVideoStream
            let audio = data.audioStreams.first
            mergeLogger.debug(
                "Clip \(item.name, privacy: .public): videoStreams=\(data.videoStreams.count) videoCodec=\(video?.codec ?? "none", privacy: .public) resolution=\(video?.width ?? 0)x\(video?.height ?? 0) par=\(video?.pixelAspectRatio?.stringValue ?? "n/a", privacy: .public) frameRate=\(video?.frameRate?.stringValue ?? "n/a", privacy: .public) audioCodec=\(audio?.codec ?? "none", privacy: .public) channels=\(self.describeInt(audio?.channels), privacy: .public) sampleRate=\(self.describeInt(audio?.sampleRate), privacy: .public)"
            )
        }
    }

    private func describeInt(_ value: Int?) -> String {
        value.map(String.init) ?? "nil"
    }

    typealias MergeCompatibilityResult = MergeCompatibilityPolicy.MergeCompatibilityResult

    /// Compatibility facade for callers that already have metadata loaded.
    static func checkMergeCompatibility(
        items: [VideoItem],
        metadata: [UUID: VideoMetadata]
    ) -> MergeCompatibilityResult {
        MergeCompatibilityPolicy.checkMergeCompatibility(items: items, metadata: metadata)
    }

    static func groupByCompatibility(
        items: [VideoItem],
        metadata: [UUID: VideoMetadata]
    ) -> [[VideoItem]] {
        MergeCompatibilityPolicy.groupByCompatibility(items: items, metadata: metadata)
    }

    /// Exposes the metadata gathered during the last merge compatibility check.
    /// Available even when clips are incompatible — used by conformance merge UI.
    func getLastMergeMetadata() -> [UUID: VideoMetadata] {
        return lastMergeMetadata
    }

    static func analyzeConformance(
        items: [VideoItem],
        referenceItemID: UUID,
        metadata: [UUID: VideoMetadata]
    ) -> [ConformanceAnalysis] {
        MergeCompatibilityPolicy.analyzeConformance(
            items: items,
            referenceItemID: referenceItemID,
            metadata: metadata
        )
    }
}
