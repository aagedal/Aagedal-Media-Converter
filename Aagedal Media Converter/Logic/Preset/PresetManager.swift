// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI

/// Manages preset selection, visibility, and custom preset naming.
/// Extracted from ContentView to reduce complexity and centralize preset logic.
@MainActor
@Observable
final class PresetManager {
    static let shared = PresetManager()

    // MARK: - Current Selection State

    var selectedPreset: ExportPreset = .videoLoop
    var hasUserChangedPreset: Bool = false

    // MARK: - Custom Preset Names (synced with UserDefaults)

    private var customPresetNames: [String]

    // MARK: - Built-in Preset Visibility

    private var videoLoopVisible: Bool
    private var videoLoopWithSoundVisible: Bool
    private var animatedStillVisible: Bool
    private var h264Visible: Bool
    private var h265Visible: Bool
    private var av1Visible: Bool
    private var av2Visible: Bool
    private var tvHEVCVisible: Bool
    private var tvAVCIntraVisible: Bool
    private var losslessVisible: Bool
    private var proresVisible: Bool
    private var proxyVisible: Bool
    private var streamCopyVisible: Bool
    private var audioOnlyVisible: Bool
    private var imageSequenceVisible: Bool
    private var dcpVisible: Bool
    private var imfJ2KVisible: Bool
    private var imfProResVisible: Bool

    // MARK: - Custom Preset Activation

    private var customPresetActives: [Bool]

    // MARK: - Initialization

    private init() {
        let defaults = UserDefaults.standard

        // Load custom preset names and activation states
        customPresetNames = (0..<10).map { slot in
            defaults.string(forKey: AppConstants.customPresetNameKey(for: slot))
                ?? AppConstants.defaultCustomPresetDisplayNames[slot]
        }
        customPresetActives = (0..<10).map { slot in
            defaults.bool(forKey: AppConstants.customPresetActiveKey(for: slot))
        }

        // Load built-in preset visibility (default to true if not set)
        videoLoopVisible = defaults.object(forKey: AppConstants.videoLoopVisibleKey) as? Bool ?? true
        videoLoopWithSoundVisible = defaults.object(forKey: AppConstants.videoLoopWithSoundVisibleKey) as? Bool ?? true
        animatedStillVisible = defaults.object(forKey: AppConstants.animatedStillVisibleKey) as? Bool ?? true
        h264Visible = defaults.object(forKey: AppConstants.h264VisibleKey) as? Bool ?? true
        h265Visible = defaults.object(forKey: AppConstants.h265VisibleKey) as? Bool ?? true
        av1Visible = defaults.object(forKey: AppConstants.av1VisibleKey) as? Bool ?? true
        av2Visible = defaults.object(forKey: AppConstants.av2VisibleKey) as? Bool ?? true
        tvHEVCVisible = defaults.object(forKey: AppConstants.tvHEVCVisibleKey) as? Bool ?? true
        tvAVCIntraVisible = defaults.object(forKey: AppConstants.tvAVCIntraVisibleKey) as? Bool ?? true
        losslessVisible = defaults.object(forKey: AppConstants.losslessVisibleKey) as? Bool ?? true
        proresVisible = defaults.object(forKey: AppConstants.proresVisibleKey) as? Bool ?? true
        proxyVisible = defaults.object(forKey: AppConstants.proxyVisibleKey) as? Bool ?? true
        streamCopyVisible = defaults.object(forKey: AppConstants.streamCopyVisibleKey) as? Bool ?? true
        audioOnlyVisible = defaults.object(forKey: AppConstants.audioOnlyVisibleKey) as? Bool ?? true
        imageSequenceVisible = defaults.object(forKey: AppConstants.imageSequenceVisibleKey) as? Bool ?? true
        dcpVisible = defaults.object(forKey: AppConstants.dcpVisibleKey) as? Bool ?? true
        imfJ2KVisible = defaults.object(forKey: AppConstants.imfJ2KVisibleKey) as? Bool ?? true
        imfProResVisible = defaults.object(forKey: AppConstants.imfProResVisibleKey) as? Bool ?? true

        // Observe UserDefaults changes for reactive updates
        setupObservers()
    }

    // MARK: - Public API

    /// Returns the list of presets currently visible in the picker
    var visiblePresets: [ExportPreset] {
        ExportPreset.allCases.filter { preset in
            switch preset {
            case .videoLoop: return videoLoopVisible
            case .videoLoopWithSound: return videoLoopWithSoundVisible
            case .animatedStill: return animatedStillVisible
            case .h264: return h264Visible
            case .h265: return h265Visible
            case .av1: return av1Visible
            case .av2: return av2Visible
            case .tvHEVC: return tvHEVCVisible
            case .tvAVCIntra: return tvAVCIntraVisible
            case .lossless: return losslessVisible
            case .prores: return proresVisible
            case .proxy: return proxyVisible
            case .streamCopy: return streamCopyVisible
            case .audioOnly: return audioOnlyVisible
            case .imageSequence: return imageSequenceVisible
            case .dcp: return dcpVisible
            case .imfJ2K: return imfJ2KVisible
            case .imfProRes: return imfProResVisible
            case .custom1, .custom2, .custom3, .custom4, .custom5,
                 .custom6, .custom7, .custom8, .custom9, .custom10:
                if let slot = preset.customSlotIndex, customPresetActives.indices.contains(slot) {
                    return customPresetActives[slot]
                }
                return false
            }
        }
    }

    /// Returns the display name for a preset, using stored custom names for custom presets
    func displayName(for preset: ExportPreset) -> String {
        guard let slot = preset.customSlotIndex else {
            return preset.displayName
        }
        let prefixes = AppConstants.customPresetPrefixes
        let fallbackSuffixes = AppConstants.defaultCustomPresetNameSuffixes
        let prefix = prefixes.indices.contains(slot) ? prefixes[slot] : "C\(slot + 1):"
        let fallbackSuffix = fallbackSuffixes.indices.contains(slot) ? fallbackSuffixes[slot] : "Custom Preset"
        let storedSuffix = customPresetNames.indices.contains(slot) ? customPresetNames[slot] : fallbackSuffix
        let sanitizedSuffix = sanitizeCustomNameSuffix(storedSuffix, prefix: prefix, fallback: fallbackSuffix)
        return "\(prefix) \(sanitizedSuffix)"
    }

    /// Loads the default preset from UserDefaults
    func loadDefaultPreset() -> ExportPreset {
        let rawValue = UserDefaults.standard.string(forKey: AppConstants.defaultPresetKey) ?? ExportPreset.videoLoop.rawValue
        return ExportPreset(rawValue: rawValue) ?? .videoLoop
    }

    /// Applies auto-mute settings when switching between presets
    /// - Parameters:
    ///   - items: The video items to modify
    ///   - oldPreset: The previous preset
    ///   - newPreset: The new preset being selected
    ///   - videoLoopDefaultMuted: Whether VideoLoop defaults to muted
    func applyAutoMuteSettings(
        to items: inout [VideoItem],
        oldPreset: ExportPreset,
        newPreset: ExportPreset,
        videoLoopDefaultMuted: Bool
    ) {
        // Auto-mute items when switching to VideoLoop preset if the setting is enabled
        if newPreset == .videoLoop && videoLoopDefaultMuted {
            for index in items.indices where items[index].status == .waiting {
                items[index].isMuted = true
            }
        }
        // Auto-unmute items when switching away from VideoLoop
        else if oldPreset == .videoLoop && newPreset != .videoLoop {
            for index in items.indices where items[index].status == .waiting {
                items[index].isMuted = false
            }
        }
    }

    /// Reloads visibility settings from UserDefaults
    /// Call this after settings are changed in the Settings view
    func reloadVisibilitySettings() {
        let defaults = UserDefaults.standard

        videoLoopVisible = defaults.object(forKey: AppConstants.videoLoopVisibleKey) as? Bool ?? true
        videoLoopWithSoundVisible = defaults.object(forKey: AppConstants.videoLoopWithSoundVisibleKey) as? Bool ?? true
        animatedStillVisible = defaults.object(forKey: AppConstants.animatedStillVisibleKey) as? Bool ?? true
        h264Visible = defaults.object(forKey: AppConstants.h264VisibleKey) as? Bool ?? true
        h265Visible = defaults.object(forKey: AppConstants.h265VisibleKey) as? Bool ?? true
        av1Visible = defaults.object(forKey: AppConstants.av1VisibleKey) as? Bool ?? true
        av2Visible = defaults.object(forKey: AppConstants.av2VisibleKey) as? Bool ?? true
        tvHEVCVisible = defaults.object(forKey: AppConstants.tvHEVCVisibleKey) as? Bool ?? true
        tvAVCIntraVisible = defaults.object(forKey: AppConstants.tvAVCIntraVisibleKey) as? Bool ?? true
        losslessVisible = defaults.object(forKey: AppConstants.losslessVisibleKey) as? Bool ?? true
        proresVisible = defaults.object(forKey: AppConstants.proresVisibleKey) as? Bool ?? true
        proxyVisible = defaults.object(forKey: AppConstants.proxyVisibleKey) as? Bool ?? true
        streamCopyVisible = defaults.object(forKey: AppConstants.streamCopyVisibleKey) as? Bool ?? true
        audioOnlyVisible = defaults.object(forKey: AppConstants.audioOnlyVisibleKey) as? Bool ?? true
        imageSequenceVisible = defaults.object(forKey: AppConstants.imageSequenceVisibleKey) as? Bool ?? true
        dcpVisible = defaults.object(forKey: AppConstants.dcpVisibleKey) as? Bool ?? true
        imfJ2KVisible = defaults.object(forKey: AppConstants.imfJ2KVisibleKey) as? Bool ?? true
        imfProResVisible = defaults.object(forKey: AppConstants.imfProResVisibleKey) as? Bool ?? true

        customPresetActives = (0..<10).map { slot in
            defaults.bool(forKey: AppConstants.customPresetActiveKey(for: slot))
        }
    }

    /// Reloads custom preset names from UserDefaults
    func reloadCustomPresetNames() {
        let defaults = UserDefaults.standard
        customPresetNames = (0..<10).map { slot in
            defaults.string(forKey: AppConstants.customPresetNameKey(for: slot))
                ?? AppConstants.defaultCustomPresetDisplayNames[slot]
        }
    }

    // MARK: - Private Helpers

    private func sanitizeCustomNameSuffix(_ value: String, prefix: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        if trimmed.lowercased().hasPrefix(prefix.lowercased()) {
            let cutoff = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            let remainder = trimmed[cutoff...].trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? fallback : remainder
        }
        if let colonIndex = trimmed.firstIndex(of: ":") {
            let remainder = trimmed[trimmed.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? fallback : remainder
        }
        return trimmed
    }

    private func setupObservers() {
        // Observe UserDefaults changes to keep visibility in sync
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadVisibilitySettings()
                self?.reloadCustomPresetNames()
            }
        }
    }
}
