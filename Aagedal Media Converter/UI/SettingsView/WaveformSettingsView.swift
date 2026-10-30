// Aagedal Media Converter — Waveform Settings Tab

import SwiftUI

/// Short edge resolution options for waveform video
enum ShortEdgeResolution: Int, CaseIterable, Identifiable {
    case p2160 = 2160
    case p1080 = 1080
    case p720 = 720
    case p480 = 480

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .p2160: return "2160p (4K)"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p480: return "480p"
        }
    }
}

struct WaveformSettingsView: View {
    @AppStorage(AppConstants.audioWaveformVideoDefaultEnabledKey) private var waveformVideoDefaultEnabled = true
    @AppStorage(AppConstants.audioWaveformAspectRatioKey) private var waveformAspectRatioRaw = AppConstants.defaultAudioWaveformAspectRatio
    @AppStorage(AppConstants.audioWaveformShortEdgeKey) private var waveformShortEdge = AppConstants.defaultAudioWaveformShortEdge
    @AppStorage(AppConstants.audioWaveformBackgroundColorKey) private var waveformBackgroundHex = "#000000"
    @AppStorage(AppConstants.audioWaveformForegroundColorKey) private var waveformForegroundHex = "#FFFFFF"
    @AppStorage(AppConstants.audioWaveformNormalizeKey) private var waveformNormalizeAudio = false
    @AppStorage(AppConstants.audioWaveformStyleKey) private var waveformStyleRaw = AppConstants.defaultAudioWaveformStyleRaw
    @AppStorage(AppConstants.audioWaveformFrameRateKey) private var waveformFrameRate = AppConstants.defaultAudioWaveformFrameRate
    @AppStorage(AppConstants.audioWaveformRenderingEngineKey) private var waveformRenderingEngineRaw = "swift"
    @AppStorage(AppConstants.audioWaveformSwiftStyleKey) private var waveformSwiftStyleRaw = "capsules"
    @AppStorage(AppConstants.audioWaveformBandCountKey) private var waveformBandCount = 32
    @AppStorage(AppConstants.audioWaveformFrequencyDistributionKey) private var waveformFrequencyDistributionRaw = "mel"

    // Gradient settings
    @AppStorage(AppConstants.audioWaveformForegroundGradientEnabledKey) private var foregroundGradientEnabled = false
    @AppStorage(AppConstants.audioWaveformForegroundGradientEndColorKey) private var foregroundGradientEndHex = "#FF0000"
    @AppStorage(AppConstants.audioWaveformBackgroundGradientEnabledKey) private var backgroundGradientEnabled = false
    @AppStorage(AppConstants.audioWaveformBackgroundGradientEndColorKey) private var backgroundGradientEndHex = "#333333"

    // Opacity setting
    @AppStorage(AppConstants.audioWaveformOpacityKey) private var waveformOpacity = 1.0

    // Alpha export
    @AppStorage(AppConstants.audioWaveformTransparentBackgroundKey) private var transparentBackground = false

    private var isSwiftEngine: Bool {
        (WaveformRenderingEngine(rawValue: waveformRenderingEngineRaw) ?? .swift) == .swift
    }

    private var selectedRenderingEngine: Binding<WaveformRenderingEngine> {
        Binding(
            get: { WaveformRenderingEngine(rawValue: waveformRenderingEngineRaw) ?? .swift },
            set: { waveformRenderingEngineRaw = $0.rawValue }
        )
    }

    private var selectedSwiftStyle: Binding<SwiftWaveformStyle> {
        Binding(
            get: { SwiftWaveformStyle(rawValue: waveformSwiftStyleRaw) ?? .capsules },
            set: { waveformSwiftStyleRaw = $0.rawValue }
        )
    }

    private var selectedAspectRatio: Binding<AspectRatio> {
        Binding(
            get: { AspectRatio(rawValue: waveformAspectRatioRaw) ?? .ratio16_9 },
            set: { waveformAspectRatioRaw = $0.rawValue }
        )
    }

    private var selectedShortEdge: Binding<ShortEdgeResolution> {
        Binding(
            get: { ShortEdgeResolution(rawValue: waveformShortEdge) ?? .p1080 },
            set: { waveformShortEdge = $0.rawValue }
        )
    }

    private var selectedFFmpegStyle: Binding<WaveformStyle> {
        Binding(
            get: { WaveformStyle(rawValue: waveformStyleRaw) ?? .linear },
            set: { waveformStyleRaw = $0.rawValue }
        )
    }

    private var selectedDistribution: Binding<FrequencyDistribution> {
        Binding(
            get: { FrequencyDistribution(rawValue: waveformFrequencyDistributionRaw) ?? .mel },
            set: { waveformFrequencyDistributionRaw = $0.rawValue }
        )
    }

    /// Computed resolution string for display
    private var computedResolution: String {
        let aspectRatio = AspectRatio(rawValue: waveformAspectRatioRaw) ?? .ratio16_9
        let shortEdge = waveformShortEdge
        let (width, height) = AudioWaveformPreferences.computeResolution(aspectRatio: aspectRatio, shortEdge: shortEdge)
        return "\(width)×\(height)"
    }

    var body: some View {
        Form {
            previewSection
            defaultsSection
            outputSection
            rendererSection
            colorsSection
            resetSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Sections

    private var previewSection: some View {
        Section(header: Text("Preview")) {
            VStack(alignment: .leading, spacing: 8) {
                if isSwiftEngine {
                    WaveformStylePreview(
                        style: selectedSwiftStyle.wrappedValue,
                        bandCount: waveformBandCount,
                        aspectRatio: selectedAspectRatio.wrappedValue,
                        frameRate: waveformFrameRate,
                        foregroundHex: waveformForegroundHex,
                        backgroundHex: waveformBackgroundHex,
                        foregroundGradientEndHex: foregroundGradientEnabled ? foregroundGradientEndHex : nil,
                        backgroundGradientEndHex: backgroundGradientEnabled ? backgroundGradientEndHex : nil,
                        opacity: waveformOpacity,
                        transparentBackground: transparentBackground
                    )
                    Text("Animated with simulated audio. Exported videos follow the real audio and frequency distribution.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Live preview is available for the Swift engine only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    private var defaultsSection: some View {
        Section(header: Text("Defaults")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Enable waveform video by default", isOn: $waveformVideoDefaultEnabled)
                    .toggleStyle(SwitchToggleStyle())
                    .help("When enabled, newly added audio-only files will generate waveform videos unless disabled per item.")

                Toggle("Normalize audio levels", isOn: $waveformNormalizeAudio)
                    .toggleStyle(SwitchToggleStyle())
                    .help("Applies dynamic normalization before rendering the waveform and exporting audio to keep amplitudes consistent.")
            }
            .padding(8)
        }
    }

    private var outputSection: some View {
        Section(header: Text("Output")) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Aspect ratio") {
                    Picker("", selection: selectedAspectRatio) {
                        ForEach(AspectRatio.allCases.filter { $0 != .free }) { ratio in
                            Text(ratio.displayName).tag(ratio)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 160)
                }

                LabeledContent("Short edge") {
                    Picker("", selection: selectedShortEdge) {
                        ForEach(ShortEdgeResolution.allCases) { resolution in
                            Text(resolution.displayName).tag(resolution)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 160)
                }

                LabeledContent("Resolution") {
                    Text(computedResolution)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Frame rate") {
                    Picker("", selection: Binding(
                        get: { Int(waveformFrameRate.rounded()) },
                        set: { waveformFrameRate = Double($0) }
                    )) {
                        ForEach([15, 24, 25, 30, 50, 60], id: \.self) { rate in
                            Text("\(rate) fps").tag(rate)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 160)
                    .help("Controls waveform animation smoothness. Higher frame rates increase render cost.")
                }
            }
            .padding(8)
        }
    }

    private var rendererSection: some View {
        Section(header: Text("Renderer")) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Engine") {
                    Picker("", selection: selectedRenderingEngine) {
                        ForEach(WaveformRenderingEngine.allCases) { engine in
                            Text(LocalizedStringKey(engine.displayName)).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)
                    .help("Swift renders frequency visualizers natively (capsules, bars, halo, ridgeline and more). FFmpeg uses classic waveform filters.")
                }

                if isSwiftEngine {
                    LabeledContent("Style") {
                        Picker("", selection: selectedSwiftStyle) {
                            ForEach(SwiftWaveformStyle.allCases) { style in
                                Text(LocalizedStringKey(style.displayName)).tag(style)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 200)
                        .help("Choose the visual appearance for the native Swift waveform renderer.")
                    }

                    LabeledContent("Bands") {
                        Picker("", selection: $waveformBandCount) {
                            ForEach([16, 24, 32, 48, 64], id: \.self) { count in
                                Text("\(count)").tag(count)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 160)
                        .help("Number of frequency bands (columns, spokes, or curve points).")
                    }

                    LabeledContent("Distribution") {
                        Picker("", selection: selectedDistribution) {
                            ForEach(FrequencyDistribution.allCases) { dist in
                                Text(LocalizedStringKey(dist.displayName)).tag(dist)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 200)
                        .help("How frequency ranges are mapped to bands. Mel Scale matches human hearing perception.")
                    }

                    LabeledContent("Opacity") {
                        HStack(spacing: 8) {
                            Slider(value: $waveformOpacity, in: 0.5...1.0, step: 0.05)
                            Text("\(Int(waveformOpacity * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        }
                        .help("Controls transparency of the waveform over background images. Lower values let the background show through.")
                    }
                } else {
                    LabeledContent("Style") {
                        Picker("", selection: selectedFFmpegStyle) {
                            ForEach(WaveformStyle.allCases) { style in
                                Text(LocalizedStringKey(style.displayName)).tag(style)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 200)
                        .help("Choose the visual appearance used when rendering waveform videos (FFmpeg engine only).")
                    }
                }
            }
            .padding(8)
        }
    }

    private var colorsSection: some View {
        Section(header: Text("Colors")) {
            VStack(alignment: .leading, spacing: 10) {
                colorRow(title: "Foreground", binding: $waveformForegroundHex)

                if isSwiftEngine {
                    Toggle("Use foreground gradient", isOn: $foregroundGradientEnabled)
                        .toggleStyle(SwitchToggleStyle())
                    if foregroundGradientEnabled {
                        colorRow(title: "Gradient end", binding: $foregroundGradientEndHex)
                    }
                }

                Divider()
                    .padding(.vertical, 2)

                colorRow(title: "Background", binding: $waveformBackgroundHex)

                if isSwiftEngine {
                    Toggle("Use background gradient", isOn: $backgroundGradientEnabled)
                        .toggleStyle(SwitchToggleStyle())
                    if backgroundGradientEnabled {
                        colorRow(title: "Gradient end", binding: $backgroundGradientEndHex)
                    }

                    Toggle("Transparent background", isOn: $transparentBackground)
                        .toggleStyle(SwitchToggleStyle())
                        .help("Exports the waveform with an alpha channel. A per-item background image still fills the frame.")
                    if transparentBackground {
                        Text("Needs an export format with alpha: ProRes 4444 or 4444 XQ, Lossless (FFV1), or an image sequence other than JPEG. Other formats use the background above, or write a matte sidecar if that option is enabled for the preset.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("Colors accept six-digit HEX values (e.g. #1A2B3C).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(8)
        }
    }

    private var resetSection: some View {
        Section {
            HStack {
                Spacer()
                Button(role: .destructive) {
                    resetWaveformDefaults()
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .help("Restore all waveform settings to their default values.")
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func colorRow(title: LocalizedStringKey, binding: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                ColorPicker(selection: Binding(
                    get: { Color(hex: binding.wrappedValue) },
                    set: { binding.wrappedValue = $0.toHexString(includeHash: true) }
                ), supportsOpacity: false) {
                    EmptyView()
                }
                .labelsHidden()
                .frame(width: 36)

                TextField("", text: binding)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                    .onSubmit(sanitizeWaveformColors)
            }
        }
    }

    // MARK: - Helpers

    private func sanitizeWaveformColors() {
        waveformBackgroundHex = "#" + AudioWaveformPreferences.sanitizeHex(waveformBackgroundHex, fallback: "000000")
        waveformForegroundHex = "#" + AudioWaveformPreferences.sanitizeHex(waveformForegroundHex, fallback: "FFFFFF")
        foregroundGradientEndHex = "#" + AudioWaveformPreferences.sanitizeHex(foregroundGradientEndHex, fallback: "FF0000")
        backgroundGradientEndHex = "#" + AudioWaveformPreferences.sanitizeHex(backgroundGradientEndHex, fallback: "333333")
    }

    private func resetWaveformDefaults() {
        waveformVideoDefaultEnabled = true
        waveformAspectRatioRaw = AppConstants.defaultAudioWaveformAspectRatio
        waveformShortEdge = AppConstants.defaultAudioWaveformShortEdge
        waveformBackgroundHex = "#000000"
        waveformForegroundHex = "#FFFFFF"
        waveformNormalizeAudio = false
        waveformStyleRaw = AppConstants.defaultAudioWaveformStyleRaw
        waveformFrameRate = AppConstants.defaultAudioWaveformFrameRate
        waveformRenderingEngineRaw = "swift"
        waveformSwiftStyleRaw = "capsules"
        waveformBandCount = 32
        waveformFrequencyDistributionRaw = "mel"
        foregroundGradientEnabled = false
        foregroundGradientEndHex = "#FF0000"
        backgroundGradientEnabled = false
        backgroundGradientEndHex = "#333333"
        waveformOpacity = 1.0
        transparentBackground = false
    }
}

// MARK: - Style Preview

/// Live, animated preview of the native Swift waveform renderer, driven by a
/// synthetic signal so it works without any audio loaded. Uses the exact same
/// drawing code as export (`NativeWaveformVideoRenderer`).
struct WaveformStylePreview: View {
    let style: SwiftWaveformStyle
    let bandCount: Int
    let aspectRatio: AspectRatio
    let frameRate: Double
    let foregroundHex: String
    let backgroundHex: String
    let foregroundGradientEndHex: String?
    let backgroundGradientEndHex: String?
    let opacity: Double
    var transparentBackground = false

    @State private var isPlaying = true

    /// Short edge of the preview bitmap. Small enough to render every frame on
    /// the main thread, large enough to look crisp in the settings window.
    private static let previewShortEdge = 360
    private static let maxDisplayHeight: CGFloat = 200

    private var pixelSize: (width: Int, height: Int) {
        // computeResolution falls back to 16:9 for the free aspect ratio.
        let (w, h) = AudioWaveformPreferences.computeResolution(aspectRatio: aspectRatio, shortEdge: Self.previewShortEdge)
        return (w, h)
    }

    private var effectiveFrameRate: Double {
        frameRate > 0 ? frameRate : AppConstants.defaultAudioWaveformFrameRate
    }

    var body: some View {
        let size = pixelSize
        let aspect = CGFloat(size.width) / CGFloat(max(1, size.height))
        HStack {
            Spacer(minLength: 0)
            TimelineView(.animation(minimumInterval: 1.0 / effectiveFrameRate, paused: !isPlaying)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    if transparentBackground {
                        CheckerboardBackground()
                    }
                    if let image = renderImage(at: time, width: size.width, height: size.height) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                    } else {
                        Color.black
                    }
                }
                .aspectRatio(aspect, contentMode: .fit)
            }
            .frame(maxHeight: Self.maxDisplayHeight)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            .overlay(alignment: .bottomTrailing) {
                Button {
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.caption)
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .help(isPlaying ? "Pause preview" : "Play preview")
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Waveform style preview")
    }

    private func renderImage(at time: TimeInterval, width: Int, height: Int) -> CGImage? {
        let frame = Self.simulatedFrame(at: time, style: style, bandCount: max(1, bandCount),
                                        frameRate: effectiveFrameRate)
        return NativeWaveformVideoRenderer.renderImage(
            style: style,
            frame: frame,
            width: width,
            height: height,
            foregroundColor: NativeWaveformRenderer.parseHexColor(foregroundHex),
            backgroundColor: NativeWaveformRenderer.parseHexColor(backgroundHex),
            foregroundGradientEnd: foregroundGradientEndHex.map(NativeWaveformRenderer.parseHexColor),
            backgroundGradientEnd: backgroundGradientEndHex.map(NativeWaveformRenderer.parseHexColor),
            waveformOpacity: opacity,
            transparentBackground: transparentBackground
        )
    }

    /// Runs the export animation state (smoothing, peak hold, ridge history)
    /// over just enough synthetic frames to reach `time`. Stateless, so the
    /// preview never drifts and restarts cleanly when settings change.
    static func simulatedFrame(
        at time: TimeInterval, style: SwiftWaveformStyle, bandCount: Int, frameRate: Double
    ) -> WaveformFrameInput {
        let currentFrame = Int((time * frameRate).rounded(.down))
        let warmUp = WaveformAnimationState.warmUpFrames(frameRate: frameRate, style: style)
        var state = WaveformAnimationState(bandCount: bandCount, frameRate: frameRate, style: style,
                                           startFrameIndex: currentFrame - warmUp)
        var input = WaveformFrameInput(magnitudes: [])
        for frame in (currentFrame - warmUp)...currentFrame {
            input = state.advance(raw: syntheticMagnitudes(at: Double(frame) / frameRate, bandCount: bandCount))
        }
        return input
    }

    /// Deterministic music-like band levels: a kick on the beat (bass), an
    /// off-beat hi-hat (treble) and a drifting melody (mids). Each hit has an
    /// instant attack and exponential release, mimicking export smoothing.
    static func syntheticMagnitudes(at time: TimeInterval, bandCount: Int) -> [Float] {
        let beat = 0.5  // 120 BPM
        let kick = exp(-max(0, time.truncatingRemainder(dividingBy: beat)) * 9)
        let hat = exp(-max(0, (time + beat / 2).truncatingRemainder(dividingBy: beat)) * 14)
        let step = floor(time * 12)  // flicker rate for per-band texture

        return (0..<bandCount).map { band in
            let x = bandCount > 1 ? Double(band) / Double(bandCount - 1) : 0.5
            let bassWeight = pow(1 - x, 2)
            let trebleWeight = pow(x, 1.5)
            let midWeight = max(0, 1 - abs(x - 0.45) * 1.8)
            let melody = 0.5 + 0.5 * sin(time * 2.1 + x * 9) * sin(time * 0.7 + x * 3)
            // Cheap hash for stable pseudo-random texture per band and step.
            let noise = abs(sin(Double(band) * 12.9898 + step * 78.233) * 43758.5453)
                .truncatingRemainder(dividingBy: 1)
            let value = 0.08
                + 0.75 * kick * bassWeight
                + 0.5 * hat * trebleWeight
                + 0.45 * melody * midWeight
                + 0.12 * noise
            return Float(min(1, max(0, value)))
        }
    }
}
