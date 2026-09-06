// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Observer management for PreviewPlayerController (loop, time, playback monitoring).

import Foundation
@preconcurrency import AVKit
@preconcurrency import AVFoundation
import OSLog

extension PreviewPlayerController {
    
    // MARK: - Loop Observer
    
    func installLoopObserver(for item: AVPlayerItem) {
        removeLoopObserver()
        let observerID = UUID()
        loopObserverID = observerID
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player?.currentItem === item, self.loopObserverID == observerID else { return }
                self.handlePlaybackEnded()
            }
        }
    }

    func removeLoopObserver() {
        loopObserverID = nil
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
    }
    
    func handlePlaybackEnded() {
        playbackDidFinish?()
        guard videoItem.loopPlayback, let player else { return }
        let target = CMTime(seconds: videoItem.effectiveTrimStart, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] finished in
            Task { @MainActor in
                guard finished, let self, let player, self.player === player else { return }
                player.play()
            }
        }
    }

    private func updateLoopBehavior() {
        // MPV loop is handled via installMPVTrimObserver
        guard videoItem.loopPlayback, let player else { return }
        player.actionAtItemEnd = .none
    }

    func updatePlayerActionAtEnd() {
        // MPV loop is handled via installMPVTrimObserver
        player?.actionAtItemEnd = videoItem.loopPlayback ? .none : .pause
    }

    // MARK: - MPV Trim Observer

    func installMPVTrimObserver() {
        removeMPVTrimObserver()

        guard useMPV, mpvPlayer != nil else { return }

        // Check playback position every 0.1 seconds
        mpvTrimObserverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let mpv = self.mpvPlayer else { return }

                // Only loop if loopPlayback is enabled
                guard self.videoItem.loopPlayback else { return }

                let currentTime = mpv.timePos
                let trimStart = self.videoItem.effectiveTrimStart
                let trimEnd = self.videoItem.effectiveTrimEnd
                let tolerance = 0.05

                // If we've reached the end trim, seek back to start and continue playing
                if currentTime >= trimEnd - tolerance {
                    let wasPlaying = mpv.isPlaying
                    mpv.seek(to: trimStart)
                    if wasPlaying {
                        mpv.play()
                    }
                }
            }
        }
    }

    func removeMPVTrimObserver() {
        mpvTrimObserverTimer?.invalidate()
        mpvTrimObserverTimer = nil
    }
    
    // MARK: - Time Observer (Trim Boundaries)
    
    func installTimeObserver(for player: AVPlayer) {
        removeTimeObserver()

        // Check playback position every 0.1 seconds
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        let observerID = UUID()
        timeObserverID = observerID
        timeObserverOwner = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
            Task { @MainActor [weak self] in
                guard let self, let player, self.player === player, self.timeObserverOwner === player, self.timeObserverID == observerID else { return }

                let currentTime = time.seconds

                // Only enforce trim boundaries when looping is enabled
                guard self.videoItem.loopPlayback else { return }

                let trimStart = self.videoItem.effectiveTrimStart
                let trimEnd = self.videoItem.effectiveTrimEnd

                // Small tolerance to avoid seeking when already at target (prevents playback freeze)
                let tolerance = 0.05

                // Enforce trim boundaries: keep playback within trimStart...trimEnd
                if currentTime < trimStart - tolerance {
                    // Significantly before trim start, seek to trim start
                    let startTime = CMTime(seconds: trimStart, preferredTimescale: 600)
                    self.player?.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
                } else if currentTime >= trimEnd - tolerance {
                    // At or past trim end, loop back to trim start
                    let startTime = CMTime(seconds: trimStart, preferredTimescale: 600)
                    self.player?.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
    }

    func removeTimeObserver() {
        timeObserverID = nil
        if let timeObserver {
            let owner = timeObserverOwner ?? player
            owner?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
            self.timeObserverOwner = nil
        }
    }
    
    // MARK: - Playback Time Observer (UI Updates)

    func installPlaybackTimeObserver(for player: AVPlayer) {
        removePlaybackTimeObserver()

        // Update playback time more frequently for smooth UI updates (every 0.05 seconds)
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        let observerID = UUID()
        playbackTimeObserverID = observerID
        playbackTimeObserverOwner = player
        playbackTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
            Task { @MainActor [weak self] in
                guard let self, let player, self.player === player, self.playbackTimeObserverOwner === player, self.playbackTimeObserverID == observerID else { return }
                let currentTime = time.seconds
                if currentTime.isFinite {
                    self.currentPlaybackTime = currentTime
                }
            }
        }
    }
    
    func removePlaybackTimeObserver() {
        playbackTimeObserverID = nil
        if let playbackTimeObserver {
            let owner = playbackTimeObserverOwner ?? player
            owner?.removeTimeObserver(playbackTimeObserver)
            self.playbackTimeObserver = nil
            self.playbackTimeObserverOwner = nil
        }
    }
    
    // MARK: - Player Item Status Observer
    
    func installPlayerItemStatusObserver(for playerItem: AVPlayerItem, startTime: TimeInterval) {
        removePlayerItemStatusObserver()
        let observerID = UUID()
        playerItemStatusObserverID = observerID
        playerItemStatusObserver = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.playerItemStatusObserverID == observerID,
                      self.player?.currentItem === item else { return }
                switch item.status {
                case .failed:
                    self.logger.warning("Direct AVPlayer playback failed: \(item.error?.localizedDescription ?? "unknown error", privacy: .public). Attempting MPV playback.")
                    self.teardown(resetAudioSelection: false)
                    self.setupMPV(url: self.videoItem.url, startTime: startTime)
                case .readyToPlay:
                    self.prepareReadyPlayerItem(item, startTime: startTime)
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    /// Both metadata inspection and the initial seek have deadlines. The detached
    /// metadata operation never mutates controller state, even if AVFoundation
    /// finishes after cancellation or after a different item has been installed.
    func prepareReadyPlayerItem(
        _ item: AVPlayerItem,
        startTime: TimeInterval,
        timeout: Duration = .seconds(10),
        verify: (@Sendable () async throws -> Bool)? = nil,
        seek: (@Sendable () async throws -> Bool)? = nil
    ) {
        playerItemStatusTask?.cancel()
        let operationID = UUID()
        playerItemStatusOperationID = operationID
        guard let player, player.currentItem === item else { return }
        let asset = item.asset
        let sourceURL = (asset as? AVURLAsset)?.url
        playerItemStatusTask = Task { @MainActor [weak self] in
            defer {
                if self?.playerItemStatusOperationID == operationID {
                    self?.playerItemStatusTask = nil
                    self?.playerItemStatusOperationID = nil
                }
            }
            let supportsPlayback: Bool
            do {
                supportsPlayback = try await NonJoiningTaskDeadline.run(timeout: timeout) {
                    try Task.checkCancellation()
                    if let verify { return try await verify() }
                    let access = sourceURL.map { SecurityScopedBookmarkManager.shared.startAccessing(url: $0) }
                    defer {
                        if let access { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
                    }
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    for track in tracks {
                        try Task.checkCancellation()
                        let formats = try await track.load(.formatDescriptions)
                        let decodable = try await track.load(.isDecodable)
                        if formats.isEmpty || !decodable { return false }
                    }
                    return true
                }
            } catch is CancellationError {
                return
            } catch {
                // Metadata is advisory; retain AVPlayer's ready status when the
                // inspection fails or times out, and still bound its initial seek.
                supportsPlayback = true
            }
            guard let self, !Task.isCancelled,
                  self.playerItemStatusOperationID == operationID,
                  self.player === player, player.currentItem === item else { return }
            guard supportsPlayback else {
                self.logger.warning("AVPlayer video track unsupported; attempting MPV playback.")
                self.teardown(resetAudioSelection: false)
                self.setupMPV(url: self.videoItem.url, startTime: startTime)
                return
            }
            do {
                _ = try await NonJoiningTaskDeadline.run(timeout: timeout) {
                    try Task.checkCancellation()
                    if let seek { return try await seek() }
                    return await player.seek(
                        to: CMTime(seconds: startTime, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.playerItemStatusOperationID == operationID,
                      self.player === player, player.currentItem === item else { return }
                item.cancelPendingSeeks()
                self.logger.debug("Initial preview seek did not finish before its deadline.")
            }
            guard !Task.isCancelled, self.playerItemStatusOperationID == operationID,
                  self.player === player, player.currentItem === item else { return }
            self.isReady = true
            self.applySelectedAudioTrack()
        }
    }

    func removePlayerItemStatusObserver() {
        playerItemStatusObserverID = nil
        playerItemStatusOperationID = nil
        playerItemStatusTask?.cancel()
        playerItemStatusTask = nil
        player?.currentItem?.cancelPendingSeeks()
        if let playerItemStatusObserver {
            (playerItemStatusObserver as? NSKeyValueObservation)?.invalidate()
            self.playerItemStatusObserver = nil
        }
    }
}
