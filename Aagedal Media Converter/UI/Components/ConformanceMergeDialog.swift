// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Two-step dialog for configuring a conformance (force) merge.
/// Step 1: User picks which clip defines the reference format.
/// Step 2: Confirmation showing what will be re-encoded.
struct ConformanceMergeDialog: View {
    let items: [VideoItem]
    let metadata: [UUID: VideoMetadata]
    let onConfirm: (UUID) -> Void  // passes reference item ID
    let onCancel: () -> Void

    @State private var selectedReferenceID: UUID?
    @State private var showConfirmation = false

    private var analyses: [ConversionManager.ConformanceAnalysis] {
        guard let refID = selectedReferenceID else { return [] }
        return ConversionManager.analyzeConformance(
            items: items,
            referenceItemID: refID,
            metadata: metadata
        )
    }

    private var referenceTarget: ConversionManager.ConformanceTarget? {
        guard let refID = selectedReferenceID,
              let meta = metadata[refID],
              let item = items.first(where: { $0.id == refID }) else { return nil }
        return ConversionManager.ConformanceTarget.from(metadata: meta, url: item.url)
    }

    private var referenceCodecSupported: Bool {
        guard let target = referenceTarget else { return false }
        return FFMPEGCommandBuilder.ffmpegVideoEncoder(for: target.videoCodec) != nil
    }

    private var clipsNeedingReencode: Int {
        analyses.filter { $0.needsConformance }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !showConfirmation {
                referencePickerView
            } else {
                confirmationView
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    // MARK: - Step 1: Reference Picker

    @ViewBuilder
    private var referencePickerView: some View {
        Text("Force Merge — Select Reference Format")
            .font(.headline)

        Text("All clips will be conformed to match the selected clip's format.")
            .font(.callout)
            .foregroundStyle(.secondary)

        ScrollView {
            VStack(spacing: 4) {
                ForEach(items, id: \.id) { item in
                    referenceRow(for: item)
                }
            }
        }
        .frame(maxHeight: 300)

        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Next") { showConfirmation = true }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedReferenceID == nil)
        }
    }

    @ViewBuilder
    private func referenceRow(for item: VideoItem) -> some View {
        let meta = metadata[item.id]
        let video = meta?.primaryVideoStream
        let audio = meta?.audioStreams.first
        let isSelected = selectedReferenceID == item.id

        Button {
            selectedReferenceID = item.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        if let v = video {
                            Text("\(v.width ?? 0)x\(v.height ?? 0)")
                            Text(v.codec ?? "?")
                            if let fr = v.frameRate?.value {
                                // Keep fractional rates (29.97, 23.976) visible: rounding
                                // made 29.97 and 30 fps clips look identical here even
                                // though the merge plan treats them as a mismatch.
                                Text(verbatim: "\(fr.formatted(.number.precision(.fractionLength(0...3))))fps")
                            }
                        }
                        if let a = audio {
                            Text("\(a.channels ?? 0)ch \(a.codec ?? "?")")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Step 2: Confirmation

    @ViewBuilder
    private var confirmationView: some View {
        Text("Conformance Merge Plan")
            .font(.headline)

        if let target = referenceTarget {
            HStack(spacing: 6) {
                Image(systemName: "target")
                    .foregroundStyle(.blue)
                Text("Target: \(target.formatSummary)")
                    .font(.callout)
            }
        }

        if !referenceCodecSupported {
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text("Cannot encode to \(referenceTarget?.videoCodec ?? "unknown") — unsupported codec. Please select a different reference clip.")
                    .font(.callout)
            }
        }

        ScrollView {
            VStack(spacing: 4) {
                ForEach(analyses) { analysis in
                    analysisRow(for: analysis)
                }
            }
        }
        .frame(maxHeight: 300)

        HStack {
            Text("\(clipsNeedingReencode) of \(items.count) clips need re-encoding")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }

        HStack {
            Button("Back") { showConfirmation = false }
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Start Force Merge") {
                if let refID = selectedReferenceID {
                    onConfirm(refID)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!referenceCodecSupported)
        }
    }

    @ViewBuilder
    private func analysisRow(for analysis: ConversionManager.ConformanceAnalysis) -> some View {
        HStack(spacing: 10) {
            if analysis.needsConformance {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(analysis.itemName)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if analysis.needsConformance {
                    let allMismatches = analysis.videoMismatches + analysis.audioMismatches
                    Text(allMismatches.joined(separator: " | "))
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Already matches — stream copy")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
    }
}
