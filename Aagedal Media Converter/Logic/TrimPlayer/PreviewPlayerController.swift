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
    struct AudioTrackOption: Identifiable, Equatable {
        let id: Int
        let position: Int
        let streamIndex: Int
        let mediaOptionIndex: Int?
        let title: String
        let subtitle: String?
    }

    // MARK: - Published State
    
    @Published var player: AVPlayer?
    @Published var isPreparing = false
    @Published var errorMessage: String?
    @Published private(set) var currentWaveformURL: URL?
    @Published var currentPlaybackTime: Double = 0
    @Published private(set) var currentPlaybackSpeed: Float = 1.0
    @Published private(set) var isReverseSimulating: Bool = false
    
    // Reverse simulation
    private var reverseSpeed: Int = 1 // 1x, 2x, 3x, 4x
    private var reverseTimer: Timer?
    
    // VLC trim observer
    var vlcTrimObserverTimer: Timer?
    @Published var previewAssets: PreviewAssets? {
        didSet { updateCurrentWaveform() }
    }
    @Published var isLoadingPreviewAssets = false
    @Published var isCapturingScreenshot = false
    @Published var isGeneratingFallbackPreview = false
    @Published var fallbackPreviewRange: ClosedRange<Double>?
    @Published var loadedChunks: Set<Int> = []
    @Published var fallbackStillImage: NSImage?
    @Published var fallbackStillTime: Double?
    @Published var isGeneratingFallbackStill = false
    @Published var isLoadingChunk = false
    @Published var pendingChunkTime: Double?
    @Published var loadingChunkIndex: Int?
    @Published var audioTrackOptions: [AudioTrackOption] = []
    
    // MARK: - Configuration
    
    let chunkDuration: TimeInterval = 5.0
    let previewMaxShortEdge: Int = 720
    var currentChunkIndex: Int = 0
    var chunkDurations: [Int: TimeInterval] = [:]
    var appliedChunks: Set<Int> = []
    
    // MARK: - State
    
    var videoItem: VideoItem
    var mp4Session: MP4PreviewSession?
    var preparationTask: Task<Void, Never>?
    var chunkLoadTask: Task<Void, Never>?
    var chunkPreloadTask: Task<Void, Never>?
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
    var composition: AVMutableComposition?
    var compositionVideoTrack: AVMutableCompositionTrack?
    var compositionAudioTrack: AVMutableCompositionTrack?
    weak var playerView: AVPlayerView?
    var previewAudioStreamIndices: [Int] = []
    var selectedAudioTrackOrderIndex: Int = 0
    
    // MARK: - VLC State
    var vlcPlayer: VLCPlayer?
    var useVLC = false
    
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
            updatePlayerActionAtEnd()
        } else if previous.trimStart != newValue.trimStart || previous.trimEnd != newValue.trimEnd {
            // Trim values changed, reinstall time observer with new boundaries
            if let player = player {
                installTimeObserver(for: player)
            }
        }
    }
    
    // MARK: - Preview Preparation
    
    func preparePreview(startTime: TimeInterval, resetAudioSelection: Bool = true) {
        teardown(resetAudioSelection: resetAudioSelection)
        isPreparing = true
        errorMessage = nil
        isLoadingPreviewAssets = true
        previewAssets = nil
        usePreviewFallback = false
        useVLC = false

        let currentItem = videoItem
        let url = currentItem.url
        
        // Try AVPlayer directly first with security-scoped resource access
        
        // First try bookmark-based access (more reliable for sandboxed apps)
        let bookmarkAccess = SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: url)
        let directAccess = !bookmarkAccess && url.startAccessingSecurityScopedResource()
        hasSecurityScope = bookmarkAccess || directAccess
        
        // Create asset with security-scoped access preference
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        
        self.player = player
        
        // Monitor player item status for failures, fallback to VLC if needed
        installPlayerItemStatusObserver(for: playerItem, startTime: startTime)
        
        self.isPreparing = false
        refreshAudioTrackOptions(for: currentItem, playerItem: playerItem)
        
        // Seek to start time but remain paused (don't auto-play)
        let seekTime = CMTime(seconds: startTime, preferredTimescale: 600)
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        
        installLoopObserver(for: playerItem)
        installTimeObserver(for: player)
        installPlaybackTimeObserver(for: player)
        updatePlayerActionAtEnd()
        loadPreviewAssets(for: currentItem.url)
    }
    
    var debugWindowController: Any? // Holds strong reference to keep window alive

    func setupVLC(url: URL, startTime: Double) {
        // Explicitly nil the player to prevent key consumption
        player = nil
        
        let vlc = VLCPlayer()
        self.vlcPlayer = vlc
        self.useVLC = true
        self.isPreparing = false
        
        // Load without autostarting
        vlc.load(url: url, autostart: false)
        
        // Seek to start position
        // IMPORTANT: Seeking can trigger playback on some VLC versions, so pause immediately after
        if startTime > 0 {
            vlc.seek(to: startTime)
            // Ensure we're paused after seek (in case seek triggered playing)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                vlc.pause()
            }
        }
        
        // Sync time
        Task { @MainActor [weak self, weak vlc] in
            guard let self, let vlc else { return }
            for await time in vlc.$timePos.values {
                self.currentPlaybackTime = time
            }
        }
        
        // Install VLC trim boundary observer for looping
        installVLCTrimObserver()
        
        // DON'T call updateCurrentWaveform() here!
        // It will be called automatically via previewAssets.didSet when assets finish loading
    }
    
    // MARK: - Unified Playback Control
    
    func togglePlayback() {
        // If reversing, K/Space should just stop reverse (stay paused)
        if isReverseSimulating {
            stopReverseSimulation()
            return
        }
        
        if useVLC, let vlc = vlcPlayer {
            // Check if currently playing
            let wasPlaying = vlc.isPlaying
            // Reset rate FIRST, ensure it's applied
            vlc.rate = 1.0
            currentPlaybackSpeed = 1.0
            
            if wasPlaying {
                vlc.pause()
            } else {
                // Make sure rate is 1.0 before playing
                vlc.play()
            }
        } else if let player = player {
            currentPlaybackSpeed = 1.0
            if player.rate != 0 {
                player.pause()
            } else {
                player.rate = 1.0
                player.play()
            }
        }
    }
    
    func pause() {
        stopReverseSimulation()
        
        if useVLC, let vlc = vlcPlayer {
            // Reset rate FIRST, then pause
            vlc.rate = 1.0
            currentPlaybackSpeed = 1.0
            vlc.pause()
        } else {
            currentPlaybackSpeed = 1.0
            player?.pause()
        }
    }
    
    func stepRate(forward: Bool) {
        if useVLC, let vlc = vlcPlayer {
            // VLC rate stepping: 0.5 -> 1.0 -> 1.5 -> 2.0 etc
            let current = vlc.rate
            let step: Float = 0.5
            let newRate = forward ? current + step : current - step
            vlc.rate = max(0.25, min(newRate, 4.0))
            currentPlaybackSpeed = vlc.rate
        } else if let player = player {
            // AVPlayer rate stepping
            let current = player.rate
            let step: Float = 1.0
            let newRate = forward ? current + step : current - step
            player.rate = newRate
            currentPlaybackSpeed = player.rate
        }
    }
    
    func startReverseSimulation() {
        // If already reversing, increase speed (max 4x)
        if isReverseSimulating {
            reverseSpeed = min(reverseSpeed + 1, 4)
            // Restart timer with new speed
            reverseTimer?.invalidate()
            let interval = (1.0/24.0) / Double(reverseSpeed)
            reverseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.seekByFrames(-1)
            }
            currentPlaybackSpeed = -Float(reverseSpeed)
            return
        }
        
        // Start new reverse simulation
        pause()
        reverseSpeed = 1
        isReverseSimulating = true
        currentPlaybackSpeed = -1.0
        
        // Start reverse simulation (step backwards at ~24fps)
        let interval = 1.0/24.0
        reverseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.seekByFrames(-1)
        }
    }
    
    func stopReverseSimulation() {
        isReverseSimulating = false
        reverseSpeed = 1
        reverseTimer?.invalidate()
        reverseTimer = nil
        // Reset speed when stopping reverse
        if !isReverseSimulating {
            currentPlaybackSpeed = 1.0
        }
    }
    
    func rewind() {
        stopReverseSimulation()
        stepRate(forward: false)
    }
    
    func fastForward() {
        // If reversing, L stops reverse
        if isReverseSimulating {
            stopReverseSimulation()
            return
        }
        
        // If paused, start playing at 1×
        if useVLC, let vlc = vlcPlayer {
            if !vlc.isPlaying {
                vlc.rate = 1.0
                currentPlaybackSpeed = 1.0
                vlc.play()
                return
            }
        } else if let player = player {
            if player.rate == 0 {
                player.rate = 1.0
                currentPlaybackSpeed = 1.0
                player.play()
                return
            }
        }
        
        // Otherwise increase forward speed
        stepRate(forward: true)
    }
    
    func seek(by seconds: Double) {
        let currentTime = getCurrentTime() ?? videoItem.effectiveTrimStart
        let newTime = currentTime + seconds
        seekTo(max(videoItem.effectiveTrimStart, min(newTime, videoItem.effectiveTrimEnd)))
    }
    
    func seekByFrames(_ frameCount: Int) {
        // Calculate seconds per frame from video metadata
        if let frameRate = videoItem.metadata?.videoStream?.frameRate,
           let frameRateValue = frameRate.value, frameRateValue > 0 {
            let secondsPerFrame = 1.0 / frameRateValue
            seek(by: Double(frameCount) * secondsPerFrame)
        } else {
            // Fallback to 1/30th second if no frame rate available
            seek(by: Double(frameCount) / 30.0)
        }
    }

    /// Determines the preferred ordering of audio stream indices based on metadata (default + channel count).
    nonisolated func determineAudioStreamOrder(for item: VideoItem) async -> [Int] {
        if let metadata = item.metadata {
            return orderAudioStreams(from: metadata)
        }
        if let metadata = try? await VideoMetadataService.shared.metadata(for: item.url) {
            return orderAudioStreams(from: metadata)
        }
        return []
    }
    
    nonisolated private func orderAudioStreams(from metadata: VideoMetadata) -> [Int] {
        guard !metadata.audioStreams.isEmpty else { return [] }
        // Default stream first, fall back to original order, then by descending channel count.
        let sorted = metadata.audioStreams.enumerated().sorted { lhs, rhs in
            let lhsDefault = metadata.isDefaultAudioStream(index: lhs.offset)
            let rhsDefault = metadata.isDefaultAudioStream(index: rhs.offset)
            if lhsDefault != rhsDefault { return lhsDefault }
            let lhsChannels = lhs.element.channels ?? 0
            let rhsChannels = rhs.element.channels ?? 0
            if lhsChannels != rhsChannels { return lhsChannels > rhsChannels }
            return lhs.offset < rhs.offset
        }
        return sorted.map { $0.offset }
    }

    private func refreshAudioTrackOptions(for item: VideoItem, playerItem: AVPlayerItem?) {
        let existingSelection = selectedAudioTrackOrderIndex
        Task { @MainActor [weak self] in
            guard let self else { return }

            let metadata: VideoMetadata?
            if let cached = item.metadata {
                metadata = cached
            } else {
                metadata = try? await VideoMetadataService.shared.metadata(for: item.url)
            }

            let orderedIndices = metadata.map { self.orderAudioStreams(from: $0) } ?? []
            let mediaGroup: AVMediaSelectionGroup?
            if let playerItem {
                mediaGroup = try? await playerItem.asset.loadMediaSelectionGroup(for: .audible)
            } else {
                mediaGroup = nil
            }

            if !orderedIndices.isEmpty {
                self.previewAudioStreamIndices = orderedIndices
            }

            self.buildAudioTrackOptions(metadata: metadata, orderedIndices: orderedIndices, mediaGroup: mediaGroup)

            if self.audioTrackOptions.isEmpty {
                self.selectedAudioTrackOrderIndex = 0
            } else {
                let clamped = min(max(existingSelection, 0), self.audioTrackOptions.count - 1)
                self.selectedAudioTrackOrderIndex = clamped
            }

            self.applySelectedAudioTrack()
        }
    }

    private func buildAudioTrackOptions(metadata: VideoMetadata?, orderedIndices: [Int], mediaGroup: AVMediaSelectionGroup?) {
        let metadataStreams = metadata?.audioStreams ?? []
        let effectiveOrder = orderedIndices.isEmpty ? Array(metadataStreams.indices) : orderedIndices
        let mediaOptions = mediaGroup?.options ?? []

        if metadataStreams.isEmpty && mediaOptions.isEmpty {
            audioTrackOptions = []
            return
        }

        var options: [AudioTrackOption] = []
        let count = max(effectiveOrder.count, mediaOptions.count)
        for position in 0..<count {
            let streamIndex = effectiveOrder.indices.contains(position) ? effectiveOrder[position] : position
            let stream = metadataStreams.indices.contains(streamIndex) ? metadataStreams[streamIndex] : nil
            let mediaOption = mediaOptions.indices.contains(position) ? mediaOptions[position] : nil
            let mediaOptionIndex = mediaOptions.indices.contains(position) ? position : nil

            let title: String
            if let stream {
                title = self.formattedAudioTrackTitle(for: stream, position: position)
            } else if let mediaOption {
                title = mediaOption.displayName
            } else {
                title = "Audio Track \(position + 1)"
            }

            var details: [String] = []
            if let stream {
                if stream.isDefault {
                    details.append("Default")
                }
                if let channels = stream.channels {
                    details.append("\(channels) ch")
                }
                if let sampleRate = stream.sampleRate {
                    details.append("\(sampleRate) Hz")
                }
                if let codec = stream.codecLongName ?? stream.codec {
                    details.append(codec)
                }
            }

            if let mediaOption, details.isEmpty {
                if let locale = mediaOption.locale {
                    details.append(locale.localizedString(forLanguageCode: locale.language.languageCode?.identifier ?? "") ?? locale.identifier)
                }
            }

            options.append(
                AudioTrackOption(
                    id: streamIndex,
                    position: position,
                    streamIndex: streamIndex,
                    mediaOptionIndex: mediaOptionIndex,
                    title: title,
                    subtitle: details.isEmpty ? nil : details.joined(separator: " • ")
                )
            )
        }

        audioTrackOptions = options
    }

    private func formattedAudioTrackTitle(for stream: VideoMetadata.AudioStream, position: Int) -> String {
        var components: [String] = []

        if let index = stream.index {
            components.append("#\(index)")
        } else {
            components.append("#\(position)")
        }

        if let language = stream.languageCode, !language.isEmpty {
            components.append(language)
        }

        if let codecName = stream.codecLongName ?? stream.codec, !codecName.isEmpty {
            components.append(codecName)
        }

        if let layout = stream.channelLayout, !layout.isEmpty {
            components.append(layout)
        }

        if components.isEmpty {
            return "Audio Track \(position + 1)"
        }

        return components.joined(separator: " – ")
    }

    func selectAudioTrack(at position: Int) {
        guard position != selectedAudioTrackOrderIndex else { return }
        selectedAudioTrackOrderIndex = position
        applySelectedAudioTrack()
        updateCurrentWaveform()
    }

    private func applySelectedAudioTrack() {
        if usePreviewFallback {
            refreshFallbackAudioSelection()
        } else {
            applySelectedAudioTrackToCurrentPlayerItem()
        }
        updateCurrentWaveform()
    }

    private func applySelectedAudioTrackToCurrentPlayerItem() {
        guard !usePreviewFallback,
              !audioTrackOptions.isEmpty,
              let playerItem = player?.currentItem else { return }

        let desiredPosition = min(max(selectedAudioTrackOrderIndex, 0), audioTrackOptions.count - 1)

        Task { @MainActor [weak playerItem, weak self] in
            guard let self, let playerItem else { return }
            let mediaGroup: AVMediaSelectionGroup?
            do {
                mediaGroup = try await playerItem.asset.loadMediaSelectionGroup(for: .audible)
            } catch {
                return
            }
            guard let mediaGroup, !mediaGroup.options.isEmpty else { return }

            let option = self.audioTrackOptions[min(desiredPosition, self.audioTrackOptions.count - 1)]
            let optionIndex: Int
            if let mappedIndex = option.mediaOptionIndex, mediaGroup.options.indices.contains(mappedIndex) {
                optionIndex = mappedIndex
            } else {
                optionIndex = min(desiredPosition, mediaGroup.options.count - 1)
            }

            guard mediaGroup.options.indices.contains(optionIndex) else { return }
            let selectedOption = mediaGroup.options[optionIndex]

            if playerItem.currentMediaSelection.selectedMediaOption(in: mediaGroup) != selectedOption {
                playerItem.select(selectedOption, in: mediaGroup)
            }
        }
    }

    private func refreshFallbackAudioSelection() {
        let currentTime = getCurrentTime() ?? videoItem.effectiveTrimStart
        teardown(resetAudioSelection: false)
        preparePreview(startTime: currentTime, resetAudioSelection: false)
    }

    private func selectedAudioStreamIndex() -> Int? {
        let position = selectedAudioTrackOrderIndex
        guard audioTrackOptions.indices.contains(position) else { return nil }
        return audioTrackOptions[position].streamIndex
    }

    private func updateCurrentWaveform() {
        let streamIndex = selectedAudioStreamIndex()
        currentWaveformURL = previewAssets?.waveform(forAudioStream: streamIndex)
        Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview").debug("Updated waveform URL: \(self.currentWaveformURL?.lastPathComponent ?? "nil", privacy: .public) for stream index: \(streamIndex ?? -1)")
    }
    
    func teardown(resetAudioSelection: Bool = true) {
        preparationTask?.cancel()
        preparationTask = nil
        chunkLoadTask?.cancel()
        chunkLoadTask = nil
        chunkPreloadTask?.cancel()
        chunkPreloadTask = nil
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
        
        if let vlc = vlcPlayer {
            vlc.stop()
            vlcPlayer = nil
        }
        useVLC = false

        isPreparing = false
        isGeneratingFallbackPreview = false
        isLoadingChunk = false
        loadingChunkIndex = nil
        isGeneratingFallbackStill = false
        fallbackPreviewRange = nil
        loadedChunks = []
        currentChunkIndex = 0
        chunkDurations.removeAll()
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
        pendingChunkTime = nil
        appliedChunks.removeAll()
        previewAudioStreamIndices = []
        if resetAudioSelection {
            selectedAudioTrackOrderIndex = 0
        }
        audioTrackOptions = []
        currentWaveformURL = nil
    }
    
    // MARK: - Playback Control
    
    func refreshPreviewForTrim() {
        if useVLC, let vlc = vlcPlayer {
            vlc.seek(to: videoItem.effectiveTrimStart)
            return
        }
        
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
        
        if useVLC, let vlc = vlcPlayer {
            vlc.seek(to: time)
            return
        }
        
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
                //scheduleQuickStillIfNeeded(for: time)
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
                    //scheduleQuickStillIfNeeded(for: time)
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
        // Return the UI's current playhead position
        // This is the authoritative source - it updates when:
        // - Player is playing (continuously synced from player)
        // - User drags the playhead (set by UI)
        // - User seeks with keyboard (updated before seeking)
        return currentPlaybackTime
    }
    
    func isChunkAvailable(for time: Double) -> Bool {
        let chunkIndex = Int(time / chunkDuration)
        if loadedChunks.contains(chunkIndex) {
            return true
        }
        if let range = fallbackPreviewRange, range.contains(time) {
            return true
        }
        return false
    }
    
    func restoreCachedChunkState(from cacheDirectory: URL) async {
        let fileManager = FileManager.default
        var chunkIndices = Set<Int>()
        let chunksDirectory = cacheDirectory.appendingPathComponent("chunks", isDirectory: true)
        if fileManager.fileExists(atPath: chunksDirectory.path),
           let chunkContents = try? fileManager.contentsOfDirectory(at: chunksDirectory, includingPropertiesForKeys: nil) {
            for url in chunkContents {
                let name = url.lastPathComponent
                if let chunk = parseIndex(in: name, prefix: "preview_chunk_", suffix: ".mp4") {
                    if await validatePreviewFile(at: url) {
                        chunkIndices.insert(chunk)
                        if let duration = await loadDuration(for: url) {
                            chunkDurations[chunk] = duration
                        }
                    } else {
                        try? fileManager.removeItem(at: url)
                    }
                }
            }
        }

        // Backwards compatibility: older caches stored chunk/section files at the root of cacheDirectory
        if let legacyContents = try? fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            for url in legacyContents where url.hasDirectoryPath == false {
                let name = url.lastPathComponent
                if let chunk = parseIndex(in: name, prefix: "preview_chunk_", suffix: ".mp4") {
                    if await validatePreviewFile(at: url) {
                        chunkIndices.insert(chunk)
                        if let duration = await loadDuration(for: url) {
                            chunkDurations[chunk] = duration
                        }
                    } else {
                        try? fileManager.removeItem(at: url)
                    }
                }
            }
        }

        loadedChunks = chunkIndices
        updateFallbackCoverageRange()
    }

    func updateFallbackCoverageRange() {
        guard !loadedChunks.isEmpty else {
            fallbackPreviewRange = nil
            return
        }

        let sortedChunks = loadedChunks.sorted()
        guard let firstIndex = sortedChunks.first else {
            fallbackPreviewRange = nil
            return
        }

        let rangeStart = Double(firstIndex) * chunkDuration
        var rangeEnd = rangeStart + (chunkDurations[firstIndex] ?? chunkDuration)
        var previousIndex = firstIndex

        for index in sortedChunks.dropFirst() {
            if index != previousIndex + 1 {
                break
            }

            let chunkStart = Double(index) * chunkDuration
            let chunkEnd = chunkStart + (chunkDurations[index] ?? chunkDuration)
            rangeEnd = max(rangeEnd, chunkEnd)
            previousIndex = index
        }

        let newRange = rangeStart...rangeEnd
        fallbackPreviewRange = newRange
    }

    private func loadDuration(for url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            guard duration.seconds.isFinite, duration.seconds > 0 else { return nil }
            return duration.seconds
        } catch {
            return nil
        }
    }

    private func parseIndex(in name: String, prefix: String, suffix: String) -> Int? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        return Int(name[start..<end])
    }

    private func validatePreviewFile(at url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else { throw MP4PreviewSession.PreviewError.outputMissing }
            let duration = try await asset.load(.duration)
            guard duration.seconds.isFinite, duration.seconds > 0 else { throw MP4PreviewSession.PreviewError.outputMissing }
            return true
        } catch {
            Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                .warning("Discarding invalid cached preview file \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
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
                if let cached = await PreviewAssetGenerator.shared.cachedAssetsIfPresent(for: url),
                   !cached.thumbnails.isEmpty || cached.waveform != nil || !cached.audioWaveforms.isEmpty {
                    self.previewAssets = cached
                    self.isLoadingPreviewAssets = false
                    return
                }
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
