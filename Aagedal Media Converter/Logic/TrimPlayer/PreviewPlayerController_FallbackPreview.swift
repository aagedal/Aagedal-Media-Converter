// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fallback preview generation for PreviewPlayerController (composition-based chunked playback).

import Foundation
import AVKit
import OSLog

extension PreviewPlayerController {
    private var chunkSegments: [ClosedRange<Double>] {
        loadedChunks.compactMap { chunkIndex in
            let start = Double(chunkIndex) * chunkDuration
            let duration = chunkDurations[chunkIndex] ?? chunkDuration
            guard duration > 0 else { return nil }
            let end = start + duration
            return start...end
        }
        .sorted { $0.lowerBound < $1.lowerBound }
    }

    @discardableResult
    func jumpToNextCachedSegmentStart() -> Bool {
        guard usePreviewFallback, let currentTime = getCurrentTime() else { return false }
        let tolerance = 0.05
        if let segment = chunkSegments.first(where: { $0.lowerBound > currentTime + tolerance }) {
            seekTo(segment.lowerBound)
            return true
        }
        return false
    }
    
    @discardableResult
    func jumpToPreviousCachedSegmentEnd() -> Bool {
        guard usePreviewFallback, let currentTime = getCurrentTime() else { return false }
        let tolerance = 0.05
        if let segment = chunkSegments.reversed().first(where: { $0.upperBound < currentTime - tolerance }) {
            let target = max(segment.upperBound - tolerance, segment.lowerBound)
            seekTo(target)
            return true
        }
        return false
    }
    
    
    // MARK: - Fallback Preview Initialization
    
    func fallbackToPreview(startTime: TimeInterval) {
        guard !usePreviewFallback else {
            errorMessage = "Unable to play this video format"
            return
        }

        usePreviewFallback = true
        isPreparing = true
        errorMessage = nil

        let currentItem = videoItem
        
        // Reload preview assets (teardown() clears them when switching from AVPlayer)
        loadPreviewAssets(for: currentItem.url)
        
        // Use the same fingerprint-based cache directory as preview assets
        Task { @MainActor in
            do {
                let cacheDirectory = try await PreviewAssetGenerator.shared.getAssetDirectory(for: currentItem.url)
                let audioStreams = await self.determineAudioStreamOrder(for: currentItem)
                self.previewAudioStreamIndices = audioStreams
                self.mp4Session = MP4PreviewSession(
                    sourceURL: currentItem.url,
                    cacheDirectory: cacheDirectory,
                    audioStreamIndices: audioStreams,
                    hasVideoStream: currentItem.hasVideoStream
                )
                await self.restoreCachedChunkState(from: cacheDirectory)
                self.startFallbackGeneration(startTime: startTime, currentItem: currentItem)
            } catch {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .error("Failed to create cache directory for fallback preview: \(error.localizedDescription, privacy: .public)")
                self.errorMessage = "Unable to prepare preview: \(error.localizedDescription)"
                self.isPreparing = false
            }
        }
    }
    
    private func startFallbackGeneration(startTime: TimeInterval, currentItem: VideoItem) {

        preparationTask = Task { @MainActor in
            defer { 
                self.isPreparing = false
                self.isGeneratingFallbackPreview = false
            }
            
            self.isGeneratingFallbackPreview = true

            do {
                guard let session = self.mp4Session else {
                    throw MP4PreviewSession.PreviewError.outputMissing
                }

                // Generate initial chunk (with embedded audio)
                let chunkIndex = 0
                let chunkStart = Double(chunkIndex) * self.chunkDuration
                let chunkResult = try await session.generatePreviewChunk(
                    chunkIndex: chunkIndex,
                    startTime: chunkStart,
                    durationLimit: self.chunkDuration,
                    maxShortEdge: self.previewMaxShortEdge
                )
                try Task.checkCancellation()

                self.chunkDurations[chunkIndex] = chunkResult.duration

                // Create AVMutableComposition using muxed chunk
                try await self.createComposition(from: chunkResult.url, duration: chunkResult.duration)
                
                // Track the loaded chunk
                self.loadedChunks = [chunkIndex]
                self.currentChunkIndex = chunkIndex
                self.appliedChunks = [chunkIndex]
                self.updateFallbackCoverageRange()

                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .info("MP4 composition playback ready (chunk \(chunkIndex, privacy: .public), 5s) for item \(currentItem.id, privacy: .public)")

                // Background: preload adjacent chunks
                self.loadAdjacentChunksInBackground(currentChunk: chunkIndex)

                // Chunk is ready, clear overlay if it matches this chunk
                let expectedPendingTime = Double(chunkIndex) * self.chunkDuration
                if self.pendingChunkTime == expectedPendingTime {
                    self.pendingChunkTime = nil
                }

            } catch is CancellationError {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .debug("MP4 fallback cancelled for item \(currentItem.id, privacy: .public)")
                self.pendingChunkTime = nil
            } catch {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .error("MP4 fallback failed: \(error.localizedDescription, privacy: .public)")
                self.pendingChunkTime = nil
                self.errorMessage = "Unable to play this video: \(error.localizedDescription)"
            }
        }
    }
    
    // MARK: - Composition Management
    
    /// Creates composition with audio and video tracks
    private func createComposition(from chunkURL: URL, duration: TimeInterval) async throws {
        let composition = AVMutableComposition()

        // Add video track
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MP4PreviewSession.PreviewError.failedToStart("Could not create video track")
        }
        guard let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MP4PreviewSession.PreviewError.failedToStart("Could not create audio track")
        }

        let asset = AVURLAsset(url: chunkURL)
        let videoSourceTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoSourceTrack = videoSourceTracks.first else {
            throw MP4PreviewSession.PreviewError.failedToStart("No video track in chunk")
        }

        let audioSourceTracks = try await asset.loadTracks(withMediaType: .audio)
        let orderedAudioTracks = orderAudioTracks(audioSourceTracks)
        let primaryAudioTrack = orderedAudioTracks.first

        guard let primaryAudioTrack else {
            throw MP4PreviewSession.PreviewError.failedToStart("No audio tracks in chunk")
        }

        let videoChunkDuration = CMTime(seconds: duration, preferredTimescale: 600)
        try videoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoChunkDuration),
            of: videoSourceTrack,
            at: .zero
        )

        let audioDuration = try await asset.load(.duration)
        try audioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: audioDuration),
            of: primaryAudioTrack,
            at: .zero
        )
        
        // Store references
        self.composition = composition
        self.compositionAudioTrack = audioTrack
        self.compositionVideoTrack = videoTrack
        
        // Create player with composition
        let playerItem = AVPlayerItem(asset: composition)
        let player = AVPlayer(playerItem: playerItem)
        self.player = player
        
        installLoopObserver(for: playerItem)
        installTimeObserver(for: player)
        installPlaybackTimeObserver(for: player)
        updatePlayerActionAtEnd()
    }
    
    @MainActor
    private func applyChunkToComposition(
        chunkIndex: Int,
        newDuration: TimeInterval,
        previousDuration: TimeInterval?,
        session: MP4PreviewSession
    ) async throws {
        guard let composition = self.composition,
              let videoTrack = self.compositionVideoTrack,
              let audioTrack = self.compositionAudioTrack else { return }

        let insertTime = CMTime(seconds: Double(chunkIndex) * self.chunkDuration, preferredTimescale: 600)
        let newDurationTime = CMTime(seconds: newDuration, preferredTimescale: 600)
        guard newDurationTime.seconds > 0 else { return }

        let chunkURL = session.chunkURL(for: chunkIndex)
        guard FileManager.default.fileExists(atPath: chunkURL.path) else { return }

        let chunkAsset = AVURLAsset(url: chunkURL)
        let chunkVideoTracks = try await chunkAsset.loadTracks(withMediaType: .video)
        guard let chunkVideoTrack = chunkVideoTracks.first else { return }
        let chunkAudioTracks = try await chunkAsset.loadTracks(withMediaType: .audio)
        let orderedAudioTracks = orderAudioTracks(chunkAudioTracks)
        let primaryAudioTrack = orderedAudioTracks.first
        guard let primaryAudioTrack else { return }

        if let previousDuration {
            let previousDurationTime = CMTime(seconds: previousDuration, preferredTimescale: 600)
            let removeRange = CMTimeRange(start: insertTime, duration: previousDurationTime)
            videoTrack.removeTimeRange(removeRange)
            audioTrack.removeTimeRange(removeRange)
        } else if appliedChunks.contains(chunkIndex) {
            let previousDurationTime = CMTime(seconds: chunkDurations[chunkIndex] ?? self.chunkDuration, preferredTimescale: 600)
            let removeRange = CMTimeRange(start: insertTime, duration: previousDurationTime)
            videoTrack.removeTimeRange(removeRange)
            audioTrack.removeTimeRange(removeRange)
        } else if insertTime < composition.duration {
            let placeholderRange = CMTimeRange(start: insertTime, duration: newDurationTime)
            videoTrack.removeTimeRange(placeholderRange)
            audioTrack.removeTimeRange(placeholderRange)
        }

        if insertTime > composition.duration {
            let gap = insertTime - composition.duration
            videoTrack.insertEmptyTimeRange(CMTimeRange(start: composition.duration, duration: gap))
            audioTrack.insertEmptyTimeRange(CMTimeRange(start: composition.duration, duration: gap))
        }
        try videoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: newDurationTime),
            of: chunkVideoTrack,
            at: insertTime
        )
        try audioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: newDurationTime),
            of: primaryAudioTrack,
            at: insertTime
        )

        appliedChunks.insert(chunkIndex)
        chunkDurations[chunkIndex] = newDuration
    }

    private func orderAudioTracks(_ tracks: [AVAssetTrack]) -> [AVAssetTrack] {
        guard !tracks.isEmpty else { return [] }
        let clampedIndex = min(max(selectedAudioTrackOrderIndex, 0), tracks.count - 1)
        var ordered = tracks
        if clampedIndex != 0 {
            let preferred = ordered.remove(at: clampedIndex)
            ordered.insert(preferred, at: 0)
        }
        return ordered
    }

    // MARK: - Chunk Loading
    
    /// Preloads upcoming chunks in the background to keep playback smooth
    private func loadAdjacentChunksInBackground(currentChunk: Int) {
        chunkPreloadTask?.cancel()
        chunkPreloadTask = Task { @MainActor in
            guard let session = self.mp4Session else { return }

            let totalChunks = Int(ceil(self.videoItem.durationSeconds / self.chunkDuration))
            let lookaheadCount = 5

            let lookbehindCount = 3
            var targets: [Int] = []

            if currentChunk > 0 {
                for offset in 1...lookbehindCount {
                    let previousChunk = currentChunk - offset
                    if previousChunk < 0 { break }
                    if self.appliedChunks.contains(previousChunk) { continue }
                    targets.append(previousChunk)
                }
            }

            for offset in 1...lookaheadCount {
                let nextChunk = currentChunk + offset
                if nextChunk >= totalChunks { break }
                if self.appliedChunks.contains(nextChunk) { continue }
                if targets.contains(nextChunk) { continue }
                targets.append(nextChunk)
            }

            for chunk in targets {
                if Task.isCancelled { return }

                let directionDescription: String
                if chunk < currentChunk {
                    directionDescription = "backfill \(currentChunk - chunk)"
                } else {
                    directionDescription = "lookahead \(chunk - currentChunk)"
                }

                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .info("Preloading chunk \(chunk, privacy: .public) (\(directionDescription))")

                do {
                    let chunkStart = Double(chunk) * self.chunkDuration
                    let chunkResult = try await session.generatePreviewChunk(
                        chunkIndex: chunk,
                        startTime: chunkStart,
                        durationLimit: self.chunkDuration,
                        maxShortEdge: self.previewMaxShortEdge
                    )

                    let previousDuration = self.chunkDurations[chunk]
                    try await self.applyChunkToComposition(
                        chunkIndex: chunk,
                        newDuration: chunkResult.duration,
                        previousDuration: previousDuration,
                        session: session
                    )
                    self.loadedChunks.insert(chunk)
                    self.updateFallbackCoverageRange()

                    Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                        .info("Preloaded chunk \(chunk, privacy: .public)")

                    if Task.isCancelled { return }

                } catch is CancellationError {
                    Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                        .debug("Chunk preloading cancelled")
                    return
                } catch {
                    Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                        .warning("Failed to preload chunk \(chunk, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
    
    /// Loads and switches to a specific chunk for a given time
    func loadChunkForTime(_ time: TimeInterval) {
        let chunkIndex = Int(time / chunkDuration)

        if appliedChunks.contains(chunkIndex), chunkDurations[chunkIndex] != nil {
            currentChunkIndex = chunkIndex
            pendingChunkTime = nil
            loadAdjacentChunksInBackground(currentChunk: chunkIndex)
            return
        }

        // Already on this chunk
        if chunkIndex == currentChunkIndex { return }
        
        // Don't try to load if already loading THIS chunk
        if isLoadingChunk && loadingChunkIndex == chunkIndex { return }

        chunkLoadTask?.cancel()
        loadingChunkIndex = chunkIndex
        
        chunkLoadTask = Task { @MainActor in
            self.isLoadingChunk = true
            defer { 
                self.isLoadingChunk = false 
                if self.loadingChunkIndex == chunkIndex {
                    self.loadingChunkIndex = nil
                }
            }
            
            do {
                guard let session = self.mp4Session else { return }
                let chunkAlreadyGenerated = self.loadedChunks.contains(chunkIndex)
                if chunkAlreadyGenerated {
                    self.pendingChunkTime = nil
                } else {
                    self.pendingChunkTime = Double(chunkIndex) * self.chunkDuration
                }
                
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .info("Loading chunk \(chunkIndex, privacy: .public) for time \(time, privacy: .public)s")
                
                let chunkStart = Double(chunkIndex) * self.chunkDuration
                let chunkResult = try await session.generatePreviewChunk(
                    chunkIndex: chunkIndex,
                    startTime: chunkStart,
                    durationLimit: self.chunkDuration,
                    maxShortEdge: self.previewMaxShortEdge
                )
                
                try Task.checkCancellation()
                
                let previousDuration = self.chunkDurations[chunkIndex]
                try await self.applyChunkToComposition(
                    chunkIndex: chunkIndex,
                    newDuration: chunkResult.duration,
                    previousDuration: previousDuration,
                    session: session
                )
                self.loadedChunks.insert(chunkIndex)
                self.currentChunkIndex = chunkIndex
                self.updateFallbackCoverageRange()
                
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .info("Applied chunk \(chunkIndex, privacy: .public) into composition")
                
                // Preload adjacent chunks
                self.loadAdjacentChunksInBackground(currentChunk: chunkIndex)

                // Chunk ready – clear overlay if it matches
                let expectedPendingTime = Double(chunkIndex) * self.chunkDuration
                if self.pendingChunkTime == expectedPendingTime {
                    self.pendingChunkTime = nil
                }

            } catch is CancellationError {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .debug("Chunk loading cancelled")
                self.pendingChunkTime = nil
            } catch {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .error("Failed to load chunk: \(error.localizedDescription, privacy: .public)")
                self.pendingChunkTime = nil
            }
        }
    }
}
