// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

/// Represents a single audio track with metadata
struct AudioTrackInfo: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    let streamIndex: Int
    let channels: Int?
    let channelLayout: String?
    let codec: String?
    let codecLongName: String?
    let sampleRate: Int?
    let languageCode: String?
    let title: String?
    let bitRate: Int64?
    let trackNumber: Int? // Position-based track number (1, 2, 3...) rather than stream index

    // SMPTE ST 377-4 Multi-Channel Audio (MCA) labels, populated for MXF/IMF essences via mxf2raw
    let mcaSoundfieldGroup: String?    // e.g. "5.1", "ST", "7.1DS"
    let mcaAudioElement: String?       // e.g. "DX", "ME", "VI-N"
    let mcaChannelLabels: [String]?    // e.g. ["L", "R", "C", "LFE", "Ls", "Rs"]

    init(
        id: UUID = UUID(),
        streamIndex: Int,
        channels: Int?,
        channelLayout: String?,
        codec: String?,
        codecLongName: String?,
        sampleRate: Int?,
        languageCode: String? = nil,
        title: String? = nil,
        bitRate: Int64? = nil,
        trackNumber: Int? = nil,
        mcaSoundfieldGroup: String? = nil,
        mcaAudioElement: String? = nil,
        mcaChannelLabels: [String]? = nil
    ) {
        self.id = id
        self.streamIndex = streamIndex
        self.channels = channels
        self.channelLayout = channelLayout
        self.codec = codec
        self.codecLongName = codecLongName
        self.sampleRate = sampleRate
        self.languageCode = languageCode
        self.title = title
        self.bitRate = bitRate
        self.trackNumber = trackNumber
        self.mcaSoundfieldGroup = mcaSoundfieldGroup
        self.mcaAudioElement = mcaAudioElement
        self.mcaChannelLabels = mcaChannelLabels
    }

    /// Human-readable track label
    var displayLabel: String {
        // Use trackNumber if available, otherwise fall back to streamIndex + 1
        let trackLabel = trackNumber.map { "Track \($0)" } ?? "Track \(streamIndex + 1)"
        var components: [String] = [trackLabel]

        if let mcaAudioElement, !mcaAudioElement.isEmpty {
            components.append(mcaAudioElement)
        }

        if let title = title, !title.isEmpty {
            components.append(title)
        }

        if let mcaSoundfieldGroup, !mcaSoundfieldGroup.isEmpty {
            components.append(mcaSoundfieldGroup)
        }

        if let channelLayout = channelLayout {
            components.append(channelLayout)
        } else if let channels = channels {
            switch channels {
            case 1: components.append("Mono")
            case 2: components.append("Stereo")
            default: components.append("\(channels) ch")
            }
        }

        return components.joined(separator: " • ")
    }

    /// Technical details for subtitle display
    var technicalDetails: String {
        var parts: [String] = []

        if let codec = codecLongName ?? codec {
            parts.append(codec)
        }

        if let sampleRate = sampleRate {
            parts.append("\(sampleRate) Hz")
        }

        if let languageCode = languageCode {
            parts.append(languageCode.uppercased())
        }

        if let mcaChannelLabels, !mcaChannelLabels.isEmpty {
            parts.append(mcaChannelLabels.joined(separator: " "))
        }

        return parts.joined(separator: " • ")
    }

    /// Returns true if this track has surround audio (more than 2 channels)
    var isSurround: Bool {
        guard let channels = channels else { return false }
        return channels > 2
    }

    /// Returns a copy of this track with the supplied MCA override merged in.
    /// Override values replace the corresponding auto-detected MCA fields; passing
    /// nil leaves all fields untouched. Channel labels follow the override's
    /// soundfield only when the channel count matches, so a 5.1 override on a
    /// 2-channel stream still updates the soundfield label without inventing
    /// per-channel labels that don't exist.
    func applyingOverride(_ override: MCALabelOverride?) -> AudioTrackInfo {
        guard let override, !override.isEmpty else { return self }
        let overriddenSoundfield = override.soundfield?.displayName ?? mcaSoundfieldGroup
        let overriddenElement = override.audioElement?.shortLabel ?? mcaAudioElement
        let overriddenChannelLabels: [String]?
        if let soundfield = override.soundfield, soundfield.channelCount == channels {
            overriddenChannelLabels = soundfield.displayChannelLabels
        } else {
            overriddenChannelLabels = mcaChannelLabels
        }
        return AudioTrackInfo(
            id: id,
            streamIndex: streamIndex,
            channels: channels,
            channelLayout: channelLayout,
            codec: codec,
            codecLongName: codecLongName,
            sampleRate: sampleRate,
            languageCode: languageCode,
            title: title,
            bitRate: bitRate,
            trackNumber: trackNumber,
            mcaSoundfieldGroup: overriddenSoundfield,
            mcaAudioElement: overriddenElement,
            mcaChannelLabels: overriddenChannelLabels
        )
    }
}

// MARK: - MCA Label Overrides

/// User-selectable soundfield groups for the manual MCA-label override.
/// Each case maps to a bmx tag symbol (used by `MCALabelsBuilder` when emitting
/// the `--track-mca-labels` file) and to the per-channel symbol list that bmx
/// expects for that soundfield.
enum MCAStandardSoundfield: String, CaseIterable, Codable, Sendable, Identifiable {
    case mono
    case stereo
    case dualMono
    case surround51
    case surround71
    case ltRt

    var id: String { rawValue }

    /// Human-readable label shown in pickers and in the routing-row display label.
    var displayName: String {
        switch self {
        case .mono: return "Mono"
        case .stereo: return "Stereo"
        case .dualMono: return "Dual Mono"
        case .surround51: return "5.1"
        case .surround71: return "7.1"
        case .ltRt: return "Lt-Rt"
        }
    }

    /// bmx Tag Symbol for the SoundfieldGroupLabelSubDescriptor.
    var bmxSymbol: String {
        switch self {
        case .mono: return "sgM"
        case .stereo: return "sgST"
        case .dualMono: return "sgDM"
        case .surround51: return "sg51"
        case .surround71: return "sg71"
        case .ltRt: return "sgLtRt"
        }
    }

    /// Channel-count this soundfield expects. Used to validate user picks against
    /// the actual stream channel count and to produce the per-channel symbol list.
    var channelCount: Int {
        switch self {
        case .mono: return 1
        case .stereo, .dualMono, .ltRt: return 2
        case .surround51: return 6
        case .surround71: return 8
        }
    }

    /// bmx channel Tag Symbols in essence channel order for this soundfield.
    var bmxChannelSymbols: [String] {
        switch self {
        case .mono: return ["chM1"]
        case .stereo: return ["chL", "chR"]
        case .dualMono: return ["chM1", "chM2"]
        case .ltRt: return ["chLt", "chRt"]
        case .surround51: return ["chL", "chR", "chC", "chLFE", "chLs", "chRs"]
        case .surround71: return ["chL", "chR", "chC", "chLFE", "chLs", "chRs", "chLss", "chRss"]
        }
    }

    /// Display labels (Tag Names) corresponding to bmxChannelSymbols, used to enrich
    /// the routing-row subtitle when an override is applied.
    var displayChannelLabels: [String] {
        switch self {
        case .mono: return ["Mono"]
        case .stereo: return ["Left", "Right"]
        case .dualMono: return ["Mono 1", "Mono 2"]
        case .ltRt: return ["Lt", "Rt"]
        case .surround51: return ["L", "R", "C", "LFE", "Ls", "Rs"]
        case .surround71: return ["L", "R", "C", "LFE", "Ls", "Rs", "Lss", "Rss"]
        }
    }

    /// Maps an input MCA soundfield label (the human-readable Tag Name surfaced by
    /// `AudioTrackInfo.mcaSoundfieldGroup`) to the matching standard soundfield, so
    /// the override picker can show the auto-detected option as "selected" before
    /// the user makes an explicit choice.
    init?(matching autoDetectedLabel: String) {
        let normalized = autoDetectedLabel.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
        switch normalized {
        case "mono", "monoaural", "10", "1": self = .mono
        case "stereo", "standardstereo", "st": self = .stereo
        case "dualmono", "dm": self = .dualMono
        case "51", "51surround": self = .surround51
        case "71", "71ds", "71sds", "71surround": self = .surround71
        case "ltrt", "ltrtdownmix": self = .ltRt
        default: return nil
        }
    }
}

/// User-selectable audio element / GOSG labels for the manual MCA-label override.
enum MCAStandardAudioElement: String, CaseIterable, Codable, Sendable, Identifiable {
    case mainProgram
    case musicAndEffects
    case dialog
    case audioDescription
    case descriptiveVideoService

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mainProgram: return "Main Program"
        case .musicAndEffects: return "Music & Effects"
        case .dialog: return "Dialog"
        case .audioDescription: return "Audio Description"
        case .descriptiveVideoService: return "Descriptive Video Service"
        }
    }

    /// Short label shown in the routing-row display label (after the track number).
    var shortLabel: String {
        switch self {
        case .mainProgram: return "MP"
        case .musicAndEffects: return "M&E"
        case .dialog: return "DX"
        case .audioDescription: return "AD"
        case .descriptiveVideoService: return "DVS"
        }
    }

    /// bmx Tag Symbol for the GroupOfSoundfieldGroupsLabelSubDescriptor.
    var bmxSymbol: String {
        switch self {
        case .mainProgram: return "ggMPg"
        case .musicAndEffects: return "ggME"
        case .dialog: return "ggDcm"
        case .audioDescription: return "ggAD"
        case .descriptiveVideoService: return "ggDVS"
        }
    }

    /// Maps an input MCA audio-element label (`AudioTrackInfo.mcaAudioElement`,
    /// either the human Tag Name like "Main Program" or the short label like "MP")
    /// to the matching standard element, so the override picker can show the
    /// auto-detected option as "selected" before the user makes an explicit choice.
    init?(matching autoDetectedLabel: String) {
        let normalized = autoDetectedLabel.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "&", with: "and")
            .replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "mainprogram", "mp", "mpg": self = .mainProgram
        case "musicandeffects", "me": self = .musicAndEffects
        case "dialogcentricmix", "dialog", "dx", "dcm": self = .dialog
        case "audiodescription", "ad": self = .audioDescription
        case "descriptivevideoservice", "dvs": self = .descriptiveVideoService
        default: return nil
        }
    }
}

/// Manual MCA-label override the user can apply to an input audio track. When
/// stored on `AudioRoutingConfig.mcaOverrides`, both the routing-row display
/// and the AVC-Intra MCA labels file prefer these values over the auto-derived
/// labels read from the input MXF.
struct MCALabelOverride: Codable, Equatable, Sendable {
    var soundfield: MCAStandardSoundfield?
    var audioElement: MCAStandardAudioElement?

    /// Returns true when neither field is set so callers can drop empty overrides.
    var isEmpty: Bool { soundfield == nil && audioElement == nil }
}

// MARK: - Output Track

/// Represents a single output audio track with per-track options
/// Allows the same input track to be added multiple times with different settings
struct OutputTrack: Equatable, Sendable, Identifiable {
    let id: UUID
    let streamIndex: Int
    var downmixToStereo: Bool
    /// Manual MCA-label override applied at the bmxtranswrap step (used by the
    /// TV AVC-Intra MXF preset). When nil, AVC-Intra falls back to input MCA
    /// labels and then to standard channel-layout assumptions.
    var mcaOverride: MCALabelOverride?

    init(id: UUID = UUID(), streamIndex: Int, downmixToStereo: Bool = false, mcaOverride: MCALabelOverride? = nil) {
        self.id = id
        self.streamIndex = streamIndex
        self.downmixToStereo = downmixToStereo
        self.mcaOverride = mcaOverride
    }
}

extension OutputTrack: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, streamIndex, downmixToStereo, mcaOverride
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        streamIndex = try container.decode(Int.self, forKey: .streamIndex)
        downmixToStereo = try container.decodeIfPresent(Bool.self, forKey: .downmixToStereo) ?? false
        mcaOverride = try container.decodeIfPresent(MCALabelOverride.self, forKey: .mcaOverride)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(streamIndex, forKey: .streamIndex)
        try container.encode(downmixToStereo, forKey: .downmixToStereo)
        try container.encodeIfPresent(mcaOverride, forKey: .mcaOverride)
    }
}

// MARK: - Channel Operations

/// Represents channel-level audio operations beyond simple track selection
enum ChannelOperation: Equatable, Sendable, Codable {
    /// Merge two mono tracks into a single stereo track
    case mergeToStereo(trackIndices: [Int])
    
    /// Split a stereo track into two mono tracks
    case splitToMono(trackIndex: Int)
    
    /// Swap left and right channels of a stereo track
    case swapChannels(trackIndex: Int)
    
    /// Extract a single channel from a multi-channel track
    case extractChannel(trackIndex: Int, channelIndex: Int, channelName: String)
    
    /// Human-readable description of the operation
    var displayDescription: String {
        switch self {
        case .mergeToStereo(let indices):
            return "Merging \(indices.count) mono tracks into stereo"
        case .splitToMono(let trackIndex):
            return "Splitting track \(trackIndex + 1) into mono channels"
        case .swapChannels(let trackIndex):
            return "Swapping L/R channels on track \(trackIndex + 1)"
        case .extractChannel(let trackIndex, _, let name):
            return "Extracting \(name) channel from track \(trackIndex + 1)"
        }
    }
    
    /// Short label for UI badges
    var shortLabel: String {
        switch self {
        case .mergeToStereo:
            return "Merge to Stereo"
        case .splitToMono:
            return "Split to Mono"
        case .swapChannels:
            return "Swap L/R"
        case .extractChannel(_, _, let name):
            return "Extract \(name)"
        }
    }
}

// MARK: - Audio Routing Configuration

/// Audio routing configuration for a video item
struct AudioRoutingConfig: Equatable, Sendable {
    /// Source tracks available in the input file
    let inputTracks: [AudioTrackInfo]

    /// Selected output tracks in desired order (supports duplicates with per-track options)
    var outputTracks: [OutputTrack]

    /// Optional channel-level operation (overrides simple track mapping)
    var channelOperation: ChannelOperation? = nil

    init(inputTracks: [AudioTrackInfo], outputTracks: [OutputTrack]? = nil) {
        self.inputTracks = inputTracks
        // Default: include all tracks in original order
        self.outputTracks = outputTracks ?? inputTracks.map { OutputTrack(streamIndex: $0.streamIndex) }
    }

    /// Backward-compatible initializer that takes stream indices
    init(inputTracks: [AudioTrackInfo], outputTrackIndices: [Int]) {
        self.inputTracks = inputTracks
        self.outputTracks = outputTrackIndices.map { OutputTrack(streamIndex: $0) }
    }

    /// Computed property for backward compatibility - returns stream indices in order
    var outputTrackIndices: [Int] {
        outputTracks.map(\.streamIndex)
    }

    /// Returns true if configuration differs from default (all tracks in order, no downmix)
    var isCustomized: Bool {
        let defaultOrder = inputTracks.map(\.streamIndex)
        let hasDownmix = outputTracks.contains { $0.downmixToStereo }
        let hasDuplicates = outputTracks.count != Set(outputTrackIndices).count
        return outputTrackIndices != defaultOrder || channelOperation != nil || hasDownmix || hasDuplicates
    }

    /// Returns true if a channel operation is active
    var hasChannelOperation: Bool {
        channelOperation != nil
    }

    /// Returns true if any input track has surround audio (more than 2 channels)
    var hasAnyInputSurroundTracks: Bool {
        inputTracks.contains { $0.isSurround }
    }

    /// Returns true if any output track has surround audio without downmix
    var hasOutputSurroundWithoutDownmix: Bool {
        outputTracks.contains { outputTrack in
            guard let info = trackInfo(for: outputTrack.streamIndex) else { return false }
            return info.isSurround && !outputTrack.downmixToStereo
        }
    }

    /// Reset to default configuration (all tracks in original order, no operations)
    mutating func resetToDefault() {
        outputTracks = inputTracks.map { OutputTrack(streamIndex: $0.streamIndex) }
        channelOperation = nil
    }

    /// Add a track to output by stream index (allows duplicates)
    mutating func addTrack(_ streamIndex: Int, downmixToStereo: Bool = false) {
        outputTracks.append(OutputTrack(streamIndex: streamIndex, downmixToStereo: downmixToStereo))
        // Clear channel operation when manually adjusting tracks
        channelOperation = nil
    }

    /// Remove a track from output by its unique ID
    mutating func removeTrack(id: UUID) {
        outputTracks.removeAll { $0.id == id }
        // Clear channel operation when manually adjusting tracks
        channelOperation = nil
    }

    /// Remove a track from output by stream index (removes first occurrence only, for backward compatibility)
    mutating func removeTrack(_ streamIndex: Int) {
        if let index = outputTracks.firstIndex(where: { $0.streamIndex == streamIndex }) {
            outputTracks.remove(at: index)
        }
        // Clear channel operation when manually adjusting tracks
        channelOperation = nil
    }

    /// Move a track from one position to another in output
    mutating func moveTrack(from sourceIndex: Int, to destinationIndex: Int) {
        guard outputTracks.indices.contains(sourceIndex),
              outputTracks.indices.contains(destinationIndex) else {
            return
        }
        let track = outputTracks.remove(at: sourceIndex)
        outputTracks.insert(track, at: destinationIndex)
        // Clear channel operation when manually reordering tracks
        channelOperation = nil
    }

    /// Toggle downmix setting for a specific output track
    mutating func toggleDownmix(for trackId: UUID) {
        if let index = outputTracks.firstIndex(where: { $0.id == trackId }) {
            outputTracks[index].downmixToStereo.toggle()
        }
    }

    /// Set downmix setting for a specific output track
    mutating func setDownmix(for trackId: UUID, downmix: Bool) {
        if let index = outputTracks.firstIndex(where: { $0.id == trackId }) {
            outputTracks[index].downmixToStereo = downmix
        }
    }

    /// Set or clear the manual MCA-label override on a specific output track.
    /// Pass nil (or an empty override) to remove the override.
    mutating func setMCAOverride(_ override: MCALabelOverride?, for trackId: UUID) {
        guard let index = outputTracks.firstIndex(where: { $0.id == trackId }) else { return }
        if let override, !override.isEmpty {
            outputTracks[index].mcaOverride = override
        } else {
            outputTracks[index].mcaOverride = nil
        }
    }

    /// Set a channel operation (clears any existing operation)
    mutating func setChannelOperation(_ operation: ChannelOperation) {
        channelOperation = operation
    }

    /// Clear the active channel operation
    mutating func clearChannelOperation() {
        channelOperation = nil
    }

    /// Get track info for a given stream index
    func trackInfo(for streamIndex: Int) -> AudioTrackInfo? {
        inputTracks.first { $0.streamIndex == streamIndex }
    }

    /// Get ordered output tracks with full info (for backward compatibility)
    var outputTracksInfo: [AudioTrackInfo] {
        outputTracks.compactMap { outputTrack in
            inputTracks.first { $0.streamIndex == outputTrack.streamIndex }
        }
    }
}

// MARK: - Codable Conformance with Migration Support

extension AudioRoutingConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case inputTracks
        case outputTracks
        case outputTrackIndices // Legacy key for backward compatibility
        case channelOperation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTracks = try container.decode([AudioTrackInfo].self, forKey: .inputTracks)
        channelOperation = try container.decodeIfPresent(ChannelOperation.self, forKey: .channelOperation)

        // Only migrate an absent schema key. A damaged modern route must not
        // silently restore legacy tracks or default to every source track.
        if container.contains(.outputTracks) {
            outputTracks = try container.decode([OutputTrack].self, forKey: .outputTracks)
        } else if container.contains(.outputTrackIndices) {
            let indices = try container.decode([Int].self, forKey: .outputTrackIndices)
            // Migrate from legacy format (outputTrackIndices as [Int])
            outputTracks = indices.map { OutputTrack(streamIndex: $0) }
        } else {
            // Fallback: default to all input tracks
            outputTracks = inputTracks.map { OutputTrack(streamIndex: $0.streamIndex) }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inputTracks, forKey: .inputTracks)
        try container.encode(outputTracks, forKey: .outputTracks)
        try container.encodeIfPresent(channelOperation, forKey: .channelOperation)
    }
}
