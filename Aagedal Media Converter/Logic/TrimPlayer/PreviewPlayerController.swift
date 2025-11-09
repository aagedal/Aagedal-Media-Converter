// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Controller for video preview playback, trimming, and screenshot capture.
// Extensions: +Screenshot, +FallbackPreview, +Observers

import SwiftUI
import AppKit
import AVKit
import OSLog

@MainActor
final class PreviewPlayerController: ObservableObject {
    // MARK: - Published State
    
    @Published internal(set) var player: AVPlayer?
    @Published internal(set) var audioPlayer: AVPlayer?
    @Published internal(set) var isPreparing = false
    @Published internal(set) var errorMessage: String?
    @Published internal(set) var currentPlaybackTime: Double = 0
    @Published internal(set) var previewAssets: PreviewAssets?
    @Published internal(set) var isLoadingPreviewAssets = false
    @Published internal(set) var isCapturingScreenshot = false
    @Published internal(set) var isGeneratingFallbackPreview = false
    @Published internal(set) var fallbackPreviewRange: ClosedRange<Double>?
    @Published internal(set) var loadedChunks: Set<Int> = []
    @Published internal(set) var fallbackStillImage: NSImage?
    @Published internal(set) var fallbackStillTime: Double?
    @Published internal(set) var isGeneratingFallbackStill = false
    @Published internal(set) var isLoadingChunk = false
    
    // MARK: - Configuration
    
    let chunkDuration: TimeInterval = 15.0
    let sectionDuration: TimeInterval = 60.0
    let chunksPerSection: Int = 4
    let previewMaxShortEdge: Int = 720
    var currentChunkIndex: Int = 0
    var concatenatedSections: Set<Int> = []
    
    // MARK: - State
    
    var videoItem: VideoItem
    var mp4Session: MP4PreviewSession?
    var preparationTask: Task<Void, Never>?
    var chunkLoadTask: Task<Void, Never>?
    var previewAssetTask: Task<Void, Never>?
    var fallbackStillTask: Task<Void, Never>?
    var loopObserver: Any?
    var timeObserver: Any?
    var playbackTimeObserver: Any?
    var audioSyncObserver: Any?
    weak var timeObserverOwner: AVPlayer?
    weak var playbackTimeObserverOwner: AVPlayer?
    weak var audioSyncObserverOwner: AVPlayer?
    var playerItemStatusObserver: Any?
    var hasSecurityScope = false
    var usePreviewFallback = false
    var isSwappingAudio = false
    var composition: AVMutableComposition?
    var compositionVideoTrack: AVMutableCompositionTrack?
    var compositionAudioTrack: AVMutableCompositionTrack?
    weak var playerView: AVPlayerView?
    
    // MARK: - Initialization
    
    var playbackTimePublisher: Published<Double>.Publisher { $currentPlaybackTime }

    init(videoItem: VideoItem) {
        self.videoItem = videoItem
    }
    
    // MARK: - Video Item Management
    
    func updateVideoItem(_ newValue: VideoItem) {
        let previous = videoItem
        videoItem = newValue

        if previous.id != newValue.id || previous.url != newValue.url {
            preparePreview(startTime: newValue.effectiveTrimStart)
            loadPreviewAssets(for: newValue.url)
        } else if previous.loopPlayback != newValue.loopPlayback {
            applyLoopSetting()
        } else if previous.trimStart != newValue.trimStart || previous.trimEnd != newValue.trimEnd {
            // Trim values changed, reinstall time observer with new boundaries
            if let player = player {
                installTimeObserver(for: player)
            }
        }
    }
    
    // MARK: - Preview Preparation
    
    func preparePreview(startTime: TimeInterval) {
        teardown()
        isPreparing = true
        errorMessage = nil
        isLoadingPreviewAssets = true
        previewAssets = nil
        usePreviewFallback = false

        let currentItem = videoItem
        
        // Try AVPlayer directly first with security-scoped resource access
        let url = currentItem.url
        
        // First try bookmark-based access (more reliable for sandboxed apps)
        let bookmarkAccess = SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: url)
        let directAccess = !bookmarkAccess && url.startAccessingSecurityScopedResource()
        hasSecurityScope = bookmarkAccess || directAccess
        
        // Create asset with security-scoped access preference
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        
        self.player = player
        
        // Monitor player item status for failures, fallback to HLS if needed
        installPlayerItemStatusObserver(for: playerItem, startTime: startTime)
        
        self.isPreparing = false
        
        // Seek to start time but remain paused (don't auto-play)
        let seekTime = CMTime(seconds: startTime, preferredTimescale: 600)
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        
        installLoopObserver(for: playerItem)
        installTimeObserver(for: player)
        installPlaybackTimeObserver(for: player)
        applyLoopSetting()
        loadPreviewAssets(for: currentItem.url)
    }
    
    func teardown() {
        preparationTask?.cancel()
        preparationTask = nil
        chunkLoadTask?.cancel()
        chunkLoadTask = nil
        previewAssetTask?.cancel()
        previewAssetTask = nil
        fallbackStillTask?.cancel()
        fallbackStillTask = nil

        player?.pause()
        
        // Release security-scoped resource only if we acquired it
        if hasSecurityScope {
            let url = videoItem.url
            // Try both release methods to ensure cleanup
            SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: url)
            url.stopAccessingSecurityScopedResource()
            hasSecurityScope = false
        }
        
        player = nil
        if let session = mp4Session {
            mp4Session = nil
            Task { await session.cancel(); await session.cleanup() }
        }

        isPreparing = false
        isGeneratingFallbackPreview = false
        isLoadingChunk = false
        isGeneratingFallbackStill = false
        fallbackPreviewRange = nil
        loadedChunks = []
        currentChunkIndex = 0
        fallbackStillImage = nil
        fallbackStillTime = nil
        removeLoopObserver()
        removeTimeObserver()
        removePlaybackTimeObserver()
        removePlayerItemStatusObserver()
        usePreviewFallback = false
        composition = nil
        compositionVideoTrack = nil
        compositionAudioTrack = nil
        isSwappingAudio = false
    }
    
    // MARK: - Playback Control
    
    func refreshPreviewForTrim() {
        guard let player else {
            preparePreview(startTime: videoItem.effectiveTrimStart)
            return
        }
        
        // Check if currently playing
        let isPlaying = player.rate > 0
        
        // Seek to the new trim start position
        let seekTime = CMTime(seconds: videoItem.effectiveTrimStart, preferredTimescale: 600)
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard finished, let self = self, isPlaying else { return }
                // Only resume playback if it was playing before
                self.player?.play()
            }
        }
    }
    
    func seekTo(_ time: Double) {
        // Update playback time immediately for UI responsiveness
        currentPlaybackTime = time
        
        guard let player else { return }
        
        // If using composition-based fallback (continuous audio)
        if usePreviewFallback, composition != nil {
            let targetChunk = Int(time / chunkDuration)
            
            // Load chunk if needed (triggers in background)
            if targetChunk != currentChunkIndex && !isLoadingChunk {
                loadChunkForTime(time)
            }
            
            // Seek to absolute time in composition (audio continues)
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            return
        }
        
        // If using legacy fallback preview with chunks (old system)
        if usePreviewFallback {
            let targetChunk = Int(time / chunkDuration)
            
            // Check if we need to load a different chunk (forward OR backward)
            if targetChunk != currentChunkIndex {
                // Load the chunk for this time
                loadChunkForTime(time)
                return
            }
            
            // Same chunk - check if within range
            if let range = fallbackPreviewRange {
                if time >= range.lowerBound && time <= range.upperBound {
                    // Within current chunk range - seek to relative position
                    let timeInChunk = time - range.lowerBound
                    let cmTime = CMTime(seconds: timeInChunk, preferredTimescale: 600)
                    player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    return
                } else {
                    // Outside chunk range but same chunk index (at edge) - generate still
                    generateFallbackStillIfNeeded(for: time)
                    player.pause()
                    return
                }
            }
        }
        
        // Not using fallback - seek normally
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    func getCurrentTime() -> TimeInterval? {
        guard let player else { return nil }
        let currentTime = player.currentTime()
        guard currentTime.seconds.isFinite else { return nil }
        
        // For composition-based playback, time is already absolute
        if usePreviewFallback, composition != nil {
            return currentTime.seconds
        }
        
        // For legacy chunked playback, calculate absolute time
        if usePreviewFallback, let previewRange = fallbackPreviewRange {
            return previewRange.lowerBound + currentTime.seconds
        }
        
        return currentTime.seconds
    }
    
    func toggleFullscreen() {
        // Try to get window from playerView first, fallback to key window
        let window = playerView?.window ?? NSApp.keyWindow
        window?.toggleFullScreen(nil)
    }
    
    // MARK: - Preview Assets
    
    func loadPreviewAssets(for url: URL) {
        previewAssetTask?.cancel()
        isLoadingPreviewAssets = true
        previewAssetTask = Task { [weak self] in
            guard let self else { return }
            do {
                let assets = try await PreviewAssetGenerator.shared.generateAssets(for: url)
                try Task.checkCancellation()
                self.previewAssets = assets
            } catch {
                self.previewAssets = nil
                if (error as? CancellationError) == nil {
                    Logger(subsystem: "com.aagedal.MediaConverter", category: "PreviewAssets").error("Failed to load preview assets for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
            self.isLoadingPreviewAssets = false
        }
    }
}
