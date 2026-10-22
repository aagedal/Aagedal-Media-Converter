// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

// MARK: - Per-item preset override

extension VideoFileCellView {

    func updatePresetButton(config: VideoFileCellConfiguration) {
        // Grouped rows follow their group's preset picker instead.
        presetButton.isHidden = config.isGroupChild
        presetButton.isEnabled = config.canOverridePreset
        let presetName = PresetManager.shared.displayName(for: config.preset)
        if let override = config.presetOverride {
            presetButton.contentTintColor = .controlAccentColor
            presetButton.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
            presetButton.toolTip = String(localized: "Preset for this item: \(PresetManager.shared.displayName(for: override)). Click to change.",
                                          comment: "Tooltip on a queue item's preset button when it has its own preset.")
            presetButton.setAccessibilityValue(presetName)
        } else {
            presetButton.contentTintColor = .secondaryLabelColor
            presetButton.layer?.borderColor = NSColor.clear.cgColor
            presetButton.toolTip = config.canOverridePreset
                ? String(localized: "Uses the queue preset (\(presetName)). Click to choose a preset for this item only.")
                : (config.mergeClipsEnabled
                    ? String(localized: "Merged clips all use the queue preset.")
                    : String(localized: "Preset: \(presetName)", comment: "Tooltip naming the preset an item will use."))
            presetButton.setAccessibilityValue(presetName)
        }
        presetButton.setAccessibilityLabel(String(localized: "Preset for this item"))
    }

    @objc func presetButtonClicked() {
        guard let config = currentConfig, config.canOverridePreset else { return }
        presetPopover?.performClose(nil)
        let itemID = config.itemID
        let picker = PresetOverridePopoverView(
            queuePreset: config.queuePreset ?? config.preset,
            override: config.presetOverride
        ) { [weak self] preset in
            guard let self, self.currentConfig?.itemID == itemID else { return }
            self.presetPopover?.performClose(nil)
            self.actionHandler?(.setPresetOverride(preset))
        }
        let host = NSHostingController(rootView: picker)
        host.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = host
        presetPopover = popover
        popover.show(relativeTo: presetButton.bounds, of: presetButton, preferredEdge: .maxY)
    }
}

/// Compact preset list shown from a queue row's preset button.
struct PresetOverridePopoverView: View {
    let queuePreset: ExportPreset
    let override: ExportPreset?
    let onSelect: (ExportPreset?) -> Void

    @State private var hovered: ExportPreset?
    @State private var hoveredQueueRow = false

    private var presets: [ExportPreset] { PresetManager.shared.visiblePresets }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Preset for This Item")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            row(
                title: String(localized: "Queue preset", comment: "Preset popover row that clears an item's own preset."),
                detail: PresetManager.shared.displayName(for: queuePreset),
                isSelected: override == nil,
                isHovered: hoveredQueueRow
            ) { onSelect(nil) }
            .onHover { hoveredQueueRow = $0 }

            Divider().padding(.vertical, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(presets, id: \.self) { preset in
                        row(
                            title: PresetManager.shared.displayName(for: preset),
                            detail: preset == queuePreset ? String(localized: "Queue", comment: "Marks the queue's preset in the per-item preset list.") : nil,
                            isSelected: override == preset,
                            isHovered: hovered == preset
                        ) { onSelect(preset == queuePreset ? nil : preset) }
                        .onHover { hovered = $0 ? preset : (hovered == preset ? nil : hovered) }
                    }
                }
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
        .frame(width: 260)
    }

    private func row(
        title: String,
        detail: String?,
        isSelected: Bool,
        isHovered: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(isSelected ? 1 : 0)
                Text(title).lineLimit(1)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.accentColor.opacity(0.18) : .clear)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }
}
