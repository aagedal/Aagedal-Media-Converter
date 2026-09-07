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
import OSLog

struct PreviewPlayerView: View {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "PreviewPlayerView")

    @Binding var item: VideoItem
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: PreviewPlayerController
    @State private var activeTrimGestures: Int = 0
    @State private var currentPlaybackTime: Double = 0
    @State private var showsPlaybackControls: Bool = false
    @State private var isCropControlsExpanded: Bool = false
    @State private var selectedCropAspectRatio: AspectRatio = .free
    @State private var timecodeActivationTrigger: String?
    @State private var isEditingTimecode: Bool = false
    @State private var timecodeDisplayMode: TimecodeDisplayMode = .preferred
    
    private let initialCropExpanded: Bool

    init(item: Binding<VideoItem>, initialCropExpanded: Bool = false) {
        self._item = item
        self._controller = StateObject(wrappedValue: PreviewPlayerController(videoItem: item.wrappedValue))
        self.initialCropExpanded = initialCropExpanded
    }

    var body: some View {
        VStack(spacing: 8) {
            PreviewPlayerContent(
                item: $item,
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
                item: $item,
                controller: controller,
                currentPlaybackTime: $currentPlaybackTime,
                isCropControlsExpanded: $isCropControlsExpanded,
                selectedCropAspectRatio: $selectedCropAspectRatio,
                onSeek: controller.seekTo,
                onReset: resetTrim,
                onCaptureScreenshot: captureScreenshot,
                trimStartBinding: trimStartBinding,
                trimEndBinding: trimEndBinding,
                onTrimEditingChanged: handleTrimEditingChanged,
                loopBinding: loopBinding,
                timecodeActivationTrigger: $timecodeActivationTrigger,
                isEditingTimecode: $isEditingTimecode,
                timecodeDisplayMode: $timecodeDisplayMode
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
        .frame(minWidth: 1150, idealWidth: 1350, minHeight: 850, idealHeight: 950)
        .background(Color(NSColor.windowBackgroundColor))
        .background(KeyboardHandler(onCommandA: {
            controller.isAudioMeterEnabled.toggle()
        }))
        .onAppear {
            // Set initial crop expanded state if requested
            if initialCropExpanded {
                isCropControlsExpanded = true
                // Sync crop overlay with controls state
                controller.isCropEnabled = true
            }

            // Skip preview loading for scheduled downloads or items being downloaded
            guard !item.isDownloading && item.scheduledDownloadTime == nil else {
                return
            }

            // Prepare preview IMMEDIATELY - don't wait for metadata
            controller.preparePreview(startTime: item.effectiveTrimStart)

            // Fetch metadata in background (non-blocking) - only if needed
            if item.metadata == nil {
                Task {
                    if let metadata = await VideoFileUtils.fetchMetadata(for: item.url) {
                        await MainActor.run {
                            item.metadata = metadata
                            // Update controller with new metadata if still relevant
                            controller.updateVideoItem(item)
                        }
                    }
                }
            }
        }
        .onDisappear {
            Task { @MainActor in controller.teardown() }
        }
        .onChange(of: item) { _, newValue in controller.updateVideoItem(newValue) }
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
                _ = try await controller.captureScreenshot(to: directoryURL)
            } catch is CancellationError {
                // Closing or replacing the preview intentionally cancels the capture.
            } catch {
                Self.logger.error("Screenshot capture failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func openFullscreenPlayer() {
        // Pause the trim player before opening fullscreen
        controller.pause()

        // Get current playback position
        let currentPosition = currentPlaybackTime

        // Open fullscreen player with position sync and trim sync
        FullscreenPlayerWindowController.shared.openFullscreenPlayerFromTrimView(
            for: item,
            startTime: currentPosition,
            onCloseWithPosition: { [weak controller] finalPosition in
                // When fullscreen closes, sync position back to trim player
                Task { @MainActor in
                    controller?.seekTo(finalPosition)
                }
            },
            onTrimChanged: { [self] trimStart, trimEnd in
                // Sync trim changes from fullscreen player back to the item
                Task { @MainActor in
                    item.trimStart = trimStart
                    item.trimEnd = trimEnd
                }
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

    private func resetTrim() {
        item.trimStart = nil
        item.trimEnd = nil
        controller.refreshPreviewForTrim()
    }

    private func handleTrimInPoint(clearToStart: Bool) {
        if clearToStart {
            // Option+I: Clear trim start (set to beginning)
            item.trimStart = nil
        } else {
            // I: Set trim start to current playback position
            // Use currentPlaybackTime directly instead of getCurrentTime() to work during preparation
            let currentTime = currentPlaybackTime
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
    
    private func handleTrimOutPoint(clearToEnd: Bool) {
        if clearToEnd {
            // Option+O: Clear trim end (set to end of video)
            item.trimEnd = nil
        } else {
            // O: Set trim end to current playback position
            // Use currentPlaybackTime directly instead of getCurrentTime() to work during preparation
            let currentTime = currentPlaybackTime
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

    // MARK: - Crop Keyboard Shortcuts

    /// Move the crop box by the given delta in normalized coordinates
    private func moveCropBox(dx: Double, dy: Double) {
        var config = item.cropConfig ?? CropConfig(normalizedRect: .fullFrame)
        var rect = config.normalizedRect

        // Apply the delta
        rect.x += dx
        rect.y += dy

        // Clamp to bounds (0-1)
        rect.x = max(0, min(1 - rect.width, rect.x))
        rect.y = max(0, min(1 - rect.height, rect.y))

        config.normalizedRect = rect
        item.cropConfig = config.isActive ? config : nil
    }

    /// Select a crop aspect ratio preset via keyboard shortcut
    private func selectCropAspectRatio(_ newRatio: AspectRatio) {
        selectedCropAspectRatio = newRatio

        var config = item.cropConfig ?? CropConfig(normalizedRect: .fullFrame)
        config.aspectRatioLock = newRatio == .free ? nil : newRatio

        // If not free, adjust the rectangle to match the aspect ratio
        if let targetRatio = newRatio.numericRatio {
            var rect = config.normalizedRect

            // Calculate center point to maintain position
            let centerX = rect.x + rect.width / 2
            let centerY = rect.y + rect.height / 2

            // Get the video's display aspect ratio
            let videoDisplayAspectRatio = item.videoDisplayAspectRatio ?? (16.0 / 9.0)

            // Convert target aspect ratio from VISUAL space to normalized (source-pixel) space
            let normalizedTargetRatio = targetRatio / videoDisplayAspectRatio

            // Calculate dimensions that maintain aspect ratio and fit within bounds
            var newWidth: Double
            var newHeight: Double

            // Try to fit rectangle with target aspect ratio within full frame
            if normalizedTargetRatio >= 1.0 {
                // Wider than tall: fit width to 1.0, scale height accordingly
                newWidth = 1.0
                newHeight = newWidth / normalizedTargetRatio
                if newHeight > 1.0 {
                    newHeight = 1.0
                    newWidth = newHeight * normalizedTargetRatio
                }
            } else {
                // Taller than wide: fit height to 1.0, scale width accordingly
                newHeight = 1.0
                newWidth = newHeight * normalizedTargetRatio
                if newWidth > 1.0 {
                    newWidth = 1.0
                    newHeight = newWidth / normalizedTargetRatio
                }
            }

            // Position to maintain center as much as possible, but ensure it fits
            rect.width = newWidth
            rect.height = newHeight
            rect.x = max(0, min(1.0 - rect.width, centerX - rect.width / 2))
            rect.y = max(0, min(1.0 - rect.height, centerY - rect.height / 2))

            config.normalizedRect = rect
        }

        item.cropConfig = config.isActive ? config : nil
    }

    /// Reset crop to full frame
    private func resetCrop() {
        item.cropConfig = nil
        selectedCropAspectRatio = .free
    }

    /// Scale the crop box by a factor while maintaining center position and aspect ratio
    private func scaleCropBox(factor: Double) {
        var config = item.cropConfig ?? CropConfig(normalizedRect: .fullFrame)
        var rect = config.normalizedRect

        // Calculate center point
        let centerX = rect.x + rect.width / 2
        let centerY = rect.y + rect.height / 2

        // Scale dimensions
        var newWidth = rect.width * factor
        var newHeight = rect.height * factor

        // Clamp to minimum size (2% of frame)
        let minSize = 0.02
        newWidth = max(minSize, newWidth)
        newHeight = max(minSize, newHeight)

        // Clamp to maximum size (full frame)
        newWidth = min(1.0, newWidth)
        newHeight = min(1.0, newHeight)

        // If aspect ratio is locked, maintain it
        if let targetRatio = selectedCropAspectRatio.numericRatio {
            let videoDisplayAspectRatio = item.videoDisplayAspectRatio ?? (16.0 / 9.0)
            let normalizedTargetRatio = targetRatio / videoDisplayAspectRatio

            // Adjust to maintain aspect ratio
            if normalizedTargetRatio >= 1.0 {
                newHeight = newWidth / normalizedTargetRatio
                if newHeight > 1.0 {
                    newHeight = 1.0
                    newWidth = newHeight * normalizedTargetRatio
                }
            } else {
                newWidth = newHeight * normalizedTargetRatio
                if newWidth > 1.0 {
                    newWidth = 1.0
                    newHeight = newWidth / normalizedTargetRatio
                }
            }
        }

        // Position centered
        rect.width = newWidth
        rect.height = newHeight
        rect.x = max(0, min(1.0 - rect.width, centerX - rect.width / 2))
        rect.y = max(0, min(1.0 - rect.height, centerY - rect.height / 2))

        config.normalizedRect = rect
        item.cropConfig = config.isActive ? config : nil
    }

    private func handleKeyCommand(key: String, modifiers: NSEvent.ModifierFlags, specialKey: NSEvent.SpecialKey? = nil) -> Bool {
        // CMD + Arrow keys: Move crop box (when crop mode is active)
        if modifiers.contains(.command) && isCropControlsExpanded {
            if let direction = specialKey {
                switch direction {
                case .leftArrow:
                    moveCropBox(dx: -0.01, dy: 0)
                    return true
                case .rightArrow:
                    moveCropBox(dx: 0.01, dy: 0)
                    return true
                case .upArrow:
                    moveCropBox(dx: 0, dy: -0.01)
                    return true
                case .downArrow:
                    moveCropBox(dx: 0, dy: 0.01)
                    return true
                default:
                    break
                }
            }
        }

        if specialKey == .downArrow {
            // Down: Jump forward 10 frames
            controller.seekByFrames(10)
            return true
        } else if specialKey == .upArrow {
            // Up: Jump backward 10 frames
            controller.seekByFrames(-10)
            return true
        } else if specialKey == .leftArrow {
            controller.seekByFrames(-1)
            return true
        } else if specialKey == .rightArrow {
            controller.seekByFrames(1)
            return true
        }

        let lowerKey = key.lowercased()

        // Space to toggle playback
        if key == " " {
            controller.togglePlayback()
            return true
        }

        // Check for number keys, +, -, ., : to activate timecode input (only if no modifiers and not already editing)
        let noModifiers = modifiers.intersection([.command, .option, .control, .shift]).isEmpty
        if noModifiers && !isEditingTimecode {
            let isNumberOrTimecodeChar = key.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789+-.:;")) != nil
            if isNumberOrTimecodeChar {
                // Activate timecode input with this character
                timecodeActivationTrigger = key
                return true
            }
        }

        if modifiers.contains(.command) {
            switch lowerKey {
            case "l":
                item.loopPlayback.toggle()
                return true
            case "f":
                openFullscreenPlayer()
                return true
            case "s":
                // CMD+S: Capture screenshot
                captureScreenshot()
                return true
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                // CMD+1...9: Select aspect ratio presets (when crop mode is active)
                if isCropControlsExpanded, let index = Int(lowerKey) {
                    let ratios = AspectRatio.allCases
                    if index >= 1 && index <= ratios.count {
                        selectCropAspectRatio(ratios[index - 1])
                        return true
                    }
                }
                return false
            case "0":
                // CMD+0: Reset crop
                if isCropControlsExpanded {
                    resetCrop()
                    return true
                }
                return false
            case "=", "+":
                // CMD+= or CMD++: Scale crop box larger
                if isCropControlsExpanded {
                    scaleCropBox(factor: 1.05)
                    return true
                }
                return false
            case "-":
                // CMD+-: Scale crop box smaller
                if isCropControlsExpanded {
                    scaleCropBox(factor: 0.95)
                    return true
                }
                return false
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
            case "x":
                resetTrim()
                return true
            case "j":
                controller.slowReverse()
                return true
            case "l":
                controller.slowForward()
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
        case "j":
            controller.startReverseSimulation()
            return true
        case "k":
            controller.togglePlayback()
            return true
        case "l":
            controller.fastForward()
            return true
        case "c":
            isCropControlsExpanded.toggle()
            // Sync crop overlay with controls state
            controller.isCropEnabled = isCropControlsExpanded
            return true
        case "t":
            // T: Toggle timecode display mode (when not editing timecode)
            if !isEditingTimecode {
                timecodeDisplayMode.toggle()
                return true
            }
            return false
        default:
            return false
        }
    }
}

// MARK: - Keyboard Handler

/// Helper view to handle keyboard shortcuts using NSEvent
private struct KeyboardHandler: NSViewRepresentable {
    let onCommandA: () -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "a" {
                onCommandA()
                return nil // Event handled
            }
            return event
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var monitor: Any?
        
        deinit {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
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
        // Make background transparent so checkerboard shows through
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

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
