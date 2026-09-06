//
//  ConversionToolbarView.swift
//  Aagedal Media Converter
//
//  Created by Truls Aagedal on 09/11/2025.
//

// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI

struct ConversionToolbarView: ToolbarContent {
    let isConverting: Bool
    let canStartConversion: Bool
    let hasFiles: Bool
    @Binding var watchFolderModeEnabled: Bool
    let watchFolderPath: String
    @Binding var selectedPreset: ExportPreset
    let presets: [ExportPreset]
    let displayName: (ExportPreset) -> String
    @Binding var mergeClipsEnabled: Bool
    let mergeClipsAvailable: Bool
    let onToggleConversion: (_ optionKeyPressed: Bool) -> Void
    let onImport: () -> Void
    let onShowDownload: () -> Void
    let onShowCapture: () -> Void
    let onResetAll: (_ optionKeyPressed: Bool) -> Void
    let hasResettableItems: Bool
    let onClear: () -> Void

    // A saved default or an App Intent can select a hidden preset. Keep that
    // selection represented so the menu can display the actual conversion mode.
    private var pickerPresets: [ExportPreset] {
        presets.contains(selectedPreset) ? presets : [selectedPreset] + presets
    }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            ConversionPlayButton(
                isConverting: isConverting,
                canStartConversion: canStartConversion,
                hasFiles: hasFiles,
                onToggleConversion: onToggleConversion
            )
            Toggle(isOn: $mergeClipsEnabled) {
                Label("Merge Clips", systemImage: "play.square.stack.fill")
            }
            .toggleStyle(.button)
            .disabled(!mergeClipsAvailable)
            .help("Merge all files into one file. Only works if input files have the same settings (e.g. resolution, codec). Note that trimming becomes less accurate when merging clips.")
        }

        ToolbarItem(placement: .automatic) {
            Spacer()
        }

        ToolbarItemGroup(placement: .automatic) {
            Toggle(isOn: $watchFolderModeEnabled) {
                Label("Watch Mode", systemImage: watchFolderModeEnabled ? "eye.fill" : "eye")
            }
            .toggleStyle(.button)
            .foregroundStyle(.yellow)
            .help(watchFolderPath.isEmpty ? "Select a watch folder to enable Watch Mode" : (watchFolderModeEnabled ? "Stop watching \(watchFolderPath)" : "Start watching \(watchFolderPath)"))

            Button(action: onShowCapture) {
                Label("Capture", systemImage: "record.circle")
                    .foregroundColor(.red)
            }
            .help("Open Capture Mode")

            Button(action: onImport) {
                Label("Import", systemImage: "plus.circle")
                    .foregroundColor(.accentColor)
            }
            .accessibilityIdentifier("toolbar.import")
            .help("Import video files")
            .keyboardShortcut("i", modifiers: .command)

            Button(action: onShowDownload) {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .foregroundStyle(.mint)
            .help("Download video from URL")
        }

        ToolbarItem(placement: .automatic) {
            Spacer()
        }

        ToolbarItemGroup(placement: .automatic) {
            ResetButton(
                hasResettableItems: hasResettableItems,
                isConverting: isConverting,
                onReset: onResetAll
            )

            ClearButton(
                hasFiles: hasFiles,
                isConverting: isConverting,
                onClear: onClear
            )

            Picker("Preset", selection: $selectedPreset) {
                ForEach(pickerPresets) { preset in
                    Text(displayName(preset)).tag(preset)
                }
            }
            .accessibilityIdentifier("toolbar.preset")
            .pickerStyle(.menu)
            .labelStyle(.titleOnly)
            .frame(width: 200)
            .disabled(isConverting)
            .foregroundColor(.primary)
            .help("Select export preset for all files")

            SettingsLink {
                Image(systemName: "gear")
                    .foregroundStyle(.blue)
            }
            .accessibilityIdentifier("toolbar.settings")
            .accessibilityLabel("Application Settings")
            .buttonStyle(.plain)
            .help("Application Settings")
            .padding(.horizontal, 8)
        }
    }
}

// MARK: - Clear Button with Confirmation Dialog

private struct ClearButton: View {
    let hasFiles: Bool
    let isConverting: Bool
    let onClear: () -> Void

    @State private var showConfirmation = false

    var body: some View {
        Button {
            showConfirmation = true
        } label: {
            Label("Clear", systemImage: "square.stack.3d.up.slash")
                .foregroundStyle((!hasFiles || isConverting) ? Color.gray : Color.red)
        }
        .help("Remove all files from the list")
        .disabled(!hasFiles || isConverting)
        .confirmationDialog(
            "Clear All Files",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                onClear()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove all files from the queue and cancel any active downloads.")
        }
    }
}

// MARK: - Play/Stop Button with Option Key Support

private struct ConversionPlayButton: View {
    let isConverting: Bool
    let canStartConversion: Bool
    let hasFiles: Bool
    let onToggleConversion: (_ optionKeyPressed: Bool) -> Void

    var body: some View {
        ConversionPlayButtonNSViewWrapper(
            isConverting: isConverting,
            canStartConversion: canStartConversion,
            hasFiles: hasFiles,
            onToggleConversion: onToggleConversion
        )
        .padding(.leading, 8)
        .padding(.trailing, 4)
    }
}

private struct ConversionPlayButtonNSViewWrapper: NSViewRepresentable {
    let isConverting: Bool
    let canStartConversion: Bool
    let hasFiles: Bool
    let onToggleConversion: (_ optionKeyPressed: Bool) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = context.coordinator
        button.action = #selector(Coordinator.buttonClicked(_:))

        // Set initial state
        configureButton(button)

        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        configureButton(nsView)
        context.coordinator.onToggleConversion = onToggleConversion
    }

    private func configureButton(_ button: NSButton) {
        button.setAccessibilityIdentifier("toolbar.conversion")

        // Symbol configuration for toolbar-sized icons
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)

        // Update icon and color based on state
        if isConverting {
            let image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "Cancel Conversion")
            button.image = image?.withSymbolConfiguration(config)
            button.contentTintColor = .systemRed
            button.setAccessibilityLabel("Cancel Conversion")
        } else {
            let image = NSImage(systemSymbolName: "play.circle", accessibilityDescription: "Start Conversion")
            button.image = image?.withSymbolConfiguration(config)
            button.contentTintColor = (!hasFiles || !canStartConversion) ? .systemGray : .systemGreen
            button.setAccessibilityLabel("Start Conversion")
        }

        // Update enabled state
        button.isEnabled = hasFiles && (canStartConversion || isConverting)

        // Update tooltip
        if !hasFiles {
            button.toolTip = "Add files to begin conversion"
        } else if isConverting {
            button.toolTip = "Cancel all conversions"
        } else if canStartConversion {
            button.toolTip = "Start converting all files. Hold Option to select output folder first."
        } else {
            button.toolTip = "No files ready to convert"
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onToggleConversion: onToggleConversion)
    }

    class Coordinator: NSObject {
        var onToggleConversion: (_ optionKeyPressed: Bool) -> Void

        init(onToggleConversion: @escaping (_ optionKeyPressed: Bool) -> Void) {
            self.onToggleConversion = onToggleConversion
        }

        @objc func buttonClicked(_ sender: NSButton) {
            let optionKeyPressed = NSEvent.modifierFlags.contains(.option)
            onToggleConversion(optionKeyPressed)
        }
    }
}

// MARK: - Reset Button with Option Key Support

private struct ResetButton: View {
    let hasResettableItems: Bool
    let isConverting: Bool
    let onReset: (_ optionKeyPressed: Bool) -> Void

    @State private var isHovering = false

    var body: some View {
        ResetButtonNSViewWrapper(
            hasResettableItems: hasResettableItems,
            isConverting: isConverting,
            onReset: onReset
        )
        .padding(.leading, 8)
        .padding(.trailing, 4)
    }
}

private struct ResetButtonNSViewWrapper: NSViewRepresentable {
    let hasResettableItems: Bool
    let isConverting: Bool
    let onReset: (_ optionKeyPressed: Bool) -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = context.coordinator
        button.action = #selector(Coordinator.buttonClicked(_:))

        // Set initial image with toolbar-sized configuration
        let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        let image = NSImage(systemSymbolName: "arrow.clockwise.circle", accessibilityDescription: "Reset All")
        button.image = image?.withSymbolConfiguration(config)

        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        let isEnabled = hasResettableItems && !isConverting
        nsView.isEnabled = isEnabled

        // Update appearance
        nsView.contentTintColor = isEnabled ? .systemBlue : .systemGray

        // Update tooltip based on settings
        let resetClearsSettings = UserDefaults.standard.bool(forKey: AppConstants.resetClearsSettingsKey)
        if resetClearsSettings {
            nsView.toolTip = "Reset all items (clears trim, crop, audio routing). Hold Option to only reset status."
        } else {
            nsView.toolTip = "Reset all items to waiting status. Hold Option to also clear trim, crop, and audio routing."
        }

        context.coordinator.onReset = onReset
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onReset: onReset)
    }

    class Coordinator: NSObject {
        var onReset: (_ optionKeyPressed: Bool) -> Void

        init(onReset: @escaping (_ optionKeyPressed: Bool) -> Void) {
            self.onReset = onReset
        }

        @objc func buttonClicked(_ sender: NSButton) {
            let optionKeyPressed = NSEvent.modifierFlags.contains(.option)
            onReset(optionKeyPressed)
        }
    }
}
