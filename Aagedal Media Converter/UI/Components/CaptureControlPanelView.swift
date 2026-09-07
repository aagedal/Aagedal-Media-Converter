// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import AVFoundation
import ScreenCaptureKit

struct CaptureControlPanelView: View {
    let onCancel: () -> Void
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void
    let onHidePanel: () -> Void
    let onRegionModeChanged: (Bool) -> Void
    let onDisplayChanged: (NSScreen, CGRect?) -> Void
    let onSetOverlayClickThrough: (Bool) -> Void
    let onScaleChanged: () -> Void

    @AppStorage(AppConstants.captureDirectoryKey) private var captureDirectoryPath = AppConstants.defaultCaptureDirectory.path
    @AppStorage(AppConstants.capturePresetKey) private var capturePresetRaw = CapturePreset.defaultPreset.rawValue
    @AppStorage(AppConstants.captureDisplayIDsKey) private var captureDisplayIDsRaw = ""
    @AppStorage(AppConstants.captureFrameRateKey) private var captureFrameRateRaw = AppConstants.defaultCaptureFrameRate
    @AppStorage(AppConstants.captureDynamicRangeKey) private var captureDynamicRangeRaw = AppConstants.defaultCaptureDynamicRange
    @AppStorage(AppConstants.captureHideCursorKey) private var captureHideCursor = AppConstants.defaultCaptureHideCursor
    @AppStorage(AppConstants.captureExcludeCurrentAppKey) private var captureExcludeCurrentApp = AppConstants.defaultCaptureExcludeCurrentApp
    @AppStorage(AppConstants.captureIncludeSystemAudioKey) private var captureIncludeSystemAudio = AppConstants.defaultCaptureIncludeSystemAudio
    @AppStorage(AppConstants.captureIncludeMicrophoneKey) private var captureIncludeMicrophone = AppConstants.defaultCaptureIncludeMicrophone
    @AppStorage(AppConstants.captureMicrophoneDeviceIDKey) private var captureMicrophoneDeviceID = AppConstants.defaultCaptureMicrophoneDeviceID
    @AppStorage(AppConstants.captureRegionModeKey) private var captureRegionMode = AppConstants.defaultCaptureRegionMode
    @AppStorage(AppConstants.captureRegionXKey) private var captureRegionX: Double = 0
    @AppStorage(AppConstants.captureRegionYKey) private var captureRegionY: Double = 0
    @AppStorage(AppConstants.captureRegionWidthKey) private var captureRegionWidth: Double = 0
    @AppStorage(AppConstants.captureRegionHeightKey) private var captureRegionHeight: Double = 0
    @AppStorage("screenRecordingAspectRatio") private var lockedAspectRatioRaw: String = AspectRatio.free.rawValue

    @StateObject private var captureManager = ScreenCaptureManager.shared
    @State private var availableDisplays: [CaptureDisplay] = []
    @State private var microphoneDevices: [AVCaptureDevice] = []
    @State private var isViewActive = false
    @State private var isMicButtonHovering = false
    @State private var showAudioExclusionPopover = false
    @State private var showDisplayMenu = false
    @State private var availableApps: [SCRunningApplication] = []
    @State private var excludedAppBundleIDs: Set<String> = []
    @State private var overlayClickThrough = false
    @State private var hoveredDisplayID: CGDirectDisplayID?
    /// When set, only this display's tile is shown, expanded to fill the panel (focus mode).
    @State private var focusedDisplayID: CGDirectDisplayID?

    // Schedule state
    @State private var showSchedulePopover = false
    @State private var scheduleStartDate = Date().addingTimeInterval(300)
    @State private var scheduleUseDuration = false
    @State private var scheduleDurationHours = 0
    @State private var scheduleDurationMinutes = 5
    @State private var scheduledStart: Date?
    @State private var scheduledDuration: TimeInterval?
    @State private var scheduleCountdown: TimeInterval = 0
    @State private var schedulePowerAssertion: UUID?

    private var presetBinding: Binding<CapturePreset> {
        Binding(
            get: {
                let preset = CapturePreset(rawValue: capturePresetRaw) ?? .defaultPreset
                return CapturePreset.availablePresets.contains(preset) ? preset : .defaultPreset
            },
            set: { capturePresetRaw = $0.rawValue }
        )
    }

    private var outputDirectoryURL: URL {
        let trimmed = captureDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AppConstants.defaultCaptureDirectory : URL(fileURLWithPath: trimmed)
    }

    private var frameRateOption: CaptureFrameRateOption {
        CaptureFrameRateOption(rawValue: captureFrameRateRaw) ?? .auto
    }

    private var dynamicRangeOption: CaptureDynamicRangeOption {
        if captureDynamicRangeRaw == "hdrP3LocalDisplay" {
            return .hdrP3CanonicalDisplay
        }
        return CaptureDynamicRangeOption(rawValue: captureDynamicRangeRaw) ?? .sdr
    }

    private var selectedMicrophoneDeviceID: String? {
        captureMicrophoneDeviceID.isEmpty ? nil : captureMicrophoneDeviceID
    }

    private var selectedRegionRect: CGRect? {
        guard captureRegionMode, captureRegionWidth > 0, captureRegionHeight > 0 else { return nil }
        return CGRect(x: captureRegionX, y: captureRegionY, width: captureRegionWidth, height: captureRegionHeight)
    }

    private var microphoneSelectionSupported: Bool {
        if #available(macOS 15, *) {
            return true
        }
        return false
    }

    // MARK: - Display Selection

    /// The user's explicit selection parsed from the comma-separated `@AppStorage` string.
    private var selectedDisplayIDs: [CGDirectDisplayID] {
        captureDisplayIDsRaw
            .split(separator: ",")
            .compactMap { CGDirectDisplayID($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func setSelectedDisplayIDs(_ ids: [CGDirectDisplayID]) {
        // De-dupe, preserve order.
        var seen = Set<CGDirectDisplayID>()
        let unique = ids.filter { seen.insert($0).inserted }
        captureDisplayIDsRaw = unique.map(String.init).joined(separator: ",")
    }

    private var primaryDisplayID: CGDirectDisplayID? {
        availableDisplays.first(where: { $0.isMain })?.id ?? availableDisplays.first?.id
    }

    /// The displays actually shown/recorded — the explicit selection, or the main display when the
    /// selection is empty (matching the manager's "empty == main" fallback). In region mode it is
    /// always a single display.
    private var effectiveDisplayIDs: [CGDirectDisplayID] {
        let valid = selectedDisplayIDs.filter { id in availableDisplays.contains(where: { $0.id == id }) }
        if captureRegionMode {
            if let first = valid.first ?? primaryDisplayID { return [first] }
            return []
        }
        if !valid.isEmpty { return valid }
        if let main = primaryDisplayID { return [main] }
        return []
    }

    private func display(for id: CGDirectDisplayID) -> CaptureDisplay? {
        availableDisplays.first(where: { $0.id == id })
    }

    private func makeSettings() -> CaptureSettings {
        var settings = CaptureSettings()
        settings.frameRate = frameRateOption
        settings.includeSystemAudio = captureIncludeSystemAudio
        settings.includeMicrophone = captureIncludeMicrophone
        settings.microphoneDeviceID = selectedMicrophoneDeviceID
        settings.hideCursor = captureHideCursor
        settings.excludeCurrentApp = captureExcludeCurrentApp
        settings.excludedAppBundleIDs = excludedAppBundleIDs
        settings.regionRect = (captureRegionMode && effectiveDisplayIDs.count == 1) ? selectedRegionRect : nil
        return settings
    }

    // MARK: - Overlay Sizing

    private static let baseContentWidth: CGFloat = 480
    private static let horizontalChrome: CGFloat = 60
    private static let compactPreviewBounds = CGSize(width: 420, height: 240)
    private static let expandedScreenFraction: CGFloat = 0.9
    private static let verticalChromeEstimate: CGFloat = 185
    private static let tileSpacing: CGFloat = 6

    /// Aspect (width / height) of the primary captured display (or region), falling back to 16:9.
    /// Used as the uniform tile aspect for grid layout; each frame still scales-to-fit inside its cell.
    private var primaryAspect: CGFloat {
        if captureRegionMode, captureRegionWidth > 1, captureRegionHeight > 1 {
            return CGFloat(captureRegionWidth / captureRegionHeight)
        }
        if let id = effectiveDisplayIDs.first, let d = display(for: id), d.width > 0, d.height > 0 {
            return CGFloat(d.width) / CGFloat(d.height)
        }
        if let main = availableDisplays.first(where: { $0.isMain }) ?? availableDisplays.first,
           main.width > 0, main.height > 0 {
            return CGFloat(main.width) / CGFloat(main.height)
        }
        return 16.0 / 9.0
    }

    private var targetScreen: NSScreen? {
        if let id = effectiveDisplayIDs.first,
           let match = NSScreen.screens.first(where: {
               ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
           }) {
            return match
        }
        return NSScreen.main
    }

    private var tileCount: Int { max(1, effectiveDisplayIDs.count) }

    /// Columns grow horizontally first, then wrap into a grid: 1→1, 2→2, 3-4→2, 5-9→3 … (ceil(√n)).
    private var gridColumns: Int { max(1, Int(ceil(Double(tileCount).squareRoot()))) }
    private var gridRows: Int { Int(ceil(Double(tileCount) / Double(gridColumns))) }

    /// The grid of all monitors always uses the compact bounds. The overlay's only enlarged state is
    /// focusing a single screen (``focusedBoxSize``) — keeping expansion to one level (compact grid
    /// ↔ one focused screen) instead of an awkward intermediate "enlarged grid".
    private var availablePreviewBounds: CGSize { Self.compactPreviewBounds }

    /// Size of the whole tile grid, aspect-fit so every cell keeps `primaryAspect` within the bounds.
    private var gridBoxSize: CGSize {
        let bounds = availablePreviewBounds
        let aspect = max(0.1, primaryAspect)
        let cols = CGFloat(gridColumns)
        let rows = CGFloat(gridRows)
        let tileWByWidth = (bounds.width - Self.tileSpacing * (cols - 1)) / cols
        let tileHByHeight = (bounds.height - Self.tileSpacing * (rows - 1)) / rows
        let tileH = max(40, min(tileHByHeight, tileWByWidth / aspect))
        let tileW = tileH * aspect
        return CGSize(
            width: (tileW * cols + Self.tileSpacing * (cols - 1)).rounded(),
            height: (tileH * rows + Self.tileSpacing * (rows - 1)).rounded()
        )
    }

    /// Size of a single focused tile (focus mode), aspect-fit within ~90% of the screen. Focusing a
    /// screen is the overlay's only enlarged state — the grid of all monitors otherwise stays compact.
    private var focusedBoxSize: CGSize {
        let aspect = max(0.1, primaryAspect)
        let screen = (targetScreen?.visibleFrame.size) ?? CGSize(width: 1440, height: 900)
        let availW = max(320, screen.width * Self.expandedScreenFraction - Self.horizontalChrome)
        let availH = max(240, screen.height * Self.expandedScreenFraction - Self.verticalChromeEstimate)
        let height = min(availH, availW / aspect)
        return CGSize(width: (height * aspect).rounded(), height: height.rounded())
    }

    private var isFocused: Bool {
        focusedDisplayID != nil && effectiveDisplayIDs.contains(focusedDisplayID!)
    }

    private var currentPreviewBox: CGSize { isFocused ? focusedBoxSize : gridBoxSize }
    private var panelWidth: CGFloat { max(Self.baseContentWidth, currentPreviewBox.width + Self.horizontalChrome) }
    private var meterHeight: CGFloat { currentPreviewBox.height }

    /// Target pixel width for each live preview stream — matches the displayed tile times backing scale.
    private var previewPixelWidth: CGFloat {
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let tileWidth = isFocused ? focusedBoxSize.width : (gridBoxSize.width / CGFloat(gridColumns))
        return max(1280, (tileWidth * backingScale).rounded(.up))
    }

    private func schedulePanelResize() {
        DispatchQueue.main.async { onScaleChanged() }
    }

    private var sizeToggleButton: some View {
        // Single expand model: focus the primary screen to fill the display, or collapse back to the
        // compact grid of all monitors. (Individual screens can also be focused via their tile's
        // expand button on hover.)
        Button {
            if isFocused {
                focusedDisplayID = nil
            } else if let first = effectiveDisplayIDs.first {
                focusedDisplayID = first
            }
            Task { await refreshPreviews() }
        } label: {
            Image(systemName: isFocused
                  ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(6)
                .background(Circle().fill(Color.black.opacity(0.25)))
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isFocused ? "Show all screens" : "Expand a screen to fill the display")
    }

    var body: some View {
        panelContent
            .onAppear { handleOnAppear() }
            .onDisappear {
                isViewActive = false
                cancelSchedule()
            }
            .onChange(of: captureRegionMode) { _, newValue in
                onRegionModeChanged(newValue)
                if newValue {
                    // Region capture is single-display: collapse the selection to the primary.
                    if let first = effectiveDisplayIDs.first { setSelectedDisplayIDs([first]) }
                    focusedDisplayID = nil
                } else if !newValue && overlayClickThrough {
                    overlayClickThrough = false
                    onSetOverlayClickThrough(false)
                }
                Task { await refreshPreviews() }
            }
            .onChange(of: captureDisplayIDsRaw) { _, _ in
                notifyDisplayChanged()
                Task { await reconcileSelection() }
            }
            .onChange(of: captureManager.recordingDisplayIDs) { _, _ in schedulePanelResize() }
            .onChange(of: currentPreviewBox) { _, _ in schedulePanelResize() }
            .onChange(of: captureManager.isProcessing) { _, _ in schedulePanelResize() }
            .onChange(of: focusedDisplayID) { _, _ in schedulePanelResize() }
            .task(id: scheduledStart) {
                guard let start = scheduledStart else { return }
                while !Task.isCancelled {
                    let remaining = start.timeIntervalSinceNow
                    if remaining <= 0 {
                        fireScheduledRecording()
                        return
                    }
                    scheduleCountdown = remaining
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            .modifier(PreviewRefreshModifier(
                captureHideCursor: captureHideCursor,
                captureExcludeCurrentApp: captureExcludeCurrentApp,
                captureFrameRateRaw: captureFrameRateRaw,
                captureIncludeMicrophone: captureIncludeMicrophone,
                captureDynamicRangeRaw: captureDynamicRangeRaw,
                excludedAppBundleIDs: excludedAppBundleIDs,
                captureRegionX: captureRegionX,
                captureRegionY: captureRegionY,
                captureRegionWidth: captureRegionWidth,
                captureRegionHeight: captureRegionHeight,
                refreshPreview: { await self.refreshPreviews() }
            ))
    }

    private var panelContent: some View {
        mainView
            .background(
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.3), radius: 12)
            .overlay(alignment: .topTrailing) {
                sizeToggleButton
            }
    }

    private func handleOnAppear() {
        isViewActive = true
        schedulePanelResize()
        if !CapturePreset.availablePresets.contains(presetBinding.wrappedValue) {
            capturePresetRaw = CapturePreset.defaultPreset.rawValue
        }
        Task {
            async let microphonesTask: () = loadMicrophones()
            do {
                let content = try await ScreenCaptureManager.shareableContent()
                let displays = ScreenCaptureManager.displays(from: content)
                let apps = content.applications
                await MainActor.run {
                    availableDisplays = displays
                    availableApps = apps
                    // Prune selected displays that no longer exist.
                    let valid = selectedDisplayIDs.filter { id in displays.contains(where: { $0.id == id }) }
                    if valid.count != selectedDisplayIDs.count {
                        setSelectedDisplayIDs(valid)
                    }
                }
                captureManager.refreshMicrophoneAuthorizationStatus()
                await reconcileSelection()
            } catch {
                await MainActor.run { availableDisplays = [] }
            }
            await microphonesTask
        }
    }

    // MARK: - Main Layout

    private var mainView: some View {
        VStack(spacing: 0) {
            previewSection
                .padding(12)

            Divider()

            controlsSection
                .padding(12)

            Divider()

            bottomBar
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(width: panelWidth)
    }

    private var previewSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                AudioMeterView(levels: captureManager.audioLevels, meterHeight: meterHeight, chrome: false)
                    .opacity(captureIncludeSystemAudio ? 1.0 : 0.3)
                    .frame(width: 12)
                    .help("System audio level")

                previewArea
                    .frame(width: currentPreviewBox.width, height: currentPreviewBox.height)

                AudioMeterView(levels: captureManager.microphoneLevels, meterHeight: meterHeight, chrome: false)
                    .saturation(microphoneButtonActive ? 1.0 : 0.0)
                    .opacity(microphoneButtonActive ? 1.0 : 0.3)
                    .frame(width: 12)
                    .help("Microphone audio level")
            }

            Text(frameRateOption.displayName + " · " + (presetBinding.wrappedValue.isGrowing ? "CFR" : "VFR"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help(presetBinding.wrappedValue.frameRateDetail)
                .accessibilityLabel(frameRateOption.displayName + ". " + presetBinding.wrappedValue.frameRateDetail)

            audioAndDisplayRow
        }
    }

    @ViewBuilder
    private var previewArea: some View {
        if isFocused, let id = focusedDisplayID {
            tileView(for: id)
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: Self.tileSpacing), count: gridColumns)
            LazyVGrid(columns: columns, spacing: Self.tileSpacing) {
                ForEach(effectiveDisplayIDs, id: \.self) { id in
                    tileView(for: id)
                        .aspectRatio(primaryAspect, contentMode: .fit)
                }
            }
        }
    }

    private func tileView(for id: CGDirectDisplayID) -> some View {
        CaptureTileView(
            displayID: id,
            name: display(for: id)?.name ?? "Display \(id)",
            image: captureManager.previewImages[id],
            isRecording: captureManager.recordingDisplayIDs.contains(id),
            isFocused: focusedDisplayID == id,
            canRemove: effectiveDisplayIDs.count > 1 && !captureRegionMode,
            isProcessing: captureManager.isProcessing,
            hoveredDisplayID: $hoveredDisplayID,
            onToggleFocus: {
                focusedDisplayID = (focusedDisplayID == id) ? nil : id
            },
            onToggleRecord: { handleTileRecord(id) },
            onRemove: { handleTileRemove(id) }
        )
    }

    private var audioAndDisplayRow: some View {
        HStack {
            Button {
                captureIncludeSystemAudio.toggle()
            } label: {
                Image(systemName: captureIncludeSystemAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 10))
                    .foregroundColor(captureIncludeSystemAudio ? .accentColor : .secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .help(captureIncludeSystemAudio ? "System audio on" : "System audio off")

            Spacer()

            displaySelectionMenu

            VirtualDisplayMenu(
                isDisabled: false,
                onDisplaysChanged: { await refreshAvailableDisplays() },
                onCreated: { id in addDisplayToSelection(id) },
                onRemoved: { id in handleTileRemove(id) },
                displaysInGrid: Set(effectiveDisplayIDs)
            )
            .controlSize(.small)

            Spacer()

            Button {
                let willEnable = !captureIncludeMicrophone
                captureIncludeMicrophone = willEnable
                if willEnable {
                    Task { await captureManager.requestMicrophonePermission() }
                }
            } label: {
                Image(systemName: captureIncludeMicrophone ? "mic.fill" : "mic.slash")
                    .font(.system(size: 10))
                    .foregroundColor(microphoneButtonActive ? .accentColor : .secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .help(captureIncludeMicrophone ? "Microphone on" : "Microphone off")
        }
    }

    private var displaySelectionMenu: some View {
        Menu {
            if captureRegionMode {
                Picker("Display", selection: Binding(
                    get: { effectiveDisplayIDs.first ?? 0 },
                    set: { setSelectedDisplayIDs([$0]) }
                )) {
                    ForEach(availableDisplays) { d in
                        Text(displayLabel(d)).tag(d.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } else {
                ForEach(availableDisplays) { d in
                    Button {
                        toggleDisplaySelection(d.id)
                    } label: {
                        if effectiveDisplayIDs.contains(d.id) {
                            Label(displayLabel(d), systemImage: "checkmark")
                        } else {
                            Text(displayLabel(d))
                        }
                    }
                }
                if availableDisplays.count > 1 {
                    Divider()
                    Button("Record All Displays") {
                        setSelectedDisplayIDs(availableDisplays.map(\.id))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: captureRegionMode ? "display" : "display.2")
                Text(displaySelectionLabel)
                    .lineLimit(1)
            }
            .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .help("Choose which display(s) to record")
    }

    private func displayLabel(_ d: CaptureDisplay) -> String {
        "\(d.name) (\(d.width)x\(d.height))" + (d.isMain ? " - Main" : "")
    }

    private var displaySelectionLabel: String {
        let n = effectiveDisplayIDs.count
        if captureRegionMode {
            if let id = effectiveDisplayIDs.first, let d = display(for: id) { return d.name }
            return "Display"
        }
        if selectedDisplayIDs.isEmpty { return "Main Display" }
        return n == 1 ? (display(for: effectiveDisplayIDs[0])?.name ?? "1 Screen") : "\(n) Screens"
    }

    private var controlsSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Picker("Mode", selection: $captureRegionMode) {
                    Text("Full Screen").tag(false)
                    Text("Region").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .disabled(captureManager.isRecording)

                cursorToggleButton
                excludeAppToggleButton
                audioExclusionButton
                if captureRegionMode {
                    overlayClickThroughToggleButton
                    aspectRatioButton
                }
                Spacer()
            }

            if let error = captureManager.errorMessage, !error.isEmpty {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if let start = scheduledStart {
                Button(action: cancelSchedule) {
                    Text("Cancel Schedule")
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "clock.fill")
                        .foregroundColor(.orange)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("Starts \(Self.startTimeFormatter.string(from: start))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("in \(scheduleCountdownText)")
                            .font(.system(.callout, design: .monospaced))
                            .monospacedDigit()
                    }
                }
                .help("Mac will stay awake until the recording starts.")
            } else if captureManager.isRecording || captureManager.isProcessing {
                recordingBottomBar
            } else {
                Button(action: onCancel) {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    scheduleStartDate = roundedScheduleDate(minutesFromNow: 5)
                    scheduleUseDuration = false
                    scheduleDurationHours = 0
                    scheduleDurationMinutes = 5
                    showSchedulePopover = true
                } label: {
                    Image(systemName: "clock")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("Schedule recording")
                .popover(isPresented: $showSchedulePopover, arrowEdge: .top) {
                    schedulePopoverContent
                }

                Button(action: handleRecordAll) {
                    Label(effectiveDisplayIDs.count > 1 ? "Record All" : "Record", systemImage: "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.regular)
            }
        }
    }

    private var recordingBottomBar: some View {
        HStack(spacing: 12) {
            if captureManager.isRecording {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .modifier(PulsingAnimation())
            }

            if captureManager.isProcessing {
                Label("Finalizing", systemImage: "hourglass")
                    .foregroundColor(.orange)
                    .font(.callout)
            } else if let totalText = autoStopTotalText {
                Text("\(elapsedText) / \(totalText)")
                    .font(.system(.title3, design: .monospaced))
                    .monospacedDigit()
            } else {
                Text(elapsedText)
                    .font(.system(.title3, design: .monospaced))
                    .monospacedDigit()
            }

            if captureManager.recordingDisplayIDs.count > 1 {
                Text("\(captureManager.recordingDisplayIDs.count) screens")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: onHidePanel) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .help("Hide this panel (use menu bar icon to re-open)")

            if captureManager.isProcessing {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                Button(action: onStopRecording) {
                    Label(captureManager.recordingDisplayIDs.count > 1 ? "Stop All" : "Stop", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Toggle Buttons

    private var microphoneIconColor: Color {
        if captureIncludeMicrophone {
            switch captureManager.microphoneCaptureStatus {
            case .authorized: return .white
            case .denied: return .orange
            case .disabled: return .yellow
            }
        }
        return .primary
    }

    private var microphoneButtonActive: Bool {
        captureIncludeMicrophone && captureManager.microphoneCaptureStatus == .authorized
    }

    private var cursorToggleButton: some View {
        Button {
            captureHideCursor.toggle()
        } label: {
            Image(systemName: captureHideCursor ? "cursorarrow.slash" : "cursorarrow")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(captureHideCursor ? .secondary : .primary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(captureHideCursor ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.2))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(captureHideCursor ? Color.primary.opacity(0.2) : Color.accentColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(captureHideCursor ? "Cursor hidden in capture" : "Cursor visible in capture")
    }

    private var lockedAspectRatio: AspectRatio {
        AspectRatio(rawValue: lockedAspectRatioRaw) ?? .free
    }

    private var aspectRatioShortLabel: String {
        String(lockedAspectRatio.displayName.split(separator: " ").first ?? "Free")
    }

    private var aspectRatioButton: some View {
        Menu {
            ForEach(AspectRatio.allCases.filter { $0 != .ratio21_9 }) { ratio in
                Button {
                    lockedAspectRatioRaw = ratio.rawValue
                } label: {
                    if ratio == lockedAspectRatio {
                        Label(ratio.displayName, systemImage: "checkmark")
                    } else {
                        Text(ratio.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "aspectratio")
                    .font(.system(size: 11, weight: .semibold))
                Text(aspectRatioShortLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundColor(lockedAspectRatio == .free ? .primary : .accentColor)
            .frame(height: 28)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(lockedAspectRatio == .free
                          ? Color.primary.opacity(0.06)
                          : Color.accentColor.opacity(0.2))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(lockedAspectRatio == .free
                            ? Color.primary.opacity(0.2)
                            : Color.accentColor,
                            lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(lockedAspectRatio == .free
              ? "Lock the recording region to an aspect ratio"
              : "Recording region locked to \(lockedAspectRatio.displayName) — choose another or Free to unlock")
    }

    private var overlayClickThroughToggleButton: some View {
        Button {
            overlayClickThrough.toggle()
            onSetOverlayClickThrough(overlayClickThrough)
        } label: {
            Image(systemName: overlayClickThrough ? "hand.raised.slash.fill" : "hand.raised.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(overlayClickThrough ? .orange : .primary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(overlayClickThrough ? Color.orange.opacity(0.15) : Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(overlayClickThrough ? Color.orange.opacity(0.6) : Color.primary.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(overlayClickThrough
              ? "Selection overlay disabled — clicks pass through to other apps. Tip: hold ⌘ to pass through temporarily."
              : "Disable the selection overlay temporarily so clicks pass through. Tip: hold ⌘ for momentary pass-through.")
    }

    private var excludeAppToggleButton: some View {
        Button {
            captureExcludeCurrentApp.toggle()
        } label: {
            Image(systemName: captureExcludeCurrentApp ? "macwindow.on.rectangle" : "macwindow")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(captureExcludeCurrentApp ? .secondary : .primary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(captureExcludeCurrentApp ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.2))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(captureExcludeCurrentApp ? Color.primary.opacity(0.2) : Color.accentColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(captureExcludeCurrentApp ? "This app excluded from capture" : "This app visible in capture")
    }

    private var audioExclusionButton: some View {
        Button {
            showAudioExclusionPopover.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: excludedAppBundleIDs.isEmpty ? "eye" : "eye.slash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(excludedAppBundleIDs.isEmpty ? .secondary : .orange)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(excludedAppBundleIDs.isEmpty ? Color.primary.opacity(0.06) : Color.orange.opacity(0.15))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(excludedAppBundleIDs.isEmpty ? Color.primary.opacity(0.2) : Color.orange.opacity(0.6), lineWidth: 1)
                    )
                if !excludedAppBundleIDs.isEmpty {
                    Text("\(excludedAppBundleIDs.count)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange))
                        .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .help(excludedAppBundleIDs.isEmpty ? "Hide and exclude sound from apps" : "\(excludedAppBundleIDs.count) app(s) hidden")
        .popover(isPresented: $showAudioExclusionPopover, arrowEdge: .bottom) {
            audioExclusionPopoverContent
        }
    }

    private var audioExclusionPopoverContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hide and Exclude Sound")
                .font(.headline)
                .padding(.bottom, 4)

            if availableApps.isEmpty {
                Text("No apps available")
                    .foregroundColor(.secondary)
                    .font(.callout)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(availableApps.filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }.sorted(by: { $0.applicationName < $1.applicationName }), id: \.bundleIdentifier) { app in
                            let bundleID = app.bundleIdentifier
                            Button {
                                if excludedAppBundleIDs.contains(bundleID) {
                                    excludedAppBundleIDs.remove(bundleID)
                                } else {
                                    excludedAppBundleIDs.insert(bundleID)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: excludedAppBundleIDs.contains(bundleID) ? "checkmark.square.fill" : "square")
                                        .foregroundColor(excludedAppBundleIDs.contains(bundleID) ? .accentColor : .secondary)
                                    Text(app.applicationName)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            if !excludedAppBundleIDs.isEmpty {
                Divider()
                Button("Clear All") {
                    excludedAppBundleIDs.removeAll()
                }
                .font(.callout)
            }
        }
        .padding(12)
        .frame(width: 220)
    }

    // MARK: - Schedule

    private var schedulePopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schedule Recording")
                .font(.headline)

            DatePicker("Start at", selection: $scheduleStartDate, in: Date()...,
                       displayedComponents: [.date, .hourAndMinute])

            Toggle("Auto-stop after", isOn: $scheduleUseDuration)

            if scheduleUseDuration {
                HStack(spacing: 4) {
                    Stepper(value: $scheduleDurationHours, in: 0...23) {
                        Text("\(scheduleDurationHours) hr")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                    .frame(width: 110)

                    Stepper(value: $scheduleDurationMinutes, in: 0...59) {
                        Text("\(scheduleDurationMinutes) min")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    .frame(width: 120)
                }
            }

            Divider()

            HStack {
                Button("Cancel") {
                    showSchedulePopover = false
                }
                Spacer()
                Button("Schedule") {
                    activateSchedule()
                    showSchedulePopover = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(scheduleStartDate <= Date() || (scheduleUseDuration && scheduleDurationHours == 0 && scheduleDurationMinutes == 0))
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private var scheduleCountdownText: String {
        let total = Int(scheduleCountdown)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var autoStopTotalText: String? {
        guard let stopDate = captureManager.autoStopDate else { return nil }
        let remaining = max(0, stopDate.timeIntervalSinceNow)
        let total = captureManager.elapsedTime + remaining
        return Self.durationFormatter.string(from: total)
    }

    private func roundedScheduleDate(minutesFromNow: Int) -> Date {
        let calendar = Calendar.current
        let future = calendar.date(byAdding: .minute, value: minutesFromNow, to: Date()) ?? Date()
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: future)
        components.second = 0
        return calendar.date(from: components) ?? future
    }

    private func activateSchedule() {
        scheduledStart = scheduleStartDate
        if scheduleUseDuration {
            let seconds = TimeInterval(scheduleDurationHours * 3600 + scheduleDurationMinutes * 60)
            scheduledDuration = seconds > 0 ? seconds : nil
        } else {
            scheduledDuration = nil
        }
        scheduleCountdown = scheduleStartDate.timeIntervalSinceNow
        if schedulePowerAssertion == nil {
            schedulePowerAssertion = PowerAssertion.shared.acquire(reason: "Waiting for scheduled screen recording")
        }
    }

    private func cancelSchedule() {
        scheduledStart = nil
        scheduledDuration = nil
        scheduleCountdown = 0
        PowerAssertion.shared.release(schedulePowerAssertion)
        schedulePowerAssertion = nil
    }

    private func fireScheduledRecording() {
        let duration = scheduledDuration
        scheduledStart = nil
        scheduledDuration = nil
        scheduleCountdown = 0
        PowerAssertion.shared.release(schedulePowerAssertion)
        schedulePowerAssertion = nil

        Task {
            onStartRecording()
            await captureManager.setSelectedDisplays(effectiveDisplayIDs, settings: makeSettings(), maxPreviewWidth: previewPixelWidth)
            await captureManager.startAllRecording(
                preset: presetBinding.wrappedValue,
                outputDirectory: outputDirectoryURL,
                dynamicRange: dynamicRangeOption
            )
            if let duration, duration > 0 {
                captureManager.setAutoStop(after: duration)
            }
        }
    }

    // MARK: - Recording / selection actions

    private func handleRecordAll() {
        Task {
            onStartRecording()
            await captureManager.setSelectedDisplays(effectiveDisplayIDs, settings: makeSettings(), maxPreviewWidth: previewPixelWidth)
            await captureManager.startAllRecording(
                preset: presetBinding.wrappedValue,
                outputDirectory: outputDirectoryURL,
                dynamicRange: dynamicRangeOption
            )
        }
    }

    private func handleTileRecord(_ id: CGDirectDisplayID) {
        Task {
            if captureManager.recordingDisplayIDs.contains(id) {
                await captureManager.stopRecording(displayID: id)
            } else {
                onStartRecording()
                await captureManager.startRecording(
                    displayID: id,
                    preset: presetBinding.wrappedValue,
                    outputDirectory: outputDirectoryURL,
                    dynamicRange: dynamicRangeOption
                )
            }
        }
    }

    private func handleTileRemove(_ id: CGDirectDisplayID) {
        guard effectiveDisplayIDs.count > 1 else { return }
        if focusedDisplayID == id { focusedDisplayID = nil }
        var ids = effectiveDisplayIDs
        ids.removeAll { $0 == id }
        setSelectedDisplayIDs(ids)
        // reconcileSelection runs via the captureDisplayIDsRaw onChange and finalizes a recording tile.

        // Under the default ephemeral policy, a virtual display removed from the grid stops existing.
        // Don't tear one down mid-recording — handleRecordingStopped sweeps those up afterwards.
        let manager = VirtualDisplayManager.shared
        if manager.isVirtual(id), !captureManager.recordingDisplayIDs.contains(id) {
            manager.destroyIfEphemeral(id)
        }
    }

    private func toggleDisplaySelection(_ id: CGDirectDisplayID) {
        var ids = effectiveDisplayIDs
        if ids.contains(id) {
            guard ids.count > 1 else { return } // keep at least one
            ids.removeAll { $0 == id }
        } else {
            ids.append(id)
        }
        setSelectedDisplayIDs(ids)
    }

    private func addDisplayToSelection(_ id: CGDirectDisplayID) {
        if captureRegionMode {
            setSelectedDisplayIDs([id])
        } else {
            var ids = effectiveDisplayIDs
            if !ids.contains(id) { ids.append(id) }
            setSelectedDisplayIDs(ids)
        }
    }

    // MARK: - Preview reconciliation

    /// Apply the current selection to the manager (adds new tiles, drops/finalizes removed ones)
    /// without disturbing existing tiles.
    private func reconcileSelection() async {
        guard isViewActive else { return }
        await captureManager.setSelectedDisplays(effectiveDisplayIDs, settings: makeSettings(), maxPreviewWidth: previewPixelWidth)
    }

    /// Rebuild all preview tiles with the latest settings (used when a non-selection setting changes,
    /// e.g. frame rate or cursor visibility). Recording tiles are left running.
    private func refreshPreviews() async {
        guard isViewActive else { return }
        await captureManager.stopPreview()
        await captureManager.setSelectedDisplays(effectiveDisplayIDs, settings: makeSettings(), maxPreviewWidth: previewPixelWidth)
    }

    private func refreshAvailableDisplays() async {
        guard let content = try? await ScreenCaptureManager.shareableContent() else { return }
        let displays = ScreenCaptureManager.displays(from: content)
        await MainActor.run { availableDisplays = displays }
    }

    private func loadMicrophones() async {
        guard #available(macOS 15, *) else {
            await MainActor.run {
                microphoneDevices = []
                captureMicrophoneDeviceID = ""
            }
            return
        }
        let devices = ScreenCaptureManager.availableMicrophones()
        await MainActor.run {
            microphoneDevices = devices
            if !devices.contains(where: { $0.uniqueID == captureMicrophoneDeviceID }) {
                captureMicrophoneDeviceID = ""
            }
        }
    }

    private func notifyDisplayChanged() {
        let screen: NSScreen?
        if let id = effectiveDisplayIDs.first, let s = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
        }) {
            screen = s
        } else {
            screen = NSScreen.main ?? NSScreen.screens.first
        }
        guard let screen else { return }
        onDisplayChanged(screen, selectedRegionRect)
    }

    // MARK: - Helpers

    private var elapsedText: String {
        Self.durationFormatter.string(from: captureManager.elapsedTime) ?? "00:00:00"
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()

    private static let startTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Capture Tile

/// One screen's live preview tile in the overlay grid. Hovering reveals expand / record-stop /
/// remove controls; a red badge marks a tile that is recording.
private struct CaptureTileView: View {
    let displayID: CGDirectDisplayID
    let name: String
    let image: CGImage?
    let isRecording: Bool
    let isFocused: Bool
    let canRemove: Bool
    let isProcessing: Bool
    @Binding var hoveredDisplayID: CGDirectDisplayID?
    let onToggleFocus: () -> Void
    let onToggleRecord: () -> Void
    let onRemove: () -> Void

    private var isHovered: Bool { hoveredDisplayID == displayID }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.3))

            if let image {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                VStack(spacing: 4) {
                    Image(systemName: "rectangle.inset.filled")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary.opacity(0.7))
                    Text(name)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            // Recording badge (top-left).
            if isRecording {
                VStack {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                        Text("REC").font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(6)
            }

            // Display name (bottom-left), shown on hover.
            if isHovered {
                VStack {
                    Spacer()
                    HStack {
                        Text(name)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.black.opacity(0.5)))
                        Spacer()
                    }
                }
                .padding(6)
            }

            // Hover controls (centered).
            if isHovered {
                HStack(spacing: 10) {
                    tileButton(systemName: isFocused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                               tint: .white,
                               help: isFocused ? "Collapse" : "Expand this screen",
                               action: onToggleFocus)

                    tileButton(systemName: isRecording ? "stop.fill" : "record.circle",
                               tint: isRecording ? .red : .green,
                               help: isRecording ? "Stop recording this screen" : "Record this screen",
                               action: onToggleRecord)
                        .disabled(isProcessing)

                    if canRemove {
                        tileButton(systemName: "xmark",
                                   tint: .white,
                                   help: "Remove this screen from the recording",
                                   action: onRemove)
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isRecording ? Color.red.opacity(0.8) : Color.white.opacity(isHovered ? 0.25 : 0), lineWidth: isRecording ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredDisplayID = displayID
            } else if hoveredDisplayID == displayID {
                hoveredDisplayID = nil
            }
        }
    }

    private func tileButton(systemName: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Visual Effect Blur

private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Pulsing Animation

private struct PulsingAnimation: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
            .onAppear { isPulsing = true }
    }
}

// MARK: - Preview Refresh Modifier

private struct PreviewRefreshModifier: ViewModifier {
    let captureHideCursor: Bool
    let captureExcludeCurrentApp: Bool
    let captureFrameRateRaw: String
    let captureIncludeMicrophone: Bool
    let captureDynamicRangeRaw: String
    let excludedAppBundleIDs: Set<String>
    let captureRegionX: Double
    let captureRegionY: Double
    let captureRegionWidth: Double
    let captureRegionHeight: Double
    let refreshPreview: () async -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: captureHideCursor) { _, _ in Task { await refreshPreview() } }
            .onChange(of: captureExcludeCurrentApp) { _, _ in Task { await refreshPreview() } }
            .onChange(of: captureFrameRateRaw) { _, _ in Task { await refreshPreview() } }
            .onChange(of: captureIncludeMicrophone) { _, _ in Task { await refreshPreview() } }
            .onChange(of: captureDynamicRangeRaw) { _, _ in Task { await refreshPreview() } }
            .onChange(of: excludedAppBundleIDs) { _, _ in Task { await refreshPreview() } }
            .onChange(of: captureRegionX) { _, _ in Task { await refreshPreview() } }
            .onChange(of: captureRegionY) { _, _ in Task { await refreshPreview() } }
            .onChange(of: captureRegionWidth) { _, _ in Task { await refreshPreview() } }
            .onChange(of: captureRegionHeight) { _, _ in Task { await refreshPreview() } }
    }
}
