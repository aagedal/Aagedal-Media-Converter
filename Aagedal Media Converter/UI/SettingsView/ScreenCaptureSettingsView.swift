// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

struct ScreenCaptureSettingsView: View {
    @AppStorage(AppConstants.captureDirectoryKey) private var captureDirectoryPath = AppConstants.defaultCaptureDirectory.path
    @AppStorage(AppConstants.capturePresetKey) private var capturePresetRaw = CapturePreset.defaultPreset.rawValue
    @AppStorage(AppConstants.captureFrameRateKey) private var captureFrameRateRaw = AppConstants.defaultCaptureFrameRate
    @AppStorage(AppConstants.captureDynamicRangeKey) private var captureDynamicRangeRaw = AppConstants.defaultCaptureDynamicRange
    @AppStorage(AppConstants.captureHideCursorKey) private var captureHideCursor = AppConstants.defaultCaptureHideCursor
    @AppStorage(AppConstants.captureExcludeCurrentAppKey) private var captureExcludeCurrentApp = AppConstants.defaultCaptureExcludeCurrentApp

    private var presetBinding: Binding<CapturePreset> {
        Binding(
            get: {
                let preset = CapturePreset(rawValue: capturePresetRaw) ?? .defaultPreset
                return CapturePreset.availablePresets.contains(preset) ? preset : .defaultPreset
            },
            set: { capturePresetRaw = $0.rawValue }
        )
    }

    private var outputDirectoryURL: URL {
        let trimmed = captureDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AppConstants.defaultCaptureDirectory : URL(fileURLWithPath: trimmed)
    }

    private var frameRateBinding: Binding<CaptureFrameRateOption> {
        Binding(
            get: { CaptureFrameRateOption(rawValue: captureFrameRateRaw) ?? .auto },
            set: { captureFrameRateRaw = $0.rawValue }
        )
    }

    private var dynamicRangeBinding: Binding<CaptureDynamicRangeOption> {
        Binding(
            get: { CaptureDynamicRangeOption(rawValue: captureDynamicRangeRaw) ?? .sdr },
            set: { captureDynamicRangeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section(header: Text("Preset")) {
                Picker("Default Preset", selection: presetBinding) {
                    ForEach(CapturePreset.availablePresets) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                Text(presetBinding.wrappedValue.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section(header: Text("Capture Options")) {
                Picker("Frame Rate", selection: frameRateBinding) {
                    ForEach(CaptureFrameRateOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("capture.frameRate")
                Text(presetBinding.wrappedValue.frameRateDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Dynamic Range", selection: dynamicRangeBinding) {
                    Text(CaptureDynamicRangeOption.sdr.displayName)
                        .tag(CaptureDynamicRangeOption.sdr)
                    if #available(macOS 26, *) {
                        Text(CaptureDynamicRangeOption.hdrP3CanonicalDisplay.displayName)
                            .tag(CaptureDynamicRangeOption.hdrP3CanonicalDisplay)
                    }
                }
                .pickerStyle(.menu)
                if #available(macOS 26, *) {
                    EmptyView()
                } else {
                    Text("HDR capture requires macOS 26 or later.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Toggle("Hide cursor", isOn: $captureHideCursor)
                    .toggleStyle(SwitchToggleStyle())
                Toggle("Hide app window", isOn: $captureExcludeCurrentApp)
                    .toggleStyle(SwitchToggleStyle())
            }

            Section(header: Text("Output Folder")) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Capture Output Folder:")
                        .font(.headline)

                    HStack {
                        Text(outputDirectoryURL.path)
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .help(outputDirectoryURL.path)

                        Button(action: {
                            NSWorkspace.shared.activateFileViewerSelecting([outputDirectoryURL])
                        }) {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .help("Show in Finder")
                        .accessibilityLabel("Show in Finder")
                        .accessibilityIdentifier("capture.showOutputFolder")

                        Button(action: { selectCaptureDirectory() }) {
                            Image(systemName: "folder.badge.gearshape")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .help("Change capture folder")
                        .accessibilityLabel("Change capture folder")
                        .accessibilityIdentifier("capture.chooseOutputFolder")

                        Button(action: { captureDirectoryPath = AppConstants.defaultCaptureDirectory.path }) {
                            Image(systemName: "arrow.counterclockwise")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .help("Reset to default")
                        .accessibilityLabel("Reset to default")
                        .accessibilityIdentifier("capture.resetOutputFolder")
                    }
                }
                .padding(8)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if !CapturePreset.availablePresets.contains(presetBinding.wrappedValue) {
                capturePresetRaw = CapturePreset.defaultPreset.rawValue
            }
            if CaptureFrameRateOption(rawValue: captureFrameRateRaw) == nil {
                captureFrameRateRaw = CaptureFrameRateOption.auto.rawValue
            }
            if CaptureDynamicRangeOption(rawValue: captureDynamicRangeRaw) == nil {
                if captureDynamicRangeRaw == "hdrP3LocalDisplay" {
                    captureDynamicRangeRaw = CaptureDynamicRangeOption.hdrP3CanonicalDisplay.rawValue
                } else {
                    captureDynamicRangeRaw = CaptureDynamicRangeOption.sdr.rawValue
                }
            }
            if CaptureDynamicRangeOption(rawValue: captureDynamicRangeRaw) != .sdr,
               !isHDRRecordingSupported {
                captureDynamicRangeRaw = CaptureDynamicRangeOption.sdr.rawValue
            }
        }
    }

    private var isHDRRecordingSupported: Bool {
        if #available(macOS 26, *) {
            return true
        }
        return false
    }

    private func selectCaptureDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputDirectoryURL

        if panel.runModal() == .OK, let url = panel.url {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            captureDirectoryPath = url.path
            _ = SecurityScopedBookmarkManager.shared.saveWritableBookmark(for: url)
        }
    }
}

#Preview {
    ScreenCaptureSettingsView()
}
