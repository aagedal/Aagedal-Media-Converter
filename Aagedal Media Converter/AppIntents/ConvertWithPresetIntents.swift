// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import AppIntents
import UniformTypeIdentifiers
import Foundation

// MARK: - Per-preset "Convert Immediately" intents
//
// These intents mirror `ConvertImmediatelyIntent`, but each one targets a
// specific built-in `ExportPreset` instead of relying on whatever preset is
// currently selected in the running app's UI. Each becomes its own action in
// the Shortcuts app (e.g. "Convert to ProRes", "Convert to H.265 / HEVC"),
// so a user can build a one-tap shortcut for a particular output format.
//
// Custom presets (Custom 1–10) are intentionally excluded: their names are
// user-defined and empty by default, so a static action title would be blank.
//
// Like `ConvertImmediatelyIntent`, these hand the files off to the running app
// via a `NotificationCenter` broadcast; the app must be running to receive it.

/// Shared implementation for every per-preset convert-immediately intent.
///
/// Conformers only declare their `preset`, `title`, `description`, the `videos`
/// parameter, and a `parameterSummary`; `perform()` is provided here so the
/// hand-off logic lives in exactly one place.
protocol ConvertWithPresetIntent: AppIntent {
    /// The export preset this intent encodes to.
    static var preset: ExportPreset { get }

    /// The video files the user passes in from the Shortcuts action.
    var videos: [IntentFile] { get }
}

extension ConvertWithPresetIntent {
    /// Launch the app when the intent runs from a closed state, so a Shortcut /
    /// Spotlight invocation converts even if the app wasn't already open. The
    /// hand-off is buffered (see ``PendingAppIntentRequests``) to survive the
    /// window not being ready yet at launch.
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        let urls = videos.compactMap { $0.fileURL }
        let presetRawValue = Self.preset.rawValue
        let requestID = UUID()

        // No file input (e.g. invoked from a Spotlight/Siri phrase, which can't
        // attach files): open the app, switch to this preset, and let the user
        // pick files in the importer; conversion starts once they choose.
        guard let firstURL = urls.first else {
            await MainActor.run {
                PendingAppIntentRequests.shared.submit(
                    name: .convertPickFiles,
                    object: nil,
                    userInfo: [
                        "presetRawValue": presetRawValue,
                        PendingAppIntentRequests.requestIDKey: requestID
                    ]
                )
            }
            return .result()
        }

        // Use the folder of the first file as the output folder, matching
        // `ConvertImmediatelyIntent`. The carried preset raw value tells the
        // running app which preset to switch to before starting conversion.
        let folder = firstURL.deletingLastPathComponent()
        await MainActor.run {
            PendingAppIntentRequests.shared.submit(
                name: .convertImmediately,
                object: nil,
                userInfo: [
                    "fileURLs": urls,
                    "outputFolderURL": folder,
                    "presetRawValue": presetRawValue,
                    PendingAppIntentRequests.requestIDKey: requestID
                ]
            )
        }
        return .result()
    }
}

// MARK: - Concrete intents (one per built-in preset)

struct ConvertToVideoLoopIntent: ConvertWithPresetIntent {
    static let preset: ExportPreset = .videoLoop
    static let title: LocalizedStringResource = "Convert to VideoLoop"
    static let description = IntentDescription("Encode the selected videos to a muted, looping MP4 (VideoLoop preset), saving alongside the source files and starting conversion immediately.")

    @Parameter(title: "Video Files", supportedContentTypes: [.movie])
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$videos) to VideoLoop")
    }
}

struct ConvertToVideoLoopWithSoundIntent: ConvertWithPresetIntent {
    static let preset: ExportPreset = .videoLoopWithSound
    static let title: LocalizedStringResource = "Convert to VideoLoop with Sound"
    static let description = IntentDescription("Encode the selected videos to a looping MP4 with audio (VideoLoop with sound preset), saving alongside the source files and starting conversion immediately.")

    @Parameter(title: "Video Files", supportedContentTypes: [.movie])
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$videos) to VideoLoop with sound")
    }
}

struct ConvertToAnimatedStillIntent: ConvertWithPresetIntent {
    static let preset: ExportPreset = .animatedStill
    static let title: LocalizedStringResource = "Convert to Animated Still"
    static let description = IntentDescription("Encode the selected videos to an animated still (AVIF/GIF/APNG, per your Animated Still settings), saving alongside the source files and starting conversion immediately.")

    @Parameter(title: "Video Files", supportedContentTypes: [.movie])
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$videos) to an animated still")
    }
}

struct ConvertToH264Intent: ConvertWithPresetIntent {
    static let preset: ExportPreset = .h264
    static let title: LocalizedStringResource = "Convert to H.264 / AVC"
    static let description = IntentDescription("Encode the selected videos with the H.264 / AVC preset, saving alongside the source files and starting conversion immediately.")

    @Parameter(title: "Video Files", supportedContentTypes: [.movie])
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$videos) to H.264 / AVC")
    }
}

struct ConvertToH265Intent: ConvertWithPresetIntent {
    static let preset: ExportPreset = .h265
    static let title: LocalizedStringResource = "Convert to H.265 / HEVC"
    static let description = IntentDescription("Encode the selected videos with the H.265 / HEVC preset, saving alongside the source files and starting conversion immediately.")

    @Parameter(title: "Video Files", supportedContentTypes: [.movie])
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$videos) to H.265 / HEVC")
    }
}

struct ConvertToAV1Intent: ConvertWithPresetIntent {
    static let preset: ExportPreset = .av1
    static let title: LocalizedStringResource = "Convert to AV1"
    static let description = IntentDescription("Encode the selected videos with the AV1 preset, saving alongside the source files and starting conversion immediately.")

    @Parameter(title: "Video Files", supportedContentTypes: [.movie])
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$videos) to AV1")
    }
}

struct ConvertToAV2Intent: ConvertWithPresetIntent {
    static let preset: ExportPreset = .av2
    static let title: LocalizedStringResource = "Convert to AV2 (Experimental)"
    static let description = IntentDescription("Encode the selected videos with the experimental AV2 preset, saving alongside the source files and starting conversion immediately. AV2 output needs an AV2-capable decoder to play back.")

    @Parameter(title: "Video Files", supportedContentTypes: [.movie])
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$videos) to AV2")
    }
}

struct ConvertToTVHEVCIntent: ConvertWithPresetIntent {
    static let preset: ExportPreset = .tvHEVC
    static let title: LocalizedStringResource = "Convert to TV (HEVC 10-bit 4:2:2)"
    static let description = IntentDescription("Encode the selected videos with the broadcast TV HEVC 10-bit 4:2:2 preset, saving alongside the source files and starting conversion immediately.")

    @Parameter(title: "Video Files", supportedContentTypes: [.movie])
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$videos) to TV (HEVC 10-bit 4:2:2)")
    }
}

struct ConvertToTVAVCIntraIntent: ConvertWithPresetIntent {
    static let preset: ExportPreset = .tvAVCIntra
    static let title: LocalizedStringResource = "Convert to TV (AVC-Intra MXF)"
    static let description = IntentDescription("Encode the selected videos with the broadcast TV AVC-Intra MXF preset, saving alongside the source files and starting conversion immediately.")

    @Parameter(title: "Video Files", supportedContentTypes: [.movie])
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$videos) to TV (AVC-Intra MXF)")
    }
}

struct ConvertToProResIntent: ConvertWithPresetIntent {
    static let preset: ExportPreset = .prores
    static let title: LocalizedStringResource = "Convert to ProRes"
    static let description = IntentDescription("Encode the selected videos with the ProRes preset, saving alongside the source files and starting conversion immediately.")

    @Parameter(title: "Video Files", supportedContentTypes: [.movie])
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$videos) to ProRes")
    }
}

struct ConvertToProxyIntent: ConvertWithPresetIntent {
    static let preset: ExportPreset = .proxy
    static let title: LocalizedStringResource = "Convert to Proxy"
    static let description = IntentDescription("Encode the selected videos with the Proxy preset (lightweight editing proxies), saving alongside the source files and starting conversion immediately.")

    @Parameter(title: "Video Files", supportedContentTypes: [.movie])
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$videos) to Proxy")
    }
}

struct ConvertToStreamCopyIntent: ConvertWithPresetIntent {
    static let preset: ExportPreset = .streamCopy
    static let title: LocalizedStringResource = "Remux (Stream Copy)"
    static let description = IntentDescription("Remux the selected videos with the Stream Copy preset (no re-encoding), saving alongside the source files and starting conversion immediately.")

    @Parameter(title: "Video Files", supportedContentTypes: [.movie])
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Remux \(\.$videos) (stream copy)")
    }
}

struct ConvertToAudioOnlyIntent: ConvertWithPresetIntent {
    static let preset: ExportPreset = .audioOnly
    static let title: LocalizedStringResource = "Extract Audio Only"
    static let description = IntentDescription("Extract audio from the selected videos with the Audio Only preset (WAV/AAC/FLAC, per your settings), saving alongside the source files and starting conversion immediately.")

    @Parameter(title: "Video Files", supportedContentTypes: [.movie])
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Extract audio from \(\.$videos)")
    }
}

struct ConvertToImageSequenceIntent: ConvertWithPresetIntent {
    static let preset: ExportPreset = .imageSequence
    static let title: LocalizedStringResource = "Convert to Image Sequence"
    static let description = IntentDescription("Encode the selected videos to an image sequence (per your Image Sequence settings), saving alongside the source files and starting conversion immediately.")

    @Parameter(title: "Video Files", supportedContentTypes: [.movie])
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$videos) to an image sequence")
    }
}

struct ConvertToDCPIntent: ConvertWithPresetIntent {
    static let preset: ExportPreset = .dcp
    static let title: LocalizedStringResource = "Convert to DCP"
    static let description = IntentDescription("Encode the selected videos with the DCP (Digital Cinema Package) preset, saving alongside the source files and starting conversion immediately.")

    @Parameter(title: "Video Files", supportedContentTypes: [.movie])
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$videos) to DCP")
    }
}

struct ConvertToIMFJ2KIntent: ConvertWithPresetIntent {
    static let preset: ExportPreset = .imfJ2K
    static let title: LocalizedStringResource = "Convert to IMF (App 2e — JPEG 2000)"
    static let description = IntentDescription("Encode the selected videos with the IMF App 2e (JPEG 2000) preset, saving alongside the source files and starting conversion immediately.")

    @Parameter(title: "Video Files", supportedContentTypes: [.movie])
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$videos) to IMF (JPEG 2000)")
    }
}

struct ConvertToIMFProResIntent: ConvertWithPresetIntent {
    static let preset: ExportPreset = .imfProRes
    static let title: LocalizedStringResource = "Convert to IMF (RDD 45 — ProRes)"
    static let description = IntentDescription("Encode the selected videos with the experimental IMF RDD 45 (ProRes) preset, saving alongside the source files and starting conversion immediately.")

    @Parameter(title: "Video Files", supportedContentTypes: [.movie])
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$videos) to IMF (ProRes)")
    }
}

// MARK: - Default-preset intent
//
// Unlike the fixed per-preset intents above, this one resolves whatever preset
// the user has set as the app default (Settings → default preset) at the moment
// it runs. Because the default can be any preset — including a user-defined
// Custom slot — this is the way to drive a Custom preset from Shortcuts /
// Spotlight, which can't expose Custom presets as their own static actions.

struct ConvertWithDefaultPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert with Default Preset"
    static let description = IntentDescription("Encode the selected videos using your default preset (set in Settings — can be any preset, including a Custom one), saving alongside the source files and starting conversion immediately.")

    /// Launch the app if it isn't already running so the conversion still happens.
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Video Files", supportedContentTypes: [.movie])
    var videos: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Convert \(\.$videos) with the default preset")
    }

    func perform() async throws -> some IntentResult {
        let urls = videos.compactMap { $0.fileURL }

        // Resolve the user's configured default preset (falls back to VideoLoop,
        // matching the app's @AppStorage default).
        let defaultRawValue = UserDefaults.standard.string(forKey: AppConstants.defaultPresetKey)
            ?? ExportPreset.videoLoop.rawValue
        let presetRawValue = ExportPreset(rawValue: defaultRawValue)?.rawValue
            ?? ExportPreset.videoLoop.rawValue
        let requestID = UUID()

        // No file input (e.g. invoked from a Spotlight/Siri phrase, which can't
        // attach files): open the app, switch to the default preset, and let the
        // user pick files in the importer; conversion starts once they choose.
        guard let firstURL = urls.first else {
            await MainActor.run {
                PendingAppIntentRequests.shared.submit(
                    name: .convertPickFiles,
                    object: nil,
                    userInfo: [
                        "presetRawValue": presetRawValue,
                        PendingAppIntentRequests.requestIDKey: requestID
                    ]
                )
            }
            return .result()
        }

        let folder = firstURL.deletingLastPathComponent()
        await MainActor.run {
            PendingAppIntentRequests.shared.submit(
                name: .convertImmediately,
                object: nil,
                userInfo: [
                    "fileURLs": urls,
                    "outputFolderURL": folder,
                    "presetRawValue": presetRawValue,
                    PendingAppIntentRequests.requestIDKey: requestID
                ]
            )
        }
        return .result()
    }
}

// MARK: - App Shortcuts (Spotlight / Siri discoverability)
//
// `AppShortcutsProvider` surfaces zero-setup actions in Spotlight and Siri.
// Apple caps this at 10 App Shortcuts per app, so we expose the 10 most common
// presets here. Every intent — including the niche ones not listed below
// (AV2, TV, Image Sequence, DCP, IMF) — is still fully available in the
// Shortcuts app; the cap only limits the Spotlight/Siri surface.
struct MediaConverterAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConvertWithDefaultPresetIntent(),
            phrases: [
                "Convert with \(.applicationName)",
                "Convert with the default preset in \(.applicationName)"
            ],
            shortTitle: "Convert (Default Preset)",
            systemImageName: "wand.and.stars"
        )
        AppShortcut(
            intent: ConvertToVideoLoopIntent(),
            phrases: [
                "Convert to VideoLoop with \(.applicationName)",
                "Make a VideoLoop in \(.applicationName)"
            ],
            shortTitle: "Convert to VideoLoop",
            systemImageName: "repeat"
        )
        AppShortcut(
            intent: ConvertToH264Intent(),
            phrases: [
                "Convert to H.264 with \(.applicationName)",
                "Encode H.264 in \(.applicationName)"
            ],
            shortTitle: "Convert to H.264",
            systemImageName: "film"
        )
        AppShortcut(
            intent: ConvertToH265Intent(),
            phrases: [
                "Convert to H.265 with \(.applicationName)",
                "Encode HEVC in \(.applicationName)"
            ],
            shortTitle: "Convert to H.265",
            systemImageName: "film"
        )
        AppShortcut(
            intent: ConvertToAV1Intent(),
            phrases: [
                "Convert to AV1 with \(.applicationName)",
                "Encode AV1 in \(.applicationName)"
            ],
            shortTitle: "Convert to AV1",
            systemImageName: "film"
        )
        AppShortcut(
            intent: ConvertToProResIntent(),
            phrases: [
                "Convert to ProRes with \(.applicationName)",
                "Encode ProRes in \(.applicationName)"
            ],
            shortTitle: "Convert to ProRes",
            systemImageName: "film.stack"
        )
        AppShortcut(
            intent: ConvertToProxyIntent(),
            phrases: [
                "Convert to a proxy with \(.applicationName)",
                "Make editing proxies in \(.applicationName)"
            ],
            shortTitle: "Convert to Proxy",
            systemImageName: "rectangle.compress.vertical"
        )
        AppShortcut(
            intent: ConvertToStreamCopyIntent(),
            phrases: [
                "Remux with \(.applicationName)",
                "Stream copy in \(.applicationName)"
            ],
            shortTitle: "Remux (Stream Copy)",
            systemImageName: "doc.on.doc"
        )
        AppShortcut(
            intent: ConvertToAudioOnlyIntent(),
            phrases: [
                "Extract audio with \(.applicationName)",
                "Convert to audio only in \(.applicationName)"
            ],
            shortTitle: "Extract Audio",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: ConvertToAnimatedStillIntent(),
            phrases: [
                "Convert to an animated still with \(.applicationName)",
                "Make an animated still in \(.applicationName)"
            ],
            shortTitle: "Animated Still",
            systemImageName: "photo.stack"
        )
    }
}
