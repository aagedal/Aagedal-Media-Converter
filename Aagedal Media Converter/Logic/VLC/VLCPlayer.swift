// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Combine
import AppKit
@preconcurrency import VLCKit
import OSLog

@MainActor
final class VLCPlayer: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    // Mark as nonisolated(unsafe) to allow access in deinit and from background threads
    nonisolated(unsafe) let mediaPlayer = VLCMediaPlayer()
    
    @Published var isPlaying = false
    @Published var duration: Double = 0
    @Published var timePos: Double = 0
    @Published var volume: Double = 100 {
        didSet {
            mediaPlayer.audio?.volume = Int32(volume)
        }
    }
    @Published var isMuted: Bool = false {
        didSet {
            mediaPlayer.audio?.isMuted = isMuted
        }
    }
    @Published var isSeekable = false
    @Published var isBusy = false
    @Published var error: String?
    
    private var timeObserver: Timer?
    
    override init() {
        super.init()
        setupMediaPlayer()
    }
    
    deinit {
        mediaPlayer.stop()
        mediaPlayer.delegate = nil
    }
    
    private func setupMediaPlayer() {
        mediaPlayer.delegate = self
    }
    
    private var startPaused = false
    private var hasInitiallyStarted = false // Track if we've done initial pause
    
    func load(url: URL, autostart: Bool = false) {
        // Reset the startPaused flag FIRST to avoid state from previous video
        startPaused = false
        
        let media = VLCMedia(url: url)
        mediaPlayer.media = media
        
        // ALWAYS start paused for VLC to ensure consistent behavior
        // Play to load metadata/first frame, then pause in delegate
        startPaused = true
        mediaPlayer.play()
    }
    
    func play() {
        // DON'T clear startPaused here - only pause() should clear it
        // This prevents external play() calls from bypassing our autostart=false logic
        mediaPlayer.play()
        isPlaying = true
    }
    
    func pause() {
        startPaused = false
        hasInitiallyStarted = false
        mediaPlayer.pause()
        isPlaying = false
    }
    
    func togglePause() {
        if mediaPlayer.isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    func stop() {
        mediaPlayer.stop()
        isPlaying = false
        timePos = 0
    }
    
    func seek(to time: TimeInterval) {
        let position = Float(time / duration)
        mediaPlayer.position = position
    }
    
    var rate: Float {
        get { mediaPlayer.rate }
        set { mediaPlayer.rate = newValue }
    }
    
    // MARK: - Audio Tracks
    
    var audioTrackNames: [String] {
        return mediaPlayer.audioTrackNames as? [String] ?? []
    }
    
    var audioTrackIndexes: [Int32] {
        return (mediaPlayer.audioTrackIndexes as? [NSNumber])?.map { $0.int32Value } ?? []
    }
    
    var currentAudioTrackIndex: Int32 {
        get { mediaPlayer.currentAudioTrackIndex }
        set { mediaPlayer.currentAudioTrackIndex = newValue }
    }
    
    // MARK: - VLCMediaPlayerDelegate
    
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        // Extract the player safely before dispatching
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        
        Task { @MainActor in
            // Only log important state changes to avoid spam
            let shouldLog = [5, 6, 7, 8].contains(player.state.rawValue) // playing, paused, stopped, error
            if shouldLog {
                print("🎬 VLC state: \(player.state.rawValue), startPaused: \(self.startPaused)")
            }
            
            switch player.state {
            case .playing:
                if self.startPaused && !self.hasInitiallyStarted {
                    print("🎬 VLC auto-pausing (initial load)")
                    self.hasInitiallyStarted = true
                    self.startPaused = false
                    // Small delay to ensure media is fully loaded
                    // Call mediaPlayer.pause() directly to avoid clearing flags via pause() method
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.mediaPlayer.pause()
                    }
                    self.isPlaying = false
                } else {
                    if shouldLog {
                        print("🎬 VLC playing normally")
                        // Log available audio tracks
                        print("🎬 VLC Audio Tracks: \(self.mediaPlayer.audioTrackIndexes ?? []) names: \(self.mediaPlayer.audioTrackNames ?? [])")
                    }
                    self.isPlaying = true
                    self.startTimeObserver()
                }
            case .paused, .stopped, .ended:
                self.isPlaying = false
                self.stopTimeObserver()
            case .error:
                self.error = "VLC Playback Error"
                self.isPlaying = false
            default:
                break
            }
            
            if let media = player.media {
                self.duration = Double(media.length.intValue) / 1000.0
            }
            
            self.isSeekable = player.isSeekable
        }
    }
    
    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        
        Task { @MainActor in
            self.timePos = Double(player.time.intValue) / 1000.0
        }
    }
    
    // MARK: - Private
    
    private func startTimeObserver() {
        // VLC delegate timeChanged might be enough, but sometimes a timer is smoother for UI
        // For now relying on delegate
    }
    
    private func stopTimeObserver() {
        timeObserver?.invalidate()
        timeObserver = nil
    }
}
