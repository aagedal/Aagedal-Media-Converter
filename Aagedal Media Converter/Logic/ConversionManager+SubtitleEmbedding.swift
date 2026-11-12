// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Embedding generated or attached subtitles into finished outputs.

import Foundation
import SwiftUI
import OSLog

extension ConversionManager {
    // MARK: - Subtitle Embedding

    /// Muxes a generated SRT file into the output video as a subtitle track using FFmpeg.
    /// The original output file is replaced in-place; the external SRT is kept.
    func embedSubtitles(
        srtURL: URL,
        into videoURL: URL,
        itemID: UUID,
        operationID: UUID?,
        followUp: ConversionFollowUp,
        droppedFiles: Binding<[VideoItem]>
    ) async {
        guard let ffmpegPath = ffmpegPathProvider() else {
            await MainActor.run {
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   operationID == nil || droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .failed("FFmpeg is unavailable")
                }
            }
            logger.error("FFmpeg binary not found for subtitle embedding")
            return
        }

        let beganCurrentAttempt = await MainActor.run { () -> Bool in
            if let idx = followUp.index(in: droppedFiles.wrappedValue),
               operationID == nil || droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                droppedFiles.wrappedValue[idx].subtitleStatus = .embedding
                return true
            }
            return false
        }
        guard beganCurrentAttempt else { return }

        let attempt = startSubtitleEmbedding(
            ffmpegPath: ffmpegPath,
            srtURL: srtURL,
            videoURL: videoURL,
            itemID: itemID,
            operationID: operationID
        )
        defer { finishSubtitleEmbedding(itemID: itemID, attemptID: attempt.id) }

        do {
            try await withTaskCancellationHandler {
                try await attempt.task.value
            } onCancel: {
                attempt.task.cancel()
            }
            guard subtitleEmbeddingAttempts[itemID]?.id == attempt.id else {
                try? FileManager.default.removeItem(at: attempt.stagedURL)
                return
            }

            let didPublish = try await MainActor.run { () throws -> Bool in
                try attempt.ownership.whileCurrent {
                    try SubtitleEmbeddingCommit.publishIfCurrent(
                        temporaryURL: attempt.stagedURL,
                        destinationURL: videoURL,
                        isCurrent: {
                            guard let idx = followUp.index(in: droppedFiles.wrappedValue) else {
                                return false
                            }
                            return operationID == nil ||
                                droppedFiles.wrappedValue[idx].subtitleOperationID == operationID
                        },
                        didPublish: {
                            if let idx = followUp.index(in: droppedFiles.wrappedValue) {
                                droppedFiles.wrappedValue[idx].subtitleStatus = .completed
                            }
                        }
                    )
                } ?? false
            }
            guard didPublish else {
                try? FileManager.default.removeItem(at: attempt.stagedURL)
                return
            }
            logger.info("Subtitles embedded into \(videoURL.lastPathComponent, privacy: .public)")
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: attempt.stagedURL)
            guard subtitleEmbeddingAttempts[itemID]?.id == attempt.id else { return }
            await MainActor.run {
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   operationID == nil || droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .notQueued
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: attempt.stagedURL)
            guard subtitleEmbeddingAttempts[itemID]?.id == attempt.id else { return }
            let message = subtitleEmbeddingErrorMessage(error)
            logger.error("Subtitle embedding error: \(message, privacy: .public)")

            await MainActor.run {
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   operationID == nil || droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .failed(message)
                }
            }
        }
    }

    /// Standalone subtitle embedding for manually attached files (no queue binding needed).
    /// Called from the context menu "Attach Subtitle File" action when the item is already done.
    func embedSubtitlesForAttachedFile(
        srtURL: URL,
        videoURL: URL,
        itemID: UUID
    ) async {
        guard let ffmpegPath = ffmpegPathProvider() else {
            logger.error("FFmpeg binary not found for subtitle embedding")
            return
        }

        let attempt = startSubtitleEmbedding(
            ffmpegPath: ffmpegPath,
            srtURL: srtURL,
            videoURL: videoURL,
            itemID: itemID,
            operationID: nil
        )
        defer { finishSubtitleEmbedding(itemID: itemID, attemptID: attempt.id) }

        do {
            try await withTaskCancellationHandler {
                try await attempt.task.value
            } onCancel: {
                attempt.task.cancel()
            }
            guard subtitleEmbeddingAttempts[itemID]?.id == attempt.id else {
                try? FileManager.default.removeItem(at: attempt.stagedURL)
                return
            }

            let didPublish = try attempt.ownership.whileCurrent {
                _ = try FileManager.default.replaceItemAt(videoURL, withItemAt: attempt.stagedURL)
            } != nil
            guard didPublish else {
                try? FileManager.default.removeItem(at: attempt.stagedURL)
                return
            }
            logger.info("Subtitles embedded (attached) into \(videoURL.lastPathComponent, privacy: .public)")
        } catch {
            try? FileManager.default.removeItem(at: attempt.stagedURL)
            if error is CancellationError { return }
            let message = subtitleEmbeddingErrorMessage(error)
            logger.error("Subtitle embedding (attached) error: \(message, privacy: .public)")
        }
    }

    func cancelSubtitleEmbedding(itemID: UUID, operationID: UUID?) {
        guard let attempt = subtitleEmbeddingAttempts[itemID],
              operationID == nil || attempt.operationID == operationID else { return }
        attempt.ownership.invalidate()
        subtitleEmbeddingAttempts.removeValue(forKey: itemID)
        attempt.task.cancel()
    }

    private func startSubtitleEmbedding(
        ffmpegPath: String,
        srtURL: URL,
        videoURL: URL,
        itemID: UUID,
        operationID: UUID?
    ) -> (id: UUID, stagedURL: URL, ownership: SubtitleEmbeddingOwnership, task: Task<Void, Error>) {
        if let previousAttempt = subtitleEmbeddingAttempts[itemID] {
            previousAttempt.ownership.invalidate()
            previousAttempt.task.cancel()
        }

        let attemptID = UUID()
        let ownership = SubtitleEmbeddingOwnership()
        let ext = videoURL.pathExtension.lowercased()
        let stagedURL = videoURL.deletingLastPathComponent()
            .appendingPathComponent(".subtitle-embed-\(attemptID.uuidString).\(ext)")
        let subtitleCodec = ext == "mkv" || ext == "mka" ? "srt" : "mov_text"
        let srtStem = srtURL.deletingPathExtension().pathExtension
        let languageCode = !srtStem.isEmpty && srtStem.count <= 3 ? srtStem : nil
        let subprocess = subtitleEmbeddingSubprocess
        let task = Task {
            try await subprocess.run(
                ffmpegPath: ffmpegPath,
                srtURL: srtURL,
                videoURL: videoURL,
                stagedURL: stagedURL,
                subtitleCodec: subtitleCodec,
                languageCode: languageCode
            )
        }
        subtitleEmbeddingAttempts[itemID] = SubtitleEmbeddingAttempt(
            id: attemptID,
            operationID: operationID,
            ownership: ownership,
            task: task
        )
        return (attemptID, stagedURL, ownership, task)
    }

    private func finishSubtitleEmbedding(itemID: UUID, attemptID: UUID) {
        guard subtitleEmbeddingAttempts[itemID]?.id == attemptID else { return }
        subtitleEmbeddingAttempts.removeValue(forKey: itemID)
    }

    func cancelAllSubtitleEmbeddings() {
        let attempts = Array(subtitleEmbeddingAttempts.values)
        subtitleEmbeddingAttempts.removeAll()
        for attempt in attempts {
            attempt.ownership.invalidate()
            attempt.task.cancel()
        }
    }

    private func subtitleEmbeddingErrorMessage(_ error: Error) -> String {
        if let subprocessError = error as? SubtitleEmbeddingSubprocessError {
            return subprocessError.localizedDescription
        }
        return "Subtitle embedding could not replace the output file."
    }
}
