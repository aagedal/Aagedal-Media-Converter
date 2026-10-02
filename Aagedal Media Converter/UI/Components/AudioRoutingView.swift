// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI

struct AudioRoutingView: View {
    @Binding var item: VideoItem
    let preset: ExportPreset
    @Environment(\.dismiss) private var dismiss
    
    @State private var validationMessages: [String] = []
    
    // Computed property for config binding with instant updates
    private var configBinding: Binding<AudioRoutingConfig> {
        Binding(
            get: {
                if let config = item.audioRoutingConfig {
                    return config
                } else if let metadata = item.metadata, !metadata.audioStreams.isEmpty {
                    let tracks = metadata.audioStreams.enumerated().map { (index, stream) in
                        AudioTrackInfo(
                            streamIndex: index,  // Use audio-relative index for FFmpeg mapping (0, 1, 2...)
                            channels: stream.channels,
                            channelLayout: stream.channelLayout,
                            codec: stream.codec,
                            codecLongName: stream.codecLongName,
                            sampleRate: stream.sampleRate,
                            languageCode: stream.languageCode,
                            title: stream.title,
                            bitRate: stream.bitRate,
                            trackNumber: index + 1  // 1-based track number
                        )
                    }
                    return AudioRoutingConfig(inputTracks: tracks)
                }
                return AudioRoutingConfig(inputTracks: [])
            },
            set: { newValue in
                item.audioRoutingConfig = newValue
                updateValidation()
            }
        )
    }
    
    private var config: AudioRoutingConfig {
        configBinding.wrappedValue
    }
    
    // MARK: - Channel Operation Detection
    
    private var canMergeToStereo: Bool {
        let monoTracks = config.outputTracks.filter { outputTrack in
            config.trackInfo(for: outputTrack.streamIndex)?.channels == 1
        }
        return monoTracks.count >= 2 && config.channelOperation == nil
    }

    private var canSplitToMono: Bool {
        guard config.outputTracks.count == 1,
              let firstTrack = config.outputTracks.first,
              let trackInfo = config.trackInfo(for: firstTrack.streamIndex) else {
            return false
        }
        return trackInfo.channels == 2 && config.channelOperation == nil
    }

    private var canSwapChannels: Bool {
        guard config.outputTracks.count == 1,
              let firstTrack = config.outputTracks.first,
              let trackInfo = config.trackInfo(for: firstTrack.streamIndex) else {
            return false
        }
        return trackInfo.channels == 2 && config.channelOperation == nil
    }
    
    private var hasActiveOperation: Bool {
        config.hasChannelOperation
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            HStack {
                // Mute toggle section
                muteToggleSection

                
                
                if config.hasAnyInputSurroundTracks && !item.isMuted {
                    surroundWarningBanner
                }
            }.frame(height: 80)
            
            Divider()

            if config.inputTracks.isEmpty {
                emptyStateView
            } else {
                // Surround audio warning banner


                // Main content: split view
                HStack(spacing: 0) {
                    // Left panel: Input tracks
                    inputTracksPanel

                    Divider()

                    // Right panel: Output configuration
                    outputTracksPanel
                }
                .opacity(item.isMuted ? 0.4 : 1.0)
                .allowsHitTesting(!item.isMuted)
            }

            Divider()

            // Bottom toolbar
            bottomToolbar
        }
        .frame(
            minWidth: 1000,
            idealWidth: 1300,
            minHeight: 700,
            idealHeight: min(1400, (NSScreen.main?.visibleFrame.height ?? 1400) * 0.85),
            maxHeight: (NSScreen.main?.visibleFrame.height ?? 1400) * 0.85
        )
        .onAppear {
            updateValidation()
        }
        // Hidden buttons for keyboard shortcuts
        .background(
            Group {
                // Ctrl+M mute toggle shortcut
                Button("") {
                    item.isMuted.toggle()
                }
                .keyboardShortcut("m", modifiers: .control)

                // CMD+1...8 track toggle shortcuts
                ForEach(1...8, id: \.self) { trackNum in
                    Button("") {
                        toggleTrack(trackNumber: trackNum)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(trackNum)")), modifiers: .command)
                }

                // CMD+Option+1...9 stereo toggle shortcuts for individual output tracks
                ForEach(1...9, id: \.self) { trackNum in
                    Button("") {
                        toggleStereoForOutputTrack(position: trackNum - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(trackNum)")), modifiers: [.command, .option])
                }

                // CMD+Option+S toggle stereo for all surround tracks
                Button("") {
                    toggleStereoForAllSurroundTracks()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        )
        .task(id: item.id) {
            await loadInputTracksIfNeeded()
        }
    }

    /// On first open of the routing view for an item, probe the input file via
    /// AudioRoutingService so MCA labels (and any other enrichment that path adds)
    /// land on the input tracks. Skipped when a config already exists so the user's
    /// customizations are preserved across re-opens.
    private func loadInputTracksIfNeeded() async {
        guard item.audioRoutingConfig == nil else { return }
        let tracks = await AudioRoutingService.fetchAudioTrackInfo(for: item.url)
        guard !tracks.isEmpty else { return }
        await MainActor.run {
            item.audioRoutingConfig = AudioRoutingConfig(inputTracks: tracks)
            updateValidation()
        }
    }

    // MARK: - Mute Toggle Section

    private var muteToggleSection: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $item.isMuted) {
                HStack(spacing: 8) {
                    Image(systemName: item.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundColor(item.isMuted ? .red : .accentColor)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mute Audio")
                            .font(.body)
                            .fontWeight(.medium)

                        Text(item.isMuted ? "All audio will be removed from output" : "Audio tracks will be included in output")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .toggleStyle(.switch)

            Spacer()

            if item.isMuted {
                Text("⌃M to toggle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
            }
        }
        .padding()
        .background(item.isMuted ? Color.red.opacity(0.05) : Color.clear)
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Audio Track Routing")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                // Display filename for context
                HStack(spacing: 6) {
                    Image(systemName: "doc.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(item.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                }
                
                Text("Configure which audio tracks to include in the output and their order")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Thumbnail for visual confirmation
            if let thumbnailData = item.thumbnailData,
               let nsImage = NSImage(data: thumbnailData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 120, height: 90)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.15), radius: 3, x: 0, y: 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }
    
    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Audio Tracks")
                .font(.title3)
                .fontWeight(.medium)

            Text("This file does not contain any audio tracks.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Surround Warning Banner

    private var surroundWarningBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.3.fill")
                .font(.title3)
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Surround Audio Detected")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("Some players (like QuickTime) may not play surround audio. Enable \"Stereo\" on tracks to downmix for compatibility.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal)
        .padding(.top, 8)
    }
    
    // MARK: - Input Tracks Panel
    
    private var inputTracksPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Input Tracks")
                .font(.headline)
                .padding(.horizontal)
            
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(config.inputTracks) { track in
                        inputTrackRow(track)
                    }
                }
                .padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
    }
    
    private func inputTrackRow(_ track: AudioTrackInfo) -> some View {
        let isInOutput = config.outputTrackIndices.contains(track.streamIndex)

        return HStack(spacing: 12) {
            // Track icon with surround indicator
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: channelIcon(for: track.channels))
                    .font(.title3)
                    .foregroundColor(.accentColor)
                    .frame(width: 32)

                // Surround indicator badge
                if track.isSurround {
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .offset(x: 4, y: 4)
                }
            }

            // Track info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(track.displayLabel)
                        .font(.body)
                        .fontWeight(.medium)

                    if track.isSurround {
                        Text("Surround")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.orange.opacity(0.15))
                            )
                    }
                }

                if !track.technicalDetails.isEmpty {
                    Text(track.technicalDetails)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Add button (always enabled - allows duplicates)
            Button {
                withAnimation {
                    var updatedConfig = config
                    updatedConfig.addTrack(track.streamIndex)
                    configBinding.wrappedValue = updatedConfig
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("Add track to output")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isInOutput ? Color.accentColor.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
    
    // MARK: - Output Tracks Panel

    private var outputTracksPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Output Tracks")
                    .font(.headline)

                Spacer()

                Text("\(config.outputTracks.count) tracks")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)

            if config.outputTracks.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary)
                    Text("No tracks selected")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Use the + button to add tracks")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(config.outputTracks.enumerated()), id: \.element.id) { index, outputTrack in
                            outputTrackRow(outputTrack, position: index)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .frame(minWidth: 550, maxWidth: .infinity)
        .padding(.vertical)
    }
    
    private func outputTrackRow(_ outputTrack: OutputTrack, position: Int) -> some View {
        let baseTrackInfo = config.trackInfo(for: outputTrack.streamIndex)
        let trackInfo = baseTrackInfo?.applyingOverride(outputTrack.mcaOverride)

        return HStack(spacing: 12) {
            // Position indicator
            Text("\(position + 1)")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))

            // Track icon with surround/downmix indicator
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: channelIcon(for: trackInfo?.channels))
                    .font(.body)
                    .foregroundColor(.primary)

                // Show stereo badge if downmixing, or surround badge if surround without downmix
                if outputTrack.downmixToStereo {
                    Image(systemName: "2.circle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                        .offset(x: 4, y: 4)
                } else if trackInfo?.isSurround == true {
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .offset(x: 4, y: 4)
                }
            }

            // Track info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(trackInfo?.displayLabel ?? "Track \(outputTrack.streamIndex + 1)")
                        .font(.body)
                        .fontWeight(.medium)

                    // Downmix status badge
                    if outputTrack.downmixToStereo {
                        Text("→ Stereo")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.green.opacity(0.15))
                            )
                    } else if trackInfo?.isSurround == true {
                        Text("Surround")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.orange.opacity(0.15))
                            )
                    }
                }

                if let details = trackInfo?.technicalDetails, !details.isEmpty {
                    Text(details)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Stereo downmix toggle (only for surround tracks)
            if trackInfo?.isSurround == true {
                Button {
                    withAnimation {
                        var updatedConfig = config
                        updatedConfig.toggleDownmix(for: outputTrack.id)
                        configBinding.wrappedValue = updatedConfig
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: outputTrack.downmixToStereo ? "checkmark.circle.fill" : "circle")
                            .font(.caption)
                        Text("Stereo")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(outputTrack.downmixToStereo ? Color.green.opacity(0.15) : Color.gray.opacity(0.1))
                    )
                    .foregroundColor(outputTrack.downmixToStereo ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help(outputTrack.downmixToStereo ? "Keep original surround audio" : "Downmix to stereo for compatibility")
            }

            // MCA labels picker (used by TV AVC-Intra MXF output)
            mcaLabelsMenu(for: outputTrack)

            // Remove button
            Button {
                withAnimation {
                    var updatedConfig = config
                    updatedConfig.removeTrack(id: outputTrack.id)
                    configBinding.wrappedValue = updatedConfig
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
                    .foregroundColor(.red)
            }
            .buttonStyle(.plain)
            .help("Remove track from output")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
        .onDrag {
            NSItemProvider(object: outputTrack.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: OutputTrackDropDelegate(
            position: position,
            config: configBinding,
            onUpdate: updateValidation
        ))
    }

    /// Popup-menu picker for the manual MCA-label override. Lives on each output
    /// track row; the AVC-Intra rewrap step reads these overrides when building
    /// the bmx labels file. The icon switches to filled when an override is set.
    ///
    /// The checkmark next to a menu entry reflects the *effective* selection:
    /// the explicit override when set, otherwise the auto-detected label read
    /// from the source input track's MCA descriptors. This way users see the
    /// label that's actually in force without having to first save it as an
    /// override.
    @ViewBuilder
    private func mcaLabelsMenu(for outputTrack: OutputTrack) -> some View {
        let current = outputTrack.mcaOverride
        let hasOverride = current?.isEmpty == false
        let inputTrack = config.trackInfo(for: outputTrack.streamIndex)
        let autoSoundfield = inputTrack?.mcaSoundfieldGroup.flatMap(MCAStandardSoundfield.init(matching:))
        let autoElement = inputTrack?.mcaAudioElement.flatMap(MCAStandardAudioElement.init(matching:))
        let effectiveSoundfield = current?.soundfield ?? autoSoundfield
        let effectiveElement = current?.audioElement ?? autoElement

        Menu {
            Section("Soundfield") {
                ForEach(MCAStandardSoundfield.allCases) { soundfield in
                    Button {
                        var updated = current ?? MCALabelOverride()
                        updated.soundfield = soundfield
                        applyMCAOverride(updated, to: outputTrack.id)
                    } label: {
                        if effectiveSoundfield == soundfield {
                            Label(soundfield.displayName, systemImage: "checkmark")
                        } else {
                            Text(soundfield.displayName)
                        }
                    }
                }
                if current?.soundfield != nil {
                    Divider()
                    Button("Clear soundfield") {
                        var updated = current ?? MCALabelOverride()
                        updated.soundfield = nil
                        applyMCAOverride(updated, to: outputTrack.id)
                    }
                }
            }

            Section("Audio Element") {
                ForEach(MCAStandardAudioElement.allCases) { element in
                    Button {
                        var updated = current ?? MCALabelOverride()
                        updated.audioElement = element
                        applyMCAOverride(updated, to: outputTrack.id)
                    } label: {
                        if effectiveElement == element {
                            Label(element.displayName, systemImage: "checkmark")
                        } else {
                            Text(element.displayName)
                        }
                    }
                }
                if current?.audioElement != nil {
                    Divider()
                    Button("Clear audio element") {
                        var updated = current ?? MCALabelOverride()
                        updated.audioElement = nil
                        applyMCAOverride(updated, to: outputTrack.id)
                    }
                }
            }

            if hasOverride {
                Section {
                    Button("Reset all labels", role: .destructive) {
                        applyMCAOverride(nil, to: outputTrack.id)
                    }
                }
            }
        } label: {
            Image(systemName: hasOverride ? "tag.fill" : "tag")
                .font(.body)
                .foregroundColor(hasOverride ? .accentColor : .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(mcaMenuHelp(for: current))
    }

    private func applyMCAOverride(_ override: MCALabelOverride?, to trackID: UUID) {
        var updated = config
        updated.setMCAOverride(override, for: trackID)
        configBinding.wrappedValue = updated
    }

    private func mcaMenuHelp(for override: MCALabelOverride?) -> String {
        guard let override, !override.isEmpty else {
            return "Set MCA labels for this output track (used by AVC-Intra MXF export)"
        }
        var parts: [String] = []
        if let element = override.audioElement { parts.append(element.displayName) }
        if let soundfield = override.soundfield { parts.append(soundfield.displayName) }
        return "MCA labels: \(parts.joined(separator: " • "))"
    }
    
    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        HStack(spacing: 16) {
            // Validation messages (hide when muted since routing is irrelevant)
            if !validationMessages.isEmpty && !item.isMuted {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(validationMessages, id: \.self) { message in
                        HStack(spacing: 6) {
                            Image(systemName: message.hasPrefix("Warning") ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                .foregroundColor(message.hasPrefix("Warning") ? .orange : .blue)
                            Text(message)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Spacer()

            // Channel operations section (disabled when muted)
            if !item.isMuted {
                channelOperationsSection
            }

            Spacer()

            // Reset button (icon only, disabled when muted)
            Button {
                withAnimation {
                    var updatedConfig = config
                    updatedConfig.resetToDefault()
                    configBinding.wrappedValue = updatedConfig
                }
            } label: {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(config.isCustomized && !item.isMuted ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!config.isCustomized || item.isMuted)
            .help("Reset to default")

            // Close button (icon only)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24, weight: .medium))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.secondary.opacity(0.7), .secondary.opacity(0.25))
            }
            .buttonStyle(.plain)
            .help("Close")
            .keyboardShortcut(.cancelAction)
        }
        .padding()
    }
    
    // MARK: - Channel Operations Section
    
    @ViewBuilder
    private var channelOperationsSection: some View {
        if hasActiveOperation || canMergeToStereo || canSplitToMono || canSwapChannels {
            VStack(alignment: .leading, spacing: 8) {
                Text("Channel Operations")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    // Active operation indicator
                    if let operation = config.channelOperation {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(operation.shortLabel)
                                .font(.caption)
                                .fontWeight(.medium)
                            
                            Button {
                                withAnimation {
                                    var updatedConfig = config
                                    updatedConfig.clearChannelOperation()
                                    configBinding.wrappedValue = updatedConfig
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Clear operation")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.green.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.green.opacity(0.3), lineWidth: 1)
                        )
                    } else {
                        // Operation buttons
                        if canMergeToStereo {
                            channelOperationButton(
                                title: "Merge to Stereo",
                                icon: "waveform.badge.plus"
                            ) {
                                let monoTracks = config.outputTracks.filter { outputTrack in
                                    config.trackInfo(for: outputTrack.streamIndex)?.channels == 1
                                }
                                let indices = monoTracks.prefix(2).map(\.streamIndex)

                                withAnimation {
                                    var updatedConfig = config
                                    updatedConfig.setChannelOperation(.mergeToStereo(trackIndices: Array(indices)))
                                    configBinding.wrappedValue = updatedConfig
                                }
                            }
                        }
                        
                        if canSplitToMono {
                            channelOperationButton(
                                title: "Split to Mono",
                                icon: "waveform.badge.minus"
                            ) {
                                if let track = config.outputTracks.first {
                                    withAnimation {
                                        var updatedConfig = config
                                        updatedConfig.setChannelOperation(.splitToMono(trackIndex: track.streamIndex))
                                        configBinding.wrappedValue = updatedConfig
                                    }
                                }
                            }
                        }
                        
                        if canSwapChannels {
                            channelOperationButton(
                                title: "Swap L/R",
                                icon: "arrow.left.arrow.right"
                            ) {
                                if let track = config.outputTracks.first {
                                    withAnimation {
                                        var updatedConfig = config
                                        updatedConfig.setChannelOperation(.swapChannels(trackIndex: track.streamIndex))
                                        configBinding.wrappedValue = updatedConfig
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func channelOperationButton(
        title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
    
    // MARK: - Helpers

    /// Toggle a track in/out of the output by its 1-based track number (CMD+1...8)
    private func toggleTrack(trackNumber: Int) {
        // Find track with this track number (1-based)
        // streamIndex is 0-based, so track 1 = streamIndex 0
        let streamIndex = trackNumber - 1

        guard streamIndex >= 0 && streamIndex < config.inputTracks.count else {
            return
        }

        // Don't allow toggling when muted
        guard !item.isMuted else { return }

        withAnimation {
            var updatedConfig = config
            if config.outputTrackIndices.contains(streamIndex) {
                updatedConfig.removeTrack(streamIndex)
            } else {
                updatedConfig.addTrack(streamIndex)
            }
            configBinding.wrappedValue = updatedConfig
        }
    }

    /// Toggle stereo downmix for a specific output track by its 0-based position (CMD+Option+1...9)
    private func toggleStereoForOutputTrack(position: Int) {
        // Don't allow toggling when muted
        guard !item.isMuted else { return }

        // Check if the position is valid
        guard position >= 0 && position < config.outputTracks.count else { return }

        let outputTrack = config.outputTracks[position]

        // Only toggle if the track is surround
        guard let trackInfo = config.trackInfo(for: outputTrack.streamIndex),
              trackInfo.isSurround else { return }

        withAnimation {
            var updatedConfig = config
            updatedConfig.toggleDownmix(for: outputTrack.id)
            configBinding.wrappedValue = updatedConfig
        }
    }

    /// Toggle stereo downmix for all surround output tracks at once (CMD+Option+S)
    private func toggleStereoForAllSurroundTracks() {
        // Don't allow toggling when muted
        guard !item.isMuted else { return }

        // Find all surround output tracks
        let surroundOutputTracks = config.outputTracks.filter { outputTrack in
            config.trackInfo(for: outputTrack.streamIndex)?.isSurround == true
        }

        guard !surroundOutputTracks.isEmpty else { return }

        // Determine target state: if any surround track is NOT downmixed, enable all; otherwise disable all
        let anyNotDownmixed = surroundOutputTracks.contains { !$0.downmixToStereo }
        let targetDownmix = anyNotDownmixed

        withAnimation {
            var updatedConfig = config
            for outputTrack in surroundOutputTracks {
                updatedConfig.setDownmix(for: outputTrack.id, downmix: targetDownmix)
            }
            configBinding.wrappedValue = updatedConfig
        }
    }

    private func channelIcon(for channels: Int?) -> String {
        guard let channels else { return "waveform" }
        switch channels {
        case 1: return "waveform.path"
        case 2: return "waveform"
        case 3...6: return "waveform.badge.magnifyingglass"
        default: return "waveform.badge.plus"
        }
    }
    
    private func updateValidation() {
        validationMessages = AudioRoutingService.validateRoutingConfig(
            config: config,
            preset: preset
        )
    }
}

// MARK: - Drop Delegate for Reordering

struct OutputTrackDropDelegate: DropDelegate {
    let position: Int
    @Binding var config: AudioRoutingConfig
    let onUpdate: () -> Void

    func performDrop(info: DropInfo) -> Bool {
        guard let itemProvider = info.itemProviders(for: [.text]).first else {
            return false
        }

        // Capture the current output tracks to avoid accessing binding in closure
        let currentTracks = config.outputTracks

        itemProvider.loadItem(forTypeIdentifier: "public.text", options: nil) { data, error in
            guard let data = data as? Data,
                  let uuidString = String(data: data, encoding: .utf8),
                  let draggedId = UUID(uuidString: uuidString),
                  let sourceIndex = currentTracks.firstIndex(where: { $0.id == draggedId }) else {
                return
            }

            DispatchQueue.main.async {
                withAnimation {
                    config.moveTrack(from: sourceIndex, to: position)
                    onUpdate()
                }
            }
        }

        return true
    }
}
