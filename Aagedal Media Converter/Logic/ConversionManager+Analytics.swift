// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Post-conversion quality analytics.

import Foundation
import SwiftUI
import OSLog

extension ConversionManager {
    // MARK: - Quality Analytics

    /// Runs quality analytics for a completed conversion
    func runAnalytics(
        for itemID: UUID,
        sourceURL: URL,
        encodedURL: URL,
        followUp: ConversionFollowUp,
        droppedFiles: Binding<[VideoItem]>
    ) async {
        let settings = analyticsSettings.analyticsSnapshot()
        let enabledMetrics = settings.enabledMetrics
        let vmafModel = settings.vmafModel

        guard !enabledMetrics.isEmpty else {
            await MainActor.run {
                if let index = followUp.analyticsIndex(in: droppedFiles.wrappedValue) {
                    droppedFiles.wrappedValue[index].analyticsStatus = .notQueued
                    droppedFiles.wrappedValue[index].analyticsOperationID = nil
                }
            }
            return
        }

        // Revalidate the reservation after dispatch.
        let beganAttempt = await MainActor.run {
            guard let idx = followUp.analyticsIndex(in: droppedFiles.wrappedValue),
                  droppedFiles.wrappedValue[idx].analyticsEnabled else { return false }
            return true
        }
        guard beganAttempt else { return }

        do {
            let results = try await analyticsService.runAnalytics(
                sourceFile: sourceURL,
                encodedFile: encodedURL,
                sourceRange: followUp.sourceRange,
                enabledMetrics: enabledMetrics,
                vmafModel: vmafModel,
                ssimulacra2MaxFrames: settings.ssimulacra2MaxFrames,
                comparisonResolution: settings.comparisonResolution,
                operationID: followUp.analyticsOperationID
            ) { metric, progressValue in
                Task { @MainActor in
                    if let idx = followUp.analyticsIndex(in: droppedFiles.wrappedValue) {
                        droppedFiles.wrappedValue[idx].analyticsStatus = .running(metric: metric, progress: progressValue)
                        droppedFiles.wrappedValue[idx].analyticsProgress = progressValue
                    }
                }
            }

            let durationSeconds = await MainActor.run {
                droppedFiles.wrappedValue.first(where: { $0.id == itemID })?.durationSeconds ?? 0
            }

            let analyticsResults = AnalyticsResults(
                sourceFileName: sourceURL.lastPathComponent,
                encodedFileName: encodedURL.lastPathComponent,
                metrics: results,
                timestamp: Date(),
                durationSeconds: durationSeconds
            )

            await MainActor.run {
                guard let idx = followUp.analyticsIndex(in: droppedFiles.wrappedValue) else { return }
                droppedFiles.wrappedValue[idx].analyticsStatus = .completed
                droppedFiles.wrappedValue[idx].analyticsOperationID = nil
                droppedFiles.wrappedValue[idx].analyticsResults = analyticsResults
                droppedFiles.wrappedValue[idx].analyticsProgress = 1.0
                AnalyticsExporter.autoExportIfEnabled(results: analyticsResults, encodedFileURL: encodedURL, settings: settings.autoExport)
            }

            logger.info("Quality analytics completed for \(encodedURL.lastPathComponent, privacy: .public)")

        } catch {
            await MainActor.run {
                if let idx = followUp.analyticsIndex(in: droppedFiles.wrappedValue) {
                    droppedFiles.wrappedValue[idx].analyticsOperationID = nil
                    if case AnalyticsError.cancelled = error {
                        droppedFiles.wrappedValue[idx].analyticsStatus = .notQueued
                        return
                    }
                    droppedFiles.wrappedValue[idx].analyticsStatus = .failed(error.localizedDescription)
                }
            }
            logger.error("Quality analytics failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Resolves an item's reported `outputURL` to the file Quality Analytics should ingest.
    /// DCP / IMF presets store the package working folder as `outputURL` (so the queue UI
    /// can show package size and Reveal-in-Finder lands in the right place), but FFmpeg
    /// can't read a folder. For those presets, return the wrapped video essence MXF inside
    /// the package. Returns `nil` if the package is missing the expected MXF.
    nonisolated func resolveAnalyticsSourceURL(for outputURL: URL, preset: ExportPreset) -> URL? {
        let fm = FileManager.default
        switch preset {
        case .dcp:
            // DCP: <packageFolder>/<isdcfFolder>/j2c_<UUID>.mxf
            guard let entries = try? fm.contentsOfDirectory(
                at: outputURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return nil }
            let subfolders = entries.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            for folder in subfolders {
                if let inner = try? fm.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ), let videoMXF = inner.first(where: {
                    $0.lastPathComponent.hasPrefix("j2c_") && $0.pathExtension.lowercased() == "mxf"
                }) {
                    return videoMXF
                }
            }
            return nil
        case .imfJ2K, .imfProRes:
            // IMF: <packageFolder>/video_<UUID>.mxf
            guard let entries = try? fm.contentsOfDirectory(
                at: outputURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return nil }
            return entries.first(where: {
                $0.lastPathComponent.hasPrefix("video_") && $0.pathExtension.lowercased() == "mxf"
            })
        default:
            return outputURL
        }
    }
}
