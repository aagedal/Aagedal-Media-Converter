// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// SwiftUI subview containing trim timeline and related controls used in PreviewPlayerView.

import SwiftUI

struct PreviewTrimControls: View {
    @Binding var item: VideoItem
    @ObservedObject var controller: PreviewPlayerController
    @Binding var currentPlaybackTime: Double
    @Binding var isCropControlsExpanded: Bool
    @Binding var selectedCropAspectRatio: AspectRatio
    let onSeek: (Double) -> Void
    let onReset: () -> Void
    let onCaptureScreenshot: () -> Void
    let trimStartBinding: Binding<Double>
    let trimEndBinding: Binding<Double>
    let onTrimEditingChanged: (Bool) -> Void
    let loopBinding: Binding<Bool>
    @Binding var timecodeActivationTrigger: String?
    @Binding var isEditingTimecode: Bool
    @Binding var timecodeDisplayMode: TimecodeDisplayMode

    @State private var timecodeInput = ""
    @State private var justActivated = false
    @State private var pendingCharacter: String?
    @State private var showChapters: Bool = true
    /// Display-only waveform enlargement, as a gain factor.
    @AppStorage("trimWaveformVisualScale") private var waveformVisualScale: Double = 4
    @AppStorage("trimWaveformLogScale") private var waveformLogScale = false
    @AppStorage(AppConstants.loudnessNormalizationEnabledKey) private var loudnessNormalizationByDefault = false
    /// The volume line's level while it is being dragged, before it is committed.
    @State private var draggedVolumeLine: Double?
    @FocusState private var isTimecodeFocused: Bool

    var body: some View {
        // Use controller's effectiveDuration which falls back to player duration if metadata isn't loaded yet
        let duration = controller.effectiveDuration
        let isCompactMode = isCropControlsExpanded
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                // Minimize trim timeline when crop controls are expanded
                TrimTimelineView(
                    trimStart: trimStartBinding,
                    trimEnd: trimEndBinding,
                    duration: duration,
                    playbackTime: currentPlaybackTime,
                    thumbnails: controller.previewAssets?.thumbnails,
                    waveformEnvelope: controller.currentWaveformEnvelope,
                    channelWaveformEnvelopes: controller.currentChannelWaveformEnvelopes,
                    waveformVisualScale: volumeLine.map { line in
                        line.isEnabled ? WaveformVolumeLine.gain(for: line.decibels) : 1
                    } ?? waveformVisualScale,
                    waveformAmplitudeScale: waveformLogScale ? .logarithmic : .linear,
                    marksWaveformClipping: volumeLine?.appliesToExport == true,
                    volumeLine: volumeLine,
                    onVolumeLineChange: volumeLineChanged,
                    channelWaveformLabels: controller.currentChannelWaveformLabels,
                    waveformURL: controller.currentWaveformURL,
                    waveformChunks: controller.currentWaveformChunks,
                    chunkTotalDuration: controller.totalDuration,
                    chapters: controller.currentChapters,
                    showChapters: showChapters,
                    isLoading: controller.isLoadingPreviewAssets || controller.isGeneratingChannelWaveform,
                    // Handles and range drags snap to frames.
                    step: TrimEditor(duration: duration, frameRate: item.trimFrameRate).step,
                    hideFilmstrip: false,
                    compactMode: isCompactMode,
                    onEditingChanged: onTrimEditingChanged,
                    onSeek: onSeek
                )
                .onReceive(controller.playbackTimePublisher) { time in
                    currentPlaybackTime = time
                }

                if !isCompactMode {
                    controlButtons
                    if hasWaveform {
                        waveformControls
                    }
                }
            }

            // Crop controls
            if item.hasVideoStream {
                CropControlsView(
                    item: $item,
                    controller: controller,
                    isExpanded: $isCropControlsExpanded,
                    selectedAspectRatio: $selectedCropAspectRatio
                )
            }
        }
        .onChange(of: timecodeActivationTrigger) { _, newValue in
            if let initialChar = newValue {
                startTimecodeEdit(withInitialText: initialChar)
                // Clear the trigger
                timecodeActivationTrigger = nil
            }
        }
    }

    private var hasWaveform: Bool {
        controller.currentWaveformEnvelope != nil || !controller.currentChannelWaveformEnvelopes.isEmpty
    }

    /// Loudness normalization re-targets the export level, which would undo a volume change.
    private var loudnessOverridesVolume: Bool {
        switch item.adjustments?.loudness ?? .useDefault {
        case .on: return true
        case .off: return false
        case .useDefault: return loudnessNormalizationByDefault
        }
    }

    private var volumeLine: WaveformVolumeLine? {
        guard hasWaveform else { return nil }
        if let gain = item.adjustments?.audioGain {
            return WaveformVolumeLine(decibels: draggedVolumeLine ?? gain, range: MediaAdjustments.audioGainRange,
                                      appliesToExport: true, isEnabled: !loudnessOverridesVolume)
        }
        let displayed = WaveformVolumeLine.decibels(forGain: waveformVisualScale)
        return WaveformVolumeLine(
            decibels: draggedVolumeLine ?? min(max(displayed, WaveformVolumeLine.displayRange.lowerBound),
                                               WaveformVolumeLine.displayRange.upperBound),
            range: WaveformVolumeLine.displayRange, appliesToExport: false)
    }

    /// Drags update the waveform live; the item or display setting changes once, at the end.
    private func volumeLineChanged(_ decibels: Double, isFinal: Bool) {
        guard isFinal else {
            draggedVolumeLine = decibels
            return
        }
        draggedVolumeLine = nil
        if item.adjustments?.audioGain != nil {
            setExportVolume(decibels)
        } else {
            waveformVisualScale = WaveformVolumeLine.gain(for: decibels)
        }
    }

    private func setExportVolume(_ decibels: Double?) {
        var adjustments = item.adjustments ?? MediaAdjustments()
        adjustments.audioGain = decibels
        item.adjustments = adjustments.isActive ? adjustments : nil
    }

    private var waveformControls: some View {
        HStack(spacing: 12) {
            Toggle("Apply volume to export", isOn: Binding(
                get: { item.adjustments?.audioGain != nil },
                set: { setExportVolume($0 ? 0 : nil) }
            ))
            .disabled(item.adjustments?.audioGain == nil && loudnessOverridesVolume)
            .accessibilityIdentifier("trim.volumeToExport")
            .help(loudnessOverridesVolume
                  ? Text("Loudness normalization sets this item's export level, so a volume change would have no effect. Turn it off for this item under Adjustments to use the volume line.")
                  : Text("When on, dragging the line over the waveform changes this item's export volume, and peaks that would clip are marked in yellow. When off, the line only enlarges the waveform. Double-click the line to reset it."))

            Toggle("Log scale", isOn: $waveformLogScale)
                .accessibilityIdentifier("trim.waveformLogScale")
                .help("Show the waveform in decibels, so quiet passages stay visible. Playback and export are unchanged.")
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
    }

    private var controlButtons: some View {
        HStack(spacing: 12) {
            Button(action: { controller.seekTo(item.effectiveTrimStart) }) {
                Label("\(formatTimecodeWithMode(seconds: item.effectiveTrimStart))", systemImage: "arrow.left.to.line")
            }
            .buttonStyle(.plain)
            .font(.system(.subheadline, design: .monospaced))
            .foregroundColor(.accentColor)
            .help("Jump to trim start")
            .accessibilityLabel("Jump to trim start")
            .accessibilityValue(formatTimecodeWithMode(seconds: item.effectiveTrimStart))
            .accessibilityIdentifier("trim.jumpToStart")
            .padding(.trailing, 15)
            
            // Current playback time - editable on double click
            if isEditingTimecode {
                HStack(spacing: 4) {
                    timecodeModePrefix
                    TextField("5.1, +10, or ..15", text: $timecodeInput)
                        .textFieldStyle(.plain)
                        .font(.system(.subheadline, design: .monospaced))
                        .focused($isTimecodeFocused)
                        .accessibilityLabel("Playback timecode")
                        .accessibilityIdentifier("trim.timecodeInput")
                        .onSubmit {
                            seekToTimecode()
                        }
                        .onExitCommand {
                            cancelTimecodeEdit()
                        }
                }
                .padding(.horizontal, 15)
            } else {
                HStack(spacing: 4) {
                    timecodeModePrefix
                    Button(action: startTimecodeEdit) {
                        Label("\(formatTimecodeWithMode(seconds: currentPlaybackTime))", systemImage: "arrowtriangle.left.and.line.vertical.and.arrowtriangle.right")
                            .font(.system(.subheadline, design: .monospaced))
                            .frame(width: 120, alignment: .leading)
                            .padding(.trailing, 25)
                    }
                    .buttonStyle(.plain)
                    .help("Edit playback timecode")
                    .accessibilityLabel("Playback timecode")
                    .accessibilityValue(formatTimecodeWithMode(seconds: currentPlaybackTime))
                    .accessibilityIdentifier("trim.timecode")
                }
            }

            Button(action: { controller.seekTo(item.effectiveTrimEnd) }) {
                Label("\(formatTimecodeWithMode(seconds: item.effectiveTrimEnd))", systemImage: "arrow.right.to.line")
                    .labelStyle(.trailingIcon)
            }
            .buttonStyle(.plain)
            .font(.system(.subheadline, design: .monospaced))
            .foregroundColor(.accentColor)
            .help("Jump to trim end")
            .accessibilityLabel("Jump to trim end")
            .accessibilityValue(formatTimecodeWithMode(seconds: item.effectiveTrimEnd))
            .accessibilityIdentifier("trim.jumpToEnd")

            // Frame rate picker for image sequences
            if item.isImageSequence, item.imageSequenceConfig != nil {
                imageSequenceFrameRatePicker
            }

            Spacer()
            
            HStack(spacing: 10) {
                Button(action: onCaptureScreenshot) {
                    Label("Capture frame", systemImage: "camera")
                        .labelStyle(.iconOnly)
                }
                .accessibilityIdentifier("trim.captureFrame")
                .disabled(controller.isCapturingScreenshot || !item.hasVideoStream)
                .help(item.hasVideoStream ? "Save the current frame as an image" : "Screenshot capture is unavailable for audio-only clips")

                Button {
                    controller.revealLastScreenshotInFinder()
                } label: {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .help("Reveal last screenshot in Finder")
                        .foregroundColor(controller.lastScreenshotURL == nil ? .gray : .blue)
                }
                .accessibilityLabel("Reveal last screenshot in Finder")
                .accessibilityIdentifier("trim.revealScreenshot")
                .disabled(controller.lastScreenshotURL == nil ? true : false)

                // Draggable icon for last screenshot
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .help("Drag last screenshot to another app")
                    .foregroundColor(controller.lastScreenshotURL == nil ? .gray : .blue)
                    .opacity(controller.lastScreenshotURL == nil ? 0.5 : 1)
                    .onDrag {
                        controller.lastScreenshotDragItemProvider() ?? NSItemProvider()
                    }
                    .disabled(controller.lastScreenshotURL == nil ? true : false)
            }
            .padding(.trailing, 16)

            // Crop toggle button
            if item.hasVideoStream {
                HStack(spacing: 10) {
                    Button(action: {
                        isCropControlsExpanded.toggle()
                        // Auto-enable crop overlay when expanding controls
                        controller.isCropEnabled = isCropControlsExpanded
                    }) {
                        Label("Crop", systemImage: "crop")
                            .labelStyle(.iconOnly)
                            .foregroundColor(isCropControlsExpanded ? .accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                    .help("Toggle crop controls (C)")
                    .accessibilityLabel("Crop controls")
                    .accessibilityValue(isCropControlsExpanded ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("trim.cropControls")

                    if let config = item.cropConfig, config.isActive {
                        Text("\(Int(config.normalizedRect.width * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.trailing, 30)
            }

            audioTrackSelector
            subtitleTrackSelector

            if !controller.currentChapters.isEmpty {
                Toggle(isOn: $showChapters) {
                    Label("Chapters", systemImage: "list.bullet.indent")
                        .labelStyle(.iconOnly)
                }
                .toggleStyle(.button)
                .accessibilityIdentifier("trim.showChapters")
                .help(showChapters
                      ? "Hide chapter markers (\(controller.currentChapters.count))"
                      : "Show chapter markers (\(controller.currentChapters.count))")
            }

            Toggle(isOn: $controller.isAudioMeterEnabled) {
                Label("Audio Meter", systemImage: "waveform")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .help("Show/hide audio level meter")
            .accessibilityIdentifier("trim.audioMeter")

            Toggle(isOn: loopBinding) {
                Label("Loop", systemImage: "repeat")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .disabled(isLoopDisabled)
            .help(loopButtonTooltip)
            .accessibilityIdentifier("trim.loop")

            Button(action: onReset) {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .labelStyle(.iconOnly)
            }
            .disabled(item.trimStart == nil && item.trimEnd == nil)
            .help("Reset trim points")
            .accessibilityLabel("Reset trim points")
            .accessibilityIdentifier("trim.reset")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private static let commonFrameRates: [Double] = [
        12, 15, 23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60
    ]

    private var imageSequenceFrameRatePicker: some View {
        HStack(spacing: 4) {
            Image(systemName: "speedometer")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Menu {
                ForEach(Self.commonFrameRates, id: \.self) { rate in
                    Button {
                        updateImageSequenceFrameRate(rate)
                    } label: {
                        HStack {
                            Text(formatFrameRate(rate))
                            if let config = item.imageSequenceConfig, abs(config.frameRate - rate) < 0.01 {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text("\(formatFrameRate(item.imageSequenceConfig?.frameRate ?? 24)) fps")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Image sequence frame rate")
            .accessibilityValue("\(formatFrameRate(item.imageSequenceConfig?.frameRate ?? 24)) fps")
            .accessibilityIdentifier("trim.imageSequenceFrameRate")
            .fixedSize()
        }
        .padding(.leading, 12)
        .help("Set the playback frame rate for this image sequence")
    }

    private func formatFrameRate(_ rate: Double) -> String {
        if rate == rate.rounded() {
            return String(format: "%.0f", rate)
        }
        return String(format: "%.3f", rate)
    }

    private func updateImageSequenceFrameRate(_ newRate: Double) {
        guard var config = item.imageSequenceConfig else { return }
        config.frameRate = newRate
        item.imageSequenceConfig = config
        // Recalculate duration from new frame rate
        item.durationSeconds = config.durationSeconds
        item.duration = VideoFileUtils.formatDuration(seconds: config.durationSeconds)
        // Restart the preview with the updated config
        controller.updateImageSequenceFrameRate(config)
    }

    private var audioTrackSelector: some View {
        Menu {
            if controller.audioTrackOptions.isEmpty {
                Text("No alternate audio tracks")
            } else {
                ForEach(controller.audioTrackOptions) { option in
                    Button {
                        controller.selectAudioTrack(at: option.position)
                    } label: {
                        HStack {
                            Text(option.title)
                            if let subtitle = option.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if option.position == controller.selectedAudioTrackOrderIndex {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(option.position == controller.selectedAudioTrackOrderIndex)
                }
            }
        } label: {
            Label("Select audio track", systemImage: "speaker.wave.2.fill")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .accessibilityValue(controller.audioTrackOptions.first(where: {
            $0.position == controller.selectedAudioTrackOrderIndex
        })?.title ?? String(localized: "No alternate audio tracks"))
        .accessibilityIdentifier("trim.audioTrack")
        .disabled(controller.audioTrackOptions.count <= 1)
        .help(controller.audioTrackOptions.isEmpty ? "No alternate audio tracks" : "Select audio track")
    }

    private var subtitleTrackSelector: some View {
        Menu {
            // "Off" option to disable subtitles
            Button {
                controller.selectSubtitleTrack(at: -1)
            } label: {
                HStack {
                    Text("Off")
                    Spacer()
                    if controller.selectedSubtitleTrackOrderIndex < 0 {
                        Image(systemName: "checkmark")
                    }
                }
            }

            if !controller.subtitleTrackOptions.isEmpty {
                Divider()

                ForEach(controller.subtitleTrackOptions) { option in
                    Button {
                        controller.selectSubtitleTrack(at: option.position)
                    } label: {
                        HStack {
                            Text(option.title)
                            Spacer()
                            if option.position == controller.selectedSubtitleTrackOrderIndex {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Label("Select subtitle track", systemImage: "captions.bubble.fill")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .accessibilityValue(controller.subtitleTrackOptions.first(where: {
            $0.position == controller.selectedSubtitleTrackOrderIndex
        })?.title ?? String(localized: "Off"))
        .accessibilityIdentifier("trim.subtitleTrack")
        .disabled(controller.subtitleTrackOptions.isEmpty)
        .help(controller.subtitleTrackOptions.isEmpty ? "No subtitle tracks" : "Select subtitle track")
    }

    // MARK: - Timecode Input Helpers

    private func startTimecodeEdit() {
        timecodeInput = formatTimecodeWithMode(seconds: currentPlaybackTime)
        withAnimation(.easeInOut(duration: 0.15)) {
            isEditingTimecode = true
        }
        isTimecodeFocused = true
    }

    private func startTimecodeEdit(withInitialText text: String) {
        // Start with empty field to avoid auto-selection issues
        timecodeInput = ""
        pendingCharacter = text
        justActivated = true

        withAnimation(.easeInOut(duration: 0.15)) {
            isEditingTimecode = true
        }

        // Focus the field first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isTimecodeFocused = true

            // Then append the initial character after focus is established
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let char = pendingCharacter {
                    timecodeInput = char
                    pendingCharacter = nil
                    justActivated = false
                }
            }
        }
    }

    private func cancelTimecodeEdit() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isEditingTimecode = false
        }
        isTimecodeFocused = false
        timecodeInput = ""
        justActivated = false
        pendingCharacter = nil
    }

    private func seekToTimecode() {
        // Clear any pending character state
        justActivated = false
        pendingCharacter = nil

        guard let seekTime = parseTimecodeToSeconds(timecodeInput) else {
            // Invalid timecode, just cancel
            cancelTimecodeEdit()
            return
        }

        // Clamp to valid range
        let duration = max(item.durationSeconds, 0)
        let clampedTime = max(0, min(seekTime, duration))

        // Seek to the position
        onSeek(clampedTime)

        // Exit edit mode
        cancelTimecodeEdit()
    }

    private func parseTimecodeToSeconds(_ timecode: String) -> Double? {
        let trimmed = timecode.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let frameRate = TimecodeFormatter.effectiveFrameRate(for: item)
        let fps = Int(frameRate.rounded())
        
        // Frames mode:
        // - "+/-N" moves relatively by N frames
        // - "N" jumps to absolute frame N
        if timecodeDisplayMode == .frames {
            if trimmed.hasPrefix("+") || trimmed.hasPrefix("-") {
                let isPositive = trimmed.hasPrefix("+")
                if let frameOffset = Int(String(trimmed.dropFirst())), frameOffset >= 0 {
                    let offsetSeconds = Double(frameOffset) / frameRate
                    return isPositive ? currentPlaybackTime + offsetSeconds : currentPlaybackTime - offsetSeconds
                }
            }

            if let frameNumber = Int(trimmed), frameNumber >= 0 {
                return Double(frameNumber) / frameRate
            }
        }

        // Check for frame-only navigation (..<number>)
        if trimmed.hasPrefix("..") {
            let frameString = String(trimmed.dropFirst(2))
            guard let frames = Int(frameString), frames >= 0, frames < fps else {
                return nil
            }

            // Set to specific frame at current second
            let currentSeconds = floor(currentPlaybackTime)
            let newTime = currentSeconds + (Double(frames) / frameRate)

            // Clamp to valid range
            let duration = max(item.durationSeconds, 0)
            return max(0, min(newTime, duration))
        }

        // Check for relative frame seeking (+..<number> or -..<number>)
        if trimmed.hasPrefix("+..") || trimmed.hasPrefix("-..") {
            let isPositive = trimmed.hasPrefix("+")
            let frameString = String(trimmed.dropFirst(3))

            guard let frames = Int(frameString), frames >= 0 else {
                return nil
            }

            let frameOffset = Double(frames) / frameRate
            let newTime = isPositive ? currentPlaybackTime + frameOffset : currentPlaybackTime - frameOffset

            // Clamp to valid range
            let duration = max(item.durationSeconds, 0)
            return max(0, min(newTime, duration))
        }

        // Check for relative seeking (+/-)
        if trimmed.hasPrefix("+") || trimmed.hasPrefix("-") {
            let isPositive = trimmed.hasPrefix("+")
            let offsetString = String(trimmed.dropFirst())

            guard let offsetSeconds = parseTimecodeOffset(offsetString, frameRate: frameRate, fps: fps) else {
                return nil
            }

            let newTime = isPositive ? currentPlaybackTime + offsetSeconds : currentPlaybackTime - offsetSeconds

            // Clamp to valid range
            let duration = max(item.durationSeconds, 0)
            return max(0, min(newTime, duration))
        }

        // Parse absolute timecode (full or shorthand)
        return parseAbsoluteTimecode(trimmed, frameRate: frameRate, fps: fps)
    }

    private func parseTimecodeOffset(_ input: String, frameRate: Double, fps: Int) -> Double? {
        // Split by : ; or . separators
        let components = input.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." })

        guard !components.isEmpty, components.count <= 4 else { return nil }

        var hours = 0
        var minutes = 0
        var seconds = 0
        var frames = 0

        switch components.count {
        case 1:
            // Just seconds
            guard let value = Int(components[0]) else { return nil }
            seconds = value
        case 2:
            // MM.SS or SS.FF
            guard let first = Int(components[0]),
                  let second = Int(components[1]) else { return nil }
            if first < 60 && second < 60 {
                // Treat as MM.SS
                minutes = first
                seconds = second
            } else {
                // Treat as SS.FF
                seconds = first
                frames = second
            }
        case 3:
            // HH.MM.SS
            guard let h = Int(components[0]),
                  let m = Int(components[1]),
                  let s = Int(components[2]) else { return nil }
            hours = h
            minutes = m
            seconds = s
        case 4:
            // HH:MM:SS:FF
            guard let h = Int(components[0]),
                  let m = Int(components[1]),
                  let s = Int(components[2]),
                  let f = Int(components[3]) else { return nil }
            hours = h
            minutes = m
            seconds = s
            frames = f
        default:
            return nil
        }

        // Convert to seconds
        let totalSeconds = Double(hours * 3600 + minutes * 60 + seconds)
        let frameSeconds = Double(frames) / frameRate
        return totalSeconds + frameSeconds
    }

    private func parseAbsoluteTimecode(_ input: String, frameRate: Double, fps: Int) -> Double? {
        // Split by : ; or . separators
        let components = input.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." })

        guard !components.isEmpty, components.count <= 4 else { return nil }

        var hours = 0
        var minutes = 0
        var seconds = 0
        var frames = 0

        // Parse components based on count
        switch components.count {
        case 1:
            // Just seconds
            guard let s = Int(components[0]) else { return nil }
            seconds = s
        case 2:
            // MM.SS
            guard let m = Int(components[0]),
                  let s = Int(components[1]) else { return nil }
            minutes = m
            seconds = s
        case 3:
            // HH.MM.SS
            guard let h = Int(components[0]),
                  let m = Int(components[1]),
                  let s = Int(components[2]) else { return nil }
            hours = h
            minutes = m
            seconds = s
        case 4:
            // HH:MM:SS:FF (full timecode)
            guard let h = Int(components[0]),
                  let m = Int(components[1]),
                  let s = Int(components[2]),
                  let f = Int(components[3]) else { return nil }
            hours = h
            minutes = m
            seconds = s
            frames = f
        default:
            return nil
        }

        // Validate ranges
        guard hours >= 0, hours < 24,
              minutes >= 0, minutes < 60,
              seconds >= 0, seconds < 60,
              frames >= 0, frames < fps else {
            return nil
        }

        // Get the starting timecode based on current display mode
        // In source mode, use the source timecode; in relative mode, treat as absolute from 00:00:00:00
        let startTC: String? = (timecodeDisplayMode == .source) ? TimecodeFormatter.effectiveStartTimecode(for: item) : nil

        // If we have a start timecode (source mode with valid TC), we need to convert the input timecode to a position relative to it
        if let startTC = startTC {
            // Parse start timecode
            let startComponents = startTC.split(whereSeparator: { $0 == ":" || $0 == ";" })
            guard startComponents.count == 4,
                  let startHours = Int(startComponents[0]),
                  let startMinutes = Int(startComponents[1]),
                  let startSeconds = Int(startComponents[2]),
                  let startFrames = Int(startComponents[3]) else {
                return nil
            }

            // Convert both to frames
            var inputTotalFrames = hours * 3600 * fps
            inputTotalFrames += minutes * 60 * fps
            inputTotalFrames += seconds * fps
            inputTotalFrames += frames

            var startTotalFrames = startHours * 3600 * fps
            startTotalFrames += startMinutes * 60 * fps
            startTotalFrames += startSeconds * fps
            startTotalFrames += startFrames

            // Calculate the difference in frames
            let frameOffset = inputTotalFrames - startTotalFrames

            // Convert to seconds
            return Double(frameOffset) / frameRate
        } else {
            // No start timecode, treat input as absolute time from 00:00:00:00
            let totalSeconds = Double(hours * 3600 + minutes * 60 + seconds)
            let frameSeconds = Double(frames) / frameRate
            return totalSeconds + frameSeconds
        }
    }

    // MARK: - Helper Properties

    private var isLoopDisabled: Bool {
        false
    }

    private var loopButtonTooltip: String {
        "Loop playback (⌘L)"
    }
    
    // MARK: - Timecode Formatting with Mode
    
    private func formatTimecodeWithMode(seconds: Double, isOutPoint: Bool = false, isDuration: Bool = false) -> String {
        return TimecodeFormatter.formatTimeForDisplayWithMode(
            seconds: seconds,
            item: item,
            mode: timecodeDisplayMode,
            isOutPoint: isOutPoint,
            isDuration: isDuration
        )
    }
    
    private var timecodeModePrefix: some View {
        Button {
            timecodeDisplayMode.toggle()
        } label: {
            Text(timecodeDisplayMode.prefix)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cycle timecode mode")
        .accessibilityValue(Text(LocalizedStringKey(timecodeDisplayMode.displayName)))
        .accessibilityIdentifier("trim.timecodeMode")
        .help("Click or press T to cycle: REL TC → SRC TC → FRM")
        .frame(width: 40)
    }
}
