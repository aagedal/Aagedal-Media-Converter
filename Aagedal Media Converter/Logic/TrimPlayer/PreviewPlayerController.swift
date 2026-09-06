// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Controller for video preview playback, trimming, and screenshot capture.
// Extensions: +Screenshot, +Observers

import SwiftUI
import AppKit
@preconcurrency import AVKit
@preconcurrency import AVFoundation
import Combine
import OSLog

@MainActor
final class PreviewPlayerController: ObservableObject {
    let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")

    struct AudioTrackOption: Identifiable, Equatable {
        let id: Int
        let position: Int
        let streamIndex: Int
        let mediaOptionIndex: Int?
        let title: String
        let subtitle: String?
    }

    struct SubtitleTrackOption: Identifiable, Equatable {
        let id: Int
        let position: Int
        let trackId: Int32
        let title: String
    }

    // MARK: - Published State
    
    @Published var volume: Double = 100 {
        didSet {
            if useMPV, let mpvPlayer {
                mpvPlayer.volume = volume
            }
            if let audioPlayer = imageSequenceAudioPlayer {
                audioPlayer.volume = Float(volume / 100.0)
            }
        }
    }
    @Published var isMuted: Bool = false {
        didSet {
            if useMPV, let mpvPlayer {
                mpvPlayer.isMuted = isMuted
            }
            if let audioPlayer = imageSequenceAudioPlayer {
                audioPlayer.isMuted = isMuted
            }
        }
    }
    @Published var player: AVPlayer?
    @Published var isPreparing = false
    @Published var isReady = false
    @Published var errorMessage: String?
    @Published private(set) var currentWaveformURL: URL?
    @Published private(set) var currentWaveformChunks: [WaveformChunk] = []
    @Published private(set) var currentNativeWaveformImage: NSImage?
    @Published private(set) var currentChannelWaveformImages: [NSImage] = []
    @Published private(set) var currentChannelWaveformLabels: [String] = []
    @Published private(set) var currentChapters: [Chapter] = []
    @Published private(set) var totalDuration: Double = 0  // For chunk width calculation
    @Published var currentPlaybackTime: Double = 0
    @Published private(set) var currentPlaybackSpeed: Float = 1.0
    @Published private(set) var isReverseSimulating: Bool = false
    // Audio monitoring is defined in extension/bottom section
    
    // Reverse simulation
    private var reverseSpeed: Int = 1
    private let slowSteps: [Float] = [0.75, 0.5, 0.25, 0.1]
    private var reverseTimer: Timer?

    /// Effective video frame rate (falls back to 30 if metadata is unavailable).
    private var effectiveFPS: Double {
        if let frameRate = videoItem.metadata?.primaryVideoStream?.frameRate,
           let v = frameRate.value, v > 0 { return v }
        return 30.0
    }

    /// Whether playback is currently active (any engine).
    var isPlaying: Bool {
        if isReverseSimulating { return true }
        if useImageSequence { return isImageSequencePlaying }
        if useMPV, let mpv = mpvPlayer { return mpv.isPlaying }
        return (player?.rate ?? 0) != 0
    }
    
    // MPV trim observer
    var mpvTrimObserverTimer: Timer?
    @Published var previewAssets: PreviewAssets? {
        didSet { updateCurrentWaveform() }
    }
    @Published var isLoadingPreviewAssets = false
    @Published var isCapturingScreenshot = false
    @Published var audioTrackOptions: [AudioTrackOption] = []
    @Published var subtitleTrackOptions: [SubtitleTrackOption] = []
    @Published var isCropEnabled: Bool = false

    // MARK: - State

    var videoItem: VideoItem
    let screenshotCaptureSubprocess: ScreenshotCaptureSubprocess
    var screenshotCaptureTask: Task<Void, Error>?
    var screenshotCaptureOperationID: UUID?
    var preparationTask: Task<Void, Never>?
    var previewAssetTask: Task<Void, Never>?
    private var previewAssetURL: URL?  // Track URL being processed to avoid redundant cancellation
    private var chapterProbeTask: Task<Void, Never>?
    private var chapterProbeURL: URL?
    private var audioTrackRefreshTask: Task<Void, Never>?
    private var audioTrackRefreshID: UUID?
    var loopObserver: Any?
    var loopObserverID: UUID?
    var playbackDidFinish: (() -> Void)?
    var timeObserver: Any?
    var timeObserverID: UUID?
    var playbackTimeObserver: Any?
    var playbackTimeObserverID: UUID?
    weak var timeObserverOwner: AVPlayer?
    weak var playbackTimeObserverOwner: AVPlayer?
    var playerItemStatusObserver: Any?
    var playerItemStatusObserverID: UUID?
    var playerItemStatusOperationID: UUID?
    var playerItemStatusTask: Task<Void, Never>?
    private var audioSelectionTask: Task<Void, Never>?
    private var audioSelectionOperationID: UUID?
    var mpvEndObserver: AnyCancellable?
    var primaryAccess: SecurityScopedAccess = .none
    var imageSequenceAudioAccess: SecurityScopedAccess = .none
    weak var playerView: AVPlayerView?
    var selectedAudioTrackOrderIndex: Int = 0
    var selectedSubtitleTrackOrderIndex: Int = -1  // -1 means subtitles disabled

    // MARK: - Audio Monitoring
    // UniversalAudioMeterService is defined below in Audio Metering section
    
    // MARK: - MPV State
    @Published var mpvPlayer: MPVPlayer?
    @Published var useMPV = false

    // MARK: - Image Sequence State
    @Published var useImageSequence = false
    @Published var imageSequenceFrame: NSImage?
    @Published var isImageSequencePlaying = false
    private var imageSequenceConfig: ImageSequenceConfig?
    private var imageSequencePlaybackTimer: Timer?
    private var imageSequenceAudioPlayer: AVPlayer?

    // MARK: - Initialization
    
    var playbackTimePublisher: Published<Double>.Publisher { $currentPlaybackTime }

    /// Returns the effective duration, preferring video item metadata but falling back to player duration
    /// This allows the timeline to be interactive even before metadata loads
    var effectiveDuration: Double {
        // First try the video item's duration (from metadata)
        if videoItem.durationSeconds > 0 {
            return videoItem.durationSeconds
        }
        // Fall back to MPV player's duration if available
        if let mpvDuration = mpvPlayer?.duration, mpvDuration > 0 {
            return mpvDuration
        }
        // Fall back to AVPlayer's duration if available
        if let playerDuration = player?.currentItem?.duration.seconds,
           playerDuration.isFinite && playerDuration > 0 {
            return playerDuration
        }
        return 0
    }

    init(
        videoItem: VideoItem,
        screenshotCaptureSubprocess: ScreenshotCaptureSubprocess = ScreenshotCaptureSubprocess()
    ) {
        self.videoItem = videoItem
        self.screenshotCaptureSubprocess = screenshotCaptureSubprocess
        setupAudioMonitoring()
    }
    
    // MARK: - Video Item Management
    
    func updateVideoItem(_ newValue: VideoItem) {
        let previous = videoItem
        videoItem = newValue

        if previous.id != newValue.id || previous.url != newValue.url {
            preparePreview(startTime: newValue.effectiveTrimStart)
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

    /// Check if the video has surround audio (any track with more than 2 channels)
    /// QuickTime/AVPlayer doesn't handle surround audio well, so we use MPV for these files
    private var hasSurroundAudio: Bool {
        guard let audioStreams = videoItem.metadata?.audioStreams else { return false }
        return audioStreams.contains { ($0.channels ?? 0) > 2 }
    }

    /// Check if the video codec is ProRes (any variant including RAW)
    /// ProRes files handle surround audio correctly in AVPlayer, unlike other codecs
    private var hasProResVideoCodec: Bool {
        guard let videoStream = videoItem.metadata?.primaryVideoStream,
              let codec = videoStream.codec?.lowercased() else { return false }

        // ProRes variants (including ProRes RAW) handle surround audio correctly in AVPlayer
        // Other codecs like HEVC may have silent audio with certain surround layouts (e.g., 5.1 side AAC)
        let proresCodecs = [
            "prores", "prores_ks",           // ProRes (all profiles)
            "ap4h", "ap4x",                   // ProRes 4444 / 4444 XQ
            "apcn", "apch", "apcs", "apco",   // ProRes 422 variants
            "aprn", "aprh",                   // ProRes RAW / RAW HQ
        ]

        return proresCodecs.contains { codec.contains($0) }
    }

    func preparePreview(startTime: TimeInterval, resetAudioSelection: Bool = true) {
        teardown(resetAudioSelection: resetAudioSelection)
        isPreparing = true
        isReady = false
        errorMessage = nil
        isLoadingPreviewAssets = true
        previewAssets = nil
        useMPV = false
        useImageSequence = false

        // Image sequence preview: load frames directly from disk
        if let config = videoItem.imageSequenceConfig {
            setupImageSequencePreview(config: config, startTime: startTime)
            return
        }

        let url = videoItem.url
        let fileExtension = url.pathExtension.lowercased()

        // Formats with no in-app decoder (e.g. AV2 .ivf): don't attempt any player or asset
        // generation — the preview UI shows a "not previewable" message for these instead.
        if AppConstants.previewUnsupportedExtensions.contains(fileExtension) {
            logger.info("Preview unavailable for unsupported format: \(url.lastPathComponent, privacy: .public)")
            isPreparing = false
            isReady = false
            isLoadingPreviewAssets = false
            return
        }

        // Force MPV for container formats that AVPlayer doesn't support well
        // MKV, WebM, AVI, FLV etc. often fail silently with AVPlayer
        let avPlayerUnsupportedContainers = ["mkv", "webm", "avi", "flv", "wmv", "ogv", "ts", "mts", "m2ts"]
        if avPlayerUnsupportedContainers.contains(fileExtension) {
            logger.info("Using MPV for \(fileExtension.uppercased(), privacy: .public) container: \(url.lastPathComponent, privacy: .public)")
            setupMPV(url: url, startTime: startTime)
            return
        }

        // Force MPV for surround audio files - but not for ProRes
        // ProRes handles surround audio correctly, other codecs (HEVC, H.264) may have silent audio
        if hasSurroundAudio && !hasProResVideoCodec {
            logger.info("Surround audio detected with non-ProRes codec, using MPV player for \(url.lastPathComponent, privacy: .public)")
            setupMPV(url: url, startTime: startTime)
            return
        }

        // Try the persisted bookmark first, fall back to direct access. Track
        // which method won so teardown only releases the one we actually
        // acquired. (The accessing calls themselves are no-ops without the
        // sandbox, but the bookmark *resolves* the URL across launches.)
        if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: url) {
            primaryAccess = .bookmark(url)
        } else if url.startAccessingSecurityScopedResource() {
            primaryAccess = .direct(url)
        } else {
            primaryAccess = .none
        }

        // Create asset with security-scoped access preference
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        
        self.player = player
        
        // Monitor player item status for failures, fallback to MPV if needed
        installPlayerItemStatusObserver(for: playerItem, startTime: startTime)
        
        self.isPreparing = false
        refreshAudioTrackOptions(for: videoItem, playerItem: playerItem)

        // Seek to start time but remain paused (don't auto-play)
        let seekTime = CMTime(seconds: startTime, preferredTimescale: 600)
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)

        installLoopObserver(for: playerItem)
        installTimeObserver(for: player)
        installPlaybackTimeObserver(for: player)
        updatePlayerActionAtEnd()
        loadPreviewAssets(for: videoItem.url)
        
        // Audio monitoring is handled globally by UniversalAudioMeterService
    }
    
    var debugWindowController: Any? // Holds strong reference to keep window alive

    func setupMPV(url: URL, startTime: Double) {
        // Explicitly nil the player to prevent key consumption
        player = nil

        // Re-acquire security-scoped access for MPV (teardown released it).
        // Track which method won so teardown only releases the one we acquired.
        if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: url) {
            primaryAccess = .bookmark(url)
        } else if url.startAccessingSecurityScopedResource() {
            primaryAccess = .direct(url)
        } else {
            primaryAccess = .none
        }

        let mpv = MPVPlayer()
        self.mpvPlayer = mpv
        self.useMPV = true
        self.isPreparing = false

        mpvEndObserver?.cancel()
        mpvEndObserver = mpv.$reachedEnd
            .removeDuplicates()
            .sink { [weak self] reached in
                self?.logger.debug("mpvEndObserver: reachedEnd changed to \(reached, privacy: .public)")
                guard reached else { return }
                Task { @MainActor in
                    let hasCallback = self?.playbackDidFinish != nil
                    self?.logger.debug("mpvEndObserver: calling playbackDidFinish (callback exists: \(hasCallback, privacy: .public))")
                    self?.playbackDidFinish?()
                }
            }

        // Apply volume/mute state before loading
        mpv.volume = volume
        mpv.isMuted = isMuted

        // Load without autostarting, with start time
        mpv.load(url: url, startTime: startTime, autostart: false)

        // Sync time position
        Task { @MainActor [weak self, weak mpv] in
            guard let self, let mpv else { return }
            for await time in mpv.$timePos.values {
                self.currentPlaybackTime = time
            }
        }

        // Observe file loaded state for isReady
        Task { @MainActor [weak self, weak mpv] in
            guard let self, let mpv else { return }
            for await isLoaded in mpv.$isFileLoaded.values {
                if isLoaded {
                    self.isReady = true
                    break  // Only need to set once per file
                }
            }
        }

        // Refresh audio tracks after a brief delay for MPV to parse the media
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.refreshAudioTrackOptions(for: self.videoItem, playerItem: nil)
        }

        // Install MPV trim boundary observer for looping
        installMPVTrimObserver()

        // Reload preview assets (teardown() clears them when switching from AVPlayer)
        // This uses the cache so it's instant
        loadPreviewAssets(for: url)

        // Audio monitoring is handled globally by UniversalAudioMeterService

        // DON'T call updateCurrentWaveform() here!
        // It will be called automatically via previewAssets.didSet when assets finish loading
    }

    // MARK: - Image Sequence Preview

    private func setupImageSequencePreview(config: ImageSequenceConfig, startTime: TimeInterval) {
        self.imageSequenceConfig = config
        self.useImageSequence = true
        self.isPreparing = false

        // Acquire security-scoped access to the sequence directory. Track which
        // method won so teardown only releases the one we acquired.
        if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: config.directory) {
            primaryAccess = .bookmark(config.directory)
        } else if config.directory.startAccessingSecurityScopedResource() {
            primaryAccess = .direct(config.directory)
        } else {
            primaryAccess = .none
        }

        // Set up audio player for the associated audio file
        if let audioURL = config.associatedAudioURL {
            // Acquire security-scoped access for the audio file (bookmark-first,
            // falling back to direct). Track which method won so teardown only
            // releases the one we actually acquired.
            if SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: audioURL) {
                imageSequenceAudioAccess = .bookmark(audioURL)
            } else if audioURL.startAccessingSecurityScopedResource() {
                imageSequenceAudioAccess = .direct(audioURL)
            } else {
                imageSequenceAudioAccess = .none
            }

            let audioAsset = AVURLAsset(url: audioURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let audioPlayerItem = AVPlayerItem(asset: audioAsset)
            let audioPlayer = AVPlayer(playerItem: audioPlayerItem)
            audioPlayer.volume = Float(volume / 100.0)
            audioPlayer.isMuted = isMuted
            self.imageSequenceAudioPlayer = audioPlayer

            // Seek audio to start time
            let seekTime = CMTime(seconds: startTime, preferredTimescale: 600)
            audioPlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)

            // Load waveform preview assets for the audio file
            loadPreviewAssets(for: audioURL)
        }

        // Load the frame at the start time
        loadImageSequenceFrame(at: startTime)

        self.isReady = true
        if config.associatedAudioURL == nil {
            self.isLoadingPreviewAssets = false
        }
    }

    /// Loads the image frame corresponding to the given time position in the sequence.
    func loadImageSequenceFrame(at time: TimeInterval) {
        guard let config = imageSequenceConfig else { return }
        let frameNumber = imageSequenceFrameNumber(at: time, config: config)
        let frameURL = imageSequenceFrameURL(frameNumber: frameNumber, config: config)

        // Avoid reloading the same frame
        if let current = imageSequenceFrame, frameURL == _lastImageSequenceFrameURL {
            _ = current // suppress unused warning
            return
        }
        _lastImageSequenceFrameURL = frameURL

        if let image = NSImage(contentsOf: frameURL) {
            self.imageSequenceFrame = image
        }
    }

    private var _lastImageSequenceFrameURL: URL?

    /// Updates the frame rate for image sequence preview and restarts playback timer if active.
    func updateImageSequenceFrameRate(_ config: ImageSequenceConfig) {
        self.imageSequenceConfig = config
        // If playing, restart the timer with the new frame rate
        if isImageSequencePlaying {
            stopImageSequencePlayback()
            startImageSequencePlayback()
        }
    }

    /// Starts timer-based playback of the image sequence at the configured frame rate.
    func startImageSequencePlayback() {
        guard let config = imageSequenceConfig, !isImageSequencePlaying else { return }
        isImageSequencePlaying = true
        currentPlaybackSpeed = 1.0

        // Start associated audio playback in sync
        if let audioPlayer = imageSequenceAudioPlayer {
            let seekTime = CMTime(seconds: currentPlaybackTime, preferredTimescale: 600)
            audioPlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak audioPlayer] _ in
                audioPlayer?.play()
            }
        }

        let interval = 1.0 / config.frameRate
        let trimEnd = videoItem.effectiveTrimEnd

        imageSequencePlaybackTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isImageSequencePlaying else { return }
                let nextTime = self.currentPlaybackTime + interval
                if nextTime >= trimEnd {
                    // Reached the end
                    if self.videoItem.loopPlayback {
                        let loopStart = self.videoItem.effectiveTrimStart
                        self.seekTo(loopStart)
                        // Resume audio playback after loop seek
                        self.imageSequenceAudioPlayer?.play()
                    } else {
                        self.stopImageSequencePlayback()
                        self.currentPlaybackTime = trimEnd
                        self.loadImageSequenceFrame(at: trimEnd)
                        self.playbackDidFinish?()
                    }
                } else {
                    self.currentPlaybackTime = nextTime
                    self.loadImageSequenceFrame(at: nextTime)
                }
            }
        }
    }

    /// Stops image sequence playback timer.
    func stopImageSequencePlayback() {
        imageSequencePlaybackTimer?.invalidate()
        imageSequencePlaybackTimer = nil
        isImageSequencePlaying = false
        currentPlaybackSpeed = 1.0
        imageSequenceAudioPlayer?.pause()
    }

    /// Restarts the image sequence timer at a new speed multiplier.
    private func updateImageSequenceSpeed(_ speed: Float) {
        guard let config = imageSequenceConfig, isImageSequencePlaying else { return }
        currentPlaybackSpeed = speed

        // Restart timer with adjusted interval
        imageSequencePlaybackTimer?.invalidate()
        let interval = 1.0 / (config.frameRate * Double(speed))
        let trimEnd = videoItem.effectiveTrimEnd

        imageSequencePlaybackTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isImageSequencePlaying else { return }
                let step = 1.0 / config.frameRate  // Always advance by one frame
                let nextTime = self.currentPlaybackTime + step
                if nextTime >= trimEnd {
                    if self.videoItem.loopPlayback {
                        let loopStart = self.videoItem.effectiveTrimStart
                        self.seekTo(loopStart)
                        self.imageSequenceAudioPlayer?.play()
                    } else {
                        self.stopImageSequencePlayback()
                        self.currentPlaybackTime = trimEnd
                        self.loadImageSequenceFrame(at: trimEnd)
                        self.playbackDidFinish?()
                    }
                } else {
                    self.currentPlaybackTime = nextTime
                    self.loadImageSequenceFrame(at: nextTime)
                }
            }
        }

        // Adjust audio playback rate if available
        imageSequenceAudioPlayer?.rate = speed
    }

    /// Converts a time position to a frame number within the sequence bounds.
    private func imageSequenceFrameNumber(at time: TimeInterval, config: ImageSequenceConfig) -> Int {
        guard config.frameRate > 0 else { return config.startNumber }
        let frame = Int(time * config.frameRate) + config.startNumber
        return max(config.startNumber, min(frame, config.endNumber))
    }

    /// Builds the URL for a specific frame number using the sequence pattern.
    private func imageSequenceFrameURL(frameNumber: Int, config: ImageSequenceConfig) -> URL {
        let pattern = config.pattern
        // Extract padding width from pattern like "frame_%04d.png"
        var paddingWidth = 4
        if let range = pattern.range(of: "%0") {
            let afterPercent = pattern[range.upperBound...]
            if let width = Int(String(afterPercent.prefix(while: { $0.isNumber }))) {
                paddingWidth = width
            }
        }
        let numberStr = String(format: "%0\(paddingWidth)d", frameNumber)
        let fileName = pattern.replacingOccurrences(of: "%0\(paddingWidth)d", with: numberStr)
        return config.directory.appendingPathComponent(fileName)
    }

    // MARK: - Unified Playback Control

    func togglePlayback() {
        // Ignore if player is not ready yet
        guard isReady else { return }

        // If reversing, K/Space should just stop reverse (stay paused)
        if isReverseSimulating {
            stopReverseSimulation()
            return
        }

        // Image sequence playback via timer
        if useImageSequence {
            if isImageSequencePlaying {
                stopImageSequencePlayback()
            } else {
                startImageSequencePlayback()
            }
            return
        }

        if useMPV, let mpv = mpvPlayer {
            // Check if currently playing
            let wasPlaying = mpv.isPlaying
            // Reset rate FIRST, ensure it's applied
            mpv.rate = 1.0
            currentPlaybackSpeed = 1.0

            if wasPlaying {
                mpv.pause()
            } else {
                // Make sure rate is 1.0 before playing
                mpv.play()
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

        if useImageSequence {
            stopImageSequencePlayback()
            return
        }

        if useMPV, let mpv = mpvPlayer {
            // Reset rate FIRST, then pause
            mpv.rate = 1.0
            currentPlaybackSpeed = 1.0
            mpv.pause()
        } else {
            currentPlaybackSpeed = 1.0
            player?.pause()
        }
    }
    
    func stepRate(forward: Bool) {
        let step: Float = 0.5
        if useMPV, let mpv = mpvPlayer {
            let current = mpv.rate
            let newRate = forward ? current + step : current - step
            mpv.rate = max(0.25, min(newRate, 8.0))
            currentPlaybackSpeed = mpv.rate
        } else if let player = player {
            let current = player.rate
            let newRate = forward ? current + step : current - step
            player.rate = max(0.25, min(newRate, 8.0))
            currentPlaybackSpeed = player.rate
        }
    }

    func startReverseSimulation() {
        guard isReady else { return }

        if isReverseSimulating {
            // Already reversing — speed up (max 8x)
            reverseSpeed = min(reverseSpeed + 1, 8)
            startReverseTimer(skip: reverseSpeed)
            currentPlaybackSpeed = -Float(reverseSpeed)
            return
        }

        // First J press — start reverse
        pause()
        reverseSpeed = 1
        isReverseSimulating = true
        startReverseTimer(skip: reverseSpeed)
        currentPlaybackSpeed = -Float(reverseSpeed)
    }

    private func startReverseTimer(skip: Int) {
        reverseTimer?.invalidate()
        let fps = effectiveFPS
        let interval = 1.0 / fps
        reverseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.currentPlaybackTime <= 0 {
                    self.stopReverseSimulation()
                    return
                }
                self.seekByFrames(-skip)
            }
        }
    }

    func stopReverseSimulation() {
        reverseTimer?.invalidate()
        reverseTimer = nil
        isReverseSimulating = false
        reverseSpeed = 1
        currentPlaybackSpeed = 1.0
    }

    func rewind() {
        stopReverseSimulation()
        stepRate(forward: false)
    }

    func fastForward() {
        guard isReady else { return }

        // If reversing, L stops reverse
        if isReverseSimulating {
            stopReverseSimulation()
            return
        }

        // Image sequence: start or speed up
        if useImageSequence {
            if !isImageSequencePlaying {
                startImageSequencePlayback()
            } else {
                let step: Float = 0.5
                let newSpeed = min(currentPlaybackSpeed + step, 8.0)
                updateImageSequenceSpeed(newSpeed)
            }
            return
        }

        // If paused, start playing at 1×
        if useMPV, let mpv = mpvPlayer {
            if !mpv.isPlaying {
                mpv.rate = 1.0
                currentPlaybackSpeed = 1.0
                mpv.play()
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

    func slowForward() {
        guard isReady else { return }

        if isReverseSimulating {
            stopReverseSimulation()
        }

        let current = currentPlaybackSpeed
        let target: Float
        if current >= 1.0 || current <= 0 {
            target = slowSteps[0]
        } else if let idx = slowSteps.firstIndex(where: { abs($0 - current) < 0.01 }) {
            target = slowSteps[min(idx + 1, slowSteps.count - 1)]
        } else {
            target = slowSteps.first(where: { $0 < current }) ?? slowSteps.last ?? slowSteps[0]
        }

        if useImageSequence {
            if !isImageSequencePlaying { startImageSequencePlayback() }
            updateImageSequenceSpeed(target)
            return
        }

        if useMPV, let mpv = mpvPlayer {
            if !mpv.isPlaying { mpv.play() }
            mpv.rate = target
        } else if let player = player {
            if player.rate == 0 { player.play() }
            player.rate = target
        }
        currentPlaybackSpeed = target
    }

    func slowReverse() {
        guard isReady else { return }

        let current = currentPlaybackSpeed
        let target: Float
        if isReverseSimulating {
            let absSpeed = abs(current)
            if let idx = slowSteps.firstIndex(where: { abs($0 - absSpeed) < 0.01 }) {
                target = slowSteps[min(idx + 1, slowSteps.count - 1)]
            } else {
                target = slowSteps[0]
            }
        } else {
            target = slowSteps[0]
        }

        // Stop any current reverse mode
        if isReverseSimulating {
            reverseTimer?.invalidate()
            reverseTimer = nil
        } else {
            pause()
        }

        isReverseSimulating = true
        reverseSpeed = 1

        // Timer-based simulation
        let fps = effectiveFPS
        let interval = 1.0 / (fps * Double(target))
        reverseTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.currentPlaybackTime <= 0 {
                    self.stopReverseSimulation()
                    return
                }
                self.seekByFrames(-1)
            }
        }
        currentPlaybackSpeed = -target
    }
    
    func seek(by seconds: Double) {
        let currentTime = getCurrentTime() ?? 0
        let newTime = currentTime + seconds
        // Allow seeking anywhere in the video, not just within trim range
        seekTo(max(0, min(newTime, videoItem.durationSeconds)))
    }
    
    func seekByFrames(_ frameCount: Int) {
        // For image sequences, use the sequence's frame rate
        if let config = imageSequenceConfig {
            let secondsPerFrame = 1.0 / config.frameRate
            seek(by: Double(frameCount) * secondsPerFrame)
            return
        }
        // Calculate seconds per frame from video metadata
        if let frameRate = videoItem.metadata?.primaryVideoStream?.frameRate,
           let frameRateValue = frameRate.value, frameRateValue > 0 {
            let secondsPerFrame = 1.0 / frameRateValue
            seek(by: Double(frameCount) * secondsPerFrame)
        } else {
            // Fallback to 1/30th second if no frame rate available
            seek(by: Double(frameCount) / 30.0)
        }
    }

    /// Determines the preferred ordering of audio stream indices based on metadata (default + channel count).
    nonisolated func determineAudioStreamOrder(
        for item: VideoItem,
        metadataTimeout: Duration = BoundedVideoMetadataProbe.defaultTimeout,
        metadataProbe: @escaping @Sendable (URL) async throws -> VideoMetadata = {
            try await VideoMetadataService.shared.metadata(for: $0)
        }
    ) async throws -> [Int] {
        if let metadata = item.metadata {
            return orderAudioStreams(from: metadata)
        }
        let metadata = try await BoundedVideoMetadataProbe.metadata(
            for: item.url,
            timeout: metadataTimeout,
            probe: metadataProbe
        )
        return orderAudioStreams(from: metadata)
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

    func refreshAudioTrackOptions(for item: VideoItem, playerItem: AVPlayerItem?) {
        audioTrackRefreshTask?.cancel()
        let refreshID = UUID()
        audioTrackRefreshID = refreshID
        let existingSelection = selectedAudioTrackOrderIndex
        audioTrackRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.audioTrackRefreshID == refreshID {
                    self.audioTrackRefreshTask = nil
                    self.audioTrackRefreshID = nil
                }
            }
            guard self.audioTrackRefreshID == refreshID, !Task.isCancelled else { return }

            if useMPV {
                guard let mpv = mpvPlayer else { return }
                let names = mpv.audioTrackNames
                let indexes = mpv.audioTrackIndexes
                buildMPVAudioTrackOptions(names: names, indexes: indexes)
                buildMPVSubtitleTrackOptions()
            } else {
                let metadata: VideoMetadata?
                if let cached = item.metadata {
                    metadata = cached
                } else {
                    do {
                        metadata = try await BoundedVideoMetadataProbe.metadata(for: item.url)
                    } catch is CancellationError {
                        return
                    } catch {
                        metadata = nil
                    }
                }

                let orderedIndices = metadata.map { self.orderAudioStreams(from: $0) } ?? []
                let mediaGroup: AVMediaSelectionGroup?
                if let playerItem {
                    let asset = playerItem.asset
                    mediaGroup = try? await NonJoiningTaskDeadline.run(timeout: .seconds(10)) {
                        try Task.checkCancellation()
                        let access = (asset as? AVURLAsset).map {
                            SecurityScopedBookmarkManager.shared.startAccessing(url: $0.url)
                        }
                        defer {
                            if let access { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
                        }
                        return try await asset.loadMediaSelectionGroup(for: .audible)
                    }
                } else {
                    mediaGroup = nil
                }

                guard self.audioTrackRefreshID == refreshID, !Task.isCancelled else { return }
                self.buildAudioTrackOptions(metadata: metadata, orderedIndices: orderedIndices, mediaGroup: mediaGroup)
            }

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
    
    private func buildMPVAudioTrackOptions(names: [String], indexes: [Int32]) {
        var options: [AudioTrackOption] = []

        // MPV returns tracks with 1-based IDs
        // We skip any "Disable" track (id 0 or -1 if present)

        for (index, trackID) in indexes.enumerated() {
            if trackID <= 0 { continue } // Skip "Disable" or invalid tracks

            let name = index < names.count ? names[index] : "Track \(trackID)"

            // Position in our UI list (0-based)
            let position = options.count

            options.append(
                AudioTrackOption(
                    id: Int(trackID),
                    position: position,
                    streamIndex: Int(trackID) - 1, // MPV track IDs are 1-based, waveforms are 0-based
                    mediaOptionIndex: nil,
                    title: name,
                    subtitle: nil
                )
            )
        }

        audioTrackOptions = options

        // Update selection if needed
        if !audioTrackOptions.isEmpty {
            if selectedAudioTrackOrderIndex >= audioTrackOptions.count {
                selectedAudioTrackOrderIndex = 0
            }
        }
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

        // Pause playback to prevent audio overlap/buffering issues
        let wasPlaying = (player?.rate ?? 0) > 0 || (mpvPlayer?.isPlaying ?? false)
        if wasPlaying {
            pause()
        }
        
        selectedAudioTrackOrderIndex = position
        applySelectedAudioTrack()
        updateCurrentWaveform()
        
        // Resume if it was playing, with a tiny delay to ensure track switch takes effect
        if wasPlaying {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.togglePlayback()
            }
        }
    }

    func applySelectedAudioTrack() {
        if useMPV {
            applySelectedAudioTrackToMPV()
        } else {
            applySelectedAudioTrackToCurrentPlayerItem()
        }
        updateCurrentWaveform()
    }

    private func applySelectedAudioTrackToMPV() {
        guard let mpv = mpvPlayer else {
            logger.error("applySelectedAudioTrackToMPV: mpvPlayer is nil")
            return
        }

        let indexes = mpv.audioTrackIndexes
        let names = mpv.audioTrackNames

        logger.debug("applySelectedAudioTrackToMPV: indexes=\(indexes, privacy: .public), names=\(names, privacy: .public), selectedOrderIndex=\(self.selectedAudioTrackOrderIndex, privacy: .public)")

        // MPV track IDs are 1-based
        // Our selectedAudioTrackOrderIndex is 0-based for actual tracks

        if self.selectedAudioTrackOrderIndex < indexes.count {
            let trackID = indexes[self.selectedAudioTrackOrderIndex]
            mpv.currentAudioTrackIndex = trackID
            logger.debug("Selected MPV audio track ID: \(trackID, privacy: .public) (name: \(self.selectedAudioTrackOrderIndex < names.count ? names[self.selectedAudioTrackOrderIndex] : "?", privacy: .public))")
        } else {
            logger.warning("Could not map audio track index \(self.selectedAudioTrackOrderIndex, privacy: .public) to MPV indexes: \(indexes, privacy: .public)")
        }
    }

    func applySelectedAudioTrackToCurrentPlayerItem() {
        guard let playerItem = player?.currentItem else { return }

        audioSelectionTask?.cancel()
        let operationID = UUID()
        audioSelectionOperationID = operationID
        audioSelectionTask = Task { @MainActor [weak self, weak playerItem] in
            guard let self, let playerItem else { return }
            defer {
                if self.audioSelectionOperationID == operationID {
                    self.audioSelectionTask = nil
                    self.audioSelectionOperationID = nil
                }
            }

            // 1. Try to load media selection group first (for alternate tracks)
            var mediaGroup: AVMediaSelectionGroup?
            do {
                let asset = playerItem.asset
                mediaGroup = try await NonJoiningTaskDeadline.run(timeout: .seconds(10)) {
                    try Task.checkCancellation()
                    let access = (asset as? AVURLAsset).map {
                        SecurityScopedBookmarkManager.shared.startAccessing(url: $0.url)
                    }
                    defer {
                        if let access { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
                    }
                    return try await asset.loadMediaSelectionGroup(for: .audible)
                }
            } catch {
                logger.error("Failed to load audible group: \(error, privacy: .public)")
            }

            guard !Task.isCancelled, self.audioSelectionOperationID == operationID,
                  self.player?.currentItem === playerItem else { return }

            // 2. Build options (this populates self.audioTrackOptions)
            self.buildAudioTrackOptions(metadata: self.videoItem.metadata, orderedIndices: [], mediaGroup: mediaGroup)

            guard !self.audioTrackOptions.isEmpty else { return }

            let desiredPosition = min(max(self.selectedAudioTrackOrderIndex, 0), self.audioTrackOptions.count - 1)
            let selectedOption = self.audioTrackOptions[desiredPosition]

            logger.debug("Applying audio selection: position=\(desiredPosition, privacy: .public), option=\(selectedOption.title, privacy: .public)")

            // 3. Strategy A: If we have a valid media group and option index, try using select()
            // This works for mutually exclusive tracks (e.g. languages)
            if let mediaGroup, let mappedIndex = selectedOption.mediaOptionIndex, mediaGroup.options.indices.contains(mappedIndex) {
                let avOption = mediaGroup.options[mappedIndex]
                if playerItem.currentMediaSelection.selectedMediaOption(in: mediaGroup) != avOption {
                    playerItem.select(avOption, in: mediaGroup)
                    logger.debug("Selected media option via group")
                    return // Done if successful
                }
            }

            // 4. Strategy B: Direct track enabling/disabling
            // This handles cases where tracks are not in a group (e.g. multi-channel recording)
            let tracks = playerItem.tracks
            var audioTracks: [AVPlayerItemTrack] = []

            for track in tracks {
                if track.assetTrack?.mediaType == .audio {
                    audioTracks.append(track)
                }
            }

            logger.debug("Found \(audioTracks.count, privacy: .public) audio tracks in player item")

            if !audioTracks.isEmpty {
                for (index, track) in audioTracks.enumerated() {
                    let shouldEnable = (index == desiredPosition)
                    if track.isEnabled != shouldEnable {
                        track.isEnabled = shouldEnable
                        logger.debug("Set track \(index, privacy: .public) enabled: \(shouldEnable, privacy: .public)")
                    }
                }
            }
        }
    }



    private func selectedAudioStreamIndex() -> Int? {
        let position = selectedAudioTrackOrderIndex
        guard audioTrackOptions.indices.contains(position) else { return nil }
        return audioTrackOptions[position].streamIndex
    }

    private var channelWaveformGenerationTask: Task<Void, Never>?

    private func updateCurrentWaveform() {
        let streamIndex = selectedAudioStreamIndex()
        // Per-channel waveform images (preferred, shows one waveform per audio channel)
        let channelWaveform = previewAssets?.nativeChannelWaveforms(forAudioStream: streamIndex)
        currentChannelWaveformImages = channelWaveform?.channelImages ?? []
        currentChannelWaveformLabels = channelWaveform?.channelLabels ?? []
        // Native waveform image (fallback, single mono image)
        currentNativeWaveformImage = previewAssets?.nativeWaveform(forAudioStream: streamIndex)
        // Legacy single-image waveform (kept for backwards compatibility)
        currentWaveformURL = previewAssets?.waveform(forAudioStream: streamIndex)
        // Chunked waveform support (fallback)
        currentWaveformChunks = previewAssets?.waveformChunks(forAudioStream: streamIndex) ?? []
        totalDuration = previewAssets?.totalDuration ?? 0
        logger.debug("Updated waveform: channels=\(self.currentChannelWaveformImages.count, privacy: .public), native=\(self.currentNativeWaveformImage != nil, privacy: .public), \(self.currentWaveformChunks.count, privacy: .public) chunks, totalDuration: \(self.totalDuration, privacy: .public)s for stream index: \(streamIndex ?? -1, privacy: .public)")

        // If per-channel waveform is missing for this stream, generate on demand
        if currentChannelWaveformImages.isEmpty, let streamIndex {
            generateChannelWaveformOnDemand(for: streamIndex)
        }
    }

    private func generateChannelWaveformOnDemand(for streamIndex: Int) {
        channelWaveformGenerationTask?.cancel()
        let url = videoItem.url
        let duration = max(videoItem.durationSeconds, 0.1)

        channelWaveformGenerationTask = Task { [weak self] in
            guard let self else { return }

            // Get metadata to know channel count and layout
            let metadata: VideoMetadata
            do {
                metadata = try await BoundedVideoMetadataProbe.metadata(for: url)
            } catch is CancellationError {
                return
            } catch {
                return
            }
            guard streamIndex < metadata.audioStreams.count else { return }

            let stream = metadata.audioStreams[streamIndex]
            let channels = stream.channels ?? 2

            guard let waveform = await PreviewAssetGenerator.shared.generateChannelWaveformForStream(
                url: url,
                streamIndex: streamIndex,
                channelCount: channels,
                channelLayout: stream.channelLayout,
                duration: duration
            ) else { return }

            guard !Task.isCancelled else { return }

            // Update the published state
            self.currentChannelWaveformImages = waveform.channelImages
            self.currentChannelWaveformLabels = waveform.channelLabels
        }
    }

    // MARK: - Subtitle Track Selection

    func buildMPVSubtitleTrackOptions() {
        guard let mpv = mpvPlayer else {
            subtitleTrackOptions = []
            return
        }

        let names = mpv.subtitleTrackNames
        let indexes = mpv.subtitleTrackIndexes

        var options: [SubtitleTrackOption] = []

        for (index, trackID) in indexes.enumerated() {
            if trackID <= 0 { continue }

            let name = index < names.count ? names[index] : "Subtitle \(trackID)"
            let position = options.count

            options.append(
                SubtitleTrackOption(
                    id: Int(trackID),
                    position: position,
                    trackId: trackID,
                    title: name
                )
            )
        }

        subtitleTrackOptions = options
    }

    func selectSubtitleTrack(at position: Int) {
        guard useMPV, let mpv = mpvPlayer else { return }

        if position < 0 {
            // Disable subtitles
            mpv.disableSubtitles()
            selectedSubtitleTrackOrderIndex = -1
        } else if position < subtitleTrackOptions.count {
            let option = subtitleTrackOptions[position]
            mpv.currentSubtitleTrackIndex = option.trackId
            selectedSubtitleTrackOrderIndex = position
        }
    }

    func teardown(resetAudioSelection: Bool = true) {
        audioSelectionOperationID = nil
        audioSelectionTask?.cancel()
        audioSelectionTask = nil
        screenshotCaptureOperationID = nil
        screenshotCaptureTask?.cancel()
        screenshotCaptureTask = nil
        preparationTask?.cancel()
        preparationTask = nil
        previewAssetTask?.cancel()
        previewAssetTask = nil

        // NOTE: We do NOT cancel FFmpeg processes here - generation continues in the
        // background even after the trim view is closed. This allows waveforms to
        // complete generating for all files in the queue.
        previewAssetURL = nil  // Reset URL tracking so next load can proceed
        player?.pause()

        // Remove observers BEFORE releasing the player, so the owner references
        // are still valid for removeTimeObserver calls.
        removeLoopObserver()
        removeTimeObserver()
        removePlaybackTimeObserver()
        removePlayerItemStatusObserver()
        removeMPVTrimObserver()

        // Release only the access method we actually acquired. The tracked URL
        // is either the video file (AVPlayer/MPV) or the sequence directory
        // (image sequences).
        SecurityScopedBookmarkManager.shared.stopAccessing(primaryAccess)
        primaryAccess = .none

        player = nil

        if let mpv = mpvPlayer {
            mpv.stop()
            mpvPlayer = nil
        }
        mpvEndObserver?.cancel()
        mpvEndObserver = nil
        useMPV = false

        // Clean up image sequence state
        stopImageSequencePlayback()
        SecurityScopedBookmarkManager.shared.stopAccessing(imageSequenceAudioAccess)
        imageSequenceAudioAccess = .none
        imageSequenceAudioPlayer?.pause()
        imageSequenceAudioPlayer = nil
        useImageSequence = false
        imageSequenceFrame = nil
        imageSequenceConfig = nil
        _lastImageSequenceFrameURL = nil

        isPreparing = false
        if resetAudioSelection {
            selectedAudioTrackOrderIndex = 0
            selectedSubtitleTrackOrderIndex = -1
        }
        audioTrackOptions = []
        subtitleTrackOptions = []
        currentWaveformURL = nil
        currentWaveformChunks = []
        currentNativeWaveformImage = nil
        currentChannelWaveformImages = []
        currentChannelWaveformLabels = []
        channelWaveformGenerationTask?.cancel()
        channelWaveformGenerationTask = nil
        audioTrackRefreshID = nil
        audioTrackRefreshTask?.cancel()
        audioTrackRefreshTask = nil
        chapterProbeTask?.cancel()
        chapterProbeTask = nil
        chapterProbeURL = nil
        currentChapters = []
        totalDuration = 0

        // Stop asset refresh polling
        assetRefreshTask?.cancel()
        assetRefreshTask = nil

        // Stop audio monitoring
        isAudioMeterEnabled = false

        // NOTE: Do NOT clear playbackDidFinish here - it's owned by the View
        // and is set before preparePreview() is called. The View clears it in onDisappear.
    }
    
    // MARK: - Playback Control
    
    func refreshPreviewForTrim() {
        if useImageSequence {
            seekTo(videoItem.effectiveTrimStart)
            return
        }

        if useMPV, let mpv = mpvPlayer {
            mpv.seek(to: videoItem.effectiveTrimStart)
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
                guard finished, let self = self, self.player === player, isPlaying else { return }
                // Only resume playback if it was playing before
                self.player?.play()
            }
        }
    }
    
    func seekTo(_ time: Double) {
        // Allow seeking even before player is fully ready - seeks will queue up
        // This enables scrubbing the timeline while player is still loading

        // Update playback time immediately for UI responsiveness
        currentPlaybackTime = time

        // Image sequence: load the frame at this time position and sync audio
        if useImageSequence {
            loadImageSequenceFrame(at: time)
            if let audioPlayer = imageSequenceAudioPlayer {
                let seekTime = CMTime(seconds: time, preferredTimescale: 600)
                audioPlayer.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            return
        }

        if useMPV, let mpv = mpvPlayer {
            mpv.seek(to: time)
            return
        }

        guard let player else { return }
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
    
    func toggleFullscreen() {
        // Try to get window from playerView first, fallback to key window
        let window = playerView?.window ?? NSApp.keyWindow
        window?.toggleFullScreen(nil)
    }
    
    // MARK: - Chapters

    /// Probes chapter markers for `url` and publishes them on `currentChapters`.
    /// Skips duplicate work when the URL matches an in-flight probe.
    private func loadChapters(for url: URL) {
        if chapterProbeURL == url, chapterProbeTask != nil { return }
        chapterProbeTask?.cancel()
        chapterProbeURL = url
        if currentChapters.isEmpty == false {
            currentChapters = []
        }
        chapterProbeTask = Task { [weak self] in
            let chapters = await FFMPEGProbeService.fetchChapters(for: url)
            guard let self, !Task.isCancelled, self.chapterProbeURL == url else { return }
            self.currentChapters = chapters
            self.chapterProbeTask = nil
        }
    }

    // MARK: - Preview Assets

    private var assetRefreshTask: Task<Void, Never>?

    func loadPreviewAssets(for url: URL) {
        // Only restart local tasks if requesting assets for a different URL
        // This prevents waveform generation from being interrupted when the same file
        // is re-selected (e.g., opening/closing fullscreen, clicking the same row)
        // NOTE: We do NOT cancel FFmpeg processes for the old URL - generation continues
        // in the background. Only the UI tracking tasks are cancelled.
        if previewAssetURL != url {
            // Cancel local UI tracking tasks (not the actual FFmpeg generation)
            previewAssetTask?.cancel()
            assetRefreshTask?.cancel()
            previewAssetURL = url
        } else if previewAssetTask != nil {
            // Same URL and task already running - don't restart
            return
        }

        loadChapters(for: url)

        isLoadingPreviewAssets = true

        // Start a refresh task that periodically updates previewAssets with partial results
        // This enables progressive loading of waveform chunks
        assetRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isLoadingPreviewAssets {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }

                if let cached = await PreviewAssetGenerator.shared.cachedAssetsIfPresent(for: url) {
                    // Only update if we have new chunks
                    let currentChunkCount = self.previewAssets?.waveformChunks.count ?? 0
                    if cached.waveformChunks.count > currentChunkCount || cached.thumbnails.count > (self.previewAssets?.thumbnails.count ?? 0) {
                        self.previewAssets = cached
                    }
                }
            }
        }

        previewAssetTask = Task { [weak self] in
            guard let self else { return }

            // Capture the URL this task is for, to avoid race conditions
            let taskURL = url

            do {
                // 1. Try to load cached assets first for immediate display
                if let cached = await PreviewAssetGenerator.shared.cachedAssetsIfPresent(for: taskURL) {
                    // Only update if we're still viewing this file
                    if self.previewAssetURL == taskURL {
                        self.previewAssets = cached
                    }

                    // 2. If we have complete waveform chunks, we're good! Return early.
                    let expectedChunks = cached.expectedChunkCount
                    if expectedChunks > 0 && cached.waveformChunks.count >= expectedChunks {
                        // Only stop loading if still viewing this file
                        if self.previewAssetURL == taskURL {
                            self.isLoadingPreviewAssets = false
                            self.assetRefreshTask?.cancel()
                        }
                        return
                    }
                    // If chunks are missing, continue to generateAssets to get the rest
                }

                // 3. Generate full assets (waits for existing task if running)
                let assets = try await PreviewAssetGenerator.shared.generateAssets(for: taskURL)
                try Task.checkCancellation()

                // Only update if we're still viewing this file
                if self.previewAssetURL == taskURL {
                    self.previewAssets = assets
                }
            } catch {
                // Only handle errors if we're still viewing this file
                if self.previewAssetURL == taskURL {
                    // Only clear assets if we don't have any (don't wipe partial cache on error)
                    if self.previewAssets == nil {
                        self.previewAssets = nil
                    }
                    if (error as? CancellationError) == nil {
                        logger.error("Failed to load preview assets for \(taskURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
            }

            // Only update loading state if we're still viewing this file
            // This prevents a cancelled old task from stopping the new task's refresh
            if self.previewAssetURL == taskURL {
                self.isLoadingPreviewAssets = false
                self.assetRefreshTask?.cancel()
                self.previewAssetTask = nil
            }
        }
    }
    
    // MARK: - Audio Metering
    
    private let universalAudioMeter = UniversalAudioMeterService()
    private var cancellables = Set<AnyCancellable>()
    
    @Published var audioLevels: UniversalAudioMeterService.AudioLevels?
    /// Real-time frequency band magnitudes for the frequency visualizer.
    @Published var frequencyBands: [Float]?
    @Published var isAudioMeterEnabled = false {
        didSet {
            toggleAudioMeter()
        }
    }
    
    private func setupAudioMonitoring() {
        // Subscribe to universal meter updates
        universalAudioMeter.$currentLevels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] levels in
                self?.audioLevels = levels
            }
            .store(in: &cancellables)

        // Subscribe to frequency band updates for visualizer
        universalAudioMeter.$frequencyBands
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bands in
                self?.frequencyBands = bands
            }
            .store(in: &cancellables)
            
        // Handle permission errors if needed
        universalAudioMeter.$permissionError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasError in
                if hasError {
                    self?.logger.debug("Audio meter permission denied")
                    // Could show alert here or disable meter
                    self?.isAudioMeterEnabled = false
                }
            }
            .store(in: &cancellables)
    }
    
    private func toggleAudioMeter() {
        Task {
            if isAudioMeterEnabled {
                await universalAudioMeter.startMonitoring()
            } else {
                await universalAudioMeter.stopMonitoring()
            }
        }
    }
}
