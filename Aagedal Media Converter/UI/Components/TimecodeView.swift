// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI

struct TimecodeView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var item: VideoItem

    @State private var selectedMode: TimecodeMode = .preserveSource
    @State private var manualTimecode: String = "00:00:00:00"
    @State private var isValidTimecode: Bool = true
    @FocusState private var isTextFieldFocused: Bool

    private enum TimecodeMode: String, CaseIterable, Identifiable {
        case preserveSource = "Preserve Source"
        case manual = "Manual Override"
        case disabled = "Disable"

        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .preserveSource: "Preserve Source"
            case .manual: "Manual Override"
            case .disabled: "Disable"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Timecode Configuration")
                        .font(.title)
                        .fontWeight(.semibold)
                    Text(item.name)
                        .font(.headline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button {
                    autoCorrectTimecode()
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.secondary.opacity(0.7), .secondary.opacity(0.25))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close timecode configuration")
                .keyboardShortcut(.escape, modifiers: [])
            }

            // Content
            VStack(alignment: .leading, spacing: 16) {
                // Mode picker
                Picker("Timecode Mode", selection: $selectedMode) {
                    ForEach(TimecodeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedMode) { _, newMode in
                    updateTimecodeConfig()
                }

                Divider()

                // Disabled mode info
                if selectedMode == .disabled {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundColor(.blue)
                            Text("No timecode will be written to the output file.")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                    .cornerRadius(10)
                }

                // Source timecode info
                if selectedMode == .preserveSource {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundColor(.blue)
                            Text("The timecode from the source file will be copied to the output.")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }

                        if let sourceTimecode = item.metadata?.timecode {
                            HStack {
                                Text("Source Timecode:")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(sourceTimecode)
                                    .font(.system(.subheadline, design: .monospaced))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor.opacity(0.15))
                                    .foregroundColor(.accentColor)
                                    .cornerRadius(6)
                            }
                        } else {
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundColor(.orange)
                                Text("No timecode found in source file.")
                                    .font(.callout)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                    .cornerRadius(10)
                }

                // Manual timecode input
                if selectedMode == .manual {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "info.circle")
                                .foregroundColor(.blue)
                            Text("Enter a custom start timecode for the output file.")
                                .font(.callout)
                                .foregroundColor(.secondary)
                        }

                        // Show source timecode for reference
                        if let sourceTimecode = item.metadata?.timecode {
                            HStack {
                                Text("Source Timecode:")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(sourceTimecode)
                                    .font(.system(.subheadline, design: .monospaced))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.secondary.opacity(0.15))
                                    .foregroundColor(.secondary)
                                    .cornerRadius(6)
                                Button(action: {
                                    manualTimecode = sourceTimecode
                                    autoCorrectTimecode()
                                }) {
                                    Label("Copy", systemImage: "doc.on.doc")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.accentColor)
                                .help("Copy source timecode")
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Output Timecode")
                                .font(.subheadline.weight(.semibold))

                            HStack(spacing: 6) {
                                // Subtract buttons
                                Button(action: { adjustFrames(by: -10) }) {
                                    Text("-10")
                                        .font(.caption)
                                        .frame(minWidth: 32)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Subtract 10 frames")

                                Button(action: { adjustFrames(by: -1) }) {
                                    Text("-1")
                                        .font(.caption)
                                        .frame(minWidth: 32)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Subtract 1 frame")

                                // Timecode input field
                                TextField("00:00:00:00", text: $manualTimecode)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                    .focused($isTextFieldFocused)
                                    .onChange(of: manualTimecode) { _, newValue in
                                        let sanitized = sanitizeTimecode(newValue)
                                        if sanitized != newValue {
                                            manualTimecode = sanitized
                                        }
                                        isValidTimecode = validateTimecode(sanitized)
                                        updateTimecodeConfig()
                                    }
                                    .onChange(of: isTextFieldFocused) { _, isFocused in
                                        // Auto-correct when losing focus
                                        if !isFocused {
                                            autoCorrectTimecode()
                                        }
                                    }
                                    .onSubmit {
                                        // Auto-correct when user presses Enter
                                        autoCorrectTimecode()
                                    }

                                // Add buttons
                                Button(action: { adjustFrames(by: 1) }) {
                                    Text("+1")
                                        .font(.caption)
                                        .frame(minWidth: 32)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Add 1 frame")

                                Button(action: { adjustFrames(by: 10) }) {
                                    Text("+10")
                                        .font(.caption)
                                        .frame(minWidth: 32)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help("Add 10 frames")
                            }

                            if !isValidTimecode {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                        .font(.caption)
                                    Text(validationErrorMessage())
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            } else {
                                let maxFrames = getMaxFramesFromMetadata()
                                Text("Format: HH:MM:SS:FF (hours: 00-23, frames: 00-\(String(format: "%02d", maxFrames - 1))) or HH:MM:SS;FF for drop-frame")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                    .cornerRadius(10)
                }

                Spacer()
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 300, idealHeight: 400)
        .onAppear {
            initializeFromConfig()
            // Validate on appear
            isValidTimecode = validateTimecode(manualTimecode)
        }
        .onDisappear {
            // Auto-correct on dismiss as safety net
            autoCorrectTimecode()
        }
        // Hidden buttons for keyboard shortcuts (CMD+1, CMD+2, CMD+3)
        .background {
            Group {
                Button("") {
                    selectedMode = .preserveSource
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("") {
                    selectedMode = .manual
                    // Focus the text field when switching to manual mode
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isTextFieldFocused = true
                    }
                }
                .keyboardShortcut("2", modifiers: .command)

                Button("") {
                    selectedMode = .disabled
                }
                .keyboardShortcut("3", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        // Handle number key presses to start typing in manual mode
        .onKeyPress(characters: .decimalDigits) { press in
            if selectedMode == .manual {
                // Already in manual mode with focus - let the text field handle it
                if isTextFieldFocused {
                    return .ignored
                }
                // Focus and insert the character
                isTextFieldFocused = true
                return .ignored
            } else {
                // Switch to manual mode and focus
                selectedMode = .manual
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isTextFieldFocused = true
                }
                return .handled
            }
        }
    }

    private func initializeFromConfig() {
        if let config = item.timecodeConfig {
            switch config.mode {
            case .preserveSource:
                selectedMode = .preserveSource
            case .manual(let tc):
                selectedMode = .manual
                manualTimecode = tc
            }
        } else {
            // nil config means timecode is disabled for this item: items receive
            // the settings default when they are queued, and the encoder treats
            // nil as "write no timecode". Re-reading the settings default here
            // would silently re-enable timecode after the user chose Disable.
            let defaultValue = UserDefaults.standard.string(forKey: AppConstants.defaultTimecodeValueKey) ?? AppConstants.defaultTimecodeValue
            selectedMode = .disabled
            manualTimecode = item.metadata?.timecode ?? defaultValue
        }
    }

    private func updateTimecodeConfig() {
        switch selectedMode {
        case .preserveSource:
            item.timecodeConfig = TimecodeConfig(mode: .preserveSource)
        case .manual:
            item.timecodeConfig = TimecodeConfig(mode: .manual(manualTimecode))
        case .disabled:
            item.timecodeConfig = nil
        }
    }

    private func sanitizeTimecode(_ input: String) -> String {
        // Only allow digits, colons, and semicolons
        let allowed = CharacterSet(charactersIn: "0123456789:;")
        let filtered = input.filter { char in
            char.unicodeScalars.allSatisfy { allowed.contains($0) }
        }

        // Limit length to 11 characters (HH:MM:SS:FF or HH:MM:SS;FF)
        let truncated = String(filtered.prefix(11))

        return truncated
    }

    private func validateTimecode(_ input: String) -> Bool {
        // Valid formats: HH:MM:SS:FF or HH:MM:SS;FF
        // Regex pattern for timecode
        let pattern = "^\\d{2}:\\d{2}:\\d{2}[:;]\\d{2}$"

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }

        let range = NSRange(location: 0, length: input.utf16.count)
        let matches = regex.firstMatch(in: input, range: range)

        if matches == nil {
            return false
        }

        // Additional validation: hours, minutes, seconds, frames should be in valid ranges
        let components = input.split(whereSeparator: { $0 == ":" || $0 == ";" })
        guard components.count == 4,
              let hours = Int(components[0]),
              let minutes = Int(components[1]),
              let seconds = Int(components[2]),
              let frames = Int(components[3]) else {
            return false
        }

        // Hours: 0-23 (24-hour format)
        guard hours < 24 else { return false }

        // Minutes: 0-59
        guard minutes < 60 else { return false }

        // Seconds: 0-59
        guard seconds < 60 else { return false }

        // Frames: 0 to (frameRate - 1)
        // Get frame rate from source metadata
        let maxFrames = getMaxFramesFromMetadata()
        guard frames < maxFrames else { return false }

        // Drop-frame (;) is only valid for 29.97/59.94-style rates, and the
        // first frame numbers of most minutes do not exist in drop-frame.
        if input.contains(";") {
            guard isDropFrameAllowed(maxFrames: maxFrames) else { return false }
            if isDroppedFrameLabel(minutes: minutes, seconds: seconds, frames: frames, maxFrames: maxFrames) {
                return false
            }
        }

        return true
    }

    private func getMaxFramesFromMetadata() -> Int {
        // Get frame rate from source video metadata
        guard let frameRate = item.metadata?.primaryVideoStream?.frameRate?.value,
              frameRate.isFinite, frameRate >= 1 else {
            // Default to 30 fps if unknown (common for video)
            return 30
        }

        // Round frame rate to nearest integer
        // Most common rates: 23.976 → 24, 29.97 → 30, 59.94 → 60, etc.
        let roundedFrameRate = Int(frameRate.rounded())

        return roundedFrameRate
    }

    /// FFmpeg only accepts drop-frame timecode for multiples of 30 fps
    /// (29.97, 59.94, ...); anything else makes the encode fail.
    private func isDropFrameAllowed(maxFrames: Int) -> Bool {
        maxFrames % 30 == 0
    }

    /// Number of frame labels skipped at the start of each non-tenth minute.
    private func dropFrameCount(maxFrames: Int) -> Int {
        maxFrames / 15
    }

    private func isDroppedFrameLabel(minutes: Int, seconds: Int, frames: Int, maxFrames: Int) -> Bool {
        seconds == 0 && minutes % 10 != 0 && frames < dropFrameCount(maxFrames: maxFrames)
    }

    private func validationErrorMessage() -> String {
        // Provide specific error message based on what's wrong
        let components = manualTimecode.split(whereSeparator: { $0 == ":" || $0 == ";" })

        if components.count != 4 {
            return String(localized: "Invalid format. Use HH:MM:SS:FF or HH:MM:SS;FF")
        }

        guard let hours = Int(components[0]),
              let minutes = Int(components[1]),
              let seconds = Int(components[2]),
              let frames = Int(components[3]) else {
            return String(localized: "Invalid format. Use HH:MM:SS:FF or HH:MM:SS;FF")
        }

        if hours >= 24 {
            return String(localized: "Hours must be 00-23")
        }

        if minutes >= 60 {
            return String(localized: "Minutes must be 00-59")
        }

        if seconds >= 60 {
            return String(localized: "Seconds must be 00-59")
        }

        let maxFrames = getMaxFramesFromMetadata()
        if frames >= maxFrames {
            let lastFrame = String(format: "%02d", maxFrames - 1)
            return String(localized: "Frames must be 00-\(lastFrame) (based on \(maxFrames)fps source)")
        }

        if manualTimecode.contains(";") {
            if !isDropFrameAllowed(maxFrames: maxFrames) {
                return String(localized: "Drop-frame timecode (;) requires a 29.97 or 59.94 fps source. Use : instead.")
            }
            if isDroppedFrameLabel(minutes: minutes, seconds: seconds, frames: frames, maxFrames: maxFrames) {
                let firstFrame = String(format: "%02d", dropFrameCount(maxFrames: maxFrames))
                return String(localized: "This frame number is skipped in drop-frame timecode. The minute starts at frame \(firstFrame).")
            }
        }

        return String(localized: "Invalid timecode format")
    }

    private func autoCorrectTimecode() {
        // Only auto-correct if in manual mode
        guard selectedMode == .manual else { return }

        let components = manualTimecode.split(whereSeparator: { $0 == ":" || $0 == ";" })

        // If format is completely wrong, reset to default
        guard components.count == 4 else {
            manualTimecode = "00:00:00:00"
            isValidTimecode = true
            updateTimecodeConfig()
            return
        }

        // Parse components
        guard let hours = Int(components[0]),
              let minutes = Int(components[1]),
              let seconds = Int(components[2]),
              let frames = Int(components[3]) else {
            manualTimecode = "00:00:00:00"
            isValidTimecode = true
            updateTimecodeConfig()
            return
        }

        // Clamp each component to valid range
        let clampedHours = min(hours, 23)
        let clampedMinutes = min(minutes, 59)
        let clampedSeconds = min(seconds, 59)
        let maxFrames = getMaxFramesFromMetadata()
        var clampedFrames = min(frames, maxFrames - 1)

        // Preserve the separator (: or ;), but only keep drop-frame when the
        // source rate supports it.
        let isDropFrame = manualTimecode.contains(";") && isDropFrameAllowed(maxFrames: maxFrames)
        let separator = isDropFrame ? ";" : ":"

        // Labels skipped by drop-frame snap to the first existing frame.
        if isDropFrame,
           isDroppedFrameLabel(minutes: clampedMinutes, seconds: clampedSeconds, frames: clampedFrames, maxFrames: maxFrames) {
            clampedFrames = dropFrameCount(maxFrames: maxFrames)
        }

        // Build corrected timecode
        let corrected = String(format: "%02d:%02d:%02d%@%02d",
                              clampedHours,
                              clampedMinutes,
                              clampedSeconds,
                              separator,
                              clampedFrames)

        manualTimecode = corrected
        isValidTimecode = true
        updateTimecodeConfig()
    }

    /// Converts a timecode label to an absolute frame count, honouring drop-frame numbering.
    private func frameNumber(hours: Int, minutes: Int, seconds: Int, frames: Int,
                             maxFrames: Int, dropFrame: Bool) -> Int {
        let totalMinutes = hours * 60 + minutes
        var total = ((hours * 3600) + (minutes * 60) + seconds) * maxFrames + frames
        if dropFrame {
            total -= dropFrameCount(maxFrames: maxFrames) * (totalMinutes - totalMinutes / 10)
        }
        return total
    }

    /// Converts an absolute frame count back to timecode components, honouring drop-frame numbering.
    private func timecodeComponents(fromFrameNumber frameNumber: Int, maxFrames: Int,
                                    dropFrame: Bool) -> (hours: Int, minutes: Int, seconds: Int, frames: Int) {
        var total = frameNumber
        if dropFrame {
            let drop = dropFrameCount(maxFrames: maxFrames)
            let framesPerMinute = maxFrames * 60 - drop
            let framesPerTenMinutes = maxFrames * 600 - drop * 9
            let tens = total / framesPerTenMinutes
            let remainder = total % framesPerTenMinutes
            total += drop * 9 * tens
            if remainder > drop {
                total += drop * ((remainder - drop) / framesPerMinute)
            }
        }
        let frames = total % maxFrames
        total /= maxFrames
        let seconds = total % 60
        total /= 60
        let minutes = total % 60
        let hours = total / 60
        return (hours, minutes, seconds, frames)
    }

    private func adjustFrames(by delta: Int) {
        let components = manualTimecode.split(whereSeparator: { $0 == ":" || $0 == ";" })

        guard components.count == 4,
              let hours = Int(components[0]),
              let minutes = Int(components[1]),
              let seconds = Int(components[2]),
              let frames = Int(components[3]) else {
            return
        }

        let maxFrames = getMaxFramesFromMetadata()
        let dropFrame = manualTimecode.contains(";") && isDropFrameAllowed(maxFrames: maxFrames)

        // Convert everything to total frames
        var totalFrames = frameNumber(hours: hours, minutes: minutes, seconds: seconds, frames: frames,
                                      maxFrames: maxFrames, dropFrame: dropFrame)

        // Add delta
        totalFrames += delta

        // Clamp to 00:00:00:00 ... 23:59:59:FF
        let lastFrame = frameNumber(hours: 23, minutes: 59, seconds: 59, frames: maxFrames - 1,
                                    maxFrames: maxFrames, dropFrame: dropFrame)
        totalFrames = min(max(0, totalFrames), lastFrame)

        // Convert back to timecode components
        let new = timecodeComponents(fromFrameNumber: totalFrames, maxFrames: maxFrames, dropFrame: dropFrame)

        // Preserve the separator (: or ;)
        let separator = dropFrame ? ";" : ":"

        // Build new timecode
        manualTimecode = String(format: "%02d:%02d:%02d%@%02d",
                                new.hours,
                                new.minutes,
                                new.seconds,
                                separator,
                                new.frames)

        isValidTimecode = true
        updateTimecodeConfig()
    }
}
