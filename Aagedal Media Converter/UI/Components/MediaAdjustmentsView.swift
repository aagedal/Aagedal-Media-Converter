// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import UniformTypeIdentifiers

/// Per-item rotation, speed, fades, audio offset/replacement, burned-in subtitles
/// and loudness override.
struct MediaAdjustmentsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var item: VideoItem
    let preset: ExportPreset

    @State private var draft = MediaAdjustments()

    private enum SubtitleChoice: Hashable {
        case none
        case embedded(Int)
        case file
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let reason = unsupportedReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Form {
                pictureSection
                timingSection
                audioSection
                subtitleSection
                loudnessSection
            }
            .formStyle(.grouped)
            footer
        }
        .padding(20)
        .frame(width: 560, height: 640)
        .onAppear { draft = item.adjustments ?? MediaAdjustments() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("File Adjustments")
                    .font(.title)
                    .fontWeight(.semibold)
                Text(item.name)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.secondary.opacity(0.7), .secondary.opacity(0.25))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close adjustments without saving")
            .keyboardShortcut(.escape, modifiers: [])
        }
    }

    private var footer: some View {
        HStack {
            Button("Reset All") { draft = MediaAdjustments() }
                .disabled(!draft.isActive)
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Apply") {
                item.adjustments = draft.isActive ? draft : nil
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Sections

    private var pictureSection: some View {
        Section("Picture") {
            Picker("Rotation", selection: $draft.rotation) {
                ForEach(MediaAdjustments.Rotation.allCases) { rotation in
                    Text(rotation.displayName).tag(rotation)
                }
            }
            Toggle("Flip horizontally", isOn: $draft.flipHorizontal)
            Toggle("Flip vertically", isOn: $draft.flipVertical)
            secondsField("Fade in from black", value: $draft.videoFadeIn)
            secondsField("Fade out to black", value: $draft.videoFadeOut)
        }
    }

    private var timingSection: some View {
        Section {
            HStack {
                Text("Speed")
                Slider(value: $draft.speed, in: MediaAdjustments.minimumSpeed...MediaAdjustments.maximumSpeed)
                TextField("Speed", value: speedBinding, format: .number.precision(.fractionLength(0...2)))
                    .labelsHidden()
                    .frame(width: 56)
                    .multilineTextAlignment(.trailing)
                Text(verbatim: "×")
            }
            HStack {
                ForEach([0.5, 1, 1.5, 2], id: \.self) { value in
                    Button(String("\(value.formatted())×")) { draft.speed = value }
                        .controlSize(.small)
                }
            }
        } header: {
            Text("Speed")
        } footer: {
            Text("Audio keeps its pitch. Soft subtitles are left out when the speed changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var audioSection: some View {
        Section {
            secondsField("Audio fade in", value: $draft.audioFadeIn)
            secondsField("Audio fade out", value: $draft.audioFadeOut)
            HStack {
                Text("Audio offset")
                Spacer()
                TextField("Offset", value: $draft.audioOffset, format: .number.precision(.fractionLength(0...3)))
                    .labelsHidden()
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                Text(verbatim: "s")
            }
            HStack {
                Text("Replacement audio")
                Spacer()
                if let replacement = draft.replacementAudio {
                    Text(replacement.url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Remove") { draft.replacementAudio = nil }
                }
                Button(draft.replacementAudio == nil ? "Choose…" : "Change…") { chooseReplacementAudio() }
            }
            if draft.replacementAudio != nil {
                Picker("Mode", selection: replacementModeBinding) {
                    ForEach(MediaAdjustments.AudioReplacementMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
        } header: {
            Text("Audio")
        } footer: {
            Text("A positive offset delays the audio; a negative one plays it earlier. Replacement audio starts with the source, honours the trim, and is padded or cut to the video's length. Replacing audio ignores Audio Routing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var subtitleSection: some View {
        Section {
            Picker("Burn in", selection: subtitleChoiceBinding) {
                Text("None").tag(SubtitleChoice.none)
                ForEach(Array(subtitleStreams.enumerated()), id: \.offset) { index, stream in
                    Text(subtitleLabel(stream, index: index)).tag(SubtitleChoice.embedded(index))
                        .disabled(isBitmap(stream))
                }
                Text(subtitleFileLabel).tag(SubtitleChoice.file)
            }
            if draft.burnInSubtitles != nil {
                Stepper(value: subtitleBinding(\.fontSize), in: 10...60) {
                    Text("Font size: \(draft.burnInSubtitles?.fontSize ?? 20)")
                }
                Toggle("Background box", isOn: subtitleBinding(\.backgroundBox))
                Picker("Position", selection: subtitleBinding(\.position)) {
                    ForEach(MediaAdjustments.SubtitlePosition.allCases) { position in
                        Text(position.displayName).tag(position)
                    }
                }
            }
        } header: {
            Text("Subtitle Burn-in")
        } footer: {
            Text("SRT, VTT and text tracks use the style above; ASS/SSA keep their own styling. Picture subtitles (PGS, DVD) must be converted to SRT with subtitle OCR first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var loudnessSection: some View {
        Section {
            Picker("Normalize loudness", selection: $draft.loudness) {
                Text("Use default (\(globalLoudnessSummary))").tag(MediaAdjustments.LoudnessOverride.useDefault)
                Text("On").tag(MediaAdjustments.LoudnessOverride.on)
                Text("Off").tag(MediaAdjustments.LoudnessOverride.off)
            }
        } header: {
            Text("Loudness")
        } footer: {
            Text("The target is set in Settings → Presets. Each track is measured first, then normalized in a second pass.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var unsupportedReason: String? {
        FFMPEGCommandBuilder.adjustmentsUnsupportedReason(
            preset: preset, codecSettings: nil,
            customInputArguments: item.imageSequenceConfig?.ffmpegInputArguments,
            generatesVideo: !item.hasVideoStream && preset.outputsVideoTrack
        )
    }

    private var globalLoudnessSummary: String {
        let settings = LoudnessNormalizationSettings(defaults: .standard)
        guard settings.enabled else { return String(localized: "Off") }
        return "\(MediaAdjustmentsPlan.number(settings.integrated)) LUFS"
    }

    private var subtitleStreams: [VideoMetadata.SubtitleStream] { item.metadata?.subtitleStreams ?? [] }

    private func isBitmap(_ stream: VideoMetadata.SubtitleStream) -> Bool {
        MediaAdjustmentsPlan.bitmapSubtitleCodecs.contains(stream.codec?.lowercased() ?? "")
    }

    private func subtitleLabel(_ stream: VideoMetadata.SubtitleStream, index: Int) -> String {
        var parts = [String(localized: "Track \(index + 1)", comment: "Subtitle track in the burn-in picker.")]
        if let language = stream.languageCode, !language.isEmpty { parts.append(language) }
        if let title = stream.title, !title.isEmpty { parts.append(title) }
        if let codec = stream.codec { parts.append("(\(codec))") }
        return parts.joined(separator: " ")
    }

    private var subtitleFileLabel: String {
        if case .file(let path)? = draft.burnInSubtitles?.source {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return String(localized: "Subtitle file…", comment: "Burn-in picker option that opens a file chooser.")
    }

    private var subtitleChoiceBinding: Binding<SubtitleChoice> {
        Binding {
            switch draft.burnInSubtitles?.source {
            case nil: return .none
            case .embedded(let index)?: return .embedded(index)
            case .file?: return .file
            }
        } set: { choice in
            switch choice {
            case .none:
                draft.burnInSubtitles = nil
            case .embedded(let index):
                setSubtitleSource(.embedded(streamIndex: index))
            case .file:
                chooseSubtitleFile()
            }
        }
    }

    private func setSubtitleSource(_ source: MediaAdjustments.SubtitleSource) {
        if draft.burnInSubtitles == nil {
            draft.burnInSubtitles = .init(source: source)
        } else {
            draft.burnInSubtitles?.source = source
        }
    }

    private func subtitleBinding<Value>(_ keyPath: WritableKeyPath<MediaAdjustments.BurnInSubtitles, Value>) -> Binding<Value> {
        Binding {
            (draft.burnInSubtitles ?? .init(source: .embedded(streamIndex: 0)))[keyPath: keyPath]
        } set: { value in
            draft.burnInSubtitles?[keyPath: keyPath] = value
        }
    }

    private var replacementModeBinding: Binding<MediaAdjustments.AudioReplacementMode> {
        Binding {
            draft.replacementAudio?.mode ?? .replace
        } set: { draft.replacementAudio?.mode = $0 }
    }

    private var speedBinding: Binding<Double> {
        Binding {
            draft.speed
        } set: { draft.speed = min(max($0, MediaAdjustments.minimumSpeed), MediaAdjustments.maximumSpeed) }
    }

    private func secondsField(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: Binding {
                value.wrappedValue
            } set: { value.wrappedValue = max(0, $0) }, format: .number.precision(.fractionLength(0...2)))
                .labelsHidden()
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
            Text(verbatim: "s")
        }
    }

    private func chooseSubtitleFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MediaAdjustmentsPlan.supportedSubtitleFileExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        panel.directoryURL = item.url.deletingLastPathComponent()
        panel.message = String(localized: "Choose a subtitle file to burn in")
        if panel.runModal() == .OK, let url = panel.url {
            setSubtitleSource(.file(path: url.path))
        }
    }

    private func chooseReplacementAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.directoryURL = item.url.deletingLastPathComponent()
        panel.message = String(localized: "Choose the audio to use in the export")
        if panel.runModal() == .OK, let url = panel.url {
            draft.replacementAudio = .init(path: url.path, mode: draft.replacementAudio?.mode ?? .replace)
        }
    }
}
