// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import OSLog
import SwiftUI

/// Sheet for quickly selecting a preset with keyboard navigation
struct PresetQuickSelectOverlay: View {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "PresetQuickSelect")

    @Binding var isPresented: Bool
    var presets: [ExportPreset]
    var currentPreset: ExportPreset
    var displayName: (ExportPreset) -> String
    var onSelect: (ExportPreset) -> Void

    @State private var selection: ExportPreset?
    @State private var hasConfirmed = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "list.bullet")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                Text("Select Preset")
                    .font(.headline)

                Spacer()

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Preset list with built-in keyboard navigation
            List(selection: $selection) {
                ForEach(Array(presets.enumerated()), id: \.element) { index, preset in
                    PresetRow(
                        preset: preset,
                        index: index,
                        isSelected: preset == currentPreset,
                        displayName: displayName(preset)
                    )
                    .tag(preset)
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                }
            }
            .listStyle(.plain)
            // Double-clicking a row applies it (mouse users have no visible confirm button).
            .contextMenu(forSelectionType: ExportPreset.self, menu: { _ in EmptyView() }) { items in
                if let preset = items.first {
                    confirmSelection(preset)
                }
            }
            .frame(height: min(CGFloat(presets.count) * 44, 320))
            .scrollContentBackground(.hidden)

            // Hint text
            HStack(spacing: 12) {
                Label("Navigate", systemImage: "arrow.up.arrow.down")
                Label("Select", systemImage: "return")
                HStack(spacing: 2) {
                    Image(systemName: "command")
                    Text("1...9 + 0")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 12)

            // Hidden confirm button for Enter key
            Button("Confirm") {
                if let selected = selection {
                    confirmSelection(selected)
                }
            }
            .keyboardShortcut(.return, modifiers: [])
            .frame(width: 0, height: 0)
            .opacity(0)

            // Hidden buttons for CMD+1-9, CMD+0 quick selection
            ForEach(1...9, id: \.self) { number in
                if number <= presets.count {
                    Button("Select \(number)") {
                        confirmSelection(presets[number - 1])
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                }
            }
            // CMD+0 for 10th preset
            if presets.count >= 10 {
                Button("Select 10") {
                    confirmSelection(presets[9])
                }
                .keyboardShortcut(KeyEquivalent(Character("0")), modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
            }
        }
        .frame(width: 340)
        .onAppear {
            selection = currentPreset
        }
    }

    private func confirmSelection(_ preset: ExportPreset) {
        // Return can reach both the list's primary action and the hidden
        // Confirm button; apply the preset only once.
        guard !hasConfirmed else { return }
        hasConfirmed = true
        onSelect(preset)
        isPresented = false
    }
}

// MARK: - Preset Row

private struct PresetRow: View {
    let preset: ExportPreset
    let index: Int
    let isSelected: Bool
    let displayName: String

    var body: some View {
        HStack(spacing: 12) {
            // Number badge (1-9 for first 9 items, 0 for 10th)
            if index < 10 {
                Text(index == 9 ? "0" : "\(index + 1)")
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.primary.opacity(0.1))
                    )
            } else {
                Color.clear
                    .frame(width: 20, height: 20)
            }

            // Preset name
            Text(displayName)
                .font(.body)
                .lineLimit(1)

            Spacer()

            // Checkmark for currently active preset
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    PresetQuickSelectOverlay(
        isPresented: .constant(true),
        presets: [.videoLoop, .prores, .h264, .h265, .av1, .animatedStill],
        currentPreset: .h264,
        displayName: { $0.description },
        onSelect: { preset in
            print("Selected: \(preset)")
        }
    )
}
