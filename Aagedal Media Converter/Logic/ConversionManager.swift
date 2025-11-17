// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import AVFoundation
import Foundation
import SwiftUI

actor ConversionManager: Sendable {
    @MainActor static let shared = ConversionManager()
    private init() {}

    enum ConversionStatus {
        case waiting
        case converting
        case done
        case failed
        case cancelled
    }
    

    private var isConverting = false
    private var currentProcess: Process?
    private var ffmpegConverter = FFMPEGConverter()
    private var conversionQueue: [VideoItem] = []
    private var currentDroppedFiles: Binding<[VideoItem]>?
    private var currentOutputFolder: String?
    private var currentPreset: ExportPreset = .videoLoop
    
    // Progress tracking with Swift Concurrency
    private var progressContinuation: AsyncStream<Double>.Continuation?
    private var progressStream: AsyncStream<Double>?
    // Periodic task that yields overall progress every few seconds while converting
    private var progressTimerTask: Task<Void, Never>?
    private struct MergePlan {
        let itemIDs: [UUID]
        let listFileURL: URL
        let outputBaseURL: URL
        let outputFolder: String
        let preset: ExportPreset
        let comment: String
        let includeDateTag: Bool
        let waveformRequest: WaveformVideoRequest?
        var hasExecuted: Bool
    }
    private var mergePlan: MergePlan?
    
    func progressUpdates() -> AsyncStream<Double> {
        let stream = AsyncStream(Double.self) { continuation in
            // Store the continuation directly without using a weak self capture
            // since we're not mutating any actor state here
            let task = Task {
                self.setProgressContinuation(continuation)
            }
            
            continuation.onTermination = { _ in
                task.cancel()
                Task {
                    await self.clearProgressContinuation()
                }
            }
        }
        progressStream = stream
        return stream
    }
    
    private func setProgressContinuation(_ continuation: AsyncStream<Double>.Continuation) {
        progressContinuation = continuation
    }
    
    private func clearProgressContinuation() {
        progressContinuation = nil
    }

    // MARK: - Periodic Progress Timer
        /// Starts a periodic task that emits overall progress every 3 s
    private func startProgressTimer(droppedFiles: Binding<[VideoItem]>) {
        progressTimerTask?.cancel()
        
                progressTimerTask = Task { [weak self] in
            guard let self else { return }
            while await self.isConverting {
                await self.updateOverallProgress(droppedFiles: droppedFiles)
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            }
        }
    }

    private func buildMergePlan(
        from items: [VideoItem],
        preset: ExportPreset,
        outputFolder: String
    ) async -> MergePlan? {
        guard case .compatible = await evaluateMergeCompatibility(for: items, preset: preset) else {
            return nil
        }

        let waitingItems = items.filter { $0.status == .waiting }
        guard waitingItems.count >= 2 else { return nil }

        let orderedWaitingItems = waitingItems
        let itemIDs = orderedWaitingItems.map { $0.id }

        guard let listFileURL = createConcatListFile(for: orderedWaitingItems) else {
            return nil
        }

        guard let firstItem = orderedWaitingItems.first else { return nil }

        let baseOutputURL = URL(fileURLWithPath: outputFolder)
            .appendingPathComponent(
                FileNameProcessor.processFileName(firstItem.url.deletingPathExtension().lastPathComponent) + preset.fileSuffix
            )

        let waveformRequest: WaveformVideoRequest? = orderedWaitingItems.contains(where: { $0.requiresWaveformVideo }) ? {
            let config = AudioWaveformPreferences.loadConfig()
            return WaveformVideoRequest(
                width: Int(config.resolution.width),
                height: Int(config.resolution.height),
                backgroundHex: config.backgroundHex,
                foregroundHex: config.foregroundHex,
                normalizeAudio: config.normalizeAudio,
                style: config.style,
                frameRate: config.frameRate
            )
        }() : nil

        return MergePlan(
            itemIDs: itemIDs,
            listFileURL: listFileURL,
            outputBaseURL: baseOutputURL,
            outputFolder: outputFolder,
            preset: preset,
            comment: firstItem.comment,
            includeDateTag: firstItem.includeDateTag,
            waveformRequest: waveformRequest,
            hasExecuted: false
        )
    }

    private func executeMergePlan(droppedFiles: Binding<[VideoItem]>) async {
        guard let plan = mergePlan else { return }

        let indices: [Int] = plan.itemIDs.compactMap { id in
            droppedFiles.wrappedValue.firstIndex(where: { $0.id == id })
        }

        guard indices.count == plan.itemIDs.count else {
            cleanupMergeArtifacts(for: plan)
            mergePlan = nil
            await convertNextFile(droppedFiles: droppedFiles, outputFolder: plan.outputFolder, preset: plan.preset)
            return
        }

        await MainActor.run {
            for index in indices {
                droppedFiles.wrappedValue[index].status = .converting
                droppedFiles.wrappedValue[index].progress = 0
                droppedFiles.wrappedValue[index].eta = nil
            }
        }

        let inputItems = indices.compactMap { droppedFiles.wrappedValue[$0] }
        guard let primaryInput = inputItems.first else {
            cleanupMergeArtifacts(for: plan)
            mergePlan = nil
            return
        }

        let customInputs = ["-f", "concat", "-safe", "0", "-i", plan.listFileURL.path]

        await ffmpegConverter.convert(
            inputURL: primaryInput.url,
            outputURL: plan.outputBaseURL,
            preset: plan.preset,
            comment: plan.comment,
            includeDateTag: plan.includeDateTag,
            trimStart: nil,
            trimEnd: nil,
            waveformRequest: plan.waveformRequest,
            customInputArguments: customInputs,
            progressUpdate: { progress, eta in
                Task { @MainActor in
                    for index in indices {
                        droppedFiles.wrappedValue[index].progress = progress
                        droppedFiles.wrappedValue[index].eta = eta
                    }
                }
            }
        ) { success in
            Task { [weak self] in
                guard let self else { return }
                await self.handleMergeCompletion(
                    plan: plan,
                    indices: indices,
                    success: success,
                    droppedFiles: droppedFiles
                )
            }
        }
    }

    private func createConcatListFile(for items: [VideoItem]) -> URL? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("concat_\(UUID().uuidString).txt")
        let content = items.map { item -> String in
            let escapedPath = item.url.path.replacingOccurrences(of: "'", with: "'\\''")
            return "file '\(escapedPath)'"
        }.joined(separator: "\n")

        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            return tempURL
        } catch {
            return nil
        }
    }

    private func cleanupMergeArtifacts(for plan: MergePlan) {
        try? FileManager.default.removeItem(at: plan.listFileURL)
    }

    private func handleMergeCompletion(
        plan: MergePlan,
        indices: [Int],
        success: Bool,
        droppedFiles: Binding<[VideoItem]>
    ) async {
        let finalURL = plan.outputBaseURL.appendingPathExtension(plan.preset.fileExtension)

        await MainActor.run {
            for index in indices {
                guard droppedFiles.wrappedValue.indices.contains(index) else { continue }
                if droppedFiles.wrappedValue[index].status != .cancelled {
                    droppedFiles.wrappedValue[index].status = success ? .done : .failed
                    droppedFiles.wrappedValue[index].progress = success ? 1.0 : 0.0
                    droppedFiles.wrappedValue[index].outputURL = success ? finalURL : nil
                }
            }
        }

        cleanupMergeArtifacts(for: plan)
        mergePlan = nil

        if isConverting {
            await convertNextFile(
                droppedFiles: droppedFiles,
                outputFolder: plan.outputFolder,
                preset: plan.preset
            )
        }
    }


    private func stopProgressTimer() {
        progressTimerTask?.cancel()
        progressTimerTask = nil
    }
    
    func isConvertingStatus() -> Bool {
        return isConverting
    }

    func evaluateMergeCompatibility(for items: [VideoItem], preset: ExportPreset) async -> MergeCompatibilityResult {
        let waitingItems = items.filter { $0.status == .waiting }
        guard waitingItems.count >= 2 else {
            return .insufficientItems(waitingItems.count)
        }

        var resolvedMetadata: [UUID: VideoMetadata] = [:]
        for item in waitingItems {
            if Task.isCancelled { return .cancelled }

            if item.trimStart != nil || item.trimEnd != nil {
                return .trimmedClip(item)
            }

            if let metadata = item.metadata {
                resolvedMetadata[item.id] = metadata
                continue
            }

            do {
                let metadata = try await VideoMetadataService.shared.metadata(for: item.url)
                resolvedMetadata[item.id] = metadata
            } catch {
                return .metadataUnavailable(item)
            }
        }

        guard let firstItem = waitingItems.first,
              let referenceMetadata = resolvedMetadata[firstItem.id],
              let referenceVideo = referenceMetadata.videoStream else {
            return .missingVideoTrack
        }

        let referenceAudio = referenceMetadata.audioStreams.first

        for item in waitingItems {
            guard let metadata = resolvedMetadata[item.id], let video = metadata.videoStream else {
                return .missingVideoTrack
            }

            if !stringsEqual(video.codec, referenceVideo.codec) {
                return .videoCodecMismatch(item)
            }

            if video.width != referenceVideo.width || video.height != referenceVideo.height {
                return .resolutionMismatch(item, expected: referenceVideo)
            }

            if !ratiosEqual(video.pixelAspectRatio, referenceVideo.pixelAspectRatio) {
                return .pixelAspectMismatch(item)
            }

            if !frameRatesEqual(video.frameRate, referenceVideo.frameRate) {
                return .frameRateMismatch(item)
            }

            switch (referenceAudio, metadata.audioStreams.first) {
            case (nil, nil):
                break
            case (nil, .some), (.some, nil):
                return .audioPresenceMismatch(item)
            case let (.some(refAudio), .some(audio)):
                if audio.channels != refAudio.channels {
                    return .audioChannelMismatch(item)
                }
                if audio.sampleRate != refAudio.sampleRate {
                    return .audioSampleRateMismatch(item)
                }
                if !stringsEqual(audio.codec, refAudio.codec) {
                    return .audioCodecMismatch(item)
                }
            }
        }

        return .compatible
    }

    enum MergeCompatibilityResult {
        case compatible
        case insufficientItems(Int)
        case metadataUnavailable(VideoItem)
        case missingVideoTrack
        case videoCodecMismatch(VideoItem)
        case resolutionMismatch(VideoItem, expected: VideoMetadata.VideoStream)
        case pixelAspectMismatch(VideoItem)
        case frameRateMismatch(VideoItem)
        case audioPresenceMismatch(VideoItem)
        case audioChannelMismatch(VideoItem)
        case audioSampleRateMismatch(VideoItem)
        case audioCodecMismatch(VideoItem)
        case trimmedClip(VideoItem)
        case cancelled

        var tooltip: String {
            switch self {
            case .compatible:
                return "Enable to merge compatible clips into one export."
            case .insufficientItems(let count):
                return count == 0 ? "Add clips to enable merging." : "Need at least two queued clips to merge."
            case .metadataUnavailable(let item):
                return "Gathering metadata for \(item.name)…"
            case .missingVideoTrack:
                return "All clips must contain a video track for merging."
            case .videoCodecMismatch:
                return "Video codec mismatch between clips."
            case .resolutionMismatch(let item, let expected):
                let expectedRes = "\(expected.width ?? 0)x\(expected.height ?? 0)"
                return "Resolution mismatch involving \(item.name). Expected \(expectedRes)."
            case .pixelAspectMismatch:
                return "Pixel aspect ratio mismatch between clips."
            case .frameRateMismatch:
                return "Frame rate mismatch between clips."
            case .audioPresenceMismatch:
                return "Some clips have audio while others do not."
            case .audioChannelMismatch:
                return "Audio channel count mismatch between clips."
            case .audioSampleRateMismatch:
                return "Audio sample rate mismatch between clips."
            case .audioCodecMismatch:
                return "Audio codec mismatch between clips."
            case .trimmedClip:
                return "Trimmed clips cannot be merged. Reset trims to enable merging."
            case .cancelled:
                return "Compatibility check cancelled."
            }
        }
    }

    private func stringsEqual(_ lhs: String?, _ rhs: String?) -> Bool {
        (lhs?.lowercased() ?? "") == (rhs?.lowercased() ?? "")
    }

    private func ratiosEqual(_ lhs: VideoMetadata.Ratio?, _ rhs: VideoMetadata.Ratio?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            if let lhsValue = lhs.doubleValue, let rhsValue = rhs.doubleValue {
                return abs(lhsValue - rhsValue) <= 0.001
            }
            return lhs.stringValue == rhs.stringValue
        case let (nil, rhs?):
            return isUnityRatio(rhs)
        case let (lhs?, nil):
            return isUnityRatio(lhs)
        }
    }

    private func isUnityRatio(_ ratio: VideoMetadata.Ratio) -> Bool {
        if let value = ratio.doubleValue {
            return abs(value - 1.0) <= 0.001
        }
        let normalized = ratio.stringValue.replacingOccurrences(of: " ", with: "").lowercased()
        return normalized == "1:1" || normalized == "1" || normalized == "0:1"
    }

    private func frameRatesEqual(_ lhs: VideoMetadata.FrameRate?, _ rhs: VideoMetadata.FrameRate?) -> Bool {
        switch (lhs?.value, rhs?.value) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return abs(lhs - rhs) <= 0.01
        default: return lhs?.stringValue == rhs?.stringValue
        }
    }

    func startConversion(
        droppedFiles: Binding<[VideoItem]>,
        outputFolder: String,
        preset: ExportPreset = .videoLoop,
        mergeClipsEnabled: Bool = false
    ) async {
        guard !self.isConverting else { return }
        self.isConverting = true
        self.currentDroppedFiles = droppedFiles
        self.currentOutputFolder = outputFolder
        self.currentPreset = preset
        if mergeClipsEnabled {
            self.mergePlan = await buildMergePlan(from: droppedFiles.wrappedValue, preset: preset, outputFolder: outputFolder)
        } else {
            self.mergePlan = nil
        }
        progressContinuation?.yield(0.0)
        // Start periodic updates so dock appears immediately
        startProgressTimer(droppedFiles: droppedFiles)
        await convertNextFile(
            droppedFiles: droppedFiles,
            outputFolder: outputFolder,
            preset: preset
        )
    }

    private func convertNextFile(
        droppedFiles: Binding<[VideoItem]>,
        outputFolder: String,
        preset: ExportPreset
    ) async {
        // Update overall progress before starting next file
        await updateOverallProgress(droppedFiles: droppedFiles)

        if let plan = mergePlan, !plan.hasExecuted {
            mergePlan?.hasExecuted = true
            await executeMergePlan(droppedFiles: droppedFiles)
            return
        }

        guard let nextFile = droppedFiles.wrappedValue.first(where: { $0.status == .waiting }) else {
            self.isConverting = false
            progressContinuation?.yield(1.0)
            stopProgressTimer()
            return
        }
        
        let fileId = nextFile.id
        guard let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == fileId }) else {
            await convertNextFile(droppedFiles: droppedFiles, outputFolder: outputFolder, preset: preset)
            return
        }
        
        // Ensure details are loaded before conversion
        if !droppedFiles.wrappedValue[idx].detailsLoaded {
            let details = await VideoFileUtils.loadDetails(for: droppedFiles.wrappedValue[idx].url, outputFolder: outputFolder, preset: preset)
            droppedFiles.wrappedValue[idx].apply(details: details)
            droppedFiles.wrappedValue[idx].detailsLoaded = true
        }
        
        // Update status to converting
        droppedFiles.wrappedValue[idx].status = .converting

        let currentItem = droppedFiles.wrappedValue[idx]
        let inputURL = currentItem.url
        let sanitizedBaseName = FileNameProcessor.processFileName(inputURL.deletingPathExtension().lastPathComponent)
        let outputFileName = sanitizedBaseName + preset.fileSuffix
        let outputURL = URL(fileURLWithPath: outputFolder).appendingPathComponent(outputFileName)

        let waveformRequest = currentItem.requiresWaveformVideo ? {
            let config = AudioWaveformPreferences.loadConfig()
            return WaveformVideoRequest(
                width: Int(config.resolution.width),
                height: Int(config.resolution.height),
                backgroundHex: config.backgroundHex,
                foregroundHex: config.foregroundHex,
                normalizeAudio: config.normalizeAudio,
                style: config.style,
                frameRate: config.frameRate
            )
        }() : nil

        await ffmpegConverter.convert(
            inputURL: inputURL,
            outputURL: outputURL,
            preset: preset,
            comment: currentItem.comment,
            includeDateTag: currentItem.includeDateTag,
            trimStart: currentItem.trimStart,
            trimEnd: currentItem.trimEnd,
            waveformRequest: waveformRequest,
            progressUpdate: { progress, eta in
                Task { @MainActor in
                    if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == fileId }) {
                        droppedFiles.wrappedValue[idx].progress = progress
                        droppedFiles.wrappedValue[idx].eta = eta
                    }
                }
            }
        ) { success in
            Task { @MainActor in
                if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == fileId }) {
                    // If user previously cancelled this item, keep it as .cancelled
                    if droppedFiles.wrappedValue[idx].status != .cancelled {
                        droppedFiles.wrappedValue[idx].status = success ? .done : .failed
                        droppedFiles.wrappedValue[idx].progress = success ? 1.0 : 0
                    }
                    
                    // Update the output URL in the video item
                    if success {
                        let outputFileURL = outputURL.appendingPathExtension(preset.fileExtension)
                        droppedFiles.wrappedValue[idx].outputURL = outputFileURL
                    }
                }
                
                // Only continue if conversion has not been cancelled
                if await self.isConverting {
                    await self.convertNextFile(
                        droppedFiles: droppedFiles,
                        outputFolder: outputFolder,
                        preset: preset
                    )
                }
            }
        }
    }

    func cancelConversion() async {
        self.isConverting = false
        await ffmpegConverter.cancelConversion()
        currentProcess = nil
        // Update status to cancelled for all converting items
        for idx in conversionQueue.indices where conversionQueue[idx].status == .converting {
            conversionQueue[idx].status = .cancelled
        }
        stopProgressTimer()
    }
    
    /// Cancels a single video item without aborting the entire queue
    func cancelItem(with id: UUID) async {
        guard let droppedFiles = currentDroppedFiles else { return }
        
        // If the item is currently converting
        if let idx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == id && $0.status == .converting }) {
            await ffmpegConverter.cancelConversion()
            currentProcess = nil
            droppedFiles.wrappedValue[idx].status = .cancelled
        #if DEBUG
        print("Item \(droppedFiles.wrappedValue[idx].name) cancelled (was converting).")
        #endif
            droppedFiles.wrappedValue[idx].progress = 0.0
            
            // Re-compute overall progress; the existing convertNextFile call in the
            // original conversion's completion handler will continue the queue, so
            // we must NOT start a new one here to avoid parallel encodes.
            await updateOverallProgress(droppedFiles: droppedFiles)
            return
        }
        
        // If the item is still waiting, simply mark as cancelled
        if let waitingIdx = droppedFiles.wrappedValue.firstIndex(where: { $0.id == id && $0.status == .waiting }) {
            droppedFiles.wrappedValue[waitingIdx].status = .cancelled
            #if DEBUG
            print("Item \(droppedFiles.wrappedValue[waitingIdx].name) cancelled (was waiting).")
            #endif
            await updateOverallProgress(droppedFiles: droppedFiles)
        }
    }
    func cancelAllConversions() async {
        self.isConverting = false
        await ffmpegConverter.cancelConversion()
        // Clear the conversion queue
        conversionQueue.removeAll()
        isConverting = false
        // Update status to cancelled
        for idx in conversionQueue.indices {
            conversionQueue[idx].status = .cancelled
        }
        progressContinuation?.yield(0.0)
        stopProgressTimer()
    }
    
    // Convert duration string ("hh:mm:ss" or "mm:ss" or "ss") to seconds
    private func timeStringToSeconds(_ str: String) -> Double {
        let components = str.split(separator: ":").map { Double($0) ?? 0 }
        switch components.count {
        case 3:
            return components[0] * 3600 + components[1] * 60 + components[2]
        case 2:
            return components[0] * 60 + components[1]
        case 1:
            return components[0]
        default:
            return 0
        }
    }
    
    private func updateOverallProgress(droppedFiles: Binding<[VideoItem]>) async {
        #if DEBUG
        print("=== updateOverallProgress called ===")
        #endif
        let files = droppedFiles.wrappedValue
        
        // Filter out cancelled items
        #if DEBUG
        print("Files: \(files.map{($0.name, $0.status, $0.durationSeconds, $0.progress)})")
        #endif
        let activeFiles = files.filter { $0.status != .cancelled && $0.status != .failed }
        
        guard !activeFiles.isEmpty else {
            progressContinuation?.yield(0.0)
            return
        }

        // Total duration of active files (seconds)
        let totalDuration = activeFiles.reduce(0.0) { sum, file in
            sum + file.trimmedDuration
        }
        guard totalDuration > 0 else {
            progressContinuation?.yield(0.0)
            return
        }

        // Completed duration so far (seconds)
        let completedDuration = activeFiles.reduce(0.0) { sum, file in
            let durSec = file.trimmedDuration
            switch file.status {
            case .done:
                return sum + durSec
            case .converting:
                return sum + durSec * file.progress
            default:
                return sum
            }
        }
        let progress = min(max(completedDuration / totalDuration, 0.0), 1.0)
        #if DEBUG
        print("totalDuration: \(totalDuration) s, completedDuration: \(completedDuration) s, overallProgress: \(progress * 100)%")
        #endif
        progressContinuation?.yield(progress)
    }
}
