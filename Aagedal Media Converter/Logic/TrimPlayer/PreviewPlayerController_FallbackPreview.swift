// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Fallback preview generation for PreviewPlayerController (composition-based chunked playback).

import Foundation
import AVKit
import OSLog

extension PreviewPlayerController {
    private struct CachedSegment {
        let start: Double
        let end: Double
    }
    
    private var cachedSegments: [CachedSegment] {
        var segments: [CachedSegment] = []
        let totalDuration = videoItem.durationSeconds
        let chunkLength = chunkDuration
        let sectionLength = chunkDuration * Double(chunksPerSection)
        
        for sectionIndex in concatenatedSections {
            let start = Double(sectionIndex) * sectionLength
            let end = min(start + sectionLength, totalDuration)
            guard end > start else { continue }
            segments.append(CachedSegment(start: start, end: end))
        }
        
        for chunkIndex in loadedChunks {
            let sectionIndex = chunkIndex / chunksPerSection
            if concatenatedSections.contains(sectionIndex) {
                continue
            }
            let start = Double(chunkIndex) * chunkLength
            let end = min(start + chunkLength, totalDuration)
            guard end > start else { continue }
            segments.append(CachedSegment(start: start, end: end))
        }
        
        segments.sort { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.end < rhs.end
            }
            return lhs.start < rhs.start
        }
        return segments
    }
    
    @discardableResult
    func jumpToNextCachedSegmentStart() -> Bool {
        guard usePreviewFallback, let currentTime = getCurrentTime() else { return false }
        let tolerance = 0.05
        if let segment = cachedSegments.first(where: { $0.start > currentTime + tolerance }) {
            seekTo(segment.start)
            return true
        }
        return false
    }
    
    @discardableResult
    func jumpToPreviousCachedSegmentEnd() -> Bool {
        guard usePreviewFallback, let currentTime = getCurrentTime() else { return false }
        let tolerance = 0.05
        if let segment = cachedSegments.reversed().first(where: { $0.end < currentTime - tolerance }) {
            let target = max(segment.end - tolerance, segment.start)
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
        
        // Use the same fingerprint-based cache directory as preview assets
        Task { @MainActor in
            do {
                let cacheDirectory = try await PreviewAssetGenerator.shared.getAssetDirectory(for: currentItem.url)
                self.mp4Session = MP4PreviewSession(sourceURL: currentItem.url, cacheDirectory: cacheDirectory)
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

                // Generate 15s audio chunk first (for quick start)
                let audioChunkURL = try await session.generateAudioChunk(durationLimit: self.chunkDuration)
                try Task.checkCancellation()
                
                // Generate initial video chunk 0 (0-15s, no audio)
                let chunkIndex = 0
                let chunkStart = Double(chunkIndex) * self.chunkDuration
                let chunkResult = try await session.generatePreviewChunk(
                    chunkIndex: chunkIndex,
                    startTime: chunkStart,
                    durationLimit: self.chunkDuration,
                    maxShortEdge: self.previewMaxShortEdge
                )
                try Task.checkCancellation()

                // Track the loaded chunk
                self.loadedChunks.insert(chunkIndex)
                self.currentChunkIndex = chunkIndex
                
                // Update preview range
                let rangeStart = chunkResult.startTime
                let rangeEnd = chunkResult.startTime + chunkResult.duration
                self.fallbackPreviewRange = rangeStart...rangeEnd

                // Create AVMutableComposition with audio + video
                try await self.createComposition(audioURL: audioChunkURL, videoURL: chunkResult.url, videoDuration: chunkResult.duration)
                
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .info("MP4 composition playback ready (chunk \(chunkIndex, privacy: .public), 15s) for item \(currentItem.id, privacy: .public)")

                // Background: generate full audio track and swap it in
                Task.detached(priority: .utility) { [weak self] in
                    await self?.generateAndSwapFullAudio(session: session)
                }
                
                // Background: preload adjacent chunks
                self.loadAdjacentChunksInBackground(currentChunk: chunkIndex)

            } catch is CancellationError {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .debug("MP4 fallback cancelled for item \(currentItem.id, privacy: .public)")
            } catch {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .error("MP4 fallback failed: \(error.localizedDescription, privacy: .public)")
                self.errorMessage = "Unable to play this video: \(error.localizedDescription)"
            }
        }
    }
    
    // MARK: - Composition Management
    
    /// Creates composition with audio and video tracks
    private func createComposition(audioURL: URL, videoURL: URL, videoDuration: TimeInterval) async throws {
        let composition = AVMutableComposition()
        
        // Add audio track
        guard let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MP4PreviewSession.PreviewError.failedToStart("Could not create audio track")
        }
        
        let audioAsset = AVURLAsset(url: audioURL)
        let audioSourceTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        guard let audioSourceTrack = audioSourceTracks.first else {
            throw MP4PreviewSession.PreviewError.failedToStart("No audio track in source")
        }
        
        let audioDuration = try await audioAsset.load(.duration)
        try audioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: audioDuration),
            of: audioSourceTrack,
            at: .zero
        )
        
        // Add video track (initial chunk)
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MP4PreviewSession.PreviewError.failedToStart("Could not create video track")
        }
        
        let videoAsset = AVURLAsset(url: videoURL)
        let videoSourceTracks = try await videoAsset.loadTracks(withMediaType: .video)
        guard let videoSourceTrack = videoSourceTracks.first else {
            throw MP4PreviewSession.PreviewError.failedToStart("No video track in source")
        }
        
        let videoChunkDuration = CMTime(seconds: videoDuration, preferredTimescale: 600)
        try videoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: videoChunkDuration),
            of: videoSourceTrack,
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
        applyLoopSetting()
    }
    
    /// Generates full audio track and swaps it in seamlessly
    private func generateAndSwapFullAudio(session: MP4PreviewSession) async {
        do {
            let fullAudioURL = try await session.generateFullAudioTrack()
            
            Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                .info("Full audio track generated, swapping...")
            
            _ = await MainActor.run {
                Task { @MainActor [weak self] in
                    try? await self?.swapAudioTrack(newAudioURL: fullAudioURL)
                }
            }
        } catch {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                .warning("Failed to generate full audio track: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    /// Swaps audio track in composition while maintaining playback position
    private func swapAudioTrack(newAudioURL: URL) async throws {
        guard let composition = self.composition,
              let audioTrack = self.compositionAudioTrack,
              let player = self.player else { return }
        
        self.isSwappingAudio = true
        defer { self.isSwappingAudio = false }
        
        // Save current playback state
        let currentTime = player.currentTime()
        let isPlaying = (player.rate > 0)
        
        // Remove old audio
        audioTrack.removeTimeRange(CMTimeRange(start: .zero, duration: composition.duration))
        
        // Insert new full audio
        let audioAsset = AVURLAsset(url: newAudioURL)
        let audioSourceTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        guard let audioSourceTrack = audioSourceTracks.first else { return }
        
        let audioDuration = try await audioAsset.load(.duration)
        try audioTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: audioDuration),
            of: audioSourceTrack,
            at: .zero
        )
        
        // Update fallback preview range to full duration
        self.fallbackPreviewRange = 0...audioDuration.seconds
        
        // Restore playback state
        await player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
        if isPlaying {
            player.play()
        }
        
        Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
            .info("Audio track swapped to full duration: \(audioDuration.seconds, privacy: .public)s")
    }
    
    /// Rebuilds the video track in the composition with all loaded chunks/sections
    /// This ensures the composition accurately reflects which files are available and prevents FigFilePlayer errors
    private func rebuildCompositionVideoTrack() async throws -> CMTime {
        guard let composition = self.composition,
              let videoTrack = self.compositionVideoTrack,
              let session = self.mp4Session else {
            throw MP4PreviewSession.PreviewError.outputMissing
        }
        
        // Clear entire video track
        videoTrack.removeTimeRange(CMTimeRange(start: .zero, duration: composition.duration))
        
        // Rebuild video track using sections/chunks as appropriate
        var maxVideoTime = CMTime.zero
        let totalChunks = Int(ceil(self.videoItem.durationSeconds / self.chunkDuration))
        
        var processedChunks = 0
        while processedChunks < totalChunks {
            let chunkSection = processedChunks / self.chunksPerSection
            
            // Check if this section is concatenated
            if self.concatenatedSections.contains(chunkSection) {
                // Use section file
                let sectionURL = session.sectionURL(for: chunkSection)
                
                // Ensure section file exists
                guard FileManager.default.fileExists(atPath: sectionURL.path) else {
                    Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                        .warning("Section file missing: \(sectionURL.path, privacy: .public), removing from concatenated set")
                    self.concatenatedSections.remove(chunkSection)
                    let firstChunk = chunkSection * self.chunksPerSection
                    let lastChunk = min(firstChunk + self.chunksPerSection - 1, totalChunks - 1)
                    processedChunks = lastChunk + 1
                    continue
                }
                
                let sectionAsset = AVURLAsset(url: sectionURL)
                let sectionVideoTracks = try await sectionAsset.loadTracks(withMediaType: .video)
                
                if let sectionVideoTrack = sectionVideoTracks.first {
                    let sectionDuration = try await sectionAsset.load(.duration)
                    let sectionStartSeconds = Double(chunkSection * self.chunksPerSection) * self.chunkDuration
                    let insertTime = CMTime(seconds: sectionStartSeconds, preferredTimescale: 600)
                    try videoTrack.insertTimeRange(
                        CMTimeRange(start: .zero, duration: sectionDuration),
                        of: sectionVideoTrack,
                        at: insertTime
                    )
                    maxVideoTime = max(maxVideoTime, CMTimeAdd(insertTime, sectionDuration))
                    
                    Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                        .debug("Inserted section \(chunkSection, privacy: .public) at \(insertTime.seconds, privacy: .public)s")
                }
                
                // Skip all chunks in this section
                let firstChunk = chunkSection * self.chunksPerSection
                let lastChunk = min(firstChunk + self.chunksPerSection - 1, totalChunks - 1)
                processedChunks = lastChunk + 1
            } else {
                // Use individual chunk if loaded
                if self.loadedChunks.contains(processedChunks) {
                    let chunkURL = session.chunkURL(for: processedChunks)
                    
                    // Ensure chunk file exists
                    guard FileManager.default.fileExists(atPath: chunkURL.path) else {
                        Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                            .warning("Chunk file missing: \(chunkURL.path, privacy: .public), skipping")
                        processedChunks += 1
                        continue
                    }
                    
                    let chunkAsset = AVURLAsset(url: chunkURL)
                    let chunkVideoTracks = try await chunkAsset.loadTracks(withMediaType: .video)
                    
                    if let chunkVideoTrack = chunkVideoTracks.first {
                        let chunkDuration = try await chunkAsset.load(.duration)
                        let chunkStartSeconds = Double(processedChunks) * self.chunkDuration
                        let insertTime = CMTime(seconds: chunkStartSeconds, preferredTimescale: 600)
                        try videoTrack.insertTimeRange(
                            CMTimeRange(start: .zero, duration: chunkDuration),
                            of: chunkVideoTrack,
                            at: insertTime
                        )
                        maxVideoTime = max(maxVideoTime, CMTimeAdd(insertTime, chunkDuration))
                    }
                }
                processedChunks += 1
            }
        }
        
        return maxVideoTime
    }
    
    // MARK: - Chunk Loading
    
    /// Preloads chunks adjacent to the current chunk in the background
    private func loadAdjacentChunksInBackground(currentChunk: Int) {
        chunkLoadTask?.cancel()
        chunkLoadTask = Task { @MainActor in
            guard let session = self.mp4Session else { return }
            
            // Load next chunk (chunk 1 after chunk 0)
            let nextChunk = currentChunk + 1
            
            do {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .info("Preloading adjacent chunk \(nextChunk, privacy: .public)")
                
                let nextChunkStart = Double(nextChunk) * self.chunkDuration
                let _ = try await session.generatePreviewChunk(
                    chunkIndex: nextChunk,
                    startTime: nextChunkStart,
                    durationLimit: self.chunkDuration,
                    maxShortEdge: self.previewMaxShortEdge
                )
                
                try Task.checkCancellation()
                
                self.loadedChunks.insert(nextChunk)
                
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .info("Preloaded chunk \(nextChunk, privacy: .public)")
                
            } catch is CancellationError {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .debug("Chunk preloading cancelled")
            } catch {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .warning("Failed to preload chunk: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    /// Loads and switches to a specific chunk for a given time
    func loadChunkForTime(_ time: TimeInterval) {
        let chunkIndex = Int(time / chunkDuration)
        let sectionIndex = chunkIndex / chunksPerSection
        
        // Check if this time is in a concatenated section
        if concatenatedSections.contains(sectionIndex) {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                .debug("Time \(time, privacy: .public)s is in concatenated section \(sectionIndex, privacy: .public), composition already has section file")
            // Just update current chunk index for tracking, don't load anything
            self.currentChunkIndex = chunkIndex
            return
        }
        
        // Already on this chunk
        if chunkIndex == currentChunkIndex { return }
        
        // Don't try to load if already loading
        guard !isLoadingChunk else { return }
        
        chunkLoadTask?.cancel()
        chunkLoadTask = Task { @MainActor in
            self.isLoadingChunk = true
            defer { self.isLoadingChunk = false }
            
            do {
                guard let session = self.mp4Session else { return }
                
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .info("Loading chunk \(chunkIndex, privacy: .public) for time \(time, privacy: .public)s")
                
                let chunkStart = Double(chunkIndex) * self.chunkDuration
                _ = try await session.generatePreviewChunk(
                    chunkIndex: chunkIndex,
                    startTime: chunkStart,
                    durationLimit: self.chunkDuration,
                    maxShortEdge: self.previewMaxShortEdge
                )
                
                try Task.checkCancellation()
                
                // Track the loaded chunk
                self.loadedChunks.insert(chunkIndex)
                self.currentChunkIndex = chunkIndex
                
                // Update composition video track (audio continues uninterrupted)
                // We need to rebuild the entire composition to prevent referencing missing chunk files
                if let composition = self.composition, let player = self.player {
                    // Preserve playback state
                    let currentTime = player.currentTime()
                    let wasPlaying = (player.rate > 0)
                    
                    // Rebuild video track with all loaded chunks/sections
                    let totalVideoDuration = try await self.rebuildCompositionVideoTrack()
                    
                    // Recreate player item with rebuilt composition
                    let newPlayerItem = AVPlayerItem(asset: composition)
                    player.replaceCurrentItem(with: newPlayerItem)
                    
                    // Reinstall observers for new item
                    self.removeLoopObserver()
                    self.installLoopObserver(for: newPlayerItem)
                    
                    // Restore playback state
                    await player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    
                    if wasPlaying {
                        player.play()
                    }
                    
                    Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                        .info("Rebuilt composition with chunk \(chunkIndex, privacy: .public), total video duration: \(totalVideoDuration.seconds, privacy: .public)s")
                }
                
                // Check if section is complete and should be concatenated
                self.checkAndConcatenateSection(for: chunkIndex)
                
                // Preload adjacent chunks
                self.loadAdjacentChunksInBackground(currentChunk: chunkIndex)
                
            } catch is CancellationError {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .debug("Chunk loading cancelled")
            } catch {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .error("Failed to load chunk: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    // MARK: - Section Concatenation
    
    /// Checks if a section is complete and concatenates chunks if needed
    private func checkAndConcatenateSection(for chunkIndex: Int) {
        let sectionIndex = chunkIndex / chunksPerSection
        
        // Skip if already concatenated
        guard !concatenatedSections.contains(sectionIndex) else { return }
        
        // Determine which chunks belong to this section
        let firstChunkInSection = sectionIndex * chunksPerSection
        let totalChunks = Int(ceil(videoItem.durationSeconds / chunkDuration))
        let lastChunkInSection = min(firstChunkInSection + chunksPerSection - 1, totalChunks - 1)
        
        let chunksInSection = Set(firstChunkInSection...lastChunkInSection)
        
        // Check if all chunks in this section are loaded
        guard chunksInSection.isSubset(of: loadedChunks) else {
            return  // Not all chunks loaded yet
        }
        
        // All chunks loaded - concatenate in background
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self, let session = await self.mp4Session else { return }
            
            do {
                let chunkIndices = Array(chunksInSection).sorted()
                
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .info("Section \(sectionIndex, privacy: .public) complete, concatenating chunks \(chunkIndices, privacy: .public)")
                
                let sectionURL = try await session.concatenateSection(
                    chunkIndices: chunkIndices,
                    sectionIndex: sectionIndex
                )
                
                await MainActor.run {
                    self.concatenatedSections.insert(sectionIndex)
                    
                    Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                        .info("Section \(sectionIndex, privacy: .public) concatenated, now using seamless 60s file")
                    
                    // If currently playing in this section, update composition to use concatenated file
                    let currentSection = self.currentChunkIndex / self.chunksPerSection
                    if currentSection == sectionIndex {
                        self.useConcatenatedSection(sectionIndex: sectionIndex, sectionURL: sectionURL)
                    }
                    
                    // Schedule cleanup of individual chunk files after a safety delay
                    Task.detached(priority: .utility) { [weak self] in
                        // Wait 15 seconds to ensure composition update is complete and stable
                        try? await Task.sleep(for: .seconds(15))
                        
                        guard let self = self, let session = await self.mp4Session else { return }
                        self.cleanupChunksForSection(sectionIndex: sectionIndex, chunkIndices: chunkIndices, session: session)
                    }
                }
            } catch {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .warning("Failed to concatenate section \(sectionIndex, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    /// Cleans up individual chunk files after section concatenation
    /// Called with a delay to ensure composition has fully transitioned to section file
    nonisolated private func cleanupChunksForSection(sectionIndex: Int, chunkIndices: [Int], session: MP4PreviewSession) {
        let fileManager = FileManager.default
        var deletedCount = 0
        
        for chunkIndex in chunkIndices {
            let chunkURL = session.chunkURL(for: chunkIndex)
            
            // Verify file exists before attempting deletion
            guard fileManager.fileExists(atPath: chunkURL.path) else { continue }
            
            do {
                try fileManager.removeItem(at: chunkURL)
                deletedCount += 1
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .debug("Deleted chunk file: \(chunkURL.lastPathComponent, privacy: .public)")
            } catch {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .warning("Failed to delete chunk \(chunkIndex, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        
        if deletedCount > 0 {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                .info("Cleaned up \(deletedCount, privacy: .public) chunk files for section \(sectionIndex, privacy: .public), now using single section file")
        }
    }
    
    /// Updates composition to use a concatenated section file instead of individual chunks
    /// Rebuilds the entire video track to avoid timeline corruption
    private func useConcatenatedSection(sectionIndex: Int, sectionURL: URL) {
        guard let composition = self.composition,
              let player = self.player else { return }
        
        // Preserve playback state
        let currentTime = player.currentTime()
        let wasPlaying = (player.rate > 0)
        
        Task { @MainActor in
            do {
                // Rebuild video track with all loaded chunks/sections
                let totalVideoDuration = try await self.rebuildCompositionVideoTrack()
                
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .info("Rebuilt composition with concatenated section \(sectionIndex, privacy: .public), total duration: \(totalVideoDuration.seconds, privacy: .public)s")
                
                // Create new player item with rebuilt composition
                let newPlayerItem = AVPlayerItem(asset: composition)
                
                // Replace player item
                player.replaceCurrentItem(with: newPlayerItem)
                
                // Reinstall observers for new player item
                self.removeLoopObserver()
                self.installLoopObserver(for: newPlayerItem)
                
                // Restore playback state
                await player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
                
                if wasPlaying {
                    player.play()
                }
                
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .info("Composition update complete - seamless playback enabled for section \(sectionIndex, privacy: .public)")
            } catch {
                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                    .error("Failed to update composition with section: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
    
    /// Helper to determine which video file to use for a given time
    private func videoFileForTime(_ time: TimeInterval) -> (url: URL, startTime: TimeInterval, duration: TimeInterval)? {
        guard let session = mp4Session else { return nil }
        
        let sectionIndex = Int(time / sectionDuration)
        
        // Check if this section has been concatenated
        if concatenatedSections.contains(sectionIndex) {
            let sectionStart = TimeInterval(sectionIndex) * sectionDuration
            let sectionEnd = min(sectionStart + sectionDuration, videoItem.durationSeconds)
            return (
                url: session.sectionURL(for: sectionIndex),
                startTime: sectionStart,
                duration: sectionEnd - sectionStart
            )
        } else {
            // Use individual chunk
            let chunkIndex = Int(time / chunkDuration)
            let chunkStart = TimeInterval(chunkIndex) * chunkDuration
            let chunkEnd = min(chunkStart + chunkDuration, videoItem.durationSeconds)
            return (
                url: session.chunkURL(for: chunkIndex),
                startTime: chunkStart,
                duration: chunkEnd - chunkStart
            )
        }
    }
}
