// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Observer management for PreviewPlayerController (loop, time, playback monitoring).

import Foundation
import AVKit
import OSLog

extension PreviewPlayerController {
    
    // MARK: - Loop Observer
    
    func installLoopObserver(for item: AVPlayerItem) {
        removeLoopObserver()
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePlaybackEnded()
            }
        }
    }

    func removeLoopObserver() {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
    }
    
    func handlePlaybackEnded() {
        guard videoItem.loopPlayback, let player else { return }
        let target = CMTime(seconds: videoItem.effectiveTrimStart, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            player.play()
        }
    }

    func applyLoopSetting() {
        player?.actionAtItemEnd = videoItem.loopPlayback ? .none : .pause
    }
    
    // MARK: - Time Observer (Trim Boundaries)
    
    func installTimeObserver(for player: AVPlayer) {
        removeTimeObserver()

        // Check playback position every 0.1 seconds
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserverOwner = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                // For composition-based fallback, still enforce trim boundaries if looping
                if self.usePreviewFallback, self.composition != nil {
                    let currentTime = time.seconds
                    
                    // Enforce trim boundaries when looping is enabled
                    guard self.videoItem.loopPlayback else { return }
                    
                    let trimStart = self.videoItem.effectiveTrimStart
                    let trimEnd = self.videoItem.effectiveTrimEnd
                    let tolerance = 0.05
                    
                    // Keep playback within trim boundaries
                    if currentTime < trimStart - tolerance {
                        // Before trim start - load correct chunk and seek
                        let targetChunk = Int(trimStart / self.chunkDuration)
                        if targetChunk != self.currentChunkIndex {
                            self.loadChunkForTime(trimStart)
                        } else {
                            let startTime = CMTime(seconds: trimStart, preferredTimescale: 600)
                            self.player?.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    } else if currentTime >= trimEnd - tolerance {
                        // At trim end - loop back to trim start
                        let targetChunk = Int(trimStart / self.chunkDuration)
                        if targetChunk != self.currentChunkIndex {
                            // Need to load different chunk for trim start
                            self.loadChunkForTime(trimStart)
                        } else {
                            // Same chunk - just seek
                            let startTime = CMTime(seconds: trimStart, preferredTimescale: 600)
                            self.player?.seek(to: startTime, toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    }
                    return
                }
                
                // For legacy chunked fallback, check if we need to switch chunks
                if self.usePreviewFallback, let previewRange = self.fallbackPreviewRange {
                    let currentTime = time.seconds
                    let chunkDuration = previewRange.upperBound - previewRange.lowerBound
                    let isPlaying = (self.player?.rate ?? 0) > 0
                    
                    // Only auto-switch during playback, not when paused/stepping frames
                    if isPlaying {
                        // Check if we've crossed chunk boundaries (forward or backward)
                        if currentTime >= chunkDuration - 1.0 {
                            // Approaching end - load next chunk
                            let nextChunkIndex = self.currentChunkIndex + 1
                            let totalChunks = Int(ceil(self.videoItem.durationSeconds / self.chunkDuration))
                            
                            if nextChunkIndex < totalChunks && !self.isLoadingChunk {
                                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                                    .info("Auto-switching to next chunk \(nextChunkIndex, privacy: .public) for continuous playback")
                                self.loadChunkForTime(Double(nextChunkIndex) * self.chunkDuration)
                                return
                            }
                        } else if currentTime < 1.0 && self.currentChunkIndex > 0 {
                            // Near beginning while playing backward - check if should load previous chunk
                            let absoluteTime = previewRange.lowerBound + currentTime
                            let targetChunk = Int(absoluteTime / self.chunkDuration)
                            
                            if targetChunk < self.currentChunkIndex && !self.isLoadingChunk {
                                Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                                    .info("Auto-switching to previous chunk \(targetChunk, privacy: .public)")
                                self.loadChunkForTime(Double(targetChunk) * self.chunkDuration)
                                return
                            }
                        }
                    }
                    return
                }

                let currentTime = time.seconds
                
                // Only enforce trim boundaries when looping is enabled and not using fallback
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
        playbackTimeObserverOwner = player
        playbackTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let currentTime = time.seconds
                if currentTime.isFinite {
                    // For composition-based playback, use composition time directly
                    if self.usePreviewFallback, self.composition != nil {
                        // Composition time is absolute across full audio duration
                        self.currentPlaybackTime = currentTime
                        
                        // Check if we need to load a different video chunk
                        let neededChunkIndex = Int(currentTime / self.chunkDuration)
                        if neededChunkIndex != self.currentChunkIndex && !self.isLoadingChunk {
                            self.loadChunkForTime(currentTime)
                        }
                    } else if self.usePreviewFallback, let range = self.fallbackPreviewRange {
                        // Legacy chunk-based playback (fallback)
                        let absoluteTime = range.lowerBound + currentTime
                        self.currentPlaybackTime = absoluteTime
                    } else {
                        // Native playback
                        self.currentPlaybackTime = currentTime
                    }
                }
            }
        }
    }
    
    func removePlaybackTimeObserver() {
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
        
        playerItemStatusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }

                let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "Preview")
                
                switch item.status {
                case .failed:
                    let failureDescription = item.error?.localizedDescription ?? "unknown error"
                    logger.warning("Direct AVPlayer playback failed (description: \(failureDescription, privacy: .public)). Preparing MP4 fallback preview.")
                    
                    if let error = item.error as NSError? {
                        let userInfoKeys = error.userInfo.keys.map { String(describing: $0) }
                        logger.warning("AVPlayer error details – domain: \(error.domain, privacy: .public), code: \(error.code, privacy: .public), userInfoKeys: \(userInfoKeys, privacy: .public)")
                        
                        if let failureReason = error.localizedFailureReason, !failureReason.isEmpty {
                            logger.debug("AVPlayer failure reason: \(failureReason, privacy: .public)")
                        }
                        
                        if let recoverySuggestion = error.localizedRecoverySuggestion, !recoverySuggestion.isEmpty {
                            logger.debug("AVPlayer recovery suggestion: \(recoverySuggestion, privacy: .public)")
                        }
                        
                        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                            logger.warning("Underlying error – domain: \(underlying.domain, privacy: .public), code: \(underlying.code, privacy: .public), description: \(underlying.localizedDescription, privacy: .public)")
                        }
                    } else {
                        logger.warning("AVPlayer item failed without NSError payload.")
                    }
                    
                    if let urlAsset = item.asset as? AVURLAsset {
                        let pathExtension = urlAsset.url.pathExtension
                        logger.debug("Failing asset metadata – extension: \(pathExtension, privacy: .public)")
                    } else {
                        logger.debug("Failing asset type: \(String(describing: type(of: item.asset)), privacy: .public)")
                    }
                    
                    let asset = item.asset
                    Task {
                        if let urlAsset = asset as? AVURLAsset {
                            do {
                                let resourceValues = try urlAsset.url.resourceValues(forKeys: [.typeIdentifierKey])
                                if let uti = resourceValues.typeIdentifier {
                                    logger.debug("Failing asset UTI: \(uti, privacy: .public)")
                                } else {
                                    logger.debug("Failing asset UTI unavailable")
                                }
                            } catch {
                                logger.debug("Failed to read asset resource values: \(error.localizedDescription, privacy: .public)")
                            }
                        }

                        do {
                            let duration = try await asset.load(.duration)
                            logger.debug("Failing asset duration: \(duration.seconds, privacy: .public)s")
                        } catch {
                            logger.debug("Failed to load asset duration: \(error.localizedDescription, privacy: .public)")
                        }

                        do {
                            let videoTracks = try await asset.loadTracks(withMediaType: .video)
                            if videoTracks.isEmpty {
                                logger.warning("No video tracks available when inspecting failed asset.")
                            }
                            
                            for track in videoTracks {
                                let frameRate = try await track.load(.nominalFrameRate)
                                let isPlayable = try await track.load(.isPlayable)
                                let naturalSize = try await track.load(.naturalSize)
                                let sizeDescription = "\(Int(naturalSize.width))x\(Int(naturalSize.height))"
                                let formatDescriptions = try await track.load(.formatDescriptions) as [CMFormatDescription]
                                
                                let codecNames: [String] = formatDescriptions.map { desc in
                                    let codec = CMFormatDescriptionGetMediaSubType(desc)
                                    let codecBytes: [UInt8] = [
                                        UInt8((codec >> 24) & 0xFF),
                                        UInt8((codec >> 16) & 0xFF),
                                        UInt8((codec >> 8) & 0xFF),
                                        UInt8(codec & 0xFF)
                                    ]
                                    
                                    if let fourCC = String(bytes: codecBytes, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters),
                                       fourCC.count == 4 {
                                        return fourCC
                                    }
                                    
                                    return String(format: "%08X", codec)
                                }
                                
                                let codecSummary = codecNames.isEmpty ? "<none>" : codecNames.joined(separator: ",")
                                logger.debug("Video track \(Int(track.trackID), privacy: .public) details – nominalFrameRate: \(frameRate, privacy: .public), naturalSize: \(sizeDescription, privacy: .public), isPlayable: \(isPlayable, privacy: .public), codecs: \(codecSummary, privacy: .public)")
                            }
                        } catch {
                            logger.error("Failed to inspect asset tracks after AVPlayer failure: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    
                    self.fallbackToPreview(startTime: startTime)
                    
                case .readyToPlay:
                    let asset = item.asset
                    
                    Task {
                        do {
                            let videoTracks = try await asset.loadTracks(withMediaType: .video)
                            
                            if !videoTracks.isEmpty {
                                // Check if video tracks have valid format descriptions
                                var hasValidVideoFormat = false
                                for track in videoTracks {
                                    let formatDescriptions = try await track.load(.formatDescriptions) as [CMFormatDescription]
                                    if !formatDescriptions.isEmpty {
                                        hasValidVideoFormat = true
                                        break
                                    }
                                }
                                
                                if !hasValidVideoFormat {
                                    logger.warning("AVPlayer ready but video format invalid. Preparing MP4 fallback preview.")
                                    self.fallbackToPreview(startTime: startTime)
                                    return
                                }
                                
                                // Check for truly unsupported video codecs (like APV)
                                for track in videoTracks {
                                    let formatDescriptions = try await track.load(.formatDescriptions) as [CMFormatDescription]
                                    for desc in formatDescriptions {
                                        let codec = CMFormatDescriptionGetMediaSubType(desc)
                                        let codecBytes: [UInt8] = [
                                            UInt8((codec >> 24) & 0xFF),
                                            UInt8((codec >> 16) & 0xFF),
                                            UInt8((codec >> 8) & 0xFF),
                                            UInt8(codec & 0xFF)
                                        ]
                                        let codecString: String
                                        if let fourCC = String(bytes: codecBytes, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters),
                                           fourCC.count == 4 {
                                            codecString = fourCC
                                        } else {
                                            codecString = String(format: "%08X", codec)
                                        }
                                        
                                        logger.debug("Video codec detected: '\(codecString)' (raw: \(codec))")
                                        
                                        // Check for truly unsupported codecs
                                        // Only APV codecs are unsupported - all ProRes variants work with AVPlayer
                                        if codecString == "apv1" || codecString == "apvx" {
                                            logger.warning("AVPlayer ready but codec '\(codecString)' unsupported. Preparing MP4 fallback preview.")
                                            self.fallbackToPreview(startTime: startTime)
                                            return
                                        }
                                    }
                                }
                            }
                            
                            // Direct playback successful
                            logger.debug("Direct AVPlayer playback ready")
                            
                        } catch {
                            // If we can't load tracks, assume it's okay and let AVPlayer try
                            logger.debug("Could not verify video tracks, proceeding with playback")
                        }
                    }
                    
                case .unknown:
                    break
                    
                @unknown default:
                    break
                }
            }
        }
    }
    
    func removePlayerItemStatusObserver() {
        if let playerItemStatusObserver {
            (playerItemStatusObserver as? NSKeyValueObservation)?.invalidate()
            self.playerItemStatusObserver = nil
        }
    }
}
