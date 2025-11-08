// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import AVKit

struct PreviewPlayerView: View {
    @Binding var item: VideoItem
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: PreviewPlayerController
    @State private var activeTrimGestures: Int = 0
    @State private var currentPlaybackTime: Double = 0

    init(item: Binding<VideoItem>) {
        self._item = item
        self._controller = StateObject(wrappedValue: PreviewPlayerController(videoItem: item.wrappedValue))
    }

    var body: some View {
        VStack(spacing: 16) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

            trimControls
                .transition(.opacity)

            footer
        }
        .padding(24)
        .frame(minWidth: 920, idealWidth: 1080, minHeight: 640, idealHeight: 720)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            controller.preparePreview(startTime: item.effectiveTrimStart)
        }
        .onDisappear {
            Task { @MainActor in controller.teardown() }
        }
        .onChange(of: item) { _, newValue in controller.updateVideoItem(newValue) }
    }

    @ViewBuilder
    private var content: some View {
        if let player = controller.player {
            PlayerContainerView(
                player: player,
                controller: controller,
                keyHandler: handleKeyCommand
            )
        } else if controller.isPreparing {
            VStack(spacing: 12) {
                ProgressView().progressViewStyle(.circular)
                Text("Preparing preview…")
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding()
        } else if let message = controller.errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 40))
                Text("Preview unavailable")
                    .font(.headline)
                    .foregroundColor(.white)
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Retry") {
                    controller.preparePreview(startTime: 0)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        } else {
            Text("Preview not available")
                .foregroundColor(.white.opacity(0.8))
                .padding()
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("Duration: \(item.duration)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(role: .cancel, action: dismiss.callAsFunction) {
                Label("Close", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close preview")
        }
    }

    private var trimControls: some View {
        let duration = max(item.durationSeconds, 0)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trim & Loop")
                        .font(.headline)
                    Text("I/O: set in/out • ⌥I/⌥O: clear • ⌘L: loop")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Reset Trim") {
                    item.trimStart = nil
                    item.trimEnd = nil
                    controller.refreshPreviewForTrim()
                }
                .disabled(item.trimStart == nil && item.trimEnd == nil)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    // Jump to start button
                    Button(action: {
                        controller.seekTo(item.effectiveTrimStart)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.left.to.line")
                            Text("Start: \(formattedTime(item.effectiveTrimStart))")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .help("Jump to trim start")
                    
                    Spacer()
                    
                    // Current playback position
                    Text("⏱ \(formattedTime(currentPlaybackTime))")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    // Jump to end button
                    Button(action: {
                        controller.seekTo(item.effectiveTrimEnd)
                    }) {
                        HStack(spacing: 4) {
                            Text("End: \(formattedTime(item.effectiveTrimEnd))")
                            Image(systemName: "arrow.right.to.line")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .help("Jump to trim end")
                }
                .font(.subheadline)
                
                // Visual playback position indicator
                ZStack(alignment: .leading) {
                    RangeSlider(
                        lowerValue: trimStartBinding,
                        upperValue: trimEndBinding,
                        bounds: 0...duration,
                        step: 0.1,
                        onEditingChanged: handleTrimEditingChanged
                    )
                    .disabled(duration == 0)
                    
                    // Playback position indicator
                    GeometryReader { geometry in
                        let position = duration > 0 ? (currentPlaybackTime / duration) * geometry.size.width : 0
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2, height: 30)
                            .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 0)
                            .offset(x: position - 1, y: -5)
                    }
                }
                .frame(height: 30)
                .padding(.vertical, 4)
                .onReceive(controller.playbackTimePublisher) { time in
                    currentPlaybackTime = time
                }
            }

            HStack {
                Toggle("Loop playback", isOn: loopBinding)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "scissors")
                        .font(.caption)
                    Text("Trimmed duration: \(formattedTime(item.trimmedDuration))")
                }
                .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var trimStartBinding: Binding<Double> {
        Binding(
            get: { item.trimStart ?? 0 },
            set: { newValue in
                let duration = max(item.durationSeconds, 0)
                let clamped = max(0, min(newValue, duration))
                let sanitized = clamped <= 0.05 ? nil : clamped
                item.trimStart = sanitized
                if let end = item.trimEnd, end < item.effectiveTrimStart {
                    item.trimEnd = sanitized
                }
                // Seek to the new trim start position to show the first frame
                controller.seekTo(item.effectiveTrimStart)
            }
        )
    }

    private var trimEndBinding: Binding<Double> {
        Binding(
            get: { item.trimEnd ?? item.durationSeconds },
            set: { newValue in
                let duration = max(item.durationSeconds, 0)
                let clamped = max(0, min(newValue, duration))
                let minEnd = item.effectiveTrimStart
                let sanitizedValue = max(clamped, minEnd)
                if sanitizedValue >= duration - 0.05 {
                    item.trimEnd = nil
                } else {
                    item.trimEnd = sanitizedValue
                }
                // Seek to the new trim end position to show the last frame
                controller.seekTo(item.effectiveTrimEnd)
            }
        )
    }

    private var loopBinding: Binding<Bool> {
        Binding(
            get: { item.loopPlayback },
            set: { newValue in
                item.loopPlayback = newValue
            }
        )
    }

    private func handleTrimEditingChanged(_ editing: Bool) {
        if editing {
            activeTrimGestures += 1
        } else {
            activeTrimGestures = max(activeTrimGestures - 1, 0)
            // No need to refresh since we're seeking in real-time during drag
        }
    }

    private func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
    
    private func handleTrimInPoint(clearToStart: Bool) {
        if clearToStart {
            // Option+I: Clear trim start (set to beginning)
            item.trimStart = nil
        } else {
            // I: Set trim start to current playback position
            if let currentTime = controller.getCurrentTime() {
                let duration = max(item.durationSeconds, 0)
                let clamped = max(0, min(currentTime, duration))
                // Only set if it's not at the very start
                item.trimStart = clamped <= 0.05 ? nil : clamped
                // Ensure trim end is after trim start
                if let end = item.trimEnd, end < item.effectiveTrimStart {
                    item.trimEnd = item.trimStart
                }
            }
        }
    }
    
    private func handleTrimOutPoint(clearToEnd: Bool) {
        if clearToEnd {
            // Option+O: Clear trim end (set to end of video)
            item.trimEnd = nil
        } else {
            // O: Set trim end to current playback position
            if let currentTime = controller.getCurrentTime() {
                let duration = max(item.durationSeconds, 0)
                let clamped = max(0, min(currentTime, duration))
                let minEnd = item.effectiveTrimStart
                let sanitizedValue = max(clamped, minEnd)
                // Only set if it's not at the very end
                if sanitizedValue >= duration - 0.05 {
                    item.trimEnd = nil
                } else {
                    item.trimEnd = sanitizedValue
                }
            }
        }
    }

    private func handleKeyCommand(key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        let lowerKey = key.lowercased()

        if modifiers.contains(.command) {
            switch lowerKey {
            case "l":
                item.loopPlayback.toggle()
                return true
            case "f":
                controller.toggleFullscreen()
                return true
            default:
                return false
            }
        }

        if modifiers.contains(.option) {
            switch lowerKey {
            case "i":
                handleTrimInPoint(clearToStart: true)
                return true
            case "o":
                handleTrimOutPoint(clearToEnd: true)
                return true
            default:
                return false
            }
        }

        let disallowedModifiers = modifiers.intersection([.command, .option, .control])
        if !disallowedModifiers.isEmpty {
            return false
        }

        switch lowerKey {
        case "i":
            handleTrimInPoint(clearToStart: false)
            return true
        case "o":
            handleTrimOutPoint(clearToEnd: false)
            return true
        default:
            return false
        }
    }
}

private final class WeakPreviewPlayerController: @unchecked Sendable {
    weak var value: PreviewPlayerController?

    init(_ value: PreviewPlayerController) {
        self.value = value
    }
}

// MARK: - Controller

@MainActor
final class PreviewPlayerController: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isPreparing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentPlaybackTime: Double = 0

    private var videoItem: VideoItem
    private var session: HLSPreviewSession?
    private var loader: PreviewAssetResourceLoader?
    private var preparationTask: Task<Void, Never>?
    private var loopObserver: Any?
    private var timeObserver: Any?
    private var playbackTimeObserver: Any?
    private var hasSecurityScope = false
    weak var playerView: AVPlayerView?
    
    var playbackTimePublisher: Published<Double>.Publisher { $currentPlaybackTime }

    init(videoItem: VideoItem) {
        self.videoItem = videoItem
    }

    func updateVideoItem(_ newValue: VideoItem) {
        let previous = videoItem
        videoItem = newValue

        if previous.id != newValue.id || previous.url != newValue.url {
            preparePreview(startTime: newValue.effectiveTrimStart)
        } else if previous.loopPlayback != newValue.loopPlayback {
            applyLoopSetting()
        } else if previous.trimStart != newValue.trimStart || previous.trimEnd != newValue.trimEnd {
            // Trim values changed, reinstall time observer with new boundaries
            if let player = player {
                installTimeObserver(for: player)
            }
        }
    }

    func preparePreview(startTime: TimeInterval) {
        teardown()
        isPreparing = true
        errorMessage = nil

        let currentItem = videoItem
        
        // Use AVPlayer directly with security-scoped resource access
        let url = currentItem.url
        hasSecurityScope = url.startAccessingSecurityScopedResource() || 
                          SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: url)
        
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: playerItem)
        
        self.player = player
        self.isPreparing = false
        
        // Seek to start time but remain paused (don't auto-play)
        let seekTime = CMTime(seconds: startTime, preferredTimescale: 600)
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
        
        installLoopObserver(for: playerItem)
        installTimeObserver(for: player)
        installPlaybackTimeObserver(for: player)
        applyLoopSetting()
    }

    func teardown() {
        preparationTask?.cancel()
        preparationTask = nil

        player?.pause()
        
        // Release security-scoped resource only if we acquired it
        if hasSecurityScope {
            let url = videoItem.url
            url.stopAccessingSecurityScopedResource()
            hasSecurityScope = false
        }
        
        player = nil
        loader = nil

        session?.stop()
        session?.cleanup()
        session = nil
        isPreparing = false
        removeLoopObserver()
        removeTimeObserver()
        removePlaybackTimeObserver()
    }

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
    
    func seekTo(_ time: TimeInterval) {
        guard let player else { return }
        let seekTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: seekTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    func getCurrentTime() -> TimeInterval? {
        guard let player else { return nil }
        let currentTime = player.currentTime()
        return currentTime.seconds.isFinite ? currentTime.seconds : nil
    }
    
    func toggleFullscreen() {
        // Try to get window from playerView first, fallback to key window
        let window = playerView?.window ?? NSApp.keyWindow
        window?.toggleFullScreen(nil)
    }

    private func installLoopObserver(for item: AVPlayerItem) {
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

    private func removeLoopObserver() {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
    }
    
    private func installTimeObserver(for player: AVPlayer) {
        removeTimeObserver()
        
        // Check playback position every 0.1 seconds
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                // Only enforce trim boundaries when looping is enabled
                guard self.videoItem.loopPlayback else { return }
                
                let currentTime = time.seconds
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
    
    private func removeTimeObserver() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }
    
    private func installPlaybackTimeObserver(for player: AVPlayer) {
        removePlaybackTimeObserver()
        
        // Update playback time more frequently for smooth UI updates (every 0.05 seconds)
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        playbackTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let currentTime = time.seconds
                if currentTime.isFinite {
                    self.currentPlaybackTime = currentTime
                }
            }
        }
    }
    
    private func removePlaybackTimeObserver() {
        if let playbackTimeObserver, let player {
            player.removeTimeObserver(playbackTimeObserver)
            self.playbackTimeObserver = nil
        }
    }

    private func handlePlaybackEnded() {
        guard videoItem.loopPlayback, let player else { return }
        let target = CMTime(seconds: videoItem.effectiveTrimStart, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            player.play()
        }
    }

    private func applyLoopSetting() {
        player?.actionAtItemEnd = videoItem.loopPlayback ? .none : .pause
    }
}

// MARK: - Player Container

private struct PlayerContainerView: NSViewRepresentable {
    let player: AVPlayer
    let controller: PreviewPlayerController
    let keyHandler: (String, NSEvent.ModifierFlags) -> Bool

    func makeNSView(context: Context) -> ShortcutAwarePlayerView {
        let view = ShortcutAwarePlayerView()
        view.configure(
            player: player,
            controller: controller,
            keyHandler: keyHandler
        )
        return view
    }

    func updateNSView(_ nsView: ShortcutAwarePlayerView, context: Context) {
        nsView.update(player: player, keyHandler: keyHandler)
    }
}

private final class ShortcutAwarePlayerView: AVPlayerView {
    private var keyHandler: ((String, NSEvent.ModifierFlags) -> Bool)?

    func configure(
        player: AVPlayer,
        controller: PreviewPlayerController,
        keyHandler: @escaping (String, NSEvent.ModifierFlags) -> Bool
    ) {
        self.keyHandler = keyHandler
        controlsStyle = .floating
        updatesNowPlayingInfoCenter = false
        showsFullScreenToggleButton = true
        showsFrameSteppingButtons = true
        showsSharingServiceButton = false
        showsTimecodes = true
        videoGravity = .resizeAspect
        allowsVideoFrameAnalysis = false
        self.player = player

        Task { @MainActor in
            controller.playerView = self
        }
    }

    func update(player: AVPlayer, keyHandler: @escaping (String, NSEvent.ModifierFlags) -> Bool) {
        self.keyHandler = keyHandler
        if self.player !== player {
            self.player = player
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            super.keyDown(with: event)
            return
        }

        if keyHandler?(characters, event.modifierFlags) == true {
            return
        }

        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return super.performKeyEquivalent(with: event)
        }

        if keyHandler?(characters, event.modifierFlags) == true {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
