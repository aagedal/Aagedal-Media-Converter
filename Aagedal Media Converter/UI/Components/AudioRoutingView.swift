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
    /// Output tracks selected for bulk codec changes (click, Shift-click, Cmd-click).
    @State private var selectedOutputTrackIDs: Set<UUID> = []
    @State private var selectionAnchorID: UUID?
    /// Tracks being dragged, and the gap they would land in (0...count).
    @State private var draggedOutputTrackIDs: Set<UUID> = []
    @State private var dropInsertionIndex: Int?
    /// Measured row heights for the drop delegates. A plain reference type on purpose:
    /// storing these in observed state re-lays out the sheet on every measurement,
    /// which loops forever.
    @State private var outputRowHeights = OutputRowHeightStore()
    
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

                if !activeSelection.isEmpty {
                    selectionToolbar
                } else if config.outputTracks.count > 1 {
                    Text("Click to select, Shift-click for a range")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

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

                        // Drop target below the last row, for moving tracks to the end
                        Color.clear
                            .frame(height: 32)
                            .contentShape(Rectangle())
                            .onDrop(of: [.text], delegate: OutputTrackDropDelegate(
                                position: config.outputTracks.count - 1,
                                rowHeight: { 0 },
                                insertionIndex: $dropInsertionIndex,
                                perform: dropOutputTracks
                            ))
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
        let isSelected = activeSelection.contains(outputTrack.id)

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

            // Per-track codec override (copy original / AAC)
            if preset.supportsPerTrackAudioEncoding {
                encodingMenu(for: outputTrack, trackInfo: trackInfo)
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
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.2), lineWidth: isSelected ? 1.5 : 1)
        )
        .overlay(alignment: .top) {
            if isDraggingOutputTracks && dropInsertionIndex == position {
                dropInsertionLine.offset(y: -5)
            }
        }
        .overlay(alignment: .bottom) {
            if isDraggingOutputTracks && dropInsertionIndex == config.outputTracks.count && position == config.outputTracks.count - 1 {
                dropInsertionLine.offset(y: 5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            handleOutputTrackClick(outputTrack.id)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            outputRowHeights.heights[outputTrack.id] = height
        }
        .onDrag {
            beginOutputTrackDrag(outputTrack.id)
            return NSItemProvider(object: outputTrack.id.uuidString as NSString)
        } preview: {
            dragPreview(for: outputTrack, trackInfo: trackInfo)
        }
        .onDrop(of: [.text], delegate: OutputTrackDropDelegate(
            position: position,
            rowHeight: { [outputRowHeights, id = outputTrack.id] in outputRowHeights.heights[id] ?? 0 },
            insertionIndex: $dropInsertionIndex,
            perform: dropOutputTracks
        ))
    }

    private var isDraggingOutputTracks: Bool {
        !draggedOutputTrackIDs.isEmpty
    }

    private var dropInsertionLine: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 3)
            .padding(.horizontal, 4)
            .allowsHitTesting(false)
    }

    private func dragPreview(for outputTrack: OutputTrack, trackInfo: AudioTrackInfo?) -> some View {
        let count = activeSelection.contains(outputTrack.id) ? activeSelection.count : 1
        let title = count > 1 ? "\(count) tracks" : (trackInfo?.displayLabel ?? "Track \(outputTrack.streamIndex + 1)")
        return Label(title, systemImage: count > 1 ? "square.stack" : "waveform")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.accentColor.opacity(0.85)))
            .foregroundColor(.white)
    }

    // MARK: - Output Track Reordering

    /// Header controls shown while output tracks are selected.
    private var selectionToolbar: some View {
        let selection = activeSelection
        let indices = config.outputTracks.indices.filter { selection.contains(config.outputTracks[$0].id) }
        // Disabled when the selection is already packed against that edge
        let canMoveUp = indices.enumerated().contains { $0.element != $0.offset }
        let canMoveDown = indices.reversed().enumerated().contains { $0.element != config.outputTracks.count - 1 - $0.offset }

        return HStack(spacing: 6) {
            Text("\(selection.count) selected")
                .font(.subheadline)
                .foregroundColor(.accentColor)

            Button {
                shiftSelectedOutputTracks(by: -1)
            } label: {
                Image(systemName: "arrow.up")
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(!canMoveUp)
            .help("Move selected tracks up (⌘↑)")

            Button {
                shiftSelectedOutputTracks(by: 1)
            } label: {
                Image(systemName: "arrow.down")
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(!canMoveDown)
            .help("Move selected tracks down (⌘↓)")

            Button {
                removeSelectedOutputTracks()
            } label: {
                Image(systemName: "trash")
            }
            .keyboardShortcut(.delete, modifiers: [])
            .help("Remove selected tracks (⌫)")

            Button("Deselect") {
                clearOutputTrackSelection()
            }
            .buttonStyle(.link)
            .font(.subheadline)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private func shiftSelectedOutputTracks(by step: Int) {
        withAnimation {
            var updated = config
            updated.shiftTracks(ids: activeSelection, by: step)
            configBinding.wrappedValue = updated
        }
    }

    private func removeSelectedOutputTracks() {
        withAnimation {
            var updated = config
            updated.removeTracks(ids: activeSelection)
            configBinding.wrappedValue = updated
        }
        clearOutputTrackSelection()
    }

    /// Dragging a selected row carries the whole selection; dragging an unselected
    /// row selects it and moves it alone, as in Finder.
    private func beginOutputTrackDrag(_ trackID: UUID) {
        dropInsertionIndex = nil
        if activeSelection.contains(trackID) {
            draggedOutputTrackIDs = activeSelection
        } else {
            selectedOutputTrackIDs = [trackID]
            selectionAnchorID = trackID
            draggedOutputTrackIDs = [trackID]
        }
    }

    private func endOutputTrackDrag() {
        draggedOutputTrackIDs = []
        dropInsertionIndex = nil
    }

    private func dropOutputTracks(at insertionIndex: Int, providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else {
            endOutputTrackDrag()
            return false
        }
        // The payload is the grabbed track's ID; only trust the remembered drag group
        // when it contains that ID, so a stale group from a cancelled drag is ignored.
        provider.loadItem(forTypeIdentifier: "public.text", options: nil) { data, _ in
            let draggedID = (data as? Data)
                .flatMap { String(data: $0, encoding: .utf8) }
                .flatMap(UUID.init(uuidString:))
            DispatchQueue.main.async {
                // SwiftUI can still deliver dropUpdated while the drop animates, which
                // would re-show the insertion line; ending the drag here hides it for good.
                let group = draggedOutputTrackIDs
                endOutputTrackDrag()
                guard let draggedID else { return }
                let ids = group.contains(draggedID) ? group : [draggedID]
                withAnimation {
                    var updated = config
                    updated.moveTracks(ids: ids, toInsertionIndex: insertionIndex)
                    configBinding.wrappedValue = updated
                }
            }
        }
        return true
    }

    // MARK: - Output Track Selection

    /// Selected tracks that still exist in the output list.
    private var activeSelection: Set<UUID> {
        selectedOutputTrackIDs.intersection(config.outputTracks.map(\.id))
    }

    /// Finder-style selection: click selects one, Cmd-click toggles, Shift-click
    /// extends a range from the last clicked track.
    private func handleOutputTrackClick(_ trackID: UUID) {
        endOutputTrackDrag()  // clears any leftover from a drag cancelled outside the list
        let modifiers = NSEvent.modifierFlags
        let ids = config.outputTracks.map(\.id)

        if modifiers.contains(.shift),
           let anchor = selectionAnchorID,
           let anchorIndex = ids.firstIndex(of: anchor),
           let clickedIndex = ids.firstIndex(of: trackID) {
            let range = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            let rangeIDs = Set(ids[range])
            selectedOutputTrackIDs = modifiers.contains(.command)
                ? activeSelection.union(rangeIDs)
                : rangeIDs
            return
        }

        if modifiers.contains(.command) || modifiers.contains(.shift) {
            if selectedOutputTrackIDs.contains(trackID) {
                selectedOutputTrackIDs.remove(trackID)
            } else {
                selectedOutputTrackIDs.insert(trackID)
            }
        } else if activeSelection == [trackID] {
            selectedOutputTrackIDs = []
        } else {
            selectedOutputTrackIDs = [trackID]
        }
        selectionAnchorID = trackID
    }

    private func clearOutputTrackSelection() {
        selectedOutputTrackIDs = []
        selectionAnchorID = nil
    }

    /// Tracks a codec menu change on `outputTrack` applies to: the whole selection
    /// when the track is part of a multi-track selection, otherwise just this track.
    private func encodingTargets(for outputTrack: OutputTrack) -> Set<UUID> {
        let selection = activeSelection
        return selection.count > 1 && selection.contains(outputTrack.id) ? selection : [outputTrack.id]
    }

    /// Codec picker for one output track. "Preset" follows the export preset, which
    /// for Stream Copy means the original stream is copied. Copy is unavailable for
    /// downmixed tracks because FFmpeg cannot stream copy filtered audio.
    @ViewBuilder
    private func encodingMenu(for outputTrack: OutputTrack, trackInfo: AudioTrackInfo?) -> some View {
        let isStreamCopy = preset == .streamCopy
        let targetCount = encodingTargets(for: outputTrack).count
        let sourceCodec = targetCount > 1 ? nil : trackInfo?.codec?.uppercased()
        let copyLabel = sourceCodec.map { "Copy original (\($0))" } ?? "Copy original"
        let streamCopyFallback = AudioTrackEncoding.aac(bitrateKbps: AudioTrackEncoding.streamCopyFallbackAACKbps)
        let presetLabel = !isStreamCopy ? "Preset codec"
            : outputTrack.downmixToStereo ? "Default (\(streamCopyFallback.shortLabel))" : copyLabel
        let label: String = if case .aac = outputTrack.encoding {
            outputTrack.encoding.shortLabel
        } else if outputTrack.downmixToStereo {
            isStreamCopy ? streamCopyFallback.shortLabel : "Preset"
        } else {
            outputTrack.encoding == .copy || isStreamCopy ? "Copy" : "Preset"
        }

        Menu {
            if targetCount > 1 {
                Text("Apply to \(targetCount) selected tracks")
            }
            encodingMenuButton(presetLabel, encoding: .preset, for: outputTrack)
            if !isStreamCopy {
                encodingMenuButton(copyLabel, encoding: .copy, for: outputTrack)
                .disabled(targetCount == 1 && outputTrack.downmixToStereo)
            }
            Section("AAC") {
                ForEach(AudioTrackEncoding.aacBitrateOptions, id: \.self) { kbps in
                    encodingMenuButton("\(kbps) kbps", encoding: .aac(bitrateKbps: kbps), for: outputTrack)
                }
            }
        } label: {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundColor(outputTrack.encoding == .preset ? .secondary : .accentColor)
        .help(outputTrack.downmixToStereo
              ? "Audio codec for this track (downmixed tracks are always encoded)"
              : "Audio codec for this track: copy the original stream or encode to AAC")
    }

    private func encodingMenuButton(_ title: String, encoding: AudioTrackEncoding, for outputTrack: OutputTrack) -> some View {
        Button {
            var updated = config
            updated.setEncoding(encoding, for: encodingTargets(for: outputTrack))
            configBinding.wrappedValue = updated
        } label: {
            if outputTrack.encoding == encoding {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
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

/// Unobserved storage for output row heights; see `AudioRoutingView.outputRowHeights`.
final class OutputRowHeightStore {
    var heights: [UUID: CGFloat] = [:]
}

struct OutputTrackDropDelegate: DropDelegate {
    /// Row this delegate is attached to.
    let position: Int
    /// Row height, used to decide whether the cursor is above or below the middle.
    /// Zero always means "below", which the end-of-list drop zone relies on.
    let rowHeight: () -> CGFloat
    @Binding var insertionIndex: Int?
    let perform: (_ insertionIndex: Int, _ providers: [NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        insertionIndex = gap(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let gap = gap(for: info)
        if insertionIndex != gap {
            insertionIndex = gap
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if insertionIndex == position || insertionIndex == position + 1 {
            insertionIndex = nil
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let gap = insertionIndex ?? gap(for: info)
        insertionIndex = nil
        return perform(gap, info.itemProviders(for: [.text]))
    }

    private func gap(for info: DropInfo) -> Int {
        let height = rowHeight()
        return height > 0 && info.location.y < height / 2 ? position : position + 1
    }
}
