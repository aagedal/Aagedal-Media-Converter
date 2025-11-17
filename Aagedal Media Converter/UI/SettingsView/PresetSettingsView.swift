// Aagedal Media Converter — Presets Settings Tab

import SwiftUI

struct PresetsSettingsView: View {
    @AppStorage(AppConstants.customPreset1CommandKey) private var customPreset1Command = AppConstants.defaultCustomPresetCommands[0]
    @AppStorage(AppConstants.customPreset1SuffixKey) private var customPreset1Suffix = AppConstants.defaultCustomPresetSuffixes[0]
    @AppStorage(AppConstants.customPreset1ExtensionKey) private var customPreset1Extension = AppConstants.defaultCustomPresetExtensions[0]
    @AppStorage(AppConstants.customPreset1NameKey) private var customPreset1Name = AppConstants.defaultCustomPresetNameSuffixes[0]
    @AppStorage(AppConstants.customPreset2CommandKey) private var customPreset2Command = AppConstants.defaultCustomPresetCommands[1]
    @AppStorage(AppConstants.customPreset2SuffixKey) private var customPreset2Suffix = AppConstants.defaultCustomPresetSuffixes[1]
    @AppStorage(AppConstants.customPreset2ExtensionKey) private var customPreset2Extension = AppConstants.defaultCustomPresetExtensions[1]
    @AppStorage(AppConstants.customPreset2NameKey) private var customPreset2Name = AppConstants.defaultCustomPresetNameSuffixes[1]
    @AppStorage(AppConstants.customPreset3CommandKey) private var customPreset3Command = AppConstants.defaultCustomPresetCommands[2]
    @AppStorage(AppConstants.customPreset3SuffixKey) private var customPreset3Suffix = AppConstants.defaultCustomPresetSuffixes[2]
    @AppStorage(AppConstants.customPreset3ExtensionKey) private var customPreset3Extension = AppConstants.defaultCustomPresetExtensions[2]
    @AppStorage(AppConstants.customPreset3NameKey) private var customPreset3Name = AppConstants.defaultCustomPresetNameSuffixes[2]

    @AppStorage(AppConstants.defaultPresetKey) private var storedDefaultPresetRawValue = ExportPreset.videoLoop.rawValue

    @State private var selectedPreset: ExportPreset = .videoLoop
    @FocusState private var focusedCustomCommandSlot: Int?
    @State private var previousFocusedCustomCommandSlot: Int?

    var body: some View {
        Form {
            presetInformationSection
            if selectedPreset.isCustom {
                customPresetSection
            }
        }
        .formStyle(.grouped)
        .onAppear {
            selectedPreset = ExportPreset(rawValue: storedDefaultPresetRawValue) ?? .videoLoop
        }
        .onChange(of: storedDefaultPresetRawValue) { _, newValue in
            selectedPreset = ExportPreset(rawValue: newValue) ?? .videoLoop
        }
        .onChange(of: focusedCustomCommandSlot) { _, newValue in
            if let previous = previousFocusedCustomCommandSlot, previous != newValue {
                finalizeCustomCommand(for: previous)
            }
            previousFocusedCustomCommandSlot = newValue
        }
        .onDisappear {
            if let previous = previousFocusedCustomCommandSlot {
                finalizeCustomCommand(for: previous)
                previousFocusedCustomCommandSlot = nil
            }
        }
    }

    private var presetInformationSection: some View {
        Section(header: Text("Preset Information")) {
            VStack(alignment: .leading) {
                HStack(alignment: .center, spacing: 12) {
                    Picker("Preset", selection: $selectedPreset) {
                        ForEach(ExportPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.automatic)
                    .labelsHidden()

                    Spacer()
                    Button(action: setSelectedPresetAsDefault) {
                        if isSelectedPresetDefault {
                            Text("Default")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.green)
                        } else {
                            Text("Set as Default")
                                .font(.subheadline)
                                .foregroundColor(.blue)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isSelectedPresetDefault)
                    .help(isSelectedPresetDefault ? "Current default preset" : "Set this preset as the default for new files")
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(selectedPreset.displayName)
                            .font(.headline)
                        Spacer()
                        HStack {
                            Text(selectedPreset.fileSuffix)
                            Text(".\(selectedPreset.fileExtension)")
                        }
                        .font(.subheadline)
                        .monospaced()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .clipShape(Capsule())
                    }

                    Text(selectedPreset.description)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
                .cornerRadius(10)
            }
        }
    }

    private var customPresetSection: some View {
        Section(header: Text("Custom Preset")) {
            let slot = selectedPreset.customSlotIndex ?? 0
            VStack(alignment: .leading, spacing: 16) {
                presetNameField(for: slot)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Specify the arguments passed to ffmpeg (without including the `ffmpeg` command itself).")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    TextEditor(text: Binding(
                        get: { customCommand(for: slot) },
                        set: { updateCustomCommand($0, slot: slot) }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )
                    .focused($focusedCustomCommandSlot, equals: slot)
                }
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Output file suffix")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        TextField("_c\(slot + 1)", text: Binding(
                            get: { customSuffix(for: slot) },
                            set: { updateCustomSuffix($0, slot: slot) }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Output extension")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        TextField("mp4", text: Binding(
                            get: { customExtension(for: slot) },
                            set: { updateCustomExtension($0, slot: slot) }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                }
                Text("Example: `-c:v libx264 -crf 18 -preset slow -c:a copy` produces `filename\(customSuffix(for: slot)).\(customExtension(for: slot))`.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Helpers (scoped to Presets tab)

    private var defaultPreset: ExportPreset {
        ExportPreset(rawValue: storedDefaultPresetRawValue) ?? .videoLoop
    }

    private var isSelectedPresetDefault: Bool {
        selectedPreset == defaultPreset
    }

    private func setSelectedPresetAsDefault() {
        storedDefaultPresetRawValue = selectedPreset.rawValue
    }

    private func customCommand(for slot: Int) -> String {
        switch slot {
        case 0: return customPreset1Command
        case 1: return customPreset2Command
        case 2: return customPreset3Command
        default:
            return AppConstants.defaultCustomPresetCommands.indices.contains(slot)
                ? AppConstants.defaultCustomPresetCommands[slot]
                : "-c copy"
        }
    }

    private func customSuffix(for slot: Int) -> String {
        switch slot {
        case 0: return customPreset1Suffix
        case 1: return customPreset2Suffix
        case 2: return customPreset3Suffix
        default:
            return AppConstants.defaultCustomPresetSuffixes.indices.contains(slot)
                ? AppConstants.defaultCustomPresetSuffixes[slot]
                : "_c\(slot + 1)"
        }
    }

    private func customExtension(for slot: Int) -> String {
        switch slot {
        case 0: return customPreset1Extension
        case 1: return customPreset2Extension
        case 2: return customPreset3Extension
        default:
            return AppConstants.defaultCustomPresetExtensions.indices.contains(slot)
                ? AppConstants.defaultCustomPresetExtensions[slot]
                : "mp4"
        }
    }

    private func customNamePrefix(for slot: Int) -> String {
        let prefixes = AppConstants.customPresetPrefixes
        return prefixes.indices.contains(slot) ? prefixes[slot] : "C\(slot + 1):"
    }

    private func customNameSuffix(for slot: Int) -> String {
        let fallback = AppConstants.defaultCustomPresetNameSuffixes.indices.contains(slot)
            ? AppConstants.defaultCustomPresetNameSuffixes[slot]
            : "Custom Preset"
        let prefix = customNamePrefix(for: slot)
        let stored: String
        switch slot {
        case 0: stored = customPreset1Name
        case 1: stored = customPreset2Name
        case 2: stored = customPreset3Name
        default: stored = fallback
        }
        let sanitized = sanitizeCustomNameSuffix(stored, prefix: prefix, fallback: fallback)
        if sanitized != stored {
            updateStoredNameSuffix(sanitized, slot: slot)
        }
        return sanitized
    }

    private func customDisplayName(for slot: Int) -> String {
        "\(customNamePrefix(for: slot)) \(customNameSuffix(for: slot))"
    }

    private func updateCustomCommand(_ value: String, slot: Int) {
        let defaults = AppConstants.defaultCustomPresetCommands
        let fallback = defaults.indices.contains(slot) ? defaults[slot] : "-c copy"
        let sanitized = sanitizeCustomCommand(value, fallback: fallback)
        switch slot {
        case 0: customPreset1Command = sanitized
        case 1: customPreset2Command = sanitized
        case 2: customPreset3Command = sanitized
        default: break
        }
    }

    private func updateCustomSuffix(_ value: String, slot: Int) {
        let defaults = AppConstants.defaultCustomPresetSuffixes
        let fallback = defaults.indices.contains(slot) ? defaults[slot] : "_c\(slot + 1)"
        let sanitized = sanitizeCustomSuffix(value, fallback: fallback)
        switch slot {
        case 0: customPreset1Suffix = sanitized
        case 1: customPreset2Suffix = sanitized
        case 2: customPreset3Suffix = sanitized
        default: break
        }
    }

    private func updateCustomExtension(_ value: String, slot: Int) {
        let defaults = AppConstants.defaultCustomPresetExtensions
        let fallback = defaults.indices.contains(slot) ? defaults[slot] : "mp4"
        let sanitized = sanitizeCustomExtension(value, fallback: fallback)
        switch slot {
        case 0: customPreset1Extension = sanitized
        case 1: customPreset2Extension = sanitized
        case 2: customPreset3Extension = sanitized
        default: break
        }
    }

    private func updateCustomNameSuffix(_ value: String, slot: Int) {
        let fallback = AppConstants.defaultCustomPresetNameSuffixes.indices.contains(slot)
            ? AppConstants.defaultCustomPresetNameSuffixes[slot]
            : "Custom Preset"
        let prefix = customNamePrefix(for: slot)
        let sanitized = sanitizeCustomNameSuffix(value, prefix: prefix, fallback: fallback)
        updateStoredNameSuffix(sanitized, slot: slot)
    }

    private func updateStoredNameSuffix(_ value: String, slot: Int) {
        switch slot {
        case 0: customPreset1Name = value
        case 1: customPreset2Name = value
        case 2: customPreset3Name = value
        default: break
        }
    }

    @ViewBuilder
    private func presetNameField(for slot: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Display name")
                .font(.footnote)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                Text(customNamePrefix(for: slot))
                    .font(.body.monospaced())
                TextField("Custom Preset", text: Binding(
                    get: { customNameSuffix(for: slot) },
                    set: { updateCustomNameSuffix($0, slot: slot) }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func sanitizeCustomSuffix(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return trimmed.hasPrefix("_") ? trimmed : "_" + trimmed
    }

    private func sanitizeCustomExtension(_ value: String, fallback: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") {
            trimmed.removeFirst()
        }
        trimmed = trimmed.replacingOccurrences(of: " ", with: "")
        return trimmed.isEmpty ? fallback : trimmed.lowercased()
    }

    private func sanitizeCustomCommand(_ value: String, fallback: String) -> String {
        let withoutControlCharacters = value.trimmingCharacters(in: .controlCharacters)
        let trimmedWhitespace = withoutControlCharacters.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedWhitespace.isEmpty {
            return fallback
        }
        return withoutControlCharacters
    }

    private func finalizeCustomCommand(for slot: Int) {
        let current = customCommand(for: slot)
        let trimmedTrailing = trimTrailingWhitespace(from: current)
        updateCustomCommand(trimmedTrailing, slot: slot)
    }

    private func trimTrailingWhitespace(from value: String) -> String {
        var result = value
        while let last = result.last, last.isWhitespace || last.isNewline {
            result.removeLast()
        }
        return result
    }

    private func sanitizeCustomNameSuffix(_ value: String, prefix: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let lowercasedPrefix = prefix.lowercased()
        var remainder = trimmed
        if trimmed.lowercased().hasPrefix(lowercasedPrefix) {
            let cutoff = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            remainder = String(trimmed[cutoff...])
        }
        remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder.first == ":" {
            remainder.removeFirst()
            remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cleaned = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }
}
