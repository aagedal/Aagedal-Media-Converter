// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct ScreenshotSettingsView: View {
    @AppStorage(AppConstants.screenshotDirectoryKey) private var screenshotDirectoryPath = AppConstants.defaultScreenshotDirectory.path
    @AppStorage(AppConstants.screenshot8BitFormatKey) private var screenshot8BitFormat = AppConstants.defaultScreenshotFormat
    @AppStorage(AppConstants.screenshot10BitFormatKey) private var screenshot10BitFormat = AppConstants.defaultScreenshotFormat
    @AppStorage(AppConstants.screenshotHighBitFormatKey) private var screenshotHighBitFormat = AppConstants.defaultScreenshotFormat
    @AppStorage(AppConstants.screenshotAlphaHandlingKey) private var screenshotAlphaHandling = AppConstants.defaultScreenshotAlphaHandling

    var body: some View {
        Form {
            folderSection
            formatsSection
            alphaSection
        }
        .formStyle(.grouped)
    }

    private var folderSection: some View {
        Section(header: Text("Screenshot Folder")) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(screenshotDirectoryPath)
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .help(screenshotDirectoryPath)

                    Button(action: {
                        let url = URL(fileURLWithPath: screenshotDirectoryPath)
                        guard FileManager.default.fileExists(atPath: url.path) else {
                            screenshotDirectoryPath = AppConstants.defaultScreenshotDirectory.path
                            return
                        }
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }) {
                        Image(systemName: "arrow.right.circle.fill")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .help("Show in Finder")
                    .accessibilityLabel("Show in Finder")
                    .accessibilityIdentifier("settings.screenshots.reveal")

                    Button(action: { selectScreenshotDirectory() }) {
                        Image(systemName: "camera.on.rectangle")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .help("Change screenshot folder")
                    .accessibilityLabel("Change screenshot folder")
                    .accessibilityIdentifier("settings.screenshots.chooseFolder")

                    Button(action: { screenshotDirectoryPath = AppConstants.defaultScreenshotDirectory.path }) {
                        Image(systemName: "arrow.counterclockwise")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .help("Reset to Downloads")
                    .accessibilityLabel("Reset to Downloads")
                    .accessibilityIdentifier("settings.screenshots.resetFolder")
                }
            }
            .padding(8)
        }
    }

    private var formatsSection: some View {
        Section(header: Text("Formats")) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("8-bit sources") {
                    formatPicker(selection: $screenshot8BitFormat, label: "8-bit sources")
                }
                LabeledContent("10-bit sources") {
                    formatPicker(selection: $screenshot10BitFormat, label: "10-bit sources")
                }
                LabeledContent(">10-bit sources") {
                    formatPicker(selection: $screenshotHighBitFormat, label: ">10-bit sources")
                }

                Text("Select the image format for screenshots based on source bit depth.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
            .padding(8)
        }
    }

    private var alphaSection: some View {
        Section(header: Text("Transparency")) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Alpha channel") {
                    Picker("Alpha channel", selection: $screenshotAlphaHandling) {
                        ForEach(ScreenshotAlphaHandling.allCases) { handling in
                            Text(LocalizedStringKey(handling.displayName)).tag(handling.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 300)
                }

                Text("Choose how to handle screenshots with alpha transparency.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func formatPicker(selection: Binding<String>, label: LocalizedStringKey) -> some View {
        Picker(label, selection: selection) {
            ForEach(ScreenshotFormat.allCases) { format in
                Text(format.displayName).tag(format.rawValue)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 160)
    }

    private func selectScreenshotDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: screenshotDirectoryPath)

        if panel.runModal() == .OK, let url = panel.url {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            screenshotDirectoryPath = url.path
            _ = SecurityScopedBookmarkManager.shared.saveWritableBookmark(for: url)
        }
    }
}

#Preview {
    ScreenshotSettingsView()
}
