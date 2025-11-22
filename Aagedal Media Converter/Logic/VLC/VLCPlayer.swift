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
    @Published var volume: Double = 100
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
    
    func load(url: URL, autostart: Bool = false) {
        // Reset the startPaused flag FIRST to avoid state from previous video
        startPaused = false
        
        let media = VLCMedia(url: url)
        mediaPlayer.media = media
        
        if autostart {
            mediaPlayer.play()
        } else {
            // Play to load metadata/first frame, then pause in delegate
            startPaused = true
            mediaPlayer.play()
        }
    }
    
    func play() {
        startPaused = false
        mediaPlayer.play()
        isPlaying = true
    }
    
    func pause() {
        startPaused = false
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
    
    func seek(to time: Double) {
        let timeObj = VLCTime(int: Int32(time * 1000))
        mediaPlayer.time = timeObj
    }
    
    var rate: Float {
        get { mediaPlayer.rate }
        set { mediaPlayer.rate = newValue }
    }
    
    // MARK: - VLCMediaPlayerDelegate
    
    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        // Extract the player safely before dispatching
        guard let player = aNotification.object as? VLCMediaPlayer else { return }
        
        Task { @MainActor in
            // We assume player is safe to use here because we are just reading state
            switch player.state {
            case .playing:
                if self.startPaused {
                    self.startPaused = false
                    player.pause()
                    self.isPlaying = false
                } else {
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
