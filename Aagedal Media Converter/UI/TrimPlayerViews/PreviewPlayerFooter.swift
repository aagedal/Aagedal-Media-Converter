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
                    .accessibilityIdentifier("preview.media")
                    .accessibilityValue(previewTestStatus)
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
            .accessibilityLabel("Close preview")
            .accessibilityIdentifier("preview.close")
        }
    }

    private var previewTestStatus: String {
#if DEBUG
        if ProcessInfo.processInfo.environment["AMC_UI_TEST_SESSION"] == "1" {
            let backend = controller.useImageSequence ? "ImageSequence" : (controller.useMPV ? "MPV" : "AVPlayer")
            return "\(backend) \(controller.isReady ? "ready" : "loading")"
        }
#endif
        return ""
    }

    private var durationDetails: some View {
        HStack(spacing: 4) {
            Text("Input Duration: \(TimecodeFormatter.formatTimeForDisplay(seconds: item.durationSeconds, item: item, isDuration: true))")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("| Trimmed duration: \(TimecodeFormatter.formatTimeForDisplay(seconds: item.trimmedDuration, item: item, isDuration: true))")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .multilineTextAlignment(.leading)
    }
}
