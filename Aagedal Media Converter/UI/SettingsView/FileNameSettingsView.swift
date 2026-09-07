// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct FileNameSettingsView: View {
    @AppStorage(AppConstants.enableFileNameProcessingKey) private var enableFileNameProcessing = true
    @AppStorage(AppConstants.fileNameReplaceSpacesKey) private var fileNameReplaceSpaces = AppConstants.defaultFileNameReplaceSpaces
    @AppStorage(AppConstants.fileNameReplaceScandinavianCharsKey) private var fileNameReplaceScandinavianChars = AppConstants.defaultFileNameReplaceScandinavianChars
    @AppStorage(AppConstants.fileNameSpecialCharRemovalModeKey) private var specialCharRemovalModeRaw = AppConstants.defaultFileNameSpecialCharRemovalMode
    @AppStorage(AppConstants.fileNameIncludePresetSuffixKey) private var fileNameIncludePresetSuffix = AppConstants.defaultFileNameIncludePresetSuffix

    @AppStorage(AppConstants.enableCustomFileNameTemplateKey) private var enableCustomTemplate = AppConstants.defaultEnableCustomFileNameTemplate
    @AppStorage(AppConstants.customFileNameTemplateKey) private var customTemplate = AppConstants.defaultCustomFileNameTemplate
    @AppStorage(AppConstants.customFileNameDateFormatKey) private var customDateFormat = AppConstants.defaultCustomFileNameDateFormat
    @AppStorage(AppConstants.customFileNameCounterPaddingKey) private var customCounterPadding = AppConstants.defaultCustomFileNameCounterPadding
    @AppStorage(AppConstants.customFileNameCounterValueKey) private var customCounterValue = AppConstants.defaultCustomFileNameCounterValue

    var body: some View {
        Form {
            fileNameSection
            customTemplateSection
        }
        .formStyle(.grouped)
    }

    private var specialCharRemovalMode: Binding<SpecialCharacterRemovalMode> {
        Binding(
            get: { SpecialCharacterRemovalMode(rawValue: specialCharRemovalModeRaw) ?? .loose },
            set: { specialCharRemovalModeRaw = $0.rawValue }
        )
    }

    private var fileNameSection: some View {
        Section(header: Text("File Names")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable filename processing", isOn: $enableFileNameProcessing)
                    .toggleStyle(SwitchToggleStyle())
                    .help("When enabled, spaces and special characters in filenames are sanitized")

                if enableFileNameProcessing {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle("Replace spaces with underscores", isOn: $fileNameReplaceSpaces)
                            .toggleStyle(SwitchToggleStyle())
                            .padding(.leading, 16)
                        Toggle("Convert Scandinavian characters (æ, ø, å)", isOn: $fileNameReplaceScandinavianChars)
                            .toggleStyle(SwitchToggleStyle())
                            .padding(.leading, 16)

                        HStack(alignment: .firstTextBaseline) {
                            Text("Remove special characters:")
                            Picker("", selection: specialCharRemovalMode) {
                                ForEach(SpecialCharacterRemovalMode.allCases) { mode in
                                    Text(LocalizedStringKey(mode.displayName)).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 360)
                            Spacer()
                        }
                        .padding(.leading, 16)

                        Text(specialCharExplanation)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 16)
                    }
                }

                Divider()
                    .padding(.vertical, 4)

                Toggle("Include preset suffix in filename", isOn: $fileNameIncludePresetSuffix)
                    .toggleStyle(SwitchToggleStyle())
                    .help("When enabled, preset suffixes like '_loop' or '_tv' are added to output filenames")
                Text("When disabled, output filenames will not include preset-specific suffixes.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }

    private var customTemplateSection: some View {
        Section(header: Text("Custom Filename Template")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Use custom filename template", isOn: $enableCustomTemplate)
                    .toggleStyle(SwitchToggleStyle())
                    .help("Compose output filenames from a template with variables.")

                if enableCustomTemplate {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Template:")
                                .frame(width: 100, alignment: .leading)
                            TextField("{sourceName}_{date}", text: $customTemplate)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack {
                            Text("Date format:")
                                .frame(width: 100, alignment: .leading)
                            TextField("yyyyMMdd", text: $customDateFormat)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 200)
                            Text(datePreview)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }

                        HStack {
                            Text("Counter padding:")
                                .frame(width: 100, alignment: .leading)
                            Picker("", selection: $customCounterPadding) {
                                Text("1 (1, 2, 3)").tag(1)
                                Text("2 (01, 02, 03)").tag(2)
                                Text("3 (001, 002, 003)").tag(3)
                                Text("4 (0001, 0002, 0003)").tag(4)
                                Text("5 (00001, 00002)").tag(5)
                                Text("6 (000001, 000002)").tag(6)
                            }
                            .labelsHidden()
                            .frame(maxWidth: 220)
                            Spacer()
                        }

                        HStack {
                            Text("Next counter:")
                                .frame(width: 100, alignment: .leading)
                            TextField("", value: $customCounterValue, formatter: Self.counterFormatter)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 100)
                            Button("Reset to 1") {
                                customCounterValue = 1
                            }
                            Spacer()
                        }

                        Divider()
                            .padding(.vertical, 2)

                        Text("Available variables:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("{sourceName} — original file name (sanitized)")
                            Text("{date} — current date using the format above")
                            Text("{counter} — sequence number, allocated per imported file")
                            Text("{presetSuffix} — preset's suffix (e.g. _h264, _tv); suppresses auto-append")
                            Text("{resolution} — preset's target resolution (e.g. 1080p), empty if unlimited")
                            Text("{framerate} — preset's target framerate (e.g. 50p, 24), empty if source")
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)

                        Text("Preview: \(templatePreview)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)

                        Divider()
                            .padding(.vertical, 2)

                        Text("Per-item overrides")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        Text("You can still rename individual files in the queue by double-clicking the output filename. Manual overrides take precedence over this template.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 16)
                }
            }
            .padding(8)
        }
    }

    private static let counterFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 0
        formatter.maximum = 999_999_999
        formatter.allowsFloats = false
        return formatter
    }()

    private var datePreview: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = customDateFormat
        return formatter.string(from: Date())
    }

    private var specialCharExplanation: LocalizedStringKey {
        switch SpecialCharacterRemovalMode(rawValue: specialCharRemovalModeRaw) ?? .loose {
        case .off:
            return "Filenames are kept as-is (after space and Scandinavian conversion above)."
        case .loose:
            return "Strips only the characters Finder/Windows reject. Accented and Nordic letters survive even when conversion above is off."
        case .strict:
            return "Strips everything except A–Z, 0–9, underscores, and hyphens. Maximum cross-platform safety."
        }
    }

    private var templatePreview: String {
        let counterString = String(format: "%0\(max(1, customCounterPadding))d", customCounterValue)
        let sampleSourceName = FileNameProcessor.processFileName("My Sømmer Vidéo æø!")
        // Sample stand-in values for preset-derived variables — actual values come from the active preset at conversion time.
        let substituted = customTemplate
            .replacingOccurrences(of: "{sourceName}", with: sampleSourceName)
            .replacingOccurrences(of: "{date}", with: datePreview)
            .replacingOccurrences(of: "{counter}", with: counterString)
            .replacingOccurrences(of: "{presetSuffix}", with: "_h264")
            .replacingOccurrences(of: "{resolution}", with: "1080p")
            .replacingOccurrences(of: "{framerate}", with: "25p")
        return FileNameProcessor.processFileName(substituted)
    }
}

#Preview {
    FileNameSettingsView()
}
