// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AVKit
@preconcurrency import AppKit
import Carbon.HIToolbox
import OSLog

/// Clean fullscreen video player view
struct FullscreenPlayerView: View {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "FullscreenPlayerView")

    let item: VideoItem
    let onClose: () -> Void
    let onCloseWithPosition: ((Double) -> Void)?
    let onPreviousItem: (@Sendable () -> Void)?
    let onNextItem: (@Sendable () -> Void)?
    let onTrimChanged: ((Double?, Double?) -> Void)?
    let onOverlayVisibilityChanged: ((Bool) -> Void)?
    let onTimecodeDisplayModeChanged: ((TimecodeDisplayMode) -> Void)?
    let canGoToPrevious: Bool
    let canGoToNext: Bool
    let onToggleQueueAutoAdvance: () -> Void
    let onToggleQueueLoop: () -> Void
    let onPlaybackDidFinish: () -> Void
    let autoPlayOnReady: Bool
    let startTime: Double?

    @StateObject private var controller: PreviewPlayerController
    @State private var itemState: VideoItem

    @State private var showOverlay: Bool
    @State private var isMouseIdle = false
    @State private var isHoveringControls = false
    @State private var isHoveringRightEdge = false
    @State private var overlayHideTask: Task<Void, Never>?
    @State private var isDraggingTimeline = false
    // Timecode display state
    @State private var timecodeDisplayMode: TimecodeDisplayMode
    @State private var isEditingTimecode = false
    @State private var timecodeInput = ""
    @State private var timecodeJustActivated = false
    @State private var pendingTimecodeCharacter: String?
    @FocusState private var isTimecodeFocused: Bool
    @State private var queueAutoAdvanceState: Bool
    @State private var queueLoopState: Bool
    @State private var autoAdvanceTriggered = false
    @State private var autoPlayPending = false

    // Timeline scrubbing
    @State private var isNarrow = false
    @State private var precisionWasActive = false
    @State private var precisionAnchorFraction: Double = 0
    @State private var precisionAnchorX: CGFloat = 0
    @AppStorage("precisionScrubFactor") private var precisionScrubFactor: Double = 10.0
    @AppStorage("showCursorHideHint") private var showCursorHideHint: Bool = true

    private let rightEdgeWidth: CGFloat = 60
    private let narrowBreakpoint: CGFloat = 620

    private var bottomBarClearance: CGFloat { isNarrow ? 110 : 80 }
    init(
        item: VideoItem,
        initialOverlayHidden: Bool = false,
        initialTimecodeDisplayMode: TimecodeDisplayMode = .preferred,
        startTime: Double? = nil,
        onClose: @escaping () -> Void,
        onCloseWithPosition: ((Double) -> Void)? = nil,
        onTrimChanged: ((Double?, Double?) -> Void)? = nil,
        onPreviousItem: (@Sendable () -> Void)? = nil,
        onNextItem: (@Sendable () -> Void)? = nil,
        onOverlayVisibilityChanged: ((Bool) -> Void)? = nil,
        onTimecodeDisplayModeChanged: ((TimecodeDisplayMode) -> Void)? = nil,
        canGoToPrevious: Bool = false,
        canGoToNext: Bool = false,
        queueAutoAdvanceEnabled: Bool = false,
        queueLoopEnabled: Bool = false,
        onToggleQueueAutoAdvance: @escaping () -> Void = {},
        onToggleQueueLoop: @escaping () -> Void = {},
        onPlaybackDidFinish: @escaping () -> Void = {},
        autoPlayOnReady: Bool = false
    ) {
        self.item = item
        self.onClose = onClose
        self.onCloseWithPosition = onCloseWithPosition
        self.onTrimChanged = onTrimChanged
        self.onPreviousItem = onPreviousItem
        self.onNextItem = onNextItem
        self.onOverlayVisibilityChanged = onOverlayVisibilityChanged
        self.onTimecodeDisplayModeChanged = onTimecodeDisplayModeChanged
        self.canGoToPrevious = canGoToPrevious
        self.canGoToNext = canGoToNext
        self.onToggleQueueAutoAdvance = onToggleQueueAutoAdvance
        self.onToggleQueueLoop = onToggleQueueLoop
        self.onPlaybackDidFinish = onPlaybackDidFinish
        self.startTime = startTime
        self._itemState = State(initialValue: item)
        self._controller = StateObject(wrappedValue: PreviewPlayerController(videoItem: item))
        self._showOverlay = State(initialValue: !initialOverlayHidden)
        self._isMouseIdle = State(initialValue: initialOverlayHidden)
        self._timecodeDisplayMode = State(initialValue: initialTimecodeDisplayMode)
        self._queueAutoAdvanceState = State(initialValue: queueAutoAdvanceEnabled)
        self._queueLoopState = State(initialValue: queueLoopEnabled)
        self.autoPlayOnReady = autoPlayOnReady
        self._autoPlayPending = State(initialValue: autoPlayOnReady)
    }
    
    private var aspectRatio: CGFloat {
        if let ratio = item.videoDisplayAspectRatio, ratio.isFinite, ratio > 0 {
            return CGFloat(ratio)
        }
        return 16.0 / 9.0
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background - tap gestures applied here
                Color.black
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .gesture(
                        TapGesture(count: 2)
                            .onEnded { _ in
                                onClose()
                            }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 1)
                            .onEnded { _ in
                                controller.togglePlayback()
                            }
                    )
                
                // Video content - tap gestures also here
                videoContent
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        TapGesture(count: 2)
                            .onEnded { _ in
                                onClose()
                            }
                    )
                    .simultaneousGesture(
                        TapGesture(count: 1)
                            .onEnded { _ in
                                controller.togglePlayback()
                            }
                    )

                // Floating speed indicator — shown when overlay is hidden so the
                // user still sees JKL feedback during cursor-hidden playback.
                if !showOverlay && !isHoveringControls && !isDraggingTimeline {
                    VStack {
                        HStack {
                            PlaybackSpeedIndicator(
                                speed: controller.currentPlaybackSpeed,
                                isReversing: controller.isReverseSimulating,
                                isPlaying: controller.isPlaying
                            )
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(16)
                    .allowsHitTesting(false)
                }

                if showOverlay || isHoveringControls || isDraggingTimeline {
                    // Overlay controls - no tap gestures, blocks clicks from reaching background
                    controlsOverlay
                        .transition(.opacity)
                }
                
                // Loading indicator
                if controller.isPreparing {
                    loadingOverlay
                }
                
                // Error message
                if let error = controller.errorMessage {
                    errorOverlay(message: error)
                }

                // Right edge cursor-hide zone - positioned at trailing edge,
                // stops above the bottom controls so the bar doesn't swallow hovers.
                HStack {
                    Spacer()
                    ZStack {
                        RightEdgeCursorHideZone { hovering in
                            isHoveringRightEdge = hovering
                            if hovering {
                                if !isHoveringControls, !isDraggingTimeline {
                                    overlayHideTask?.cancel()
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        showOverlay = false
                                    }
                                    onOverlayVisibilityChanged?(true)
                                }
                            } else {
                                showOverlay = true
                                scheduleOverlayHide()
                            }
                        }

                        if showCursorHideHint && showOverlay && !isHoveringRightEdge {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                .foregroundStyle(.white.opacity(0.25))
                                .overlay {
                                    ZStack {
                                        Image(systemName: "cursorarrow")
                                            .font(.system(size: 14))
                                        Rectangle()
                                            .frame(width: 18, height: 1.5)
                                            .rotationEffect(.degrees(-45))
                                    }
                                    .foregroundStyle(.white.opacity(0.3))
                                }
                                .padding(6)
                                .animation(.easeInOut(duration: 0.3), value: showOverlay)
                                .animation(.easeInOut(duration: 0.3), value: isHoveringRightEdge)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: rightEdgeWidth)
                }
                .padding(.bottom, bottomBarClearance)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    handleMouseHover()
                case .ended:
                    break
                }
            }

        }
        .background(
            FullscreenKeyboardHandler(
                controller: controller,
                onClose: { @Sendable in
                    Task { @MainActor in
                        onClose()
                    }
                },
                onToggleTimecodeMode: { @Sendable in
                    Task { @MainActor in
                        toggleTimecodeMode()
                    }
                },
                onTimecodeInput: { @Sendable char in
                    Task { @MainActor in
                        startTimecodeEditWithChar(char)
                    }
                },
                captureScreenshot: { @Sendable in
                    Task { @MainActor in
                        captureScreenshot()
                    }
                },
                onPreviousItem: onPreviousItem,
                onNextItem: onNextItem,
                canGoToPrevious: canGoToPrevious,
                canGoToNext: canGoToNext,
                isEditingTimecode: isEditingTimecode,
                onToggleAutoNext: { @Sendable in
                    Task { @MainActor in
                        toggleQueueAutoAdvance()
                    }
                },
                onToggleLoop: { @Sendable in
                    Task { @MainActor in
                        toggleQueueLoop()
                    }
                },
                isAutoNextEnabled: queueAutoAdvanceState,
                onSetTrimIn: { @Sendable in
                    Task { @MainActor in
                        handleTrimInPoint(clearToStart: false)
                    }
                },
                onSetTrimOut: { @Sendable in
                    Task { @MainActor in
                        handleTrimOutPoint(clearToEnd: false)
                    }
                },
                onClearTrimIn: { @Sendable in
                    Task { @MainActor in
                        handleTrimInPoint(clearToStart: true)
                    }
                },
                onClearTrimOut: { @Sendable in
                    Task { @MainActor in
                        handleTrimOutPoint(clearToEnd: true)
                    }
                },
                onClearAllTrim: { @Sendable in
                    Task { @MainActor in
                        clearAllTrimPoints()
                    }
                },
                onSeekToTrimIn: { @Sendable in
                    Task { @MainActor in
                        seekToTrimIn()
                    }
                },
                onSeekToTrimOut: { @Sendable in
                    Task { @MainActor in
                        seekToTrimOut()
                    }
                }
            )
        )
        .onReceive(controller.playbackTimePublisher) { time in
            handleAutoAdvanceProximity(time)
        }
        .onChange(of: controller.isReady) { _, isReady in
            guard isReady, autoPlayPending else { return }
            if !isPlaybackActive {
                controller.togglePlayback()
            }
            autoPlayPending = false
        }
        .onAppear {
            autoAdvanceTriggered = false
            controller.playbackDidFinish = onPlaybackDidFinish
            // Schedule overlay hide if it's currently visible
            if showOverlay {
                scheduleOverlayHide()
            }

            // Capture startTime immediately on appear to avoid any SwiftUI state issues
            let capturedStartTime = startTime

            // Prepare preview IMMEDIATELY - don't wait for metadata
            controller.updateVideoItem(itemState)
            let initialTime = capturedStartTime ?? itemState.effectiveTrimStart
            Self.logger.debug("startTime=\(String(describing: capturedStartTime)), effectiveTrimStart=\(itemState.effectiveTrimStart), using initialTime=\(initialTime)")
            controller.preparePreview(startTime: initialTime)

            // Fetch metadata in background (non-blocking) - only if needed
            if itemState.metadata == nil {
                Task {
                    if let metadata = await VideoFileUtils.fetchMetadata(for: itemState.url) {
                        await MainActor.run {
                            itemState.metadata = metadata
                            // Update controller with new metadata if still relevant
                            controller.updateVideoItem(itemState)
                        }
                    }
                }
            }
        }
        .onDisappear {
            controller.playbackDidFinish = nil
            overlayHideTask?.cancel()
            overlayHideTask = nil

            // Report final position before teardown
            let finalPosition = controller.currentPlaybackTime
            onCloseWithPosition?(finalPosition)

            Task { @MainActor in
                controller.teardown()
            }
        }
    }
    
    private func handleAutoAdvanceProximity(_ currentTime: Double) {
        guard queueAutoAdvanceState else {
            autoAdvanceTriggered = false
            return
        }

        guard isPlaybackActive else { return }
        let duration = observedDuration
        guard duration > 0 else { return }

        let threshold = max(0, duration - 0.03)
        if currentTime >= threshold && !autoAdvanceTriggered {
            autoAdvanceTriggered = true
            onPlaybackDidFinish()
        } else if currentTime < threshold {
            autoAdvanceTriggered = false
        }
    }

    private var observedDuration: Double {
        // Prefer item's metadata duration, but fall back to player duration if not available yet
        if itemState.durationSeconds > 0 {
            return itemState.durationSeconds
        }
        // Try MPV player duration
        if let mpvDuration = controller.mpvPlayer?.duration, mpvDuration > 0 {
            return mpvDuration
        }
        // Try AVPlayer duration
        if let avDuration = controller.player?.currentItem?.duration.seconds,
           avDuration.isFinite && avDuration > 0 {
            return avDuration
        }
        return 0
    }

    // MARK: - Video Content

    @ViewBuilder
    private var videoContent: some View {
        ZStack {
            if !itemState.hasVideoStream {
                Color.black
            }

            if let player = controller.player {
                FullscreenAVPlayerView(player: player)
                    .opacity(itemState.hasVideoStream ? 1 : 0.001)
            } else if controller.useMPV, let mpvPlayer = controller.mpvPlayer {
                FullscreenMPVView(player: mpvPlayer)
                    .opacity(itemState.hasVideoStream ? 1 : 0.001)
            } else if controller.useImageSequence, let frame = controller.imageSequenceFrame {
                Image(nsImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if itemState.hasVideoStream {
                Color.black
            } else {
                Color.clear
            }
        }
    }
    
    // MARK: - Controls Overlay

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topBar
                .transition(.move(edge: .top).combined(with: .opacity))
                .onHover(perform: handleControlsHover)

            Spacer(minLength: 0)
                .allowsHitTesting(false)

            bottomBar
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onHover(perform: handleControlsHover)
        }
    }

    private func handleControlsHover(_ hovering: Bool) {
        isHoveringControls = hovering
        if hovering {
            showOverlay = true
            isMouseIdle = false
            overlayHideTask?.cancel()
        } else {
            scheduleOverlayHide()
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)

                #if DEBUG
                Text(controller.useMPV ? "MPV" : "AVPlayer")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                #endif
            }

            if isLowQualityPreview {
                Text("Low quality preview")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.4))
                    )
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close (esc)")
            .accessibilityLabel("Close fullscreen player")
            .accessibilityIdentifier("fullscreen.close")
        }
        .padding(.leading, 20)
        .padding(.trailing, rightEdgeWidth + 16)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            timelineSlider

            if isNarrow {
                VStack(spacing: 6) {
                    HStack(spacing: 6) { transportButtons }
                    HStack(spacing: 8) {
                        speedIndicatorView
                        Spacer()
                        timecodeDisplay
                    }
                }
            } else {
                HStack(spacing: 10) {
                    transportButtons
                    Spacer()
                    speedIndicatorView
                    timecodeDisplay
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(
            GeometryReader { geo in
                Color.clear
                    .onAppear { isNarrow = geo.size.width < narrowBreakpoint }
                    .onChange(of: geo.size.width) { _, newWidth in
                        isNarrow = newWidth < narrowBreakpoint
                    }
            }
            .allowsHitTesting(false)
        )
    }

    @ViewBuilder
    private var transportButtons: some View {
        navButton(systemName: "backward.end.fill",
                  size: 11, width: 26,
                  enabled: canGoToPrevious,
                  help: "Previous in queue (⌘B)",
                  accessibilityLabel: "Previous in queue",
                  identifier: "fullscreen.previous") {
            onPreviousItem?()
        }

        navButton(systemName: "gobackward.10",
                  size: 14, width: 28,
                  enabled: true,
                  help: "Back 10 seconds",
                  accessibilityLabel: "Back 10 seconds",
                  identifier: "fullscreen.skipBackward") {
            controller.seek(by: -10)
        }

        navButton(systemName: isPlaybackActive ? "pause.fill" : "play.fill",
                  size: 18, width: 32,
                  enabled: true,
                  help: "Play/Pause (Space)",
                  accessibilityLabel: isPlaybackActive ? "Pause" : "Play",
                  identifier: "fullscreen.playPause") {
            controller.togglePlayback()
        }

        navButton(systemName: "goforward.10",
                  size: 14, width: 28,
                  enabled: true,
                  help: "Forward 10 seconds",
                  accessibilityLabel: "Forward 10 seconds",
                  identifier: "fullscreen.skipForward") {
            controller.seek(by: 10)
        }

        navButton(systemName: "forward.end.fill",
                  size: 11, width: 26,
                  enabled: canGoToNext,
                  help: "Next in queue (⌘N)",
                  accessibilityLabel: "Next in queue",
                  identifier: "fullscreen.next") {
            onNextItem?()
        }

        Divider().frame(height: 18)

        if controller.audioTrackOptions.count > 1 {
            audioTrackSelector
        }

        if !controller.subtitleTrackOptions.isEmpty {
            subtitleTrackSelector
        }

        toggleButton(systemName: queueAutoAdvanceState ? "arrow.right.circle.fill" : "arrow.right.circle",
                     isOn: queueAutoAdvanceState,
                     enabled: true,
                     help: queueAutoAdvanceState ? "Disable Auto Next (A)" : "Enable Auto Next (A)",
                     accessibilityLabel: "Automatically play next item",
                     identifier: "fullscreen.autoNext") {
            toggleQueueAutoAdvance()
        }

        toggleButton(systemName: "repeat",
                     isOn: queueLoopState,
                     enabled: queueAutoAdvanceState,
                     help: queueLoopState ? "Disable Loop Queue (⌘L)" : "Enable Loop Queue (⌘L)",
                     accessibilityLabel: "Loop queue",
                     identifier: "fullscreen.loopQueue") {
            toggleQueueLoop()
        }
    }

    private func navButton(systemName: String,
                           size: CGFloat,
                           width: CGFloat,
                           enabled: Bool,
                           help: String,
                           accessibilityLabel: LocalizedStringKey,
                           identifier: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size))
                .frame(width: width, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(identifier)
    }

    private func toggleButton(systemName: String,
                              isOn: Bool,
                              enabled: Bool,
                              help: String,
                              accessibilityLabel: LocalizedStringKey,
                              identifier: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14))
                .foregroundColor(isOn ? .accentColor : .secondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var speedIndicatorView: some View {
        if controller.isPlaying && (controller.currentPlaybackSpeed != 1.0 || controller.isReverseSimulating) {
            Text(controller.isReverseSimulating
                 ? "REV \(String(format: "%.1fx", controller.currentPlaybackSpeed))"
                 : String(format: "%.1fx", controller.currentPlaybackSpeed))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var timecodeDisplay: some View {
        if isEditingTimecode {
            timecodeEditor
        } else {
            timecodeReadonly
        }
    }

    private var timecodeReadonly: some View {
        HStack(spacing: 4) {
            Text(timecodeDisplayMode.prefix)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)

            Text(TimecodeFormatter.formatTimeForDisplayWithMode(
                seconds: controller.currentPlaybackTime,
                item: itemState,
                mode: timecodeDisplayMode
            ))
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(.primary)

            Text("/")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)

            Text(TimecodeFormatter.formatTimeForDisplayWithMode(
                seconds: observedDuration,
                item: itemState,
                mode: timecodeDisplayMode,
                isDuration: true
            ))
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleTimecodeMode() }
        .onTapGesture(count: 2) { startTimecodeEdit() }
        .help("Click to cycle mode (T), double-click or type numbers to edit")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback timecode")
        .accessibilityValue(TimecodeFormatter.formatTimeForDisplayWithMode(
            seconds: controller.currentPlaybackTime,
            item: itemState,
            mode: timecodeDisplayMode
        ))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { startTimecodeEdit() }
        .accessibilityAction(named: "Cycle timecode mode") { toggleTimecodeMode() }
        .accessibilityIdentifier("fullscreen.timecode")
    }

    private var timecodeEditor: some View {
        TextField("0:00 or +10", text: $timecodeInput)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .textFieldStyle(.plain)
            .frame(width: 140)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.white.opacity(0.1))
            .cornerRadius(4)
            .focused($isTimecodeFocused)
            .accessibilityLabel("Playback timecode")
            .accessibilityIdentifier("fullscreen.timecodeInput")
            .onSubmit { seekToTimecode() }
            .onExitCommand { cancelTimecodeEdit() }
    }

    private var timelineSlider: some View {
        GeometryReader { geo in
            let duration = observedDuration
            let progress = duration > 0 ? controller.currentPlaybackTime / duration : 0
            let width = geo.size.width
            let trimInFrac: CGFloat = duration > 0 ? CGFloat((itemState.trimStart ?? 0) / duration) : 0
            let trimOutFrac: CGFloat = duration > 0 ? CGFloat((itemState.trimEnd ?? duration) / duration) : 1
            let hasTrim = itemState.trimStart != nil || itemState.trimEnd != nil

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 4)

                if duration > 0 && hasTrim {
                    Rectangle()
                        .fill(Color.blue.opacity(0.25))
                        .frame(width: max(0, (trimOutFrac - trimInFrac) * width), height: 6)
                        .offset(x: trimInFrac * width)
                }

                if itemState.trimStart != nil {
                    Rectangle()
                        .fill(Color.blue.opacity(0.8))
                        .frame(width: 2, height: 14)
                        .offset(x: max(0, min(width - 2, trimInFrac * width - 1)))
                }

                if itemState.trimEnd != nil {
                    Rectangle()
                        .fill(Color.blue.opacity(0.8))
                        .frame(width: 2, height: 14)
                        .offset(x: max(0, min(width - 2, trimOutFrac * width - 1)))
                }

                Rectangle()
                    .fill(Color(red: 1.0, green: 0.071, blue: 0.361)) // #FF125C
                    .frame(width: 2, height: 14)
                    .offset(x: max(0, min(width - 2, width * CGFloat(progress) - 1)))
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDraggingTimeline {
                            isDraggingTimeline = true
                            precisionWasActive = false
                            let clickFraction = max(0, min(1, value.location.x / width))
                            let target = Double(clickFraction) * duration
                            controller.seekTo(target)
                        }
                        let isPrecision = NSEvent.modifierFlags.contains(.option)
                        let targetFraction: Double
                        if isPrecision {
                            if !precisionWasActive {
                                let currentFraction = duration > 0 ? controller.currentPlaybackTime / duration : 0
                                precisionAnchorFraction = currentFraction
                                precisionAnchorX = value.location.x
                                precisionWasActive = true
                            }
                            let delta = (value.location.x - precisionAnchorX) / width
                            targetFraction = max(0, min(1, precisionAnchorFraction + Double(delta) / precisionScrubFactor))
                        } else {
                            precisionWasActive = false
                            targetFraction = max(0, min(1, Double(value.location.x / width)))
                        }
                        controller.seekTo(targetFraction * duration)
                    }
                    .onEnded { _ in
                        isDraggingTimeline = false
                        precisionWasActive = false
                    }
            )
        }
        .frame(height: 20)
        .accessibilityRepresentation {
            Slider(
                value: Binding(
                    get: { min(max(0, controller.currentPlaybackTime), max(0, observedDuration)) },
                    set: { controller.seekTo($0) }
                ),
                in: 0...max(observedDuration, 0.001),
                step: 1
            ) {
                Text("Playback position")
            }
            .disabled(observedDuration <= 0)
            .accessibilityValue(TimecodeFormatter.formatTimeForDisplayWithMode(
                seconds: controller.currentPlaybackTime,
                item: itemState,
                mode: timecodeDisplayMode
            ))
            .accessibilityIdentifier("fullscreen.timeline")
        }
    }

    private func toggleQueueAutoAdvance() {
        queueAutoAdvanceState.toggle()
        if !queueAutoAdvanceState {
            autoAdvanceTriggered = false
            autoPlayPending = false
        }
        onToggleQueueAutoAdvance()
    }

    private func toggleQueueLoop() {
        queueLoopState.toggle()
        onToggleQueueLoop()
    }

    // MARK: - Loading & Error Overlays
    
    private var loadingOverlay: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.5)
                .tint(.white)
            
            Text("Loading...")
                .font(.headline)
                .foregroundColor(.white)
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.7))
        )
    }
    
    private func errorOverlay(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.yellow)
            
            Text("Playback Error")
                .font(.headline)
                .foregroundColor(.white)
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            
            Button("Close") {
                onClose()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.8))
        )
    }
    
    // MARK: - Helpers

    private var isPlaybackActive: Bool {
        if controller.isReverseSimulating { return true }
        if controller.useMPV, let mpv = controller.mpvPlayer {
            return mpv.isPlaying || mpv.reachedEnd
        }
        return (controller.player?.rate ?? 0) != 0
    }

    private var isLowQualityPreview: Bool {
        false  // All playback now uses native AVPlayer or MPV
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
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 28)
        .help(controller.audioTrackOptions.isEmpty ? "No alternate audio tracks" : "Select audio track")
    }

    private var subtitleTrackSelector: some View {
        Menu {
            Button {
                controller.selectSubtitleTrack(at: -1)
            } label: {
                HStack {
                    Text("Off")
                    Spacer()
                    if controller.selectedSubtitleTrackOrderIndex < 0 {
                        Image(systemName: "checkmark")
                    }
                }
            }

            if !controller.subtitleTrackOptions.isEmpty {
                Divider()

                ForEach(controller.subtitleTrackOptions) { option in
                    Button {
                        controller.selectSubtitleTrack(at: option.position)
                    } label: {
                        HStack {
                            Text(option.title)
                            Spacer()
                            if option.position == controller.selectedSubtitleTrackOrderIndex {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 28)
        .help("Select subtitle track")
    }

    private func handleKeyCommand(_ key: String, _ modifiersRaw: UInt, _ keyCode: UInt16) -> Bool {
        let modifiers = NSEvent.ModifierFlags(rawValue: modifiersRaw)
        let lower = key.lowercased()

        if key == " " {
            controller.togglePlayback()
            return true
        }

        // Option+J/L: slow reverse/forward
        if modifiers.contains(.option) {
            switch lower {
            case "j":
                controller.slowReverse()
                return true
            case "l":
                controller.slowForward()
                return true
            default:
                break
            }
        }

        switch lower {
        case "j":
            controller.startReverseSimulation()
            return true
        case "k":
            controller.togglePlayback()
            return true
        case "l":
            controller.fastForward()
            return true
        default:
            break
        }

        switch Int(keyCode) {
        case kVK_LeftArrow:
            controller.seekByFrames(-1)
            return true
        case kVK_RightArrow:
            controller.seekByFrames(1)
            return true
        case kVK_UpArrow:
            controller.seekByFrames(-10)
            return true
        case kVK_DownArrow:
            controller.seekByFrames(10)
            return true
        default:
            break
        }

        return false
    }

    private func scheduleOverlayHide() {
        overlayHideTask?.cancel()

        guard !isHoveringControls, !isDraggingTimeline else { return }

        overlayHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            guard !isHoveringControls, !isDraggingTimeline else { return }

            // Set cursor state immediately (not animatable)
            isMouseIdle = true

            withAnimation(.easeOut(duration: 0.25)) {
                showOverlay = false
                isHoveringControls = false
            }
            onOverlayVisibilityChanged?(true)
        }
    }

    private func forceHideOverlay() {
        // Don't hide while hovering controls or dragging the timeline
        guard !isHoveringControls, !isDraggingTimeline else { return }

        overlayHideTask?.cancel()
        overlayHideTask = nil

        isMouseIdle = true

        withAnimation(.easeOut(duration: 0.2)) {
            showOverlay = false
        }
        onOverlayVisibilityChanged?(true)
    }

    private func captureScreenshot() {
        Task {
            let defaults = UserDefaults.standard
            let directoryPath = defaults.string(forKey: AppConstants.screenshotDirectoryKey) ?? AppConstants.defaultScreenshotDirectory.path
            let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)

            do {
                _ = try await controller.captureScreenshot(to: directoryURL)
            } catch is CancellationError {
                // Closing or replacing the preview intentionally cancels the capture.
            } catch {
                Self.logger.error("Screenshot capture failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func handleMouseHover() {
        // Don't show overlay if in right edge zone
        guard !isHoveringRightEdge else { return }

        if !showOverlay {
            onOverlayVisibilityChanged?(false)
        }
        showOverlay = true
        isMouseIdle = false
        scheduleOverlayHide()
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
    
    // MARK: - Timecode Editing
    
    private func startTimecodeEdit() {
        pendingTimecodeCharacter = nil
        timecodeJustActivated = false
        timecodeInput = TimecodeFormatter.formatTimeForDisplayWithMode(
            seconds: controller.currentPlaybackTime,
            item: itemState,
            mode: timecodeDisplayMode
        )
        withAnimation(.easeInOut(duration: 0.15)) {
            isEditingTimecode = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isTimecodeFocused = true
        }
    }
    
    private func startTimecodeEditWithChar(_ char: String) {
        // Use the same focus-then-append approach as the trim view.
        // This avoids the first character getting overwritten due to TextField auto-selection.
        timecodeInput = ""
        pendingTimecodeCharacter = char
        timecodeJustActivated = true

        withAnimation(.easeInOut(duration: 0.15)) {
            isEditingTimecode = true
        }

        // Focus first, then append initial character after focus is established.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isTimecodeFocused = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let initialChar = pendingTimecodeCharacter {
                    timecodeInput = initialChar
                    pendingTimecodeCharacter = nil
                }
                timecodeJustActivated = false
            }
        }
    }
    
    private func cancelTimecodeEdit() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isEditingTimecode = false
        }
        isTimecodeFocused = false
        timecodeInput = ""
        pendingTimecodeCharacter = nil
        timecodeJustActivated = false
    }
    
    private func seekToTimecode() {
        guard let seekTime = parseTimecodeToSeconds(timecodeInput) else {
            cancelTimecodeEdit()
            return
        }
        
        // Clamp to valid range
        let duration = max(itemState.durationSeconds, 0)
        let clampedTime = max(0, min(seekTime, duration))
        
        // Seek to position
        controller.seekTo(clampedTime)
        
        // Exit edit mode
        cancelTimecodeEdit()
    }
    
    private func parseTimecodeToSeconds(_ timecode: String) -> Double? {
        let trimmed = timecode.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        
        let frameRate = TimecodeFormatter.effectiveFrameRate(for: itemState)
        let fps = Int(frameRate.rounded())
        
        // Frames mode:
        // - "+/-N" moves relatively by N frames
        // - "N" jumps to absolute frame N
        if timecodeDisplayMode == .frames {
            if trimmed.hasPrefix("+") || trimmed.hasPrefix("-") {
                let isPositive = trimmed.hasPrefix("+")
                if let frameOffset = Int(String(trimmed.dropFirst())), frameOffset >= 0 {
                    let offsetSeconds = Double(frameOffset) / frameRate
                    return isPositive ? controller.currentPlaybackTime + offsetSeconds : controller.currentPlaybackTime - offsetSeconds
                }
            }

            if let frameNumber = Int(trimmed), frameNumber >= 0 {
                return Double(frameNumber) / frameRate
            }
        }
        
        // Check for relative seeking (+/-)
        if trimmed.hasPrefix("+") || trimmed.hasPrefix("-") {
            let isPositive = trimmed.hasPrefix("+")
            let offsetString = String(trimmed.dropFirst())
            
            guard let offsetSeconds = parseTimecodeOffset(offsetString, frameRate: frameRate, fps: fps) else {
                return nil
            }
            
            let newTime = isPositive ? controller.currentPlaybackTime + offsetSeconds : controller.currentPlaybackTime - offsetSeconds
            return newTime
        }
        
        // Parse absolute timecode
        return parseAbsoluteTimecode(trimmed, frameRate: frameRate, fps: fps)
    }
    
    private func parseTimecodeOffset(_ input: String, frameRate: Double, fps: Int) -> Double? {
        let components = input.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." })
        guard !components.isEmpty, components.count <= 4 else { return nil }
        
        var hours = 0, minutes = 0, seconds = 0, frames = 0
        
        switch components.count {
        case 1:
            guard let value = Int(components[0]) else { return nil }
            seconds = value
        case 2:
            guard let first = Int(components[0]), let second = Int(components[1]) else { return nil }
            if first < 60 && second < 60 {
                minutes = first; seconds = second
            } else {
                seconds = first; frames = second
            }
        case 3:
            guard let h = Int(components[0]), let m = Int(components[1]), let s = Int(components[2]) else { return nil }
            hours = h; minutes = m; seconds = s
        case 4:
            guard let h = Int(components[0]), let m = Int(components[1]), let s = Int(components[2]), let f = Int(components[3]) else { return nil }
            hours = h; minutes = m; seconds = s; frames = f
        default:
            return nil
        }
        
        let totalSeconds = Double(hours * 3600 + minutes * 60 + seconds)
        let frameSeconds = Double(frames) / frameRate
        return totalSeconds + frameSeconds
    }
    
    private func parseAbsoluteTimecode(_ input: String, frameRate: Double, fps: Int) -> Double? {
        let components = input.split(whereSeparator: { $0 == ":" || $0 == ";" || $0 == "." })
        guard !components.isEmpty, components.count <= 4 else { return nil }
        
        var hours = 0, minutes = 0, seconds = 0, frames = 0
        
        switch components.count {
        case 1:
            guard let s = Int(components[0]) else { return nil }
            seconds = s
        case 2:
            guard let m = Int(components[0]), let s = Int(components[1]) else { return nil }
            minutes = m; seconds = s
        case 3:
            guard let h = Int(components[0]), let m = Int(components[1]), let s = Int(components[2]) else { return nil }
            hours = h; minutes = m; seconds = s
        case 4:
            guard let h = Int(components[0]), let m = Int(components[1]), let s = Int(components[2]), let f = Int(components[3]) else { return nil }
            hours = h; minutes = m; seconds = s; frames = f
        default:
            return nil
        }
        
        // Validate ranges
        guard hours >= 0, hours < 24, minutes >= 0, minutes < 60, seconds >= 0, seconds < 60, frames >= 0, frames < fps else {
            return nil
        }
        
        // Handle source timecode offset when in source mode
        if timecodeDisplayMode == .source, let startTC = TimecodeFormatter.effectiveStartTimecode(for: itemState) {
            let startComponents = startTC.split(whereSeparator: { $0 == ":" || $0 == ";" })
            guard startComponents.count == 4,
                  let startHours = Int(startComponents[0]),
                  let startMinutes = Int(startComponents[1]),
                  let startSeconds = Int(startComponents[2]),
                  let startFrames = Int(startComponents[3]) else {
                return nil
            }
            
            let inputTotalFrames = hours * 3600 * fps + minutes * 60 * fps + seconds * fps + frames
            let startTotalFrames = startHours * 3600 * fps + startMinutes * 60 * fps + startSeconds * fps + startFrames
            
            let frameOffset = inputTotalFrames - startTotalFrames
            return Double(frameOffset) / frameRate
        }
        
        // Relative mode - treat as absolute from 00:00:00:00
        let totalSeconds = Double(hours * 3600 + minutes * 60 + seconds)
        let frameSeconds = Double(frames) / frameRate
        return totalSeconds + frameSeconds
    }
    
    private func toggleTimecodeMode() {
        timecodeDisplayMode.toggle()
        onTimecodeDisplayModeChanged?(timecodeDisplayMode)
    }

    // MARK: - Trim Handling

    private func handleTrimInPoint(clearToStart: Bool) {
        if clearToStart {
            itemState.trimStart = nil
        } else {
            let currentTime = controller.currentPlaybackTime
            let duration = max(itemState.durationSeconds, 0)
            let clamped = max(0, min(currentTime, duration))
            itemState.trimStart = clamped <= 0.05 ? nil : clamped
            if let end = itemState.trimEnd, end < itemState.effectiveTrimStart {
                itemState.trimEnd = itemState.trimStart
            }
        }
        onTrimChanged?(itemState.trimStart, itemState.trimEnd)
    }

    private func handleTrimOutPoint(clearToEnd: Bool) {
        if clearToEnd {
            itemState.trimEnd = nil
        } else {
            let currentTime = controller.currentPlaybackTime
            let duration = max(itemState.durationSeconds, 0)
            let clamped = max(0, min(currentTime, duration))
            let minEnd = itemState.effectiveTrimStart
            let sanitizedValue = max(clamped, minEnd)
            if sanitizedValue >= duration - 0.05 {
                itemState.trimEnd = nil
            } else {
                itemState.trimEnd = sanitizedValue
            }
        }
        onTrimChanged?(itemState.trimStart, itemState.trimEnd)
    }

    private func clearAllTrimPoints() {
        itemState.trimStart = nil
        itemState.trimEnd = nil
        onTrimChanged?(nil, nil)
    }

    private func seekToTrimIn() {
        controller.seekTo(itemState.effectiveTrimStart)
    }

    private func seekToTrimOut() {
        controller.seekTo(itemState.effectiveTrimEnd)
    }
}

// MARK: - Cursor Modifier

private struct CursorVisibilityModifier: ViewModifier {
    let isHidden: Bool

    @State private var isHovering = false
    @State private var hasPushedCursor = false

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if !isHovering {
                        isHovering = true
                        pushCursor()
                    }
                case .ended:
                    if isHovering {
                        isHovering = false
                        popCursor()
                    }
                }
            }
            .onChange(of: isHidden) { _, _ in
                // Cursor visibility changed while hovering - update the cursor
                if isHovering {
                    popCursor()
                    pushCursor()
                }
            }
            .onDisappear {
                popCursor()
            }
    }

    private func pushCursor() {
        let cursor = isHidden ? NSCursor.hidden : NSCursor.arrow
        cursor.push()
        hasPushedCursor = true
    }

    private func popCursor() {
        if hasPushedCursor {
            NSCursor.pop()
            hasPushedCursor = false
        }
    }
}

extension View {
    func hideCursor(_ hide: Bool) -> some View {
        modifier(CursorVisibilityModifier(isHidden: hide))
    }
}

extension NSCursor {
    static var hidden: NSCursor {
        // Create a transparent cursor image
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.set()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
    }
}

// MARK: - Right Edge Cursor Hide Zone

private struct RightEdgeCursorHideZone: NSViewRepresentable {
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> RightEdgeCursorHideNSView {
        let view = RightEdgeCursorHideNSView()
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ nsView: RightEdgeCursorHideNSView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
    }
}

private class RightEdgeCursorHideNSView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    // Allow clicks to pass through while keeping tracking areas active
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        if let area = trackingArea {
            addTrackingArea(area)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
        NSCursor.hide()
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
        NSCursor.unhide()
        onHoverChanged?(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            updateTrackingAreas()
        }
    }

    override func removeFromSuperview() {
        if isHovering {
            NSCursor.unhide()
            isHovering = false
        }
        super.removeFromSuperview()
    }

    deinit {
        if isHovering {
            NSCursor.unhide()
        }
    }
}

// MARK: - AVPlayer View

private struct FullscreenAVPlayerView: NSViewRepresentable {
    let player: AVPlayer
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.allowsVideoFrameAnalysis = false
        return playerView
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

// MARK: - Keyboard Handler

private struct FullscreenKeyboardHandler: NSViewRepresentable {
    let controller: PreviewPlayerController
    let onClose: @Sendable () -> Void
    let onToggleTimecodeMode: @Sendable () -> Void
    let onTimecodeInput: @Sendable (String) -> Void
    let captureScreenshot: @Sendable () -> Void
    let onPreviousItem: (@Sendable () -> Void)?
    let onNextItem: (@Sendable () -> Void)?
    let canGoToPrevious: Bool
    let canGoToNext: Bool
    let isEditingTimecode: Bool
    let onToggleAutoNext: @Sendable () -> Void
    let onToggleLoop: @Sendable () -> Void
    let isAutoNextEnabled: Bool
    let onSetTrimIn: @Sendable () -> Void
    let onSetTrimOut: @Sendable () -> Void
    let onClearTrimIn: @Sendable () -> Void
    let onClearTrimOut: @Sendable () -> Void
    let onClearAllTrim: @Sendable () -> Void
    let onSeekToTrimIn: @Sendable () -> Void
    let onSeekToTrimOut: @Sendable () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            controller: controller,
            onClose: onClose,
            onToggleTimecodeMode: onToggleTimecodeMode,
            onTimecodeInput: onTimecodeInput,
            captureScreenshot: captureScreenshot,
            onPreviousItem: onPreviousItem,
            onNextItem: onNextItem,
            canGoToPrevious: canGoToPrevious,
            canGoToNext: canGoToNext,
            isEditingTimecode: isEditingTimecode,
            onToggleAutoNext: onToggleAutoNext,
            onToggleLoop: onToggleLoop,
            isAutoNextEnabled: isAutoNextEnabled,
            onSetTrimIn: onSetTrimIn,
            onSetTrimOut: onSetTrimOut,
            onClearTrimIn: onClearTrimIn,
            onClearTrimOut: onClearTrimOut,
            onClearAllTrim: onClearAllTrim,
            onSeekToTrimIn: onSeekToTrimIn,
            onSeekToTrimOut: onSeekToTrimOut
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.isHidden = true
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.controller = controller
        context.coordinator.onClose = onClose
        context.coordinator.onToggleTimecodeMode = onToggleTimecodeMode
        context.coordinator.onTimecodeInput = onTimecodeInput
        context.coordinator.captureScreenshot = captureScreenshot
        context.coordinator.onPreviousItem = onPreviousItem
        context.coordinator.onNextItem = onNextItem
        context.coordinator.canGoToPrevious = canGoToPrevious
        context.coordinator.canGoToNext = canGoToNext
        context.coordinator.isEditingTimecode = isEditingTimecode
        context.coordinator.onToggleAutoNext = onToggleAutoNext
        context.coordinator.onToggleLoop = onToggleLoop
        context.coordinator.isAutoNextEnabled = isAutoNextEnabled
        context.coordinator.onSetTrimIn = onSetTrimIn
        context.coordinator.onSetTrimOut = onSetTrimOut
        context.coordinator.onClearTrimIn = onClearTrimIn
        context.coordinator.onClearTrimOut = onClearTrimOut
        context.coordinator.onClearAllTrim = onClearAllTrim
        context.coordinator.onSeekToTrimIn = onSeekToTrimIn
        context.coordinator.onSeekToTrimOut = onSeekToTrimOut
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator: @unchecked Sendable {
        var controller: PreviewPlayerController
        var onClose: @Sendable () -> Void
        var onToggleTimecodeMode: @Sendable () -> Void
        var onTimecodeInput: @Sendable (String) -> Void
        var captureScreenshot: @Sendable () -> Void
        var onPreviousItem: (@Sendable () -> Void)?
        var onNextItem: (@Sendable () -> Void)?
        var canGoToPrevious: Bool
        var canGoToNext: Bool
        var isEditingTimecode: Bool
        var onToggleAutoNext: @Sendable () -> Void
        var onToggleLoop: @Sendable () -> Void
        var isAutoNextEnabled: Bool
        var onSetTrimIn: @Sendable () -> Void
        var onSetTrimOut: @Sendable () -> Void
        var onClearTrimIn: @Sendable () -> Void
        var onClearTrimOut: @Sendable () -> Void
        var onClearAllTrim: @Sendable () -> Void
        var onSeekToTrimIn: @Sendable () -> Void
        var onSeekToTrimOut: @Sendable () -> Void
        private var monitor: Any?

        init(
            controller: PreviewPlayerController,
            onClose: @Sendable @escaping () -> Void,
            onToggleTimecodeMode: @Sendable @escaping () -> Void,
            onTimecodeInput: @Sendable @escaping (String) -> Void,
            captureScreenshot: @Sendable @escaping () -> Void,
            onPreviousItem: (@Sendable () -> Void)?,
            onNextItem: (@Sendable () -> Void)?,
            canGoToPrevious: Bool,
            canGoToNext: Bool,
            isEditingTimecode: Bool,
            onToggleAutoNext: @Sendable @escaping () -> Void,
            onToggleLoop: @Sendable @escaping () -> Void,
            isAutoNextEnabled: Bool,
            onSetTrimIn: @Sendable @escaping () -> Void,
            onSetTrimOut: @Sendable @escaping () -> Void,
            onClearTrimIn: @Sendable @escaping () -> Void,
            onClearTrimOut: @Sendable @escaping () -> Void,
            onClearAllTrim: @Sendable @escaping () -> Void,
            onSeekToTrimIn: @Sendable @escaping () -> Void,
            onSeekToTrimOut: @Sendable @escaping () -> Void
        ) {
            self.controller = controller
            self.onClose = onClose
            self.onToggleTimecodeMode = onToggleTimecodeMode
            self.onTimecodeInput = onTimecodeInput
            self.captureScreenshot = captureScreenshot
            self.onPreviousItem = onPreviousItem
            self.onNextItem = onNextItem
            self.canGoToPrevious = canGoToPrevious
            self.canGoToNext = canGoToNext
            self.isEditingTimecode = isEditingTimecode
            self.onToggleAutoNext = onToggleAutoNext
            self.onToggleLoop = onToggleLoop
            self.isAutoNextEnabled = isAutoNextEnabled
            self.onSetTrimIn = onSetTrimIn
            self.onSetTrimOut = onSetTrimOut
            self.onClearTrimIn = onClearTrimIn
            self.onClearTrimOut = onClearTrimOut
            self.onClearAllTrim = onClearAllTrim
            self.onSeekToTrimIn = onSeekToTrimIn
            self.onSeekToTrimOut = onSeekToTrimOut
        }

        func install() {
            guard monitor == nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] (event: NSEvent) -> NSEvent? in
                guard let self else { return event }
                guard let characters = event.charactersIgnoringModifiers else { return event }

                let keyCode = event.keyCode
                let modifiers = event.modifierFlags
                let hasOption = modifiers.contains(.option)
                let hasCommand = modifiers.contains(.command)
                let hasShift = modifiers.contains(.shift)
                let hasControl = modifiers.contains(.control)
                let noModifiers = !hasOption && !hasCommand && !hasShift && !hasControl

                // Escape to close
                if keyCode == 53 {
                    self.onClose()
                    return nil
                }

                let lower = characters.lowercased()

                // CMD+B: Go to previous item in queue
                if hasCommand && !hasShift && !hasOption && !hasControl && lower == "b" {
                    if self.canGoToPrevious, let onPrevious = self.onPreviousItem {
                        DispatchQueue.main.async {
                            onPrevious()
                        }
                    }
                    // Always consume the event to prevent propagation to other handlers
                    return nil
                }

                // CMD+N: Go to next item in queue
                if hasCommand && !hasShift && !hasOption && !hasControl && lower == "n" {
                    if self.canGoToNext, let onNext = self.onNextItem {
                        DispatchQueue.main.async {
                            onNext()
                        }
                    }
                    // Always consume the event to prevent propagation to other handlers
                    return nil
                }

                // T (no modifiers): Toggle timecode mode
                if noModifiers && !self.isEditingTimecode && lower == "t" {
                    DispatchQueue.main.async { [weak self] in
                        self?.onToggleTimecodeMode()
                    }
                    return nil
                }

                // A (no modifiers): Toggle Auto Next
                if noModifiers && !self.isEditingTimecode && lower == "a" {
                    DispatchQueue.main.async { [weak self] in
                        self?.onToggleAutoNext()
                    }
                    return nil
                }

                // CMD+L: Toggle Loop Queue (only when Auto Next is enabled)
                if hasCommand && !hasShift && !hasOption && !hasControl && lower == "l" && self.isAutoNextEnabled {
                    DispatchQueue.main.async { [weak self] in
                        self?.onToggleLoop()
                    }
                    return nil
                }

                // Trim shortcuts (I, O, Shift+I, Shift+O, Option+I, Option+O, Option+X)
                if !self.isEditingTimecode && !hasCommand && !hasControl {
                    // Option+X: Clear all trim points
                    if hasOption && !hasShift && lower == "x" {
                        DispatchQueue.main.async { [weak self] in
                            self?.onClearAllTrim()
                        }
                        return nil
                    }

                    // Option+I: Clear trim in
                    if hasOption && !hasShift && lower == "i" {
                        DispatchQueue.main.async { [weak self] in
                            self?.onClearTrimIn()
                        }
                        return nil
                    }

                    // Option+O: Clear trim out
                    if hasOption && !hasShift && lower == "o" {
                        DispatchQueue.main.async { [weak self] in
                            self?.onClearTrimOut()
                        }
                        return nil
                    }

                    // Shift+I: Seek to trim in
                    if hasShift && !hasOption && lower == "i" {
                        DispatchQueue.main.async { [weak self] in
                            self?.onSeekToTrimIn()
                        }
                        return nil
                    }

                    // Shift+O: Seek to trim out
                    if hasShift && !hasOption && lower == "o" {
                        DispatchQueue.main.async { [weak self] in
                            self?.onSeekToTrimOut()
                        }
                        return nil
                    }

                    // I (no modifiers): Set trim in at current position
                    if noModifiers && lower == "i" {
                        DispatchQueue.main.async { [weak self] in
                            self?.onSetTrimIn()
                        }
                        return nil
                    }

                    // O (no modifiers): Set trim out at current position
                    if noModifiers && lower == "o" {
                        DispatchQueue.main.async { [weak self] in
                            self?.onSetTrimOut()
                        }
                        return nil
                    }
                }

                // Number keys and timecode characters to activate timecode input (when not already editing)
                // Exclude 't' since it's used for timecode mode toggle
                if noModifiers && !self.isEditingTimecode {
                    let timecodeChars = CharacterSet(charactersIn: "0123456789+-.:;")
                    if characters.rangeOfCharacter(from: timecodeChars) != nil {
                        DispatchQueue.main.async { [weak self] in
                            self?.onTimecodeInput(characters)
                        }
                        return nil
                    }
                }

                // CMD+S: Capture screenshot
                if hasCommand && lower == "s" {
                    DispatchQueue.main.async { [weak self] in
                        self?.captureScreenshot()
                    }
                    return nil
                }

                // Option+J/L: slow reverse/forward
                if hasOption && !hasCommand && !hasControl {
                    let controller = self.controller
                    if lower == "j" {
                        MainActor.assumeIsolated { controller.slowReverse() }
                        return nil
                    } else if lower == "l" {
                        MainActor.assumeIsolated { controller.slowForward() }
                        return nil
                    }
                }

                // Only consume keys we actually use
                let shouldConsume: Bool = {
                    if characters == " " { return true }
                    if lower == "j" || lower == "k" || lower == "l" { return true }
                    switch Int(keyCode) {
                    case kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow:
                        return true
                    default:
                        return false
                    }
                }()

                guard shouldConsume else { return event }

                let controller = self.controller
                MainActor.assumeIsolated {
                    if characters == " " {
                        controller.togglePlayback()
                        return
                    }

                    switch lower {
                    case "j":
                        controller.startReverseSimulation()
                        return
                    case "k":
                        controller.togglePlayback()
                        return
                    case "l":
                        controller.fastForward()
                        return
                    default:
                        break
                    }

                    switch Int(keyCode) {
                    case kVK_LeftArrow:
                        controller.seekByFrames(-1)
                    case kVK_RightArrow:
                        controller.seekByFrames(1)
                    case kVK_UpArrow:
                        controller.seekByFrames(-10)
                    case kVK_DownArrow:
                        controller.seekByFrames(10)
                    default:
                        break
                    }
                }

                return nil
            }
        }

        func teardown() {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
