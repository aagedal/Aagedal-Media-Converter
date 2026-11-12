// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Post-conversion subtitle generation: Whisper, Parakeet, Nemotron and OCR.

import Foundation
import SwiftUI
import OSLog

extension ConversionManager {
    // MARK: - Subtitle Generation

    /// Generates subtitles for a completed conversion
    func generateSubtitles(
        for itemID: UUID,
        inputURL: URL,
        followUp: ConversionFollowUp,
        droppedFiles: Binding<[VideoItem]>
    ) async {
        logger.info("[subtitle-trigger] post-encode Whisper for item \(itemID, privacy: .public) inputURL=\(inputURL.lastPathComponent, privacy: .public)")
        let settings = transcriptionSettings.transcriptionSnapshot()
        let model = settings.whisperModel
        let language = settings.whisperLanguage

        let operationID = followUp.subtitleOperationID
        // The completion callback reserved this token before dispatching work.
        let beganAttempt = await MainActor.run {
            followUp.canBeginSubtitles(in: droppedFiles.wrappedValue)
        }
        guard beganAttempt else { return }

        // Verify model is downloaded
        guard WhisperModelManager.shared.isModelDownloaded(model) else {
            await MainActor.run {
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .failed("Model not downloaded")
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }
            return
        }

        do {
            let outputDir = inputURL.deletingLastPathComponent()

            let audioStreamIndex = droppedFiles.wrappedValue.first(where: { $0.id == itemID })?.selectedAudioStreamIndex
            let srtURL = try await WhisperService.shared.generateSubtitles(
                inputFile: inputURL,
                outputDirectory: outputDir,
                model: model,
                language: language,
                operationID: operationID,
                audioStreamIndex: audioStreamIndex,
                fasterTranscription: settings.whisperFasterTranscription,
                publicationIsCurrent: {
                    followUp.canBeginSubtitles(in: droppedFiles.wrappedValue)
                }
            ) { [weak self] whisperProgress in
                Task { @MainActor in
                    guard let _ = self else { return }
                    if let idx = followUp.index(in: droppedFiles.wrappedValue),
                       droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                        switch whisperProgress.stage {
                        case .extractingAudio:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .extractingAudio
                        case .transcribing:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .generating(progress: whisperProgress.percentage)
                        case .complete:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .completed
                        case .failed(let error):
                            droppedFiles.wrappedValue[idx].subtitleStatus = .failed(error)
                        default:
                            break
                        }
                        droppedFiles.wrappedValue[idx].subtitleProgress = whisperProgress.percentage
                    }
                }
            }

            let isCurrentAttempt = await MainActor.run { () -> Bool in
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .completed
                    droppedFiles.wrappedValue[idx].subtitleFilePath = srtURL
                    droppedFiles.wrappedValue[idx].subtitleProgress = 1.0
                    return true
                }
                return false
            }
            guard isCurrentAttempt else { return }

            logger.info("Subtitles generated: \(srtURL.lastPathComponent, privacy: .public)")

            // Embed SRT into the output file if enabled
            if settings.embedSubtitles {
                await embedSubtitles(
                    srtURL: srtURL,
                    into: inputURL,
                    itemID: itemID,
                    operationID: operationID,
                    followUp: followUp,
                    droppedFiles: droppedFiles
                )
            }

            await MainActor.run {
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }

        } catch WhisperServiceError.cancelled {
            await MainActor.run {
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .notQueued
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }
        } catch {
            await MainActor.run {
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .failed(error.localizedDescription)
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }
            logger.error("Subtitle generation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Parakeet Subtitle Generation

    /// Generates subtitles for a completed conversion using parakeet-mlx
    func generateParakeetSubtitles(
        for itemID: UUID,
        inputURL: URL,
        followUp: ConversionFollowUp,
        droppedFiles: Binding<[VideoItem]>
    ) async {
        logger.info("[subtitle-trigger] post-encode Parakeet for item \(itemID, privacy: .public) inputURL=\(inputURL.lastPathComponent, privacy: .public)")
        let settings = transcriptionSettings.transcriptionSnapshot()
        let model = settings.parakeetModel
        let language = settings.parakeetLanguage

        let operationID = followUp.subtitleOperationID
        // The completion callback reserved this token before dispatching work.
        let beganAttempt = await MainActor.run {
            followUp.canBeginSubtitles(in: droppedFiles.wrappedValue)
        }
        guard beganAttempt else { return }

        do {
            let outputDir = inputURL.deletingLastPathComponent()

            let audioStreamIndex = droppedFiles.wrappedValue.first(where: { $0.id == itemID })?.selectedAudioStreamIndex
            let srtURL = try await ParakeetService.shared.generateSubtitles(
                inputFile: inputURL,
                outputDirectory: outputDir,
                model: model,
                language: language,
                operationID: operationID,
                audioStreamIndex: audioStreamIndex,
                publicationIsCurrent: {
                    followUp.canBeginSubtitles(in: droppedFiles.wrappedValue)
                }
            ) { [weak self] parakeetProgress in
                Task { @MainActor in
                    guard let _ = self else { return }
                    if let idx = followUp.index(in: droppedFiles.wrappedValue),
                       droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                        switch parakeetProgress.stage {
                        case .extractingAudio:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .extractingAudio
                        case .transcribing:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .generating(progress: parakeetProgress.percentage)
                        case .complete:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .completed
                        case .failed(let error):
                            droppedFiles.wrappedValue[idx].subtitleStatus = .failed(error)
                        }
                        droppedFiles.wrappedValue[idx].subtitleProgress = parakeetProgress.percentage
                    }
                }
            }

            let isCurrentAttempt = await MainActor.run { () -> Bool in
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .completed
                    droppedFiles.wrappedValue[idx].subtitleFilePath = srtURL
                    droppedFiles.wrappedValue[idx].subtitleProgress = 1.0
                    return true
                }
                return false
            }
            guard isCurrentAttempt else { return }

            logger.info("Parakeet subtitles generated: \(srtURL.lastPathComponent, privacy: .public)")

            // Embed SRT into the output file if enabled
            if settings.embedSubtitles {
                await embedSubtitles(
                    srtURL: srtURL,
                    into: inputURL,
                    itemID: itemID,
                    operationID: operationID,
                    followUp: followUp,
                    droppedFiles: droppedFiles
                )
            }

            await MainActor.run {
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }

        } catch ParakeetServiceError.cancelled {
            await MainActor.run {
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .notQueued
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }
        } catch {
            await MainActor.run {
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .failed(error.localizedDescription)
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }
            logger.error("Parakeet subtitle generation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func generateNemotronSubtitles(
        for itemID: UUID,
        inputURL: URL,
        followUp: ConversionFollowUp,
        droppedFiles: Binding<[VideoItem]>
    ) async {
        logger.info("[subtitle-trigger] post-encode Nemotron for item \(itemID, privacy: .public) inputURL=\(inputURL.lastPathComponent, privacy: .public)")
        let settings = transcriptionSettings.transcriptionSnapshot()
        let model = AppConstants.defaultNemotronModel
        let language = settings.nemotronLanguage

        let operationID = followUp.subtitleOperationID
        // The completion callback reserved this token before dispatching work.
        let beganAttempt = await MainActor.run {
            followUp.canBeginSubtitles(in: droppedFiles.wrappedValue)
        }
        guard beganAttempt else { return }

        do {
            let outputDir = inputURL.deletingLastPathComponent()

            let audioStreamIndex = droppedFiles.wrappedValue.first(where: { $0.id == itemID })?.selectedAudioStreamIndex
            let srtURL = try await NemotronService.shared.generateSubtitles(
                inputFile: inputURL,
                outputDirectory: outputDir,
                model: model,
                language: language,
                operationID: operationID,
                audioStreamIndex: audioStreamIndex,
                publicationIsCurrent: {
                    followUp.canBeginSubtitles(in: droppedFiles.wrappedValue)
                }
            ) { [weak self] nemotronProgress in
                Task { @MainActor in
                    guard let _ = self else { return }
                    if let idx = followUp.index(in: droppedFiles.wrappedValue),
                       droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                        switch nemotronProgress.stage {
                        case .extractingAudio:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .extractingAudio
                        case .transcribing:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .generating(progress: nemotronProgress.percentage)
                        case .complete:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .completed
                        case .failed(let error):
                            droppedFiles.wrappedValue[idx].subtitleStatus = .failed(error)
                        }
                        droppedFiles.wrappedValue[idx].subtitleProgress = nemotronProgress.percentage
                    }
                }
            }

            let isCurrentAttempt = await MainActor.run { () -> Bool in
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .completed
                    droppedFiles.wrappedValue[idx].subtitleFilePath = srtURL
                    droppedFiles.wrappedValue[idx].subtitleProgress = 1.0
                    return true
                }
                return false
            }
            guard isCurrentAttempt else { return }

            logger.info("Nemotron subtitles generated: \(srtURL.lastPathComponent, privacy: .public)")

            // Embed SRT into the output file if enabled
            if settings.embedSubtitles {
                await embedSubtitles(
                    srtURL: srtURL,
                    into: inputURL,
                    itemID: itemID,
                    operationID: operationID,
                    followUp: followUp,
                    droppedFiles: droppedFiles
                )
            }

            await MainActor.run {
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }

        } catch NemotronServiceError.cancelled {
            await MainActor.run {
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .notQueued
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }
        } catch {
            await MainActor.run {
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .failed(error.localizedDescription)
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }
            logger.error("Nemotron subtitle generation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - OCR Subtitle Generation

    /// Converts bitmap subtitle stream in the source MKV to SRT using Tesseract OCR.
    /// Saves the SRT alongside the encoded output file.
    func generateOCRSubtitles(
        for itemID: UUID,
        sourceURL: URL,
        outputURL: URL,
        metadata: VideoMetadata?,
        followUp: ConversionFollowUp,
        droppedFiles: Binding<[VideoItem]>
    ) async {
        logger.info("[subtitle-trigger] post-encode OCR for item \(itemID, privacy: .public) sourceURL=\(sourceURL.lastPathComponent, privacy: .public)")
        let settings = ocrSettings.ocrSnapshot()
        // Identify the chosen (or first) bitmap subtitle stream
        let chosenStreamIndex = droppedFiles.wrappedValue.first(where: { $0.id == itemID })?.selectedBitmapSubtitleStreamIndex
        // FFprobe-style + Matroska container IDs (SwiftExif's MKV reader surfaces the latter).
        let bitmapCodecs: Set<String> = ["pgssub", "hdmv_pgs_subtitle", "dvd_subtitle", "dvdsub", "s_hdmv/pgs", "s_vobsub"]
        guard let stream = metadata?.subtitleStreams.first(where: {
            if let chosen = chosenStreamIndex { return $0.index == chosen }
            return bitmapCodecs.contains($0.codec?.lowercased() ?? "")
        }) else {
            await MainActor.run {
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == followUp.subtitleOperationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .failed("No bitmap subtitle stream found")
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }
            return
        }

        let streamIndex = stream.index ?? 0
        let codec = stream.codec ?? "pgssub"

        // Language: stream language wins (ISO 639-2; both engines accept it).
        // Otherwise fall back to the engine-specific user preference.
        let language = settings.language(forStreamLanguage: stream.languageCode)

        let operationID = followUp.subtitleOperationID
        let beganAttempt = await MainActor.run {
            followUp.canBeginSubtitles(in: droppedFiles.wrappedValue)
        }
        guard beganAttempt else { return }

        do {
            // Save SRT alongside the encoded output (mirrors Whisper behaviour)
            let outputDir = outputURL.deletingLastPathComponent()
            let srtURL = try await TesseractService.shared.generateSubtitles(
                sourceFile: sourceURL,
                outputDirectory: outputDir,
                operationID: operationID,
                subtitleStreamIndex: streamIndex,
                codec: codec,
                language: language,
                engineKind: settings.engine,
                sourceRange: followUp.sourceRange,
                publicationIsCurrent: {
                    followUp.canBeginSubtitles(in: droppedFiles.wrappedValue)
                }
            ) { [weak self] ocrProgress in
                Task { @MainActor in
                    guard let _ = self else { return }
                    if let idx = followUp.index(in: droppedFiles.wrappedValue),
                       droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                        switch ocrProgress.stage {
                        case .extractingTrack:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .extractingAudio
                        case .parsingFrames:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .extractingAudio
                        case .recognizing:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .generating(progress: ocrProgress.percentage)
                        case .complete:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .completed
                        case .failed(let error):
                            droppedFiles.wrappedValue[idx].subtitleStatus = .failed(error)
                        case .writingSRT:
                            droppedFiles.wrappedValue[idx].subtitleStatus = .generating(progress: ocrProgress.percentage)
                        }
                        droppedFiles.wrappedValue[idx].subtitleProgress = ocrProgress.percentage
                    }
                }
            }

            let isCurrentAttempt = await MainActor.run { () -> Bool in
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .completed
                    droppedFiles.wrappedValue[idx].subtitleFilePath = srtURL
                    droppedFiles.wrappedValue[idx].subtitleProgress = 1.0
                    return true
                }
                return false
            }
            guard isCurrentAttempt else { return }

            logger.info("OCR subtitles generated: \(srtURL.lastPathComponent, privacy: .public)")

            // Embed SRT into the output file if enabled
            if settings.embedSubtitles {
                await embedSubtitles(
                    srtURL: srtURL,
                    into: outputURL,
                    itemID: itemID,
                    operationID: operationID,
                    followUp: followUp,
                    droppedFiles: droppedFiles
                )
            }

            await MainActor.run {
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }

        } catch TesseractServiceError.cancelled {
            await MainActor.run {
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .notQueued
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }
        } catch {
            await MainActor.run {
                if let idx = followUp.index(in: droppedFiles.wrappedValue),
                   droppedFiles.wrappedValue[idx].subtitleOperationID == operationID {
                    droppedFiles.wrappedValue[idx].subtitleStatus = .failed(error.localizedDescription)
                    droppedFiles.wrappedValue[idx].subtitleOperationID = nil
                }
            }
            logger.error("OCR subtitle generation failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
