// Aagedal VideoLoop Converter 2.0
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    let isPresentedAsSheet: Bool
    
    init(isPresentedAsSheet: Bool = false) {
        self.isPresentedAsSheet = isPresentedAsSheet
    }
    @AppStorage("outputFolder") private var outputFolder = AppConstants.defaultOutputDirectory.path
    @AppStorage(AppConstants.includeDateTagPreferenceKey) private var includeDateTagByDefault = false
    @State private var selectedPreset: ExportPreset = .videoLoop
    
    var body: some View {
        Form {
            // App Info Section
            Section {
                HStack {
                    if let appIcon = NSImage(named: "AppIcon") {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    }
                    
                    VStack(alignment: .leading) {
                        Text("Aagedal VideoLoop Converter")
                            .font(.headline)
                        
                        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                           let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                            Text("Version \(version) (\(build))")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.leading, 8)
                }
                .padding(.vertical, 4)
                
                Text("FFMPEG frontend with focus on creating videoloops: small .mp4-files are intended to loop infinitely and automatically inline on websites. This works as a modern replacement for GIFs.")
                    .font(.body)
                    .padding(8)
                
                // Divider()
                
                // Output Folder
                VStack(alignment: .leading, spacing: 4) {
                    Text("Default Output Folder:")
                        .font(.headline)
                    
                    HStack {
                        Text(outputFolder)
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .help(outputFolder)
                        
                        Button(action: {
                            let url = URL(fileURLWithPath: outputFolder)
                            guard FileManager.default.fileExists(atPath: url.path) else {
                                // If the saved folder doesn't exist, reset to default
                                outputFolder = AppConstants.defaultOutputDirectory.path
                                NSWorkspace.shared.activateFileViewerSelecting([AppConstants.defaultOutputDirectory])
                                return
                            }
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }) {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .help("Show in Finder")
                        
                        // Choose new folder
                        Button(action: {
                            selectNewOutputFolder()
                        }) {
                            Image(systemName: "folder.badge.gearshape")
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .help("Change default output folder")
                    }
                }
                .padding(8)
            }
            
            // Preset Information Section
            Section(header: Text("Preset Information")) {
                VStack(alignment: .leading) {
                    Toggle("Include date tag on new files", isOn: $includeDateTagByDefault)
                        .toggleStyle(SwitchToggleStyle())
                        .padding(.bottom, 8)
                        .help("Controls whether newly added files include the \"Date generated\" metadata tag by default")

                    // Segmented Control for Preset Selection
                    Picker("Preset", selection: $selectedPreset) {
                        ForEach(ExportPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.automatic)
                    .labelsHidden()
                    
                    // Preset Description
                    VStack(alignment: .leading, spacing: 8) {
                        Text(selectedPreset.displayName)
                            .font(.headline)
                        
                        Text(selectedPreset.description)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(8)
                }
            }
            
            // Links Section
            Section {
                HStack(spacing: 20) {
                    // Left-aligned Close button (only shown in sheet)
                    if isPresentedAsSheet {
                        Button(action: { dismiss() }) {
                            Text("Close")
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                    } else {
                        // Spacer to push content to the right when not in sheet mode
                        Spacer()
                    }
                    
                    Spacer()
                    // Right-aligned links
                    HStack(spacing: 20) {
                        Link("GitHub Project", destination: URL(string: "https://github.com/yourusername/Aagedal-VideoLoop-Converter-2.0")!)
                            .foregroundColor(.blue)
                            .buttonStyle(.plain)
                        
                        Link("Developer Website", destination: URL(string: "https://aagedal.me")!)
                            .foregroundColor(.blue)
                            .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 8)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: isPresentedAsSheet ? 680 : 580)
        .navigationTitle("About Aagedal Video Loop Converter")
        .padding(.top, isPresentedAsSheet ? 120 : 00)
    }
    
    // MARK: - Helpers
    
    private func selectNewOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: outputFolder)
        
        if panel.runModal() == .OK, let url = panel.url {
            // Ensure directory exists
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            outputFolder = url.path
        }
    }
}

#Preview {
    SettingsView()
}
