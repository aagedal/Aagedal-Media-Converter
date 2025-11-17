// Aagedal Media Converter — Waveform Settings Tab

import SwiftUI

struct WaveformSettingsView: View {
    @AppStorage(AppConstants.audioWaveformVideoDefaultEnabledKey) private var waveformVideoDefaultEnabled = true
    @AppStorage(AppConstants.audioWaveformResolutionKey) private var waveformResolutionString = "1280x720"
    @AppStorage(AppConstants.audioWaveformBackgroundColorKey) private var waveformBackgroundHex = "#000000"
    @AppStorage(AppConstants.audioWaveformForegroundColorKey) private var waveformForegroundHex = "#FFFFFF"
    @AppStorage(AppConstants.audioWaveformNormalizeKey) private var waveformNormalizeAudio = false
    @AppStorage(AppConstants.audioWaveformStyleKey) private var waveformStyleRaw = AppConstants.defaultAudioWaveformStyleRaw
    @AppStorage(AppConstants.audioWaveformFrameRateKey) private var waveformFrameRate = AppConstants.defaultAudioWaveformFrameRate

    @State private var resolutionSanitizationTask: Task<Void, Never>?

    var body: some View {
        Form {
            waveformSection
        }
        .formStyle(.grouped)
        .onDisappear {
            resolutionSanitizationTask?.cancel()
            sanitizeWaveformResolution()
            sanitizeWaveformColors()
        }
    }

    private var waveformSection: some View {
        Section(header: Text("Audio Waveform Video")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable waveform video by default", isOn: $waveformVideoDefaultEnabled)
                    .toggleStyle(SwitchToggleStyle())
                    .help("When enabled, newly added audio-only files will generate waveform videos unless disabled per item.")

                Toggle("Normalize audio levels", isOn: $waveformNormalizeAudio)
                    .toggleStyle(SwitchToggleStyle())
                    .help("Applies dynamic normalization before rendering the waveform and exporting audio to keep amplitudes consistent.")

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Resolution (e.g. 1280x720)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("1280x720", text: $waveformResolutionString)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(sanitizeWaveformResolution)
                            .onChange(of: waveformResolutionString) { _, newValue in
                                scheduleResolutionSanitization(for: newValue)
                            }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Background HEX")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            ColorPicker("", selection: Binding(
                                get: { Color(hex: waveformBackgroundHex) },
                                set: { waveformBackgroundHex = $0.toHexString(includeHash: true) }
                            ))
                            .labelsHidden()
                            .frame(width: 36)

                            TextField("#000000", text: $waveformBackgroundHex)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(sanitizeWaveformColors)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Waveform HEX")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            ColorPicker("", selection: Binding(
                                get: { Color(hex: waveformForegroundHex) },
                                set: { waveformForegroundHex = $0.toHexString(includeHash: true) }
                            ))
                            .labelsHidden()
                            .frame(width: 36)

                            TextField("#FFFFFF", text: $waveformForegroundHex)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(sanitizeWaveformColors)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Frame Rate")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Picker("Frame Rate", selection: Binding(
                        get: { Int(waveformFrameRate.rounded()) },
                        set: { waveformFrameRate = Double($0) }
                    )) {
                        ForEach([15, 24, 25, 30, 50, 60], id: \.self) { rate in
                            Text("\(rate) fps").tag(rate)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .help("Controls waveform animation smoothness. Higher frame rates increase render cost.")
                }

                Picker(
                    "Waveform style",
                    selection: Binding(
                        get: { WaveformStyle(rawValue: waveformStyleRaw) ?? .linear },
                        set: { waveformStyleRaw = $0.rawValue }
                    )
                ) {
                    ForEach(WaveformStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .help("Choose the visual appearance used when rendering waveform videos.")

                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        resetWaveformDefaults()
                    } label: {
                        Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .help("Restore waveform color and normalization settings to their default values.")
                }

                Text("These defaults control waveform video generation for audio-only media. Colors should be six-digit HEX values.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }

    // MARK: - Helpers (scoped to Waveform tab)

    private func scheduleResolutionSanitization(for newValue: String) {
        resolutionSanitizationTask?.cancel()
        resolutionSanitizationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard newValue == waveformResolutionString else { return }
            sanitizeWaveformResolution()
        }
    }

    private func sanitizeWaveformResolution() {
        let trimmed = waveformResolutionString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let (width, height) = AudioWaveformPreferences.parseResolution(trimmed) {
            waveformResolutionString = "\(width)x\(height)"
        } else {
            waveformResolutionString = "1280x720"
        }
    }

    private func sanitizeWaveformColors() {
        waveformBackgroundHex = "#" + AudioWaveformPreferences.sanitizeHex(waveformBackgroundHex, fallback: "000000")
        waveformForegroundHex = "#" + AudioWaveformPreferences.sanitizeHex(waveformForegroundHex, fallback: "FFFFFF")
    }

    private func resetWaveformDefaults() {
        waveformVideoDefaultEnabled = true
        waveformResolutionString = "1280x720"
        waveformBackgroundHex = "#000000"
        waveformForegroundHex = "#FFFFFF"
        waveformNormalizeAudio = false
        waveformStyleRaw = AppConstants.defaultAudioWaveformStyleRaw
        waveformFrameRate = AppConstants.defaultAudioWaveformFrameRate
    }
}
