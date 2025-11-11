// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Footer section for PreviewPlayerView showing metadata and controls.

import SwiftUI

struct PreviewPlayerFooter: View {
    let item: VideoItem
    let controller: PreviewPlayerController
    let currentPlaybackTime: Double
    let dismiss: () -> Void
    let togglePlaybackControls: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                durationDetails
            }

            Spacer()

            VStack(alignment: .leading, spacing: 2) {
                Text("Keyboard shortcuts:").font(.headline)
                Text("J/K/L: reverse • pause • play (use for smooth playback)")
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Text("I/O: in/out • ⇧I/⇧O: jump • ⌥I/⌥O: clear • ⌘L: loop")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.trailing, 10)

            Button(role: .cancel, action: dismiss) {
                Label("Close", systemImage: "xmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundColor(.secondary)
                    .font(.system(size: 24))
            }
            .buttonStyle(.plain)
            .help("Close preview")
        }
    }

    private var durationDetails: some View {
        HStack(spacing: 4) {
            Text("Input Duration: \(item.duration)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("| Trimmed duration: \(formattedTime(item.trimmedDuration))")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if let range = controller.fallbackPreviewRange {
                Text("| Preview: \(formattedTime(range.lowerBound))–\(formattedTime(range.upperBound))")
                    .font(.subheadline)
                    .foregroundColor(.orange)

                if controller.isLoadingChunk {
                    Text("(loading chunk…)")
                        .font(.caption)
                        .foregroundColor(.orange.opacity(0.7))
                } else if controller.loadedChunks.count > 1 {
                    Text("(\(controller.loadedChunks.count) chunks loaded)")
                        .font(.caption)
                        .foregroundColor(.orange.opacity(0.7))
                }
            }
        }
        .multilineTextAlignment(.leading)
    }

    private func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }
        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%02d:%02d", minutes, secs)
        }
    }
}
