// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import SwiftUI

/// Crop controls panel with aspect ratio picker and pixel inputs
struct CropControlsView: View {
    @Binding var item: VideoItem
    @ObservedObject var controller: PreviewPlayerController
    @Binding var isExpanded: Bool
    @Binding var selectedAspectRatio: AspectRatio

    // Pixel input states
    @State private var pixelX: String = "0"
    @State private var pixelY: String = "0"
    @State private var pixelWidth: String = "1920"
    @State private var pixelHeight: String = "1080"

    // Focus management for Tab navigation
    @FocusState private var focusedField: Field?

    enum Field: Hashable {
        case x, y, width, height

        var accessibilityLabel: LocalizedStringKey {
            switch self {
            case .x: return "Crop horizontal position"
            case .y: return "Crop vertical position"
            case .width: return "Crop width"
            case .height: return "Crop height"
            }
        }
    }

    /// Pixel grid the fields edit, oriented as shown in the preview (rotated clips included).
    private var frame: CropFrame {
        item.cropFrame ?? CropFrame(pixelWidth: 1920, pixelHeight: 1080, displayAspectRatio: item.videoDisplayAspectRatio)
    }

    private var currentConfig: CropConfig {
        item.cropConfig ?? CropConfig(normalizedRect: .fullFrame)
    }

    private var aspectRatioBinding: Binding<AspectRatio> {
        Binding(
            get: { selectedAspectRatio },
            set: { newRatio in
                selectedAspectRatio = newRatio
                item.updateCrop { config, editor in config.lockAspectRatio(newRatio, using: editor) }
            }
        )
    }

    var body: some View {
        if isExpanded {
            VStack(spacing: 4) {
                // Main controls row
                HStack(spacing: 8) {
                    // Aspect ratio picker
                    Picker("Crop aspect ratio", selection: aspectRatioBinding) {
                        ForEach(AspectRatio.allCases) { ratio in
                            Text(ratio.displayName).tag(ratio)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityIdentifier("crop.aspectRatio")
                    .frame(width: 200)

                    Divider()
                        .frame(height: 20)

                    // Pixel inputs apply on Return and when focus leaves the field
                    compactPixelField(label: "X", value: $pixelX, field: .x)
                    compactPixelField(label: "Y", value: $pixelY, field: .y)
                    compactPixelField(label: "W", value: $pixelWidth, field: .width)
                    compactPixelField(label: "H", value: $pixelHeight, field: .height)

                    Divider()
                        .frame(height: 20)

                    // Quick actions
                    Button("Reset") {
                        resetCrop()
                    }
                    .accessibilityLabel("Reset crop")
                    .accessibilityIdentifier("crop.reset")
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Center") {
                        centerCrop()
                    }
                    .help("Center the crop box in the frame")
                    .accessibilityLabel("Center crop")
                    .accessibilityIdentifier("crop.center")
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    // Exit/Done button
                    Button("Done") {
                        isExpanded = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Exit crop mode")
                    .accessibilityLabel("Exit crop mode")
                    .accessibilityIdentifier("crop.done")
                }

                // Info line (always visible to prevent UI shift)
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if let config = item.cropConfig, let output = frame.outputSize(for: config) {
                        Text(outputDescription(output))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                            .accessibilityIdentifier("crop.outputSize")
                        Text("·")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text("Note: Crop requires re-encoding and will not work with Stream Copy preset.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .onAppear {
                updatePixelInputsFromConfig()
                // Initialize aspect ratio from config
                if let config = item.cropConfig {
                    selectedAspectRatio = config.aspectRatioLock ?? .free
                }
            }
            .onChange(of: item.cropConfig) { _, _ in
                // Drags and keyboard shortcuts edit the crop too; keep the fields current.
                updatePixelInputsFromConfig()
            }
            .onChange(of: item.cropFrame) { _, _ in
                // Metadata can arrive after the panel opens; drop values typed against the
                // 1920×1080 placeholder so leaving a field doesn't apply them to the real frame.
                updatePixelInputsFromConfig()
            }
            .onChange(of: focusedField) { previous, _ in
                if let previous { applyPixelInputs(editedField: previous) }
            }
        }
    }

    private func outputDescription(_ output: (width: Int, height: Int)) -> String {
        let size = "\(output.width) × \(output.height)"
        if abs(frame.pixelAspectRatio - 1) > 0.01 {
            return String(localized: "Output \(size) (square pixels)", comment: "Crop output size for an anamorphic source.")
        }
        return String(localized: "Output \(size)", comment: "Crop output size.")
    }

    private func compactPixelField(label: String, value: Binding<String>, field: Field) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: 12)
            TextField("", text: value)
                .textFieldStyle(.roundedBorder)
                .frame(width: 50)
                .font(.caption)
                .focused($focusedField, equals: field)
                .accessibilityLabel(field.accessibilityLabel)
                .accessibilityValue("\(value.wrappedValue) pixels")
                .accessibilityHint("Enter a pixel value and press Return to apply.")
                .accessibilityIdentifier("crop.\(field)")
                .onSubmit {
                    applyPixelInputs(editedField: field)
                }
        }
    }

    private func updatePixelInputsFromConfig() {
        let pixelRect = currentConfig.pixelRect(sourceWidth: frame.pixelWidth, sourceHeight: frame.pixelHeight)
        pixelX = "\(pixelRect.x)"
        pixelY = "\(pixelRect.y)"
        pixelWidth = "\(pixelRect.width)"
        pixelHeight = "\(pixelRect.height)"
    }

    /// Applies the typed pixel values. Values are clamped to the frame; with an aspect-ratio
    /// lock, the edited dimension wins and the other one follows.
    private func applyPixelInputs(editedField: Field) {
        let frame = frame
        let current = currentConfig.pixelRect(sourceWidth: frame.pixelWidth, sourceHeight: frame.pixelHeight)
        guard let x = Int(pixelX.trimmingCharacters(in: .whitespaces)),
              let y = Int(pixelY.trimmingCharacters(in: .whitespaces)),
              let width = Int(pixelWidth.trimmingCharacters(in: .whitespaces)),
              let height = Int(pixelHeight.trimmingCharacters(in: .whitespaces)) else {
            updatePixelInputsFromConfig()
            return
        }
        let typed = PixelCropRect(x: x, y: y, width: width, height: height)
        guard typed != current else { return }

        let lock = selectedAspectRatio
        item.updateCrop { config, editor in
            var rect = editor.clamped(CropRect.fromPixelRect(typed, width: frame.pixelWidth, height: frame.pixelHeight))
            if let ratio = lock.numericRatio {
                switch editedField {
                case .width, .height:
                    rect = editor.matching(rect, aspectRatio: ratio, keepingWidth: editedField == .width)
                case .x, .y:
                    // Only the position changed; keep the locked size.
                    rect.width = config.normalizedRect.width
                    rect.height = config.normalizedRect.height
                    rect = editor.clamped(rect)
                }
            }
            config.normalizedRect = rect
            config.aspectRatioLock = lock == .free ? nil : lock
        }
        // Show the values actually applied (clamped or ratio-adjusted).
        updatePixelInputsFromConfig()
    }

    private func resetCrop() {
        item.cropConfig = nil
        selectedAspectRatio = .free
        updatePixelInputsFromConfig()
    }

    /// Centers the current crop box; with no crop yet, starts from an 80% box in the chosen ratio.
    private func centerCrop() {
        let lock = selectedAspectRatio
        item.updateCrop { config, editor in
            var rect = config.normalizedRect
            if !config.isActive {
                let ratio = lock.numericRatio
                let start = ratio.map { editor.fitted(rect, to: $0) } ?? rect
                rect = editor.scaled(start, by: 0.8, aspectRatio: ratio)
            }
            config.normalizedRect = editor.centered(rect)
            config.aspectRatioLock = lock == .free ? nil : lock
        }
    }
}
