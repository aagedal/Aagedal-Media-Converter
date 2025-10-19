// Aagedal VideoLoop Converter 2.0
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

    private func stopProgressTimer() {
        progressTimerTask?.cancel()
        progressTimerTask = nil
    }
    
    func isConvertingStatus() -> Bool {
        return isConverting
    }

    func startConversion(
        droppedFiles: Binding<[VideoItem]>,
        outputFolder: String,
        preset: ExportPreset = .videoLoop
    ) async {
        guard !self.isConverting else { return }
        self.isConverting = true
        self.currentDroppedFiles = droppedFiles
        self.currentOutputFolder = outputFolder
        self.currentPreset = preset
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
        
        // Update status to converting
        droppedFiles.wrappedValue[idx].status = .converting
        
        let inputURL = nextFile.url
        let sanitizedBaseName = FileNameProcessor.processFileName(inputURL.deletingPathExtension().lastPathComponent)
        let outputFileName = sanitizedBaseName + preset.fileSuffix
        let outputURL = URL(fileURLWithPath: outputFolder).appendingPathComponent(outputFileName)

        await ffmpegConverter.convert(
            inputURL: inputURL,
            outputURL: outputURL,
            preset: preset,
            comment: nextFile.comment,
            includeDateTag: nextFile.includeDateTag,
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
            return sum + file.durationSeconds
        }
        guard totalDuration > 0 else {
            progressContinuation?.yield(0.0)
            return
        }
        
        // Completed duration so far (seconds)
        let completedDuration = activeFiles.reduce(0.0) { sum, file in
            let durSec = file.durationSeconds
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
