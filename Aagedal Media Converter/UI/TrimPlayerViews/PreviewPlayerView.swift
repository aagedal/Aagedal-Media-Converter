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
                currentPlaybackTime: $currentPlaybackTime,
                cropAspectRatioLock: selectedCropAspectRatio
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
        .onAppear {
            // Set initial crop expanded state if requested
            if initialCropExpanded {
                isCropControlsExpanded = true
                // Sync crop overlay with controls state
                controller.isCropEnabled = true
            }

            // Skip preview loading for scheduled, queued or in-progress downloads
            guard !item.hasPendingDownload else {
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

    /// Trim rules for this item; the timeline uses the same duration and frame grid.
    private var trimEditor: TrimEditor {
        TrimEditor(duration: controller.effectiveDuration, frameRate: item.trimFrameRate)
    }

    // The timeline seeks (throttled) while it edits these, so the setters only store values.
    private var trimStartBinding: Binding<Double> {
        Binding(
            get: { item.trimStart ?? 0 },
            set: { newValue in
                (item.trimStart, item.trimEnd) = trimEditor.settingIn(newValue, end: item.trimEnd)
            }
        )
    }

    private var trimEndBinding: Binding<Double> {
        Binding(
            get: { item.trimEnd ?? trimEditor.duration },
            set: { newValue in
                (item.trimStart, item.trimEnd) = trimEditor.settingOut(newValue, start: item.trimStart)
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
            controller.beginScrubbing()
        } else {
            activeTrimGestures = max(activeTrimGestures - 1, 0)
            if activeTrimGestures == 0 { controller.endScrubbing() }
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
            // I: Set trim start to current playback position. An in-point past the out-point
            // clears the out-point. Uses currentPlaybackTime so it works during preparation;
            // MPV reports times between frames, so snap to the nearest one.
            let editor = trimEditor
            (item.trimStart, item.trimEnd) = editor.settingIn(editor.snap(currentPlaybackTime), end: item.trimEnd)
        }
    }

    private func handleTrimOutPoint(clearToEnd: Bool) {
        if clearToEnd {
            // Option+O: Clear trim end (set to end of video)
            item.trimEnd = nil
        } else {
            // O: Set trim end to current playback position. An out-point before the in-point
            // clears the in-point.
            let editor = trimEditor
            (item.trimStart, item.trimEnd) = editor.settingOut(editor.snap(currentPlaybackTime), start: item.trimStart)
        }
    }

    // MARK: - Crop Keyboard Shortcuts

    /// Move the crop box by the given delta in normalized coordinates
    private func moveCropBox(dx: Double, dy: Double) {
        let lock = selectedCropAspectRatio
        item.updateCrop { config, editor in
            config.normalizedRect = editor.moved(config.normalizedRect, by: CGSize(width: dx, height: dy))
            config.aspectRatioLock = lock == .free ? nil : lock
        }
    }

    /// Select a crop aspect ratio preset via keyboard shortcut
    private func selectCropAspectRatio(_ newRatio: AspectRatio) {
        selectedCropAspectRatio = newRatio
        item.updateCrop { config, editor in config.lockAspectRatio(newRatio, using: editor) }
    }

    /// Reset crop to full frame
    private func resetCrop() {
        item.cropConfig = nil
        selectedCropAspectRatio = .free
    }

    /// Scale the crop box around its center, keeping a locked aspect ratio
    private func scaleCropBox(factor: Double) {
        let lock = selectedCropAspectRatio
        item.updateCrop { config, editor in
            config.normalizedRect = editor.scaled(config.normalizedRect, by: factor, aspectRatio: lock.numericRatio)
            config.aspectRatioLock = lock == .free ? nil : lock
        }
    }

    private func handleKeyCommand(key: String, modifiers: NSEvent.ModifierFlags, specialKey: NSEvent.SpecialKey? = nil) -> Bool {
        // Native field editors own selection, cursor movement, and typed text.
        // Let AppKit deliver these events instead of treating them as playback commands.
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSTextView || responder is NSTextField {
            return false
        }

        // Number keys, +, -, ., : and ; start timecode input (only without modifiers and not already editing)
        let noModifiers = modifiers.intersection([.command, .option, .control, .shift]).isEmpty
        if noModifiers && !isEditingTimecode && specialKey == nil
            && key.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789+-.:;")) != nil {
            timecodeActivationTrigger = key
            return true
        }

        guard let binding = ShortcutBinding.pressed(characters: key, modifierFlags: modifiers, specialKey: specialKey) else { return false }
        if let command = ShortcutRegistry.shared.command(for: binding, in: .trim), perform(command) { return true }
        // Arrows and Space with modifiers that do nothing here (such as ⌘→ while the crop
        // controls are closed, or ⇧→) run what the bare key runs, as they always have.
        guard !binding.modifiers.isEmpty, ["left", "right", "up", "down", "space"].contains(binding.key),
              let command = ShortcutRegistry.shared.command(for: ShortcutBinding(key: binding.key), in: .trim) else { return false }
        return perform(command)
    }

    /// Runs a trim-view command, returning false when it does not apply right now.
    private func perform(_ command: ShortcutCommand) -> Bool {
        if command.category == .crop && command != .trimToggleCrop && !isCropControlsExpanded { return false }
        if let ratio = command.cropAspectRatio {
            selectCropAspectRatio(ratio)
            return true
        }
        switch command {
        case .trimTogglePlayback: controller.togglePlayback()
        case .trimPlayReverse: controller.startReverseSimulation()
        case .trimPlayForward: controller.fastForward()
        case .trimSlowReverse: controller.slowReverse()
        case .trimSlowForward: controller.slowForward()
        case .trimToggleLoop: item.loopPlayback.toggle()
        case .trimPreviousFrame: controller.seekByFrames(-1)
        case .trimNextFrame: controller.seekByFrames(1)
        case .trimBackTenFrames: controller.seekByFrames(-10)
        case .trimForwardTenFrames: controller.seekByFrames(10)
        case .trimSetIn: handleTrimInPoint(clearToStart: false)
        case .trimSetOut: handleTrimOutPoint(clearToEnd: false)
        case .trimClearIn: handleTrimInPoint(clearToStart: true)
        case .trimClearOut: handleTrimOutPoint(clearToEnd: true)
        case .trimClearBoth: resetTrim()
        case .trimGoToIn: controller.seekTo(item.effectiveTrimStart)
        case .trimGoToOut: controller.seekTo(item.effectiveTrimEnd)
        case .trimToggleTimecodeMode:
            guard !isEditingTimecode else { return false }
            timecodeDisplayMode.toggle()
        case .trimToggleAudioMeter: controller.isAudioMeterEnabled.toggle()
        case .trimCaptureScreenshot: captureScreenshot()
        case .trimOpenFullscreen: openFullscreenPlayer()
        case .trimToggleCrop:
            isCropControlsExpanded.toggle()
            // Sync crop overlay with controls state
            controller.isCropEnabled = isCropControlsExpanded
        case .trimResetCrop: resetCrop()
        case .trimCropLarger: scaleCropBox(factor: 1.05)
        case .trimCropSmaller: scaleCropBox(factor: 0.95)
        case .trimMoveCropLeft: moveCropBox(dx: -0.01, dy: 0)
        case .trimMoveCropRight: moveCropBox(dx: 0.01, dy: 0)
        case .trimMoveCropUp: moveCropBox(dx: 0, dy: -0.01)
        case .trimMoveCropDown: moveCropBox(dx: 0, dy: 0.01)
        default: return false
        }
        return true
    }
}
