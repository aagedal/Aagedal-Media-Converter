// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import AppKit
import AVKit

private struct ScreenshotFeedback: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct PreviewPlayerView: View {
    @Binding var item: VideoItem
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: PreviewPlayerController
    @State private var activeTrimGestures: Int = 0
    @State private var currentPlaybackTime: Double = 0
    @State private var screenshotFeedback: ScreenshotFeedback?
    @State private var showsPlaybackControls: Bool = false

    init(item: Binding<VideoItem>) {
        self._item = item
        self._controller = StateObject(wrappedValue: PreviewPlayerController(videoItem: item.wrappedValue))
    }

    var body: some View {
        VStack(spacing: 8) {
            PreviewPlayerContent(
                item: item,
                controller: controller,
                showsPlaybackControls: showsPlaybackControls,
                togglePlaybackControls: { showsPlaybackControls.toggle() },
                keyHandler: handleKeyCommand,
                currentPlaybackTime: $currentPlaybackTime
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )

            PreviewTrimControls(
                item: item,
                controller: controller,
                currentPlaybackTime: $currentPlaybackTime,
                onSeek: controller.seekTo,
                onReset: resetTrim,
                onCaptureScreenshot: captureScreenshot,
                trimStartBinding: trimStartBinding,
                trimEndBinding: trimEndBinding,
                onTrimEditingChanged: handleTrimEditingChanged,
                loopBinding: loopBinding
            )
            .transition(.opacity)

            PreviewPlayerFooter(
                item: item,
                controller: controller,
                currentPlaybackTime: currentPlaybackTime,
                dismiss: dismiss.callAsFunction,
                togglePlaybackControls: { showsPlaybackControls.toggle() }
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(minWidth: 920, idealWidth: 1080, minHeight: 640, idealHeight: 720)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            controller.preparePreview(startTime: item.effectiveTrimStart)
        }
        .onDisappear {
            Task { @MainActor in controller.teardown() }
        }
        .onChange(of: item) { _, newValue in controller.updateVideoItem(newValue) }
        .alert(item: $screenshotFeedback) { feedback in
            Alert(
                title: Text(feedback.title),
                message: Text(feedback.message),
                dismissButton: .default(Text("OK"))
            )
        }
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

    private func captureScreenshot() {
        Task {
            let defaults = UserDefaults.standard
            let directoryPath = defaults.string(forKey: AppConstants.screenshotDirectoryKey) ?? AppConstants.defaultScreenshotDirectory.path
            let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)

            do {
                let savedURL = try await controller.captureScreenshot(to: directoryURL)
                screenshotFeedback = ScreenshotFeedback(
                    title: "Frame saved",
                    message: savedURL.path
                )
            } catch {
                screenshotFeedback = ScreenshotFeedback(
                    title: "Capture failed",
                    message: error.localizedDescription
                )
            }
        }
    }


    private func handleTrimEditingChanged(_ editing: Bool) {
        if editing {
            activeTrimGestures += 1
        } else {
            activeTrimGestures = max(activeTrimGestures - 1, 0)
            // No need to refresh since we're seeking in real-time during drag
        }
    }

    private func resetTrim() {
        item.trimStart = nil
        item.trimEnd = nil
        controller.refreshPreviewForTrim()
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

    private func handleKeyCommand(key: String, modifiers: NSEvent.ModifierFlags, specialKey: NSEvent.SpecialKey? = nil) -> Bool {
        if specialKey == .downArrow {
            if controller.jumpToNextCachedSegmentStart() {
                return true
            }
        } else if specialKey == .upArrow {
            if controller.jumpToPreviousCachedSegmentEnd() {
                return true
            }
        }

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

        // Check for Shift+I/O to jump to trim positions
        // Must have shift, and must NOT have command/option/control
        let hasShift = modifiers.contains(.shift)
        let hasOtherModifiers = !modifiers.intersection([.command, .option, .control]).isEmpty
        
        if hasShift && !hasOtherModifiers {
            switch lowerKey {
            case "i":
                controller.seekTo(item.effectiveTrimStart)
                return true
            case "o":
                controller.seekTo(item.effectiveTrimEnd)
                return true
            default:
                return false
            }
        }

        // Check for plain I/O (no modifiers) to set trim positions
        let disallowedModifiers = modifiers.intersection([.command, .option, .control, .shift])
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

// MARK: - Player Container

private struct PlayerContainerView: NSViewRepresentable {
    let player: AVPlayer
    let controller: PreviewPlayerController
    let showsPlaybackControls: Bool
    let keyHandler: (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool

    func makeNSView(context: Context) -> ShortcutAwarePlayerView {
        let view = ShortcutAwarePlayerView()
        view.configure(
            player: player,
            controller: controller,
            showsPlaybackControls: showsPlaybackControls,
            keyHandler: keyHandler
        )
        return view
    }

    func updateNSView(_ nsView: ShortcutAwarePlayerView, context: Context) {
        nsView.update(player: player, showsPlaybackControls: showsPlaybackControls, keyHandler: keyHandler)
    }
}

private final class ShortcutAwarePlayerView: AVPlayerView {
    private var keyHandler: ((String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool)?

    func configure(
        player: AVPlayer,
        controller: PreviewPlayerController,
        showsPlaybackControls: Bool,
        keyHandler: @escaping (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool
    ) {
        self.keyHandler = keyHandler
        controlsStyle = showsPlaybackControls ? .inline : .none
        updatesNowPlayingInfoCenter = false
        showsFullScreenToggleButton = showsPlaybackControls
        showsFrameSteppingButtons = showsPlaybackControls
        showsSharingServiceButton = false
        showsTimecodes = showsPlaybackControls
        videoGravity = .resizeAspect
        allowsVideoFrameAnalysis = false
        self.player = player

        Task { @MainActor in
            controller.playerView = self
        }
    }

    func update(player: AVPlayer, showsPlaybackControls: Bool, keyHandler: @escaping (String, NSEvent.ModifierFlags, NSEvent.SpecialKey?) -> Bool) {
        self.keyHandler = keyHandler
        if self.player !== player {
            self.player = player
        }
        
        // Update controls visibility
        controlsStyle = showsPlaybackControls ? .inline : .none
        showsFullScreenToggleButton = showsPlaybackControls
        showsFrameSteppingButtons = showsPlaybackControls
        showsTimecodes = showsPlaybackControls
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

        if keyHandler?(characters, event.modifierFlags, event.specialKey) == true {
            return
        }

        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else {
            return super.performKeyEquivalent(with: event)
        }

        if keyHandler?(characters, event.modifierFlags, event.specialKey) == true {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
