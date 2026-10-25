// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// Picks a clip of an online video before it is downloaded: plays the probe's
/// preview stream with mpv and sets in and out points at the playhead on the
/// fullscreen player's timeline. Without a playable stream the timeline still
/// moves a playhead, so points can be set by position alone.
///
/// Keys (while no text field has focus, or during a timeline drag): Space
/// play/pause, I/O set in/out, ⌥I/⌥O clear, ⇧I/⇧O jump to the point,
/// ←/→ step 1 s (⇧ 10 s). The in and out handles can also be dragged.
struct ClipPreviewView: View {
    /// Best stream first; the next is tried when one fails to load.
    let streams: [YTDLPPreviewStream]
    let duration: Double
    /// In-point in source seconds; nil is the start of the video.
    @Binding var inPoint: Double?
    /// Out-point in source seconds; nil is the end of the video.
    @Binding var outPoint: Double?
    /// Height of the video box; the parent shrinks it in short windows.
    var videoHeight: CGFloat = 300
    /// Lets the parent clear its own text-field focus state, which would
    /// otherwise take keyboard focus back from the picker.
    var onReleaseTextFocus: () -> Void = {}

    @StateObject private var player = MPVPlayer()
    @State private var streamIndex = 0
    /// Playhead while scrubbing, without a stream, or until a seek lands.
    @State private var localTime: Double = 0
    @State private var isDraggingTimeline = false
    /// Seek target the player hasn't reported reaching yet.
    @State private var settlingTarget: Double?

    /// Points this close to either end of the video mean "no point".
    private static let edgeTolerance = 0.05
    /// Shortest clip the handles allow.
    private static let minimumClipLength = 0.1

    private var stream: YTDLPPreviewStream? { streams.indices.contains(streamIndex) ? streams[streamIndex] : nil }

    private var hasPlayer: Bool { stream != nil && player.error == nil }

    private var playheadTime: Double {
        guard hasPlayer, player.isFileLoaded, !isDraggingTimeline, settlingTarget == nil else { return localTime }
        return min(max(0, player.timePos), duration)
    }

    private var videoAspectRatio: CGFloat {
        if let width = stream?.width, let height = stream?.height, width > 0, height > 0 {
            return CGFloat(width) / CGFloat(height)
        }
        return 16.0 / 9.0
    }

    var body: some View {
        VStack(spacing: 6) {
            videoArea
            PlayheadTrimTimeline(
                duration: duration,
                playbackTime: playheadTime,
                trimStart: inPoint,
                trimEnd: outPoint,
                trackColor: Color.primary.opacity(0.2),
                isDragging: $isDraggingTimeline,
                accessibilityValue: DownloadSection.formatTime(playheadTime),
                accessibilityIdentifier: "downloadClipTimeline",
                onScrubBegan: {
                    releaseTextFocus()
                    localTime = playheadTime
                },
                onSeek: { time in
                    localTime = time
                    if hasPlayer { player.seekForScrubbing(to: time) }
                },
                onScrubEnded: { seek(to: localTime) },
                onTrimStartDrag: { time in
                    let latest = (outPoint ?? duration) - Self.minimumClipLength
                    let clamped = min(max(0, time), latest)
                    inPoint = clamped <= Self.edgeTolerance ? nil : clamped
                },
                onTrimEndDrag: { time in
                    let earliest = (inPoint ?? 0) + Self.minimumClipLength
                    let clamped = max(min(duration, time), earliest)
                    outPoint = clamped >= duration - Self.edgeTolerance ? nil : clamped
                }
            )
            transportRow
        }
        .background(ClipPreviewKeyMonitor(handler: handleKey))
        .task(id: streamIndex) { loadStream() }
        .onChange(of: player.error) { _, error in
            // A refused format URL (HTTP 403) often has a working sibling.
            if error != nil, streamIndex + 1 < streams.count { streamIndex += 1 }
        }
        .onChange(of: player.timePos) { _, time in
            if let target = settlingTarget, abs(time - target) < 0.5 { settlingTarget = nil }
        }
        .onChange(of: player.isPlaying) { _, playing in
            if playing { settlingTarget = nil }
        }
        .onDisappear { player.stop() }
    }

    // MARK: - Subviews

    private var videoArea: some View {
        ZStack {
            Color.black
            if stream != nil {
                // mpv binds to its first drawable, so this view stays mounted
                // through failed loads and fallbacks, and the parent gives each
                // URL a fresh view (and player) instead of swapping this one.
                FullscreenMPVView(player: player, fixedRenderAspect: videoAspectRatio)
                    .aspectRatio(videoAspectRatio, contentMode: .fit)
            }
            if hasPlayer {
                if !player.isFileLoaded || player.isBusy {
                    ProgressView().controlSize(.small).tint(.white)
                }
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "eye.slash")
                    Text(stream == nil
                         ? "No preview for this video. Set points on the timeline."
                         : "The preview couldn't be played. Set points on the timeline.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.7))
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
            }
        }
        // The representable has no intrinsic size; a fixed box keeps the
        // video from collapsing while the panel sizes to its content.
        .frame(maxWidth: .infinity)
        .frame(height: videoHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            releaseTextFocus()
            togglePlayback()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Clip preview")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { togglePlayback() }
        .accessibilityIdentifier("downloadClipPreview")
    }

    private var transportRow: some View {
        HStack(spacing: 10) {
            Button { seek(to: inPoint ?? 0) } label: {
                Label(DownloadSection.formatTime(inPoint ?? 0), systemImage: "arrow.left.to.line")
            }
            .help("Jump to in point (⇧I)")
            .accessibilityLabel("Jump to in point")
            .accessibilityIdentifier("downloadClipJumpToIn")

            Button(action: togglePlayback) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 14)
            }
            .disabled(!hasPlayer || !player.isFileLoaded)
            .help("Play or pause (Space)")
            .accessibilityLabel(player.isPlaying ? Text("Pause") : Text("Play"))
            .accessibilityIdentifier("downloadClipPlayPause")

            Text(verbatim: "\(DownloadSection.formatTime(playheadTime)) / \(DownloadSection.formatTime(duration))")
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel("Playback position")
                .accessibilityValue(DownloadSection.formatTime(playheadTime))

            Button { seek(to: outPoint ?? duration) } label: {
                Label(DownloadSection.formatTime(outPoint ?? duration), systemImage: "arrow.right.to.line")
                    .labelStyle(.trailingIcon)
            }
            .help("Jump to out point (⇧O)")
            .accessibilityLabel("Jump to out point")
            .accessibilityIdentifier("downloadClipJumpToOut")

            Spacer()

            Button("Set In", action: setInPoint)
                .help("Set the in point at the playhead (I). ⌥I clears it.")
                .accessibilityIdentifier("downloadClipSetIn")
            Button("Set Out", action: setOutPoint)
                .help("Set the out point at the playhead (O). ⌥O clears it.")
                .accessibilityIdentifier("downloadClipSetOut")
        }
        .buttonStyle(.borderless)
        .font(.system(.subheadline, design: .monospaced))
        .controlSize(.small)
    }

    // MARK: - Playback

    private func loadStream() {
        guard let stream else { return }
        player.load(
            url: stream.videoURL,
            startTime: inPoint ?? 0,
            autostart: false,
            source: .init(externalAudioURL: stream.audioURL, httpHeaders: stream.httpHeaders)
        )
        localTime = inPoint ?? 0
    }

    private func togglePlayback() {
        guard hasPlayer, player.isFileLoaded else { return }
        if !player.isPlaying, playheadTime >= duration - 0.25 {
            seek(to: inPoint ?? 0)
        }
        player.togglePause()
    }

    private func seek(to time: Double) {
        let target = min(max(0, time), duration)
        localTime = target
        guard hasPlayer else { return }
        settlingTarget = player.isFileLoaded ? target : nil
        player.cancelPendingScrubSeeks()
        player.seek(to: target)
    }

    // MARK: - In and out points

    private func setInPoint() {
        let time = playheadTime
        inPoint = time <= Self.edgeTolerance ? nil : time
        if let outPoint, outPoint <= time { self.outPoint = nil }
    }

    private func setOutPoint() {
        let time = playheadTime
        outPoint = time >= duration - Self.edgeTolerance ? nil : time
        if let inPoint, inPoint >= time { self.inPoint = nil }
    }

    /// Keys reach the player only once the URL and time fields give up focus.
    private func releaseTextFocus() {
        onReleaseTextFocus()
        if let window = NSApp.keyWindow, window.firstResponder is NSText {
            window.makeFirstResponder(nil)
        }
    }

    private func handleKey(_ event: ClipPreviewKeyPress, editingText: Bool) -> Bool {
        // Text fields keep their keys, except while the timeline is dragged.
        guard !editingText || isDraggingTimeline else { return false }
        let modifiers = event.modifiers.intersection([.command, .control, .option, .shift])
        if let arrow = event.arrow {
            guard modifiers.isSubset(of: .shift) else { return false }
            let step = modifiers.contains(.shift) ? 10.0 : 1.0
            seek(to: playheadTime + (arrow == .left ? -step : step))
            return true
        }
        guard !modifiers.contains(.command), !modifiers.contains(.control),
              let key = event.characters?.lowercased() else { return false }
        switch (key, modifiers) {
        case (" ", []):
            togglePlayback()
        case ("i", []):
            setInPoint()
        case ("o", []):
            setOutPoint()
        case ("i", .option):
            inPoint = nil
        case ("o", .option):
            outPoint = nil
        case ("i", .shift):
            seek(to: inPoint ?? 0)
        case ("o", .shift):
            seek(to: outPoint ?? duration)
        default:
            return false
        }
        return true
    }
}

private struct ClipPreviewKeyPress: Sendable {
    let characters: String?
    let modifiers: NSEvent.ModifierFlags
    let arrow: Arrow?

    enum Arrow: Sendable { case left, right }
}

/// Routes key presses in the hosting window to the clip preview while no text
/// field is being edited.
private struct ClipPreviewKeyMonitor: NSViewRepresentable {
    let handler: (ClipPreviewKeyPress, _ editingText: Bool) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = handler
    }

    func makeCoordinator() -> Coordinator { Coordinator(handler: handler) }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, @unchecked Sendable {
        var handler: (ClipPreviewKeyPress, Bool) -> Bool
        weak var view: NSView?
        private var monitor: Any?

        init(handler: @escaping (ClipPreviewKeyPress, Bool) -> Bool) {
            self.handler = handler
            super.init()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let windowNumber = event.windowNumber
                let press = ClipPreviewKeyPress(
                    characters: event.charactersIgnoringModifiers,
                    modifiers: event.modifierFlags,
                    arrow: event.specialKey == .leftArrow ? .left : event.specialKey == .rightArrow ? .right : nil
                )
                // Local monitors run on the main thread.
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard let window = self.view?.window, window.windowNumber == windowNumber, window.isKeyWindow,
                          window.attachedSheet == nil else { return false }
                    return self.handler(press, window.firstResponder is NSText)
                }
                return handled ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { stop() }
    }
}
