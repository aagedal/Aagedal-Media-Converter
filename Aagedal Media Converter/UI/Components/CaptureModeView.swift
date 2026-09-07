// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit
import CoreGraphics
import AVFoundation
import ScreenCaptureKit

struct CaptureModeView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppConstants.captureDirectoryKey) private var captureDirectoryPath = AppConstants.defaultCaptureDirectory.path
    @AppStorage(AppConstants.capturePresetKey) private var capturePresetRaw = CapturePreset.defaultPreset.rawValue
    @AppStorage(AppConstants.captureDisplayIDKey) private var captureDisplayID = 0
    @AppStorage(AppConstants.captureFrameRateKey) private var captureFrameRateRaw = AppConstants.defaultCaptureFrameRate
    @AppStorage(AppConstants.captureDynamicRangeKey) private var captureDynamicRangeRaw = AppConstants.defaultCaptureDynamicRange
    @AppStorage(AppConstants.captureHideCursorKey) private var captureHideCursor = AppConstants.defaultCaptureHideCursor
    @AppStorage(AppConstants.captureExcludeCurrentAppKey) private var captureExcludeCurrentApp = AppConstants.defaultCaptureExcludeCurrentApp
    @AppStorage(AppConstants.captureIncludeMicrophoneKey) private var captureIncludeMicrophone = AppConstants.defaultCaptureIncludeMicrophone
    @AppStorage(AppConstants.captureMicrophoneDeviceIDKey) private var captureMicrophoneDeviceID = AppConstants.defaultCaptureMicrophoneDeviceID
    @AppStorage(AppConstants.captureRegionModeKey) private var captureRegionMode = AppConstants.defaultCaptureRegionMode
    @AppStorage(AppConstants.captureRegionXKey) private var captureRegionX: Double = 0
    @AppStorage(AppConstants.captureRegionYKey) private var captureRegionY: Double = 0
    @AppStorage(AppConstants.captureRegionWidthKey) private var captureRegionWidth: Double = 0
    @AppStorage(AppConstants.captureRegionHeightKey) private var captureRegionHeight: Double = 0
    @StateObject private var captureManager = ScreenCaptureManager.shared
    @State private var availableDisplays: [CaptureDisplay] = []
    @State private var isViewActive = false
    @State private var microphoneDevices: [AVCaptureDevice] = []
    @State private var isMicButtonHovering = false
    @State private var showAudioExclusionPopover = false
    @State private var availableApps: [SCRunningApplication] = []
    @State private var excludedAppBundleIDs: Set<String> = []

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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerRow
            Divider()
            previewSection
            HStack {
                controlRow
                outputSection
                
            }
            if let error = captureManager.errorMessage, !error.isEmpty {
                Text(error)
                    .foregroundColor(.red)
                    .font(.callout)
            }
            Spacer(minLength: 0)
            footerNote
        }
        .padding(16)
        .frame(minWidth: 840, minHeight: 620)
        .interactiveDismissDisabled(captureManager.isRecording || captureManager.isProcessing)
        .onAppear {
            isViewActive = true
            if !CapturePreset.availablePresets.contains(presetBinding.wrappedValue) {
                capturePresetRaw = CapturePreset.defaultPreset.rawValue
            }
            Task {
                // Fetch shareable content once and reuse for both displays and preview
                async let microphonesTask: () = loadMicrophones()

                do {
                    let content = try await ScreenCaptureManager.shareableContent()
                    let displays = ScreenCaptureManager.displays(from: content)
                    let apps = content.applications
                    await MainActor.run {
                        availableDisplays = displays
                        availableApps = apps
                        if captureDisplayID != 0,
                           !displays.contains(where: { Int($0.id) == captureDisplayID }) {
                            captureDisplayID = 0
                        }
                    }
                    captureManager.refreshMicrophoneAuthorizationStatus()
                    await startPreview(with: content)
                } catch {
                    await MainActor.run {
                        availableDisplays = []
                        captureDisplayID = 0
                    }
                }

                await microphonesTask
            }
        }
        .onDisappear {
            isViewActive = false
            Task {
                await captureManager.stopPreview()
            }
        }
        .onChange(of: captureDisplayID) { _, _ in
            // Region is display-specific; clear it when display changes
            if captureRegionMode {
                captureRegionWidth = 0
                captureRegionHeight = 0
            }
            Task {
                await refreshPreview()
            }
        }
        .onChange(of: captureRegionMode) { _, _ in
            Task {
                await refreshPreview()
            }
        }
        .onChange(of: captureHideCursor) { _, _ in
            Task {
                await refreshPreview()
            }
        }
        .onChange(of: captureExcludeCurrentApp) { _, _ in
            Task {
                await refreshPreview()
            }
        }
        .onChange(of: captureFrameRateRaw) { _, _ in
            Task {
                await refreshPreview()
            }
        }
        .onChange(of: captureIncludeMicrophone) { _, _ in
            Task {
                await refreshPreview()
            }
        }
        .onChange(of: captureMicrophoneDeviceID) { _, _ in
            Task {
                await refreshPreview()
            }
        }
        .onChange(of: captureDynamicRangeRaw) { _, _ in
            Task {
                await refreshPreview()
            }
        }
        .onChange(of: excludedAppBundleIDs) { _, _ in
            Task {
                await refreshPreview()
            }
        }
        .onChange(of: captureManager.isRecording) { _, isRecording in
            guard !isRecording else { return }
            Task {
                await refreshPreview()
            }
        }
    }

    private var headerRow: some View {
        HStack {
            Text("Capture Mode")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.secondary.opacity(0.7), .secondary.opacity(0.25))
            }
            .buttonStyle(.plain)
            .help("Close")
            .disabled(captureManager.isRecording || captureManager.isProcessing)
            .keyboardShortcut(.cancelAction)
        }
    }

    private var previewSection: some View {
        HStack {
            VStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.2))
                    if let image = captureManager.previewImage {
                        Image(decorative: image, scale: 1.0)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "rectangle.inset.filled")
                                .font(.system(size: 28))
                                .foregroundColor(.secondary.opacity(0.7))
                            Text(captureManager.isRecording ? "Waiting for frames..." : "Preview should appear shortly")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(minWidth: 560, maxWidth: .infinity, minHeight: 320, maxHeight: 420)
                
                
                HStack {
                    Picker("Display", selection: $captureDisplayID) {
                        Text("Automatic (Main Display)")
                            .tag(0)
                        ForEach(availableDisplays) { display in
                            let label = "\(display.name) (\(display.width)x\(display.height))" + (display.isMain ? " • Main" : "")
                            Text(label).tag(Int(display.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 260)
                    .disabled(captureManager.isRecording || captureManager.isProcessing)

                    VirtualDisplayMenu(
                        isDisabled: captureManager.isRecording || captureManager.isProcessing,
                        onDisplaysChanged: { await refreshAvailableDisplays() },
                        onCreated: { id in captureDisplayID = Int(id) },
                        onRemoved: { id in if captureDisplayID == Int(id) { captureDisplayID = 0 } },
                        displaysInGrid: captureDisplayID > 0 ? [CGDirectDisplayID(captureDisplayID)] : []
                    )

                    Spacer()
                    
                    if microphoneSelectionSupported {
                        Picker("Microphone", selection: $captureMicrophoneDeviceID) {
                            Text("System Default").tag("")
                            ForEach(microphoneDevices, id: \.uniqueID) { device in
                                Text(device.localizedName).tag(device.uniqueID)
                            }
                        }
                        .pickerStyle(.menu)
                        .disabled(captureManager.isRecording || captureManager.isProcessing)
                        .help("Select the microphone used for the secondary audio track")
                    } else {
                        Text("Microphone selection requires macOS 15 or later.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

            }
            

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("System Audio")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        AudioMeterView(levels: captureManager.audioLevels, meterHeight: 320)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Microphone")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        AudioMeterView(levels: captureManager.microphoneLevels, meterHeight: 320)
                            .saturation(microphoneButtonActive ? 1.0 : 0.0)
                            .opacity(microphoneButtonActive ? 1.0 : 0.5)
                    }
                }
                microphoneToggleButton
                Spacer()
            }
            .frame(width: 140, alignment: .leading)
        }
    }

    private var controlRow: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button(action: toggleRecording) {
                    Label(captureManager.isRecording ? "Stop" : "Record", systemImage: captureManager.isRecording ? "stop.circle.fill" : "record.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(captureManager.isRecording ? .red : .green)
                .controlSize(.regular)
                .disabled(captureManager.isProcessing)

                cursorToggleButton
                excludeAppToggleButton
                audioExclusionButton

                Spacer()
            }

            HStack(spacing: 8) {
                Picker("Mode", selection: $captureRegionMode) {
                    Text("Full Screen").tag(false)
                    Text("Region").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .disabled(captureManager.isRecording || captureManager.isProcessing)

                if captureRegionMode {
                    Button {
                        openRegionSelector()
                    } label: {
                        Label("Select Region\u{2026}", systemImage: "rectangle.dashed")
                    }
                    .disabled(captureManager.isRecording || captureManager.isProcessing || RegionSelectionWindowController.shared.isShowing)

                    if captureRegionWidth > 0, captureRegionHeight > 0 {
                        Text("\(Int(captureRegionWidth)) \u{00D7} \(Int(captureRegionHeight)) pts")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()
            }

            HStack {
                if captureManager.isRecording {
                    Label("Recording", systemImage: "record.circle.fill")
                        .foregroundColor(.red)
                } else if captureManager.isProcessing {
                    Label("Finalizing", systemImage: "hourglass")
                        .foregroundColor(.orange)
                } else {
                    Label("Ready", systemImage: "circle.fill")
                        .foregroundColor(.green)
                }

                Text(elapsedText)
                    .font(.callout)
                    .monospacedDigit()

                if captureManager.isProcessing {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                }
             
                Spacer()
            }

        }.frame(minWidth: 300)
    }

    private var microphoneToggleButton: some View {
        Button {
            let willEnable = !captureIncludeMicrophone
            captureIncludeMicrophone = willEnable
            if willEnable {
                Task {
                    await captureManager.requestMicrophonePermission()
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: captureIncludeMicrophone ? "mic.fill" : "mic.slash")
                    .font(.system(size: 14, weight: .semibold))
                    .scaleEffect(isMicButtonHovering ? 1.05 : 1.0)
                Text(captureIncludeMicrophone ? "Microphone On" : "Microphone Off")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(microphoneIconColor)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(microphoneButtonBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(microphoneButtonBorder, lineWidth: isMicButtonHovering ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isMicButtonHovering = hovering
        }
        .help(microphoneButtonHelpText)
        .disabled(captureManager.isRecording || captureManager.isProcessing)
    }

    private var microphoneIconColor: Color {
        if captureIncludeMicrophone {
            switch captureManager.microphoneCaptureStatus {
            case .authorized:
                return .white
            case .denied:
                return .orange
            case .disabled:
                return .yellow
            }
        }
        return .primary
    }

    private var microphoneButtonBackground: Color {
        if microphoneButtonActive {
            return Color.accentColor.opacity(isMicButtonHovering ? 0.35 : 0.25)
        }
        if captureIncludeMicrophone && captureManager.microphoneCaptureStatus == .denied {
            return Color.red.opacity(isMicButtonHovering ? 0.16 : 0.12)
        }
        return Color.primary.opacity(isMicButtonHovering ? 0.15 : 0.06)
    }

    private var microphoneButtonBorder: Color {
        if microphoneButtonActive {
            return Color.accentColor
        }
        if captureIncludeMicrophone && captureManager.microphoneCaptureStatus == .denied {
            return Color.red
        }
        return Color.primary.opacity(0.35)
    }

    private var microphoneButtonHelpText: String {
        if captureIncludeMicrophone {
            switch captureManager.microphoneCaptureStatus {
            case .authorized:
                return "Microphone will be recorded as a separate 24-bit LPCM track."
            case .denied:
                return "Microphone access is blocked; click to re-open the permission prompt."
            case .disabled:
                return "Requesting microphone permission so a secondary track can be captured."
            }
        }
        return "Enable the microphone track (system + mic) so you can capture narrations."
    }

    private var microphoneButtonActive: Bool {
        captureIncludeMicrophone && captureManager.microphoneCaptureStatus == .authorized
    }

    private var cursorToggleButton: some View {
        Button {
            captureHideCursor.toggle()
        } label: {
            Image(systemName: captureHideCursor ? "cursorarrow.slash" : "cursorarrow")
                .font(.system(size: 14, weight: .semibold))
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
        .disabled(captureManager.isRecording || captureManager.isProcessing)
    }

    private var excludeAppToggleButton: some View {
        Button {
            captureExcludeCurrentApp.toggle()
        } label: {
            Image(systemName: captureExcludeCurrentApp ? "macwindow.on.rectangle" : "macwindow")
                .font(.system(size: 14, weight: .semibold))
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
        .disabled(captureManager.isRecording || captureManager.isProcessing)
    }

    private var audioExclusionButton: some View {
        Button {
            showAudioExclusionPopover.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: excludedAppBundleIDs.isEmpty ? "eye" : "eye.slash")
                    .font(.system(size: 14, weight: .semibold))
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
        .disabled(captureManager.isRecording || captureManager.isProcessing)
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

    @ViewBuilder
    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last Capture")
                .font(.headline)
            HStack(spacing: 10) {
                if let lastURL = captureManager.lastOutputURL {
                    Text(lastURL.lastPathComponent)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No captures yet")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
                dragIcon(
                    for: captureManager.lastOutputURL,
                    color: .blue,
                    helpText: "Drag the recorded file to another app or folder."
                )
                
                Button {
                    guard let lastURL = captureManager.lastOutputURL else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([lastURL])
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help("Reveal the recording in Finder")
                .disabled(captureManager.lastOutputURL == nil)
                
                Button {
                    guard let lastURL = captureManager.lastOutputURL else { return }
                    NotificationCenter.default.post(name: .enqueueFileURL, object: lastURL)
                } label: {
                    Image(systemName: "plus.square.on.square")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Send recording to the conversion queue")
                .disabled(captureManager.lastOutputURL == nil)
            }
        }
    }

    @ViewBuilder
    private func dragIcon(for outputURL: URL?, color: Color, helpText: String) -> some View {
        if let url = outputURL {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .foregroundColor(color)
                .help(helpText)
                .onDrag {
                    let provider = NSItemProvider(object: url as NSURL)
                    provider.suggestedName = url.lastPathComponent
                    return provider
                }
        } else {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .foregroundColor(color.opacity(0.45))
                .help("Drag a recording once one is available.")
        }
    }

    private var footerNote: some View {
        Text("Captures the selected display at native resolution with system audio. Preset and output folder are managed in Settings > Screen Capture.")
            .font(.caption)
            .foregroundColor(.secondary)
    }

    private var elapsedText: String {
        Self.durationFormatter.string(from: captureManager.elapsedTime) ?? "00:00:00"
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()

    private func toggleRecording() {
        Task {
            if captureManager.isRecording {
                await captureManager.stopRecording()
            } else {
                let displayID = captureDisplayID == 0 ? nil : CGDirectDisplayID(captureDisplayID)
                await captureManager.startRecording(
                    preset: presetBinding.wrappedValue,
                    outputDirectory: outputDirectoryURL,
                    displayID: displayID,
                    frameRate: frameRateOption,
                    dynamicRange: dynamicRangeOption,
                    includeMicrophone: captureIncludeMicrophone,
                    microphoneDeviceID: selectedMicrophoneDeviceID,
                    hideCursor: captureHideCursor,
                    excludeCurrentApp: captureExcludeCurrentApp,
                    excludedAppBundleIDs: excludedAppBundleIDs,
                    regionRect: selectedRegionRect
                )
            }
        }
    }

    private func loadDisplays() async {
        do {
            let displays = try await ScreenCaptureManager.availableDisplays()
            await MainActor.run {
                availableDisplays = displays
                if captureDisplayID != 0,
                   !displays.contains(where: { Int($0.id) == captureDisplayID }) {
                    captureDisplayID = 0
                }
            }
        } catch {
            await MainActor.run {
                availableDisplays = []
                captureDisplayID = 0
            }
        }
    }

    /// Re-fetch the display list after a virtual display is added/removed so it
    /// appears in (or disappears from) the picker.
    private func refreshAvailableDisplays() async {
        guard let content = try? await ScreenCaptureManager.shareableContent() else { return }
        let displays = ScreenCaptureManager.displays(from: content)
        await MainActor.run {
            availableDisplays = displays
        }
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

    private func refreshPreview() async {
        await startPreview(with: nil)
    }

    private func startPreview(with cachedContent: SCShareableContent?) async {
        guard isViewActive, !captureManager.isRecording else { return }
        let displayID = captureDisplayID == 0 ? nil : CGDirectDisplayID(captureDisplayID)
        await captureManager.startPreview(
            displayID: displayID,
            frameRate: frameRateOption,
            includeMicrophone: captureIncludeMicrophone,
            microphoneDeviceID: selectedMicrophoneDeviceID,
            hideCursor: captureHideCursor,
            excludeCurrentApp: captureExcludeCurrentApp,
            excludedAppBundleIDs: excludedAppBundleIDs,
            cachedContent: cachedContent,
            regionRect: selectedRegionRect
        )
    }

    private func openRegionSelector() {
        let displayID = captureDisplayID == 0 ? nil : CGDirectDisplayID(captureDisplayID)
        let screen: NSScreen?
        if let displayID, let s = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }) {
            screen = s
        } else {
            screen = NSScreen.main ?? NSScreen.screens.first
        }
        guard let screen else { return } // no active displays — can't place the selector

        let initialRegion = selectedRegionRect
        RegionSelectionWindowController.shared.showOverlay(on: screen, initialRegion: initialRegion) { rect in
            if let rect {
                captureRegionX = rect.origin.x
                captureRegionY = rect.origin.y
                captureRegionWidth = rect.size.width
                captureRegionHeight = rect.size.height
            }
            Task {
                await refreshPreview()
            }
        }
    }
}

#Preview {
    CaptureModeView()
}
