// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// SwiftUI subview containing trim timeline and related controls used in PreviewPlayerView.

import SwiftUI

struct PreviewTrimControls: View {
    let item: VideoItem
    @ObservedObject var controller: PreviewPlayerController
    @Binding var currentPlaybackTime: Double
    let onSeek: (Double) -> Void
    let onReset: () -> Void
    let onCaptureScreenshot: () -> Void
    let trimStartBinding: Binding<Double>
    let trimEndBinding: Binding<Double>
    let onTrimEditingChanged: (Bool) -> Void
    let loopBinding: Binding<Bool>

    var body: some View {
        let duration = max(item.durationSeconds, 0)
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                TrimTimelineView(
                    trimStart: trimStartBinding,
                    trimEnd: trimEndBinding,
                    duration: duration,
                    playbackTime: currentPlaybackTime,
                    thumbnails: controller.previewAssets?.thumbnails,
                    waveformURL: controller.currentWaveformURL,
                    isLoading: controller.isLoadingPreviewAssets,
                    fallbackPreviewRange: controller.fallbackPreviewRange,
                    loadedChunks: controller.loadedChunks,
                    step: 0.1,
                    onEditingChanged: onTrimEditingChanged,
                    onSeek: onSeek
                )
                .onReceive(controller.playbackTimePublisher) { time in
                    currentPlaybackTime = time
                }

                controlButtons
            }
        }
    }

    private var controlButtons: some View {
        HStack(spacing: 12) {
            Button(action: { controller.seekTo(item.effectiveTrimStart) }) {
                Label("\(formattedTime(item.effectiveTrimStart))", systemImage: "arrow.left.to.line")
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .help("Jump to trim start")

            HStack {
                Label("\(formattedTime(currentPlaybackTime))", systemImage: "arrowtriangle.left.and.line.vertical.and.arrowtriangle.right")
                    .font(.system(.subheadline, design: .monospaced))
                    .padding(0)
            }
            .padding(.horizontal, 30)

            Button(action: { controller.seekTo(item.effectiveTrimEnd) }) {
                Label("\(formattedTime(item.effectiveTrimEnd))", systemImage: "arrow.right.to.line")
                    .labelStyle(.trailingIcon)
            }
            .buttonStyle(.plain)
            .font(.system(.subheadline, design: .monospaced))
            .foregroundColor(.accentColor)
            .help("Jump to trim end")

            Spacer()
            
            HStack(spacing: 10) {
                Button(action: onCaptureScreenshot) {
                    Label("Capture frame", systemImage: "camera")
                        .labelStyle(.iconOnly)
                }
                .disabled(controller.isCapturingScreenshot)
                .help("Save the current frame as an image")

                Button {
                    controller.revealLastScreenshotInFinder()
                } label: {
                    Image(systemName: "magnifyingglass.circle.fill")
                        .help("Reveal last screenshot in Finder")
                        .foregroundColor(controller.lastScreenshotURL == nil ? .gray : .blue)
                }
                .disabled(controller.lastScreenshotURL == nil ? true : false)

                // Draggable icon for last screenshot
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .help("Drag last screenshot to another app")
                    .foregroundColor(controller.lastScreenshotURL == nil ? .gray : .blue)
                    .opacity(controller.lastScreenshotURL == nil ? 0.5 : 1)
                    .onDrag {
                        controller.lastScreenshotDragItemProvider() ?? NSItemProvider()
                    }
                    .disabled(controller.lastScreenshotURL == nil ? true : false)
            }
            .padding(.trailing, 30)

            audioTrackSelector

            Toggle(isOn: loopBinding) {
                Label("Loop", systemImage: "repeat")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .help("Loop playback (⌘L)")

            Button(action: onReset) {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .labelStyle(.iconOnly)
            }
            .disabled(item.trimStart == nil && item.trimEnd == nil)
            .help("Reset trim points")
        }
    }

    private var audioTrackSelector: some View {
        Menu {
            if controller.audioTrackOptions.isEmpty {
                Text("No alternate audio tracks")
            } else {
                ForEach(controller.audioTrackOptions) { option in
                    Button {
                        controller.selectAudioTrack(at: option.position)
                    } label: {
                        HStack {
                            Text(option.title)
                            if let subtitle = option.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if option.position == controller.selectedAudioTrackOrderIndex {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .disabled(option.position == controller.selectedAudioTrackOrderIndex)
                }
            }
        } label: {
            Label("Select audio track", systemImage: "speaker.wave.2.fill")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .disabled(controller.audioTrackOptions.count <= 1)
        .help(controller.audioTrackOptions.isEmpty ? "No alternate audio tracks" : "Select audio track")
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
