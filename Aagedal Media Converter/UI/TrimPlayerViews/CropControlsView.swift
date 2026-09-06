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

    private var sourceWidth: Int {
        item.metadata?.primaryVideoStream?.width ?? 1920
    }

    private var sourceHeight: Int {
        item.metadata?.primaryVideoStream?.height ?? 1080
    }

    /// The video's display aspect ratio (accounting for pixel aspect ratio / PAR)
    private var videoDisplayAspectRatio: Double {
        item.videoDisplayAspectRatio ?? (Double(sourceWidth) / Double(sourceHeight))
    }

    private var configBinding: Binding<CropConfig> {
        // Lazy initialization pattern from AudioRoutingView
        Binding(
            get: {
                if let config = item.cropConfig {
                    return config
                } else {
                    // Default: full frame
                    return CropConfig(normalizedRect: .fullFrame)
                }
            },
            set: { newValue in
                item.cropConfig = newValue.isActive ? newValue : nil
                updatePixelInputsFromConfig()
            }
        )
    }

    var body: some View {
        if isExpanded {
            VStack(spacing: 4) {
                // Main controls row
                HStack(spacing: 8) {
                    // Aspect ratio picker
                    Picker("Crop aspect ratio", selection: $selectedAspectRatio) {
                        ForEach(AspectRatio.allCases) { ratio in
                            Text(ratio.displayName).tag(ratio)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityIdentifier("crop.aspectRatio")
                    .frame(width: 200)
                    .onChange(of: selectedAspectRatio) { _, newRatio in
                        var config = configBinding.wrappedValue
                        config.aspectRatioLock = newRatio == .free ? nil : newRatio

                         // If not free, adjust the rectangle to match the aspect ratio
                         if let targetRatio = newRatio.numericRatio {
                             var rect = config.normalizedRect

                             // Calculate center point to maintain position
                             let centerX = rect.x + rect.width / 2
                             let centerY = rect.y + rect.height / 2

                             // Convert target aspect ratio from VISUAL space to normalized (source-pixel) space.
                             // The target ratio (e.g. 1:1) specifies the desired displayed/output shape.
                             // For anamorphic sources, normalizedRect is stored in source pixel coordinates,
                             // so we must use the *display* aspect ratio (DAR) to derive the pixel-space ratio.
                             let normalizedTargetRatio = targetRatio / videoDisplayAspectRatio

                             // Calculate maximum rectangle that fits aspect ratio within bounds
                             // Start with current area, but ensure it fits within 1.0 x 1.0 bounds
                             let area = min(rect.width * rect.height, 1.0 * 1.0)

                             // Calculate dimensions that maintain aspect ratio and fit within bounds
                             var newWidth: Double
                             var newHeight: Double

                             // Try to fit rectangle with target aspect ratio within full frame
                             if normalizedTargetRatio >= 1.0 {
                                 // Wider than tall: fit width to 1.0, scale height accordingly
                                 newWidth = 1.0
                                 newHeight = newWidth / normalizedTargetRatio
                                 if newHeight > 1.0 {
                                     // If height still exceeds, scale down proportionally
                                     newHeight = 1.0
                                     newWidth = newHeight * normalizedTargetRatio
                                 }
                             } else {
                                 // Taller than wide: fit height to 1.0, scale width accordingly
                                 newHeight = 1.0
                                 newWidth = newHeight * normalizedTargetRatio
                                 if newWidth > 1.0 {
                                     // If width still exceeds, scale down proportionally
                                     newWidth = 1.0
                                     newHeight = newWidth / normalizedTargetRatio
                                 }
                             }

                             // If the calculated rectangle is smaller than we'd like, try to make it larger
                             // while maintaining aspect ratio and staying within bounds
                             let maxPossibleWidth = 1.0
                             let maxPossibleHeight = 1.0

                             if normalizedTargetRatio >= 1.0 {
                                 // For wide ratios, maximize width first
                                 newWidth = min(maxPossibleWidth, sqrt(area * normalizedTargetRatio))
                                 newHeight = newWidth / normalizedTargetRatio
                                 if newHeight > maxPossibleHeight {
                                     newHeight = maxPossibleHeight
                                     newWidth = newHeight * normalizedTargetRatio
                                 }
                             } else {
                                 // For tall ratios, maximize height first
                                 newHeight = min(maxPossibleHeight, sqrt(area / normalizedTargetRatio))
                                 newWidth = newHeight * normalizedTargetRatio
                                 if newWidth > maxPossibleWidth {
                                     newWidth = maxPossibleWidth
                                     newHeight = newWidth / normalizedTargetRatio
                                 }
                             }

                             // Position to maintain center as much as possible, but ensure it fits
                             rect.width = newWidth
                             rect.height = newHeight
                             rect.x = max(0, min(1.0 - rect.width, centerX - rect.width / 2))
                             rect.y = max(0, min(1.0 - rect.height, centerY - rect.height / 2))

                             config.normalizedRect = rect
                         }

                        configBinding.wrappedValue = config
                        updatePixelInputsFromConfig()
                    }

                    Divider()
                        .frame(height: 20)

                    // Pixel inputs with auto-apply
                    compactPixelField(label: "X", value: $pixelX, field: .x, autoApply: true)
                    compactPixelField(label: "Y", value: $pixelY, field: .y, autoApply: true)
                    compactPixelField(label: "W", value: $pixelWidth, field: .width, autoApply: true)
                    compactPixelField(label: "H", value: $pixelHeight, field: .height, autoApply: true)

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

                // Warning message for Stream Copy preset (always visible to prevent UI shift)
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundColor(.secondary)
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
        }
    }

    private func compactPixelField(label: String, value: Binding<String>, field: Field, autoApply: Bool = false) -> some View {
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
                    if autoApply {
                        applyPixelInputs()
                    }
                }
        }
    }

    private func updatePixelInputsFromConfig() {
        let config = configBinding.wrappedValue
        let pixelRect = config.pixelRect(sourceWidth: sourceWidth, sourceHeight: sourceHeight)

        pixelX = "\(pixelRect.x)"
        pixelY = "\(pixelRect.y)"
        pixelWidth = "\(pixelRect.width)"
        pixelHeight = "\(pixelRect.height)"
    }

    private func applyPixelInputs() {
        guard let x = Int(pixelX),
              let y = Int(pixelY),
              let width = Int(pixelWidth),
              let height = Int(pixelHeight) else {
            return
        }

        let pixelRect = PixelCropRect(x: x, y: y, width: width, height: height)
        var config = CropConfig.fromPixelRect(
            pixelRect,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            aspectRatioLock: selectedAspectRatio == .free ? nil : selectedAspectRatio
        )
        config.aspectRatioLock = selectedAspectRatio == .free ? nil : selectedAspectRatio
        configBinding.wrappedValue = config
    }

    private func resetCrop() {
        item.cropConfig = nil
        selectedAspectRatio = .free
        updatePixelInputsFromConfig()
    }

    private func centerCrop() {
        // Create a centered crop at 80% of source dimensions
        let centerX = 0.1
        let centerY = 0.1
        let cropWidth = 0.8
        let cropHeight = 0.8

        var config = CropConfig(
            normalizedRect: CropRect(x: centerX, y: centerY, width: cropWidth, height: cropHeight)
        )
        config.aspectRatioLock = selectedAspectRatio == .free ? nil : selectedAspectRatio
        configBinding.wrappedValue = config
    }
}
