// Aagedal Media Converter — Presets Settings Tab

import SwiftUI

struct PresetsSettingsView: View {
    // Refresh token to trigger re-reads from UserDefaults after custom preset edits
    @State private var customPresetRefreshToken = UUID()

    // ProRes profile
    @AppStorage(AppConstants.proResProfileKey) private var proResProfileRawValue = ProResProfile.standard.rawValue

    // Animated Still format
    @AppStorage(AppConstants.animatedStillFormatKey) private var animatedStillFormat = AppConstants.defaultAnimatedStillFormat

    // Image Sequence export settings
    @AppStorage(AppConstants.imageSequenceExportFormatKey) private var imageSequenceExportFormat = AppConstants.defaultImageSequenceExportFormat
    @AppStorage(AppConstants.imageSequenceExportQualityKey) private var imageSequenceExportQuality = AppConstants.defaultImageSequenceExportQuality
    @AppStorage(AppConstants.imageSequenceNumberingPaddingKey) private var imageSequenceNumberingPadding = AppConstants.defaultImageSequenceNumberingPadding

    // Image sequence metadata sidecar
    @AppStorage(AppConstants.imageSequenceMetadataSidecarEnabledKey) private var metadataSidecarEnabled = AppConstants.defaultImageSequenceMetadataSidecarEnabled
    @AppStorage(AppConstants.imageSequenceMetadataSidecarFormatKey) private var metadataSidecarFormat = AppConstants.defaultImageSequenceMetadataSidecarFormat

    // TV preset settings
    @AppStorage(AppConstants.tvFramerateModeKey) private var tvFramerateMode = AppConstants.defaultTVFramerateMode
    @AppStorage(AppConstants.tvResolutionLimitKey) private var tvResolutionLimit = AppConstants.defaultTVResolutionLimit

    // AVC-Intra settings
    @AppStorage(AppConstants.avcIntraClassKey) private var avcIntraClass = AppConstants.defaultAVCIntraClass
    @AppStorage(AppConstants.avcIntraAudioChannelsKey) private var avcIntraAudioChannels = AppConstants.defaultAVCIntraAudioChannels
    @AppStorage(AppConstants.avcIntraDefaultMCASoundfield1ChKey) private var avcIntra1ChMCADefault = ""
    @AppStorage(AppConstants.avcIntraDefaultMCASoundfield2ChKey) private var avcIntra2ChMCADefault = ""
    @AppStorage(AppConstants.avcIntraDefaultMCASoundfield6ChKey) private var avcIntra6ChMCADefault = ""
    @AppStorage(AppConstants.avcIntraDefaultMCASoundfield8ChKey) private var avcIntra8ChMCADefault = ""

    // DCP settings
    @AppStorage(AppConstants.dcpResolutionKey) private var dcpResolution = AppConstants.defaultDCPResolution
    @AppStorage(AppConstants.dcpFrameRateKey) private var dcpFrameRate = AppConstants.defaultDCPFrameRate
    @AppStorage(AppConstants.dcpBitrateKey) private var dcpBitrate = AppConstants.defaultDCPBitrate
    @AppStorage(AppConstants.dcpScalingModeKey) private var dcpScalingMode = AppConstants.defaultDCPScalingMode
    @AppStorage(AppConstants.dcpKeepJP2ImagesKey) private var dcpKeepJP2Images = false
    @AppStorage(AppConstants.imfResolutionKey) private var imfResolution = AppConstants.defaultIMFResolution
    @AppStorage(AppConstants.imfFrameRateKey) private var imfFrameRate = AppConstants.defaultIMFFrameRate
    @AppStorage(AppConstants.imfScalingModeKey) private var imfScalingMode = AppConstants.defaultIMFScalingMode
    @AppStorage(AppConstants.imfJ2KColorEncodingKey) private var imfJ2KColorEncoding = AppConstants.defaultIMFJ2KColorEncoding
    @AppStorage(AppConstants.imfJ2KBitrateKey) private var imfJ2KBitrate = AppConstants.defaultIMFJ2KBitrate
    @AppStorage(AppConstants.imfProResProfileKey) private var imfProResProfile = AppConstants.defaultIMFProResProfile
    @AppStorage(AppConstants.imfKeepIntermediatesKey) private var imfKeepIntermediates = false

    // Stream Copy container
    @AppStorage(AppConstants.streamCopyContainerKey) private var streamCopyContainer = AppConstants.defaultStreamCopyContainer

    // VideoLoop mute default
    @AppStorage(AppConstants.videoLoopDefaultMutedKey) private var videoLoopDefaultMuted = AppConstants.defaultVideoLoopMuted

    // Proxy preset settings
    @AppStorage(AppConstants.proxyCodecKey) private var proxyCodec = AppConstants.defaultProxyCodec
    @AppStorage(AppConstants.proxyResolutionLimitKey) private var proxyResolutionLimit = AppConstants.defaultProxyResolutionLimit

    // H.264 preset settings
    @AppStorage(AppConstants.h264EncoderKey) private var h264Encoder = AppConstants.defaultH264Encoder
    @AppStorage(AppConstants.h264ContainerKey) private var h264Container = AppConstants.defaultH264Container
    @AppStorage(AppConstants.h264QualityKey) private var h264Quality = AppConstants.defaultH264Quality
    @AppStorage(AppConstants.h264SpeedKey) private var h264Speed = AppConstants.defaultH264Speed
    @AppStorage(AppConstants.h264ResolutionLimitKey) private var h264ResolutionLimit = AppConstants.defaultH264ResolutionLimit
    @AppStorage(AppConstants.h264BitrateKey) private var h264Bitrate = AppConstants.defaultH264Bitrate
    @AppStorage(AppConstants.h264AudioFormatKey) private var h264AudioFormat = AppConstants.defaultH264AudioFormat
    @AppStorage(AppConstants.h264AudioBitrateKey) private var h264AudioBitrate = AppConstants.defaultH264AudioBitrate

    // H.265 preset settings
    @AppStorage(AppConstants.h265EncoderKey) private var h265Encoder = AppConstants.defaultH265Encoder
    @AppStorage(AppConstants.h265ContainerKey) private var h265Container = AppConstants.defaultH265Container
    @AppStorage(AppConstants.h265QualityKey) private var h265Quality = AppConstants.defaultH265Quality
    @AppStorage(AppConstants.h265SpeedKey) private var h265Speed = AppConstants.defaultH265Speed
    @AppStorage(AppConstants.h265ResolutionLimitKey) private var h265ResolutionLimit = AppConstants.defaultH265ResolutionLimit
    @AppStorage(AppConstants.h265BitrateKey) private var h265Bitrate = AppConstants.defaultH265Bitrate
    @AppStorage(AppConstants.h265AudioFormatKey) private var h265AudioFormat = AppConstants.defaultH265AudioFormat
    @AppStorage(AppConstants.h265AudioBitrateKey) private var h265AudioBitrate = AppConstants.defaultH265AudioBitrate

    // AV1 preset settings
    @AppStorage(AppConstants.av1ContainerKey) private var av1Container = AppConstants.defaultAV1Container
    @AppStorage(AppConstants.av1QualityKey) private var av1Quality = AppConstants.defaultAV1Quality
    @AppStorage(AppConstants.av1SpeedKey) private var av1Speed = AppConstants.defaultAV1Speed
    @AppStorage(AppConstants.av1ResolutionLimitKey) private var av1ResolutionLimit = AppConstants.defaultAV1ResolutionLimit
    @AppStorage(AppConstants.av1AudioFormatKey) private var av1AudioFormat = AppConstants.defaultAV1AudioFormat
    @AppStorage(AppConstants.av1AudioBitrateKey) private var av1AudioBitrate = AppConstants.defaultAV1AudioBitrate
    @AppStorage(AppConstants.av1TuneKey) private var av1Tune = AppConstants.defaultAV1Tune
    @AppStorage(AppConstants.av1FilmGrainKey) private var av1FilmGrain = AppConstants.defaultAV1FilmGrain
    @AppStorage(AppConstants.av1FilmGrainDenoiseKey) private var av1FilmGrainDenoise = true
    @AppStorage(AppConstants.av1SharpnessKey) private var av1Sharpness = AppConstants.defaultAV1Sharpness
    @AppStorage(AppConstants.av1FastDecodeKey) private var av1FastDecode = false
    @AppStorage(AppConstants.av1VarianceBoostKey) private var av1VarianceBoost = AppConstants.defaultAV1VarianceBoost
    @AppStorage(AppConstants.av1VarianceBoostCurveKey) private var av1VarianceBoostCurve = AppConstants.defaultAV1VarianceBoostCurve

    // AV2 (experimental, avmenc) preset settings
    @AppStorage(AppConstants.av2RateControlModeKey) private var av2RateControlMode = AppConstants.defaultAV2RateControlMode
    @AppStorage(AppConstants.av2QualityKey) private var av2Quality = AppConstants.defaultAV2Quality
    @AppStorage(AppConstants.av2TargetBitrateKey) private var av2TargetBitrate = AppConstants.defaultAV2TargetBitrate
    @AppStorage(AppConstants.av2SpeedKey) private var av2Speed = AppConstants.defaultAV2Speed
    @AppStorage(AppConstants.av2BitDepthKey) private var av2BitDepth = AppConstants.defaultAV2BitDepth
    @AppStorage(AppConstants.av2ResolutionLimitKey) private var av2ResolutionLimit = AppConstants.defaultAV2ResolutionLimit
    @AppStorage(AppConstants.av2ThreadsKey) private var av2Threads = AppConstants.defaultAV2Threads
    @AppStorage(AppConstants.av2TileColumnsKey) private var av2TileColumns = AppConstants.defaultAV2TileColumns
    @AppStorage(AppConstants.av2TileRowsKey) private var av2TileRows = AppConstants.defaultAV2TileRows
    @AppStorage(AppConstants.av2ParallelChunksKey) private var av2ParallelChunks = AppConstants.defaultAV2ParallelChunks
    @AppStorage(AppConstants.av2ContainerKey) private var av2Container = AppConstants.defaultAV2Container
    @AppStorage(AppConstants.av2AudioCodecKey) private var av2AudioCodec = AppConstants.defaultAV2AudioCodec
    @AppStorage(AppConstants.av2AudioBitrateKey) private var av2AudioBitrate = AppConstants.defaultAV2AudioBitrate

    @AppStorage(AppConstants.keepSubtitlesKey) private var keepSubtitles = AppConstants.defaultKeepSubtitles

    // Built-in preset visibility (default to true)
    @AppStorage(AppConstants.videoLoopVisibleKey) private var videoLoopVisible = true
    @AppStorage(AppConstants.videoLoopWithSoundVisibleKey) private var videoLoopWithSoundVisible = true
    @AppStorage(AppConstants.animatedStillVisibleKey) private var animatedStillVisible = true
    @AppStorage(AppConstants.h264VisibleKey) private var h264Visible = true
    @AppStorage(AppConstants.h265VisibleKey) private var h265Visible = true
    @AppStorage(AppConstants.av1VisibleKey) private var av1Visible = true
    @AppStorage(AppConstants.av2VisibleKey) private var av2Visible = true
    @AppStorage(AppConstants.tvHEVCVisibleKey) private var tvHEVCVisible = true
    @AppStorage(AppConstants.tvAVCIntraVisibleKey) private var tvAVCIntraVisible = true
    @AppStorage(AppConstants.proresVisibleKey) private var proresVisible = true
    @AppStorage(AppConstants.proxyVisibleKey) private var proxyVisible = true
    @AppStorage(AppConstants.streamCopyVisibleKey) private var streamCopyVisible = true
    @AppStorage(AppConstants.audioOnlyVisibleKey) private var audioOnlyVisible = true

    // Audio Only preset settings
    @AppStorage(AppConstants.audioOnlyFormatKey) private var audioOnlyFormat = AppConstants.defaultAudioOnlyFormat
    @AppStorage(AppConstants.audioOnlyBitDepthKey) private var audioOnlyBitDepth = AppConstants.defaultAudioOnlyBitDepth
    @AppStorage(AppConstants.audioOnlyAACBitrateKey) private var audioOnlyAACBitrate = AppConstants.defaultAudioOnlyAACBitrate
    @AppStorage(AppConstants.audioOnlyMP4CodecKey) private var audioOnlyMP4Codec = AppConstants.defaultAudioOnlyMP4Codec
    @AppStorage(AppConstants.audioOnlyMP4BitrateKey) private var audioOnlyMP4Bitrate = AppConstants.defaultAudioOnlyMP4Bitrate
    @AppStorage(AppConstants.imageSequenceVisibleKey) private var imageSequenceVisible = true
    @AppStorage(AppConstants.dcpVisibleKey) private var dcpVisible = true
    @AppStorage(AppConstants.imfJ2KVisibleKey) private var imfJ2KVisible = true
    @AppStorage(AppConstants.imfProResVisibleKey) private var imfProResVisible = true

    @AppStorage(AppConstants.defaultPresetKey) private var storedDefaultPresetRawValue = ExportPreset.videoLoop.rawValue

    @State private var selectedPreset: ExportPreset = .videoLoop
    @FocusState private var focusedCustomCommandSlot: Int?
    @State private var previousFocusedCustomCommandSlot: Int?

    var body: some View {
        HSplitView {
            // Left side: Preset list
            presetListView
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 250)

            // Right side: Preset details
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    presetDetailView
                    if selectedPreset.isCustom {
                        customPresetSection
                    }
                }
                .padding()
            }
            .frame(minWidth: 400)
        }
        .onAppear {
            selectedPreset = ExportPreset(rawValue: storedDefaultPresetRawValue) ?? .videoLoop
        }
        .onChange(of: storedDefaultPresetRawValue) { _, newValue in
            selectedPreset = ExportPreset(rawValue: newValue) ?? .videoLoop
        }
        .onChange(of: focusedCustomCommandSlot) { _, newValue in
            if let previous = previousFocusedCustomCommandSlot, previous != newValue {
                finalizeCustomCommand(for: previous)
            }
            previousFocusedCustomCommandSlot = newValue
        }
        .onDisappear {
            if let previous = previousFocusedCustomCommandSlot {
                finalizeCustomCommand(for: previous)
                previousFocusedCustomCommandSlot = nil
            }
        }
    }

    // MARK: - Preset List View

    private var presetListView: some View {
        List(selection: $selectedPreset) {
            Section("Built-in Presets") {
                ForEach(ExportPreset.allCases.filter { !$0.isCustom }) { preset in
                    presetListRow(for: preset)
                        .tag(preset)
                }
            }

            Section("Custom Presets") {
                ForEach(ExportPreset.allCases.filter { $0.isCustom }) { preset in
                    presetListRow(for: preset)
                        .tag(preset)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func presetListRow(for preset: ExportPreset) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(".\(preset.fileExtension)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if preset == defaultPreset {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Preset Detail View

    private var presetDetailView: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header with preset name and default button
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(selectedPreset.displayName)
                            .font(.title2.bold())
                        if selectedPreset.isExperimental {
                            Text("EXPERIMENTAL")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.2))
                                .foregroundColor(.orange)
                                .clipShape(Capsule())
                        }
                    }
                    HStack(spacing: 8) {
                        Text(selectedPreset.fileSuffix)
                        Text(".\(selectedPreset.fileExtension)")
                    }
                    .font(.subheadline)
                    .monospaced()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundColor(.accentColor)
                    .clipShape(Capsule())
                }

                Spacer()

                Button(action: setSelectedPresetAsDefault) {
                    if isSelectedPresetDefault {
                        Label("Default", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.green)
                    } else {
                        Text("Set as Default")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isSelectedPresetDefault)
                .help(isSelectedPresetDefault ? "Current default preset" : "Set this preset as the default for new files")
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .cornerRadius(10)

            // Description
            Text(selectedPreset.description)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.4))
                .cornerRadius(10)

            // Preset-specific settings
            presetSpecificSettings
        }
    }

    @ViewBuilder
    private var presetSpecificSettings: some View {
        if selectedPreset == .prores {
            settingsCard {
                HStack {
                    Text("Format")
                    Spacer()
                    Picker("", selection: $proResProfileRawValue) {
                        ForEach(ProResProfile.allCases) { profile in
                            Text(profile.rawValue).tag(profile.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .labelsHidden()
                    .help("Proxy and LT are lightweight for offline editing. Standard 422 is the most common for post-production. HQ offers higher quality at roughly 50% larger files. 4444 and 4444 XQ add alpha channel support and are suited for compositing and VFX.")
                }
            }
        }

        if selectedPreset == .animatedStill {
            settingsCard {
                HStack {
                    Text("Format")
                    Spacer()
                    Picker("", selection: $animatedStillFormat) {
                        ForEach(AnimatedStillFormat.availableCases) { format in
                            Text(format.rawValue).tag(format.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .labelsHidden()
                    .help("AVIF offers the best compression and quality for animated images. GIF is universally compatible but limited to 256 colors. APNG supports full-color transparency and is widely supported in web browsers.")
                }
            }
        }

        if selectedPreset == .imageSequence {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Format")
                        Spacer()
                        Picker("", selection: $imageSequenceExportFormat) {
                            ForEach(ImageSequenceFormat.allCases) { format in
                                Text(format.rawValue).tag(format.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("PNG is lossless and widely compatible. TIFF and EXR are preferred for VFX pipelines. DPX is standard for film scanning. JPEG and JPEG XL are lossy but produce smaller files. JPEG 2000 is used in DCP workflows.")
                    }

                    if imageSequenceExportFormat == ImageSequenceFormat.jpeg.rawValue {
                        HStack {
                            Text("Quality")
                            Spacer()
                            Picker("", selection: $imageSequenceExportQuality) {
                                Text("Best (1)").tag(1)
                                Text("High (2)").tag(2)
                                Text("Good (5)").tag(5)
                                Text("Medium (10)").tag(10)
                                Text("Low (20)").tag(20)
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                            .help("JPEG quality (lower number = higher quality).")
                        }
                    }

                    HStack {
                        Text("Frame Number Padding")
                        Spacer()
                        Picker("", selection: $imageSequenceNumberingPadding) {
                            Text("4 digits").tag(4)
                            Text("5 digits").tag(5)
                            Text("6 digits").tag(6)
                            Text("8 digits").tag(8)
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Number of digits in frame numbers (e.g., 6 → frame_000001.png).")
                    }
                }
            }
        }

        if selectedPreset == .imageSequence {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $metadataSidecarEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Metadata Sidecar")
                            Text("Include a file with source color space and technical specs")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(SwitchToggleStyle())

                    if metadataSidecarEnabled {
                        HStack {
                            Text("Sidecar Format")
                            Spacer()
                            Picker("", selection: $metadataSidecarFormat) {
                                ForEach(MetadataSidecarGenerator.SidecarFormat.allCases) { format in
                                    Text(format.rawValue).tag(format.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                        }
                    }
                }
            }
        }

        if selectedPreset == .dcp {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Resolution")
                        Spacer()
                        Picker("", selection: $dcpResolution) {
                            ForEach(DCPResolution.allCases) { res in
                                Text(res.shortLabel).tag(res.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("DCI resolution. 2K Flat/Scope are standard theatrical. 4K for premium screens.")
                    }

                    HStack {
                        Text("Frame Rate")
                        Spacer()
                        Picker("", selection: $dcpFrameRate) {
                            ForEach(DCPFrameRate.allCases) { rate in
                                Text(rate.rawValue).tag(rate.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("DCI frame rate. 24 fps is standard for theatrical.")
                    }

                    HStack {
                        Text("Video Bitrate")
                        Spacer()
                        Picker("", selection: $dcpBitrate) {
                            ForEach(DCPBitrate.allCases) { br in
                                Text(br.rawValue).tag(br.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("JPEG 2000 video bitrate. 250 Mbps is the DCI maximum for 2K.")
                    }

                    HStack {
                        Text("Scaling")
                        Spacer()
                        Picker("", selection: $dcpScalingMode) {
                            ForEach(DCPScalingMode.allCases) { mode in
                                Text(mode.displayName).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Fill crops the image to fill the DCP frame. Fit adds black bars to preserve the full image.")
                    }

                    Toggle(isOn: $dcpKeepJP2Images) {
                        Text("Keep JP2 image sequence")
                    }
                    .help("Retain the JPEG 2000 image files in the working folder after DCP creation. Useful for importing as an image sequence.")

                    Text("JPEG 2000 video in MXF with 24-bit PCM audio. XYZ color space (DCI P3).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }

        if selectedPreset == .imfJ2K || selectedPreset == .imfProRes {
            settingsCard {
                Text("IMF export is unavailable in 4.4 because package descriptors and conformance have not been validated. Use another export preset and a validated IMF mastering tool.")
                    .foregroundStyle(.secondary)
            }
        }

        if selectedPreset == .imfJ2K {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Resolution")
                        Spacer()
                        Picker("", selection: $imfResolution) {
                            ForEach(IMFResolution.allCases) { res in
                                Text(res.rawValue).tag(res.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("HD (1920×1080) or UHD (3840×2160). IMF App #2e is commonly delivered at one of these tiers.")
                    }

                    HStack {
                        Text("Frame Rate")
                        Spacer()
                        Picker("", selection: $imfFrameRate) {
                            ForEach(IMFFrameRate.allCases) { rate in
                                Text(rate.rawValue).tag(rate.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("IMF allows a wider range of frame rates than DCP, including drop-frame variants for NTSC delivery.")
                    }

                    HStack {
                        Text("Color")
                        Spacer()
                        Picker("", selection: $imfJ2KColorEncoding) {
                            ForEach(IMFColorEncoding.allCases) { color in
                                Text(color.rawValue).tag(color.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Color encoding for the J2K essence. Use Rec. 709 for HD SDR, Rec. 2020 PQ/HLG for HDR10/HLG.")
                    }

                    HStack {
                        Text("Video Bitrate")
                        Spacer()
                        Picker("", selection: $imfJ2KBitrate) {
                            ForEach(DCPBitrate.allCases) { br in
                                Text(br.rawValue).tag(br.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("JPEG 2000 video bitrate. Higher bitrates yield better quality at the cost of file size.")
                    }

                    HStack {
                        Text("Scaling")
                        Spacer()
                        Picker("", selection: $imfScalingMode) {
                            ForEach(IMFScalingMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Fill crops the source to fill the IMF frame; Fit adds black bars to preserve the full image.")
                    }

                    Toggle(isOn: $imfKeepIntermediates) {
                        Text("Keep intermediate files")
                    }
                    .help("Retain the JP2 image sequence and temp MXF files after the IMP is assembled. Useful for debugging.")

                    Text("JPEG 2000 video in MXF (App #2e). PCM audio with MCA labels. CPL/PKL/ASSETMAP manifests.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }

        if selectedPreset == .imfProRes {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Resolution")
                        Spacer()
                        Picker("", selection: $imfResolution) {
                            ForEach(IMFResolution.allCases) { res in
                                Text(res.rawValue).tag(res.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                    }

                    HStack {
                        Text("Frame Rate")
                        Spacer()
                        Picker("", selection: $imfFrameRate) {
                            ForEach(IMFFrameRate.allCases) { rate in
                                Text(rate.rawValue).tag(rate.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                    }

                    HStack {
                        Text("ProRes Profile")
                        Spacer()
                        Picker("", selection: $imfProResProfile) {
                            ForEach(IMFProResProfile.allCases) { profile in
                                Text(profile.rawValue).tag(profile.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("ST 2067-50 permits 422 HQ, 4444, and 4444 XQ. Lower-quality profiles are not allowed for IMF delivery.")
                    }

                    HStack {
                        Text("Color")
                        Spacer()
                        Picker("", selection: $imfJ2KColorEncoding) {
                            ForEach(IMFColorEncoding.allCases) { color in
                                Text(color.rawValue).tag(color.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                    }

                    HStack {
                        Text("Scaling")
                        Spacer()
                        Picker("", selection: $imfScalingMode) {
                            ForEach(IMFScalingMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                    }

                    Toggle(isOn: $imfKeepIntermediates) {
                        Text("Keep intermediate files")
                    }

                    Text("Apple ProRes video in MXF (App #5). PCM audio with MCA labels. CPL/PKL/ASSETMAP manifests.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }

        if selectedPreset == .audioOnly {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Format")
                        Spacer()
                        Picker("", selection: $audioOnlyFormat) {
                            ForEach(AudioOnlyFormat.allCases) { format in
                                Text(format.rawValue).tag(format.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Select the audio output format. WAV and FLAC support a single audio stream; MP4 and M4A support multiple tracks.")
                    }

                    // WAV: bit depth picker
                    if audioOnlyFormat == AudioOnlyFormat.wav.rawValue {
                        HStack {
                            Text("Bit Depth")
                            Spacer()
                            Picker("", selection: $audioOnlyBitDepth) {
                                ForEach(AudioOnlyBitDepth.allCases) { depth in
                                    Text(depth.rawValue).tag(depth.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                            .fixedSize()
                            .labelsHidden()
                            .help("PCM bit depth. 24-bit is standard for professional audio.")
                        }
                    }

                    // AAC (M4A): bitrate picker
                    if audioOnlyFormat == AudioOnlyFormat.aac.rawValue {
                        HStack {
                            Text("Bitrate")
                            Spacer()
                            Picker("", selection: $audioOnlyAACBitrate) {
                                ForEach(AudioBitrate.allCases) { br in
                                    Text(br.rawValue).tag(br.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                            .help("Higher bitrate = better audio quality and larger files.")
                        }
                    }

                    // MP4: codec picker + conditional bitrate
                    if audioOnlyFormat == AudioOnlyFormat.mp4.rawValue {
                        HStack {
                            Text("Audio Codec")
                            Spacer()
                            Picker("", selection: $audioOnlyMP4Codec) {
                                ForEach(AudioOnlyMP4Codec.allCases) { codec in
                                    Text(codec.rawValue).tag(codec.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                            .help("AAC is widely compatible. PCM is uncompressed lossless.")
                        }

                        if AudioOnlyMP4Codec(rawValue: audioOnlyMP4Codec)?.requiresBitrate == true {
                            HStack {
                                Text("Bitrate")
                                Spacer()
                                Picker("", selection: $audioOnlyMP4Bitrate) {
                                    ForEach(AudioBitrate.allCases) { br in
                                        Text(br.rawValue).tag(br.rawValue)
                                    }
                                }
                                .pickerStyle(.menu)
                                .fixedSize()
                                .labelsHidden()
                                .help("Higher bitrate = better audio quality and larger files.")
                            }
                        }
                    }
                }
            }
        }

        if selectedPreset == .h264 {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Encoder")
                        Spacer()
                        Picker("", selection: $h264Encoder) {
                            ForEach(H264Encoder.allCases) { encoder in
                                Text(encoder.rawValue).tag(encoder.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .labelsHidden()
                        .help("Hardware uses VideoToolbox for fast encoding. Software (libx264) offers better compression with CRF quality control.")
                    }

                    if H264Encoder(rawValue: h264Encoder) == .software {
                        HStack {
                            Text("Quality (CRF)")
                            Spacer()
                            Picker("", selection: $h264Quality) {
                                ForEach(CodecQualityLevel.allCases) { quality in
                                    Text(quality.rawValue).tag(quality.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                            .help("Lower CRF values = higher quality and larger files. 23 is a good default for H.264.")
                        }

                        HStack {
                            Text("Encoding Speed")
                            Spacer()
                            Picker("", selection: $h264Speed) {
                                ForEach(EncodingSpeed.allCases) { speed in
                                    Text(speed.rawValue).tag(speed.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                            .help("Slower presets produce better quality at the same file size.")
                        }
                    } else {
                        HStack {
                            Text("Bitrate")
                            Spacer()
                            TextField("10M", text: $h264Bitrate)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .help("Target bitrate (e.g., 10M, 5000k)")
                        }
                    }

                    HStack {
                        Text("Container")
                        Spacer()
                        Picker("", selection: $h264Container) {
                            ForEach(CodecContainer.allCases) { container in
                                Text(container.rawValue).tag(container.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .labelsHidden()
                        .help("MP4 is most compatible. MOV is native to Apple. MKV supports all features but has less compatibility.")
                        .onChange(of: h264Container) { _, newValue in
                            // Reset audio format to AAC if Opus is selected but container doesn't support it
                            if h264AudioFormat == CodecAudioFormat.opus.rawValue && newValue != CodecContainer.mkv.rawValue {
                                h264AudioFormat = CodecAudioFormat.aac.rawValue
                            }
                        }
                    }

                    HStack {
                        Text("Resolution Limit")
                        Spacer()
                        Picker("", selection: $h264ResolutionLimit) {
                            ForEach(CodecResolutionLimit.allCases) { res in
                                Text(res.rawValue).tag(res.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Limit the output resolution. Unlimited preserves source resolution.")
                    }

                    Divider()

                    HStack {
                        Text("Audio Codec")
                        Spacer()
                        Picker("", selection: $h264AudioFormat) {
                            ForEach(CodecAudioFormat.availableCases(for: CodecContainer(rawValue: h264Container) ?? .mp4)) { format in
                                Text(format.rawValue).tag(format.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("AAC is widely compatible. PCM is uncompressed. Opus requires MKV container.")
                    }

                    if CodecAudioFormat(rawValue: h264AudioFormat)?.requiresBitrate == true {
                        HStack {
                            Text("Audio Bitrate")
                            Spacer()
                            Picker("", selection: $h264AudioBitrate) {
                                ForEach(AudioBitrate.allCases) { bitrate in
                                    Text(bitrate.rawValue).tag(bitrate.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                            .help("Higher bitrate = better audio quality and larger files.")
                        }
                    }
                }
            }
        }

        if selectedPreset == .h265 {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Encoder")
                        Spacer()
                        Picker("", selection: $h265Encoder) {
                            ForEach(H265Encoder.allCases) { encoder in
                                Text(encoder.rawValue).tag(encoder.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .labelsHidden()
                        .help("Hardware uses VideoToolbox for fast encoding. Software (libx265) offers better compression with CRF quality control.")
                    }

                    if H265Encoder(rawValue: h265Encoder) == .software {
                        HStack {
                            Text("Quality (CRF)")
                            Spacer()
                            Picker("", selection: $h265Quality) {
                                ForEach(CodecQualityLevel.allCases) { quality in
                                    Text(quality.rawValue).tag(quality.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                            .help("Lower CRF values = higher quality and larger files. 28 is a good default for H.265.")
                        }

                        HStack {
                            Text("Encoding Speed")
                            Spacer()
                            Picker("", selection: $h265Speed) {
                                ForEach(EncodingSpeed.allCases) { speed in
                                    Text(speed.rawValue).tag(speed.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                            .help("Slower presets produce better quality at the same file size.")
                        }
                    } else {
                        HStack {
                            Text("Bitrate")
                            Spacer()
                            TextField("8M", text: $h265Bitrate)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .help("Target bitrate (e.g., 8M, 5000k)")
                        }
                    }

                    HStack {
                        Text("Container")
                        Spacer()
                        Picker("", selection: $h265Container) {
                            ForEach(CodecContainer.allCases) { container in
                                Text(container.rawValue).tag(container.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .labelsHidden()
                        .help("MP4 is most compatible. MOV is native to Apple. MKV supports all features but has less compatibility.")
                        .onChange(of: h265Container) { _, newValue in
                            // Reset audio format to AAC if Opus is selected but container doesn't support it
                            if h265AudioFormat == CodecAudioFormat.opus.rawValue && newValue != CodecContainer.mkv.rawValue {
                                h265AudioFormat = CodecAudioFormat.aac.rawValue
                            }
                        }
                    }

                    HStack {
                        Text("Resolution Limit")
                        Spacer()
                        Picker("", selection: $h265ResolutionLimit) {
                            ForEach(CodecResolutionLimit.allCases) { res in
                                Text(res.rawValue).tag(res.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Limit the output resolution. Unlimited preserves source resolution.")
                    }

                    Divider()

                    HStack {
                        Text("Audio Codec")
                        Spacer()
                        Picker("", selection: $h265AudioFormat) {
                            ForEach(CodecAudioFormat.availableCases(for: CodecContainer(rawValue: h265Container) ?? .mp4)) { format in
                                Text(format.rawValue).tag(format.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("AAC is widely compatible. PCM is uncompressed. Opus requires MKV container.")
                    }

                    if CodecAudioFormat(rawValue: h265AudioFormat)?.requiresBitrate == true {
                        HStack {
                            Text("Audio Bitrate")
                            Spacer()
                            Picker("", selection: $h265AudioBitrate) {
                                ForEach(AudioBitrate.allCases) { bitrate in
                                    Text(bitrate.rawValue).tag(bitrate.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                            .help("Higher bitrate = better audio quality and larger files.")
                        }
                    }
                }
            }
        }

        if selectedPreset == .av1 {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                        Text("AV1 encoding uses SVT-AV1 (software). No hardware acceleration available.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(6)

                    HStack {
                        Text("Quality (CRF)")
                        Spacer()
                        Picker("", selection: $av1Quality) {
                            ForEach(AV1QualityLevel.allCases) { quality in
                                Text(quality.rawValue).tag(quality.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("CRF (Constant Rate Factor) controls the quality-to-size tradeoff. Lower values produce higher quality and larger files. 30 is the SVT-AV1 default and works well for most content. Use 23 or lower for high-quality archival, or 35+ for smaller files where some quality loss is acceptable.")
                    }

                    HStack {
                        Text("Encoding Speed (Preset)")
                        Spacer()
                        Picker("", selection: $av1Speed) {
                            ForEach(AV1EncodingSpeed.allCases) { speed in
                                Text(speed.displayName).tag(speed.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Controls the time spent optimizing each frame. Lower values (slower) produce better quality and smaller files at the same CRF, but take significantly longer to encode. Preset 6 offers a good balance. Presets 0\u{2013}4 are best reserved for final encodes where encoding time is not a concern.")
                    }

                    HStack {
                        Text("Tune")
                        Spacer()
                        Picker("", selection: $av1Tune) {
                            ForEach(AV1TuneMode.allCases) { tune in
                                Text(tune.displayName).tag(tune.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Optimizes the encoder for a specific quality goal. Default (VQ) uses the encoder\u{2019}s standard visual quality heuristics and works well for most content. Subjective Quality goes further by applying psychovisual optimizations that prioritize how the video looks to the human eye \u{2014} it may produce slightly lower objective scores but often looks better in practice, and it uses its own Sharpness and Variance Boost values. SSIM and PSNR optimize purely for their respective objective metrics.")
                    }

                    HStack {
                        Text("Film Grain Synthesis")
                        Spacer()
                        Picker("", selection: $av1FilmGrain) {
                            ForEach(AV1FilmGrainLevel.allCases) { level in
                                Text(level.rawValue).tag(level.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Removes film grain from the source before encoding, then embeds instructions for the decoder to recreate similar grain during playback. This dramatically improves compression of grainy footage since the encoder no longer wastes bits on random noise. Choose a level that matches your source material\u{2019}s grain intensity.")
                    }

                    if AV1FilmGrainLevel(rawValue: av1FilmGrain)?.value ?? 0 > 0 {
                        Toggle("Film Grain Denoise", isOn: $av1FilmGrainDenoise)
                            .help("When enabled (recommended), the encoder removes existing grain before compressing and recreates it during playback \u{2014} producing smaller files with no visible quality loss. When disabled, the original grain is kept in the encoded bitstream and additional synthesized grain is layered on top, which can look heavier than the original.")
                    }

                    if av1Tune != AV1TuneMode.subjective.rawValue {
                        HStack {
                            Text("Sharpness")
                            Spacer()
                            Picker("", selection: $av1Sharpness) {
                                ForEach(AV1Sharpness.allCases) { level in
                                    Text(level.rawValue).tag(level.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                            .help("Applies adaptive sharpening to counteract the softening that can occur during compression. Higher values increase edge definition and perceived detail. Start with 1\u{2013}2 for subtle enhancement. Avoid high values on already-sharp or noisy content, as it may introduce ringing artifacts.")
                        }

                        HStack {
                            Text("Variance Boost")
                            Spacer()
                            Picker("", selection: $av1VarianceBoost) {
                                ForEach(AV1VarianceBoost.allCases) { level in
                                    Text(level.rawValue).tag(level.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                            .help("Allocates more bits to areas with high detail and texture (like foliage, fabric, or skin), preserving fine detail that would otherwise be smoothed out. Improves visual quality in complex scenes at the cost of slightly larger files. Recommended for detailed or textured content.")
                        }

                        if AV1VarianceBoost(rawValue: av1VarianceBoost)?.value ?? 0 > 0 {
                            HStack {
                                Text("Variance Boost Curve")
                                Spacer()
                                Picker("", selection: $av1VarianceBoostCurve) {
                                    ForEach(AV1VarianceBoostCurve.allCases) { curve in
                                        Text(curve.rawValue).tag(curve.rawValue)
                                    }
                                }
                                .pickerStyle(.menu)
                                .fixedSize()
                                .labelsHidden()
                                .help("Controls how the extra bits from Variance Boost are distributed. Linear applies a uniform boost proportional to detail complexity. Moderate concentrates more of the boost on medium-to-high complexity areas. Aggressive focuses the boost heavily on the most complex areas, which is effective for highly detailed content.")
                            }
                        }
                    }

                    Toggle("Fast Decode", isOn: $av1FastDecode)
                        .help("Limits encoding tools to produce output that is easier for decoders to process. Improves playback compatibility on older or less powerful devices (like set-top boxes and mobile phones) at the cost of slightly reduced compression efficiency. Recommended for content targeting a wide range of playback devices.")

                    HStack {
                        Text("Container")
                        Spacer()
                        Picker("", selection: $av1Container) {
                            ForEach(CodecContainer.allCases) { container in
                                Text(container.rawValue).tag(container.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .labelsHidden()
                        .help("MP4 is the most widely compatible container for web and device playback. MOV is native to Apple workflows. MKV supports all AV1 features and codec combinations including Opus audio, but has more limited playback support.")
                        .onChange(of: av1Container) { _, newValue in
                            // Reset audio format to AAC if Opus is selected but container doesn't support it
                            if av1AudioFormat == CodecAudioFormat.opus.rawValue && newValue != CodecContainer.mkv.rawValue {
                                av1AudioFormat = CodecAudioFormat.aac.rawValue
                            }
                        }
                    }

                    HStack {
                        Text("Resolution Limit")
                        Spacer()
                        Picker("", selection: $av1ResolutionLimit) {
                            ForEach(CodecResolutionLimit.allCases) { res in
                                Text(res.rawValue).tag(res.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Limit the output resolution. Unlimited preserves source resolution.")
                    }

                    Divider()

                    HStack {
                        Text("Audio Codec")
                        Spacer()
                        Picker("", selection: $av1AudioFormat) {
                            ForEach(CodecAudioFormat.availableCases(for: CodecContainer(rawValue: av1Container) ?? .mp4)) { format in
                                Text(format.rawValue).tag(format.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("AAC is widely compatible. PCM is uncompressed. Opus requires MKV container.")
                    }

                    if CodecAudioFormat(rawValue: av1AudioFormat)?.requiresBitrate == true {
                        HStack {
                            Text("Audio Bitrate")
                            Spacer()
                            Picker("", selection: $av1AudioBitrate) {
                                ForEach(AudioBitrate.allCases) { bitrate in
                                    Text(bitrate.rawValue).tag(bitrate.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                            .help("Higher bitrate = better audio quality and larger files.")
                        }
                    }
                }
            }
        }

        if selectedPreset == .av2 {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Experimental. AV2 is encoded by the bundled avmenc (AOM AVM) encoder. The app can split the encode across all CPU cores for a large speed-up, and optionally mux the result with audio into a Matroska (.mkv) file. AV2 is very new — the output needs an AV2-capable decoder to play and cannot be previewed inside this app yet.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(6)

                    HStack {
                        Text("Container")
                        Spacer()
                        Picker("", selection: $av2Container) {
                            ForEach(AV2Container.allCases) { container in
                                Text(container.rawValue).tag(container.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("IVF is the raw, video-only AV2 bitstream. Matroska (.mkv) wraps the AV2 video with a re-encoded audio track using the app's built-in muxer (FFmpeg can't write AV2 yet). mp4 isn't offered because there's no standard way to store AV2 in it.")
                    }

                    if av2Container == AV2Container.mkv.rawValue {
                        HStack {
                            Text("Audio")
                            Spacer()
                            Picker("", selection: $av2AudioCodec) {
                                ForEach(AV2AudioCodec.allCases) { codec in
                                    Text(codec.rawValue).tag(codec.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                            Picker("", selection: $av2AudioBitrate) {
                                ForEach(AudioBitrate.allCases) { rate in
                                    Text(rate.rawValue).tag(rate.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            .labelsHidden()
                        }
                        .help("The source audio is re-encoded to this codec and muxed into the .mkv. Sources without audio produce a video-only .mkv.")
                    }

                    HStack {
                        Text("Rate Control")
                        Spacer()
                        Picker("", selection: $av2RateControlMode) {
                            ForEach(AV2RateControlMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Constant Quality targets a fixed visual quality (avmenc --qp). Target Bitrate aims for a specific average bitrate (avmenc VBR mode).")
                    }

                    if av2RateControlMode == AV2RateControlMode.constantQuality.rawValue {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Quality (QP)")
                                Spacer()
                                Text("\(av2Quality)")
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(av2Quality) },
                                    set: { av2Quality = Int($0.rounded()) }
                                ),
                                in: 0...255,
                                step: 1
                            )
                            .help("avmenc --qp. Lower values mean higher quality and larger files (0 = best, 255 = smallest). Around 100–130 is a reasonable starting point for visually good quality.")
                            HStack {
                                Text("Best quality").font(.caption2).foregroundColor(.secondary)
                                Spacer()
                                Text("Smallest file").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    } else {
                        HStack {
                            Text("Target Bitrate")
                            Spacer()
                            TextField("", value: $av2TargetBitrate, format: .number)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.roundedBorder)
                            Text("kbps").foregroundColor(.secondary)
                        }
                        .help("avmenc --target-bitrate in kilobits per second. The encoder aims for this average bitrate across the clip.")
                    }

                    HStack {
                        Text("Encoding Speed")
                        Spacer()
                        Picker("", selection: $av2Speed) {
                            ForEach(AV2EncodingSpeed.allCases) { speed in
                                Text(speed.displayName).tag(speed.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("avmenc --cpu-used. Lower values encode slower but produce better quality at the same setting. AV2 reference encoding is very slow — higher values are useful for quick tests.")
                    }

                    HStack {
                        Text("Bit Depth")
                        Spacer()
                        Picker("", selection: $av2BitDepth) {
                            ForEach(AV2BitDepthOption.allCases) { depth in
                                Text(depth.rawValue).tag(depth.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Auto matches the source (10-bit sources encode as 10-bit, otherwise 8-bit). Force 8-bit or 10-bit if you need a specific depth.")
                    }

                    HStack {
                        Text("Resolution Limit")
                        Spacer()
                        Picker("", selection: $av2ResolutionLimit) {
                            ForEach(CodecResolutionLimit.allCases) { limit in
                                Text(limit.rawValue).tag(limit.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Caps the short edge of the output, scaling down larger sources while preserving aspect ratio.")
                    }

                    DisclosureGroup("Advanced") {
                        VStack(alignment: .leading, spacing: 10) {
                            Stepper("Parallel Chunks: \(av2ParallelChunks == 0 ? "Auto" : (av2ParallelChunks == 1 ? "Off (single process)" : "\(av2ParallelChunks)"))", value: $av2ParallelChunks, in: 0...64)
                                .help("Splits the clip into independent ranges and encodes them simultaneously, one avmenc per CPU core — the biggest speed-up for AV2. 0 = Auto (one chunk per core). 1 = off (a single encoder using tiles). Higher values force a specific chunk count. Constant-Quality only; tiling below is disabled while chunking is active because chunks already use every core (and untiled chunks compress slightly better).")
                            Divider()
                            Stepper("Threads: \(av2Threads == 0 ? "Auto" : "\(av2Threads)")", value: $av2Threads, in: 0...64)
                                .help("avmenc -t for the single-process path. 0 lets the app use all available cores.")
                            Stepper("Tile Columns (log2): \(av2TileColumns == 0 ? "Auto" : "\(av2TileColumns)")", value: $av2TileColumns, in: 0...6)
                                .help("avmenc --tile-columns (log2: 1 = 2 columns, 2 = 4, …) for the single-process path. 0 = Auto, which picks a tile count from the resolution. Ignored when Parallel Chunks is active.")
                            Stepper("Tile Rows (log2): \(av2TileRows == 0 ? "Auto" : "\(av2TileRows)")", value: $av2TileRows, in: 0...6)
                                .help("avmenc --tile-rows (log2) for the single-process path. 0 = Auto (chosen from the frame height). Ignored when Parallel Chunks is active.")
                        }
                        .padding(.top, 6)
                    }
                }
            }
        }

        if selectedPreset == .tvHEVC {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Framerate")
                        Spacer()
                        Picker("", selection: $tvFramerateMode) {
                            ForEach(TVFramerateMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Source keeps original framerate. Interlaced modes (50i, 59.94i) apply field-based encoding.")
                    }
                    HStack {
                        Text("Resolution Limit")
                        Spacer()
                        Picker("", selection: $tvResolutionLimit) {
                            ForEach(TVResolutionLimit.allCases) { res in
                                Text(res.rawValue).tag(res.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Limit output resolution. Bitrate scales automatically with resolution.")
                    }
                }
            }
        }

        if selectedPreset == .tvAVCIntra {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("AVC-Intra Class")
                        Spacer()
                        Picker("", selection: $avcIntraClass) {
                            ForEach(AVCIntraClass.allCases) { avcClass in
                                Text(avcClass.rawValue).tag(avcClass.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("AVC-Intra 50 uses the least bandwidth and is suited for SD/720p. AVC-Intra 100 is the standard for 1080i/1080p broadcast delivery. AVC-Intra 200 provides the highest quality with full 10-bit 4:2:2 at higher bitrates.")
                    }
                    HStack {
                        Text("Audio Channels")
                        Spacer()
                        Picker("", selection: $avcIntraAudioChannels) {
                            ForEach(AVCIntraAudioChannels.allCases) { channels in
                                Text(channels.rawValue).tag(channels.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Number of mono audio channels in output. Source audio is mapped to first two channels.")
                    }
                    HStack {
                        Text("Framerate")
                        Spacer()
                        Picker("", selection: $tvFramerateMode) {
                            ForEach(TVFramerateMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Source keeps original framerate. Interlaced modes (50i, 59.94i) apply field-based encoding.")
                    }
                    HStack {
                        Text("Resolution Limit")
                        Spacer()
                        Picker("", selection: $tvResolutionLimit) {
                            ForEach(TVResolutionLimit.allCases) { res in
                                Text(res.rawValue).tag(res.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                        .help("Limit output resolution. Bitrate scales automatically with resolution.")
                    }

                    Divider()
                    Text("Default MCA Labels")
                        .font(.subheadline.bold())
                    Text("Used when the source has no MCA labels and no per-track override is set. Choose 'None' to leave the audio essence unlabelled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("1-channel default")
                        Spacer()
                        Picker("", selection: $avcIntra1ChMCADefault) {
                            Text("None").tag("")
                            Text(MCAStandardSoundfield.mono.displayName).tag(MCAStandardSoundfield.mono.rawValue)
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                    }
                    HStack {
                        Text("2-channel default")
                        Spacer()
                        Picker("", selection: $avcIntra2ChMCADefault) {
                            Text("None").tag("")
                            Text(MCAStandardSoundfield.stereo.displayName).tag(MCAStandardSoundfield.stereo.rawValue)
                            Text(MCAStandardSoundfield.dualMono.displayName).tag(MCAStandardSoundfield.dualMono.rawValue)
                            Text(MCAStandardSoundfield.ltRt.displayName).tag(MCAStandardSoundfield.ltRt.rawValue)
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                    }
                    HStack {
                        Text("6-channel default")
                        Spacer()
                        Picker("", selection: $avcIntra6ChMCADefault) {
                            Text("None").tag("")
                            Text(MCAStandardSoundfield.surround51.displayName).tag(MCAStandardSoundfield.surround51.rawValue)
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                    }
                    HStack {
                        Text("8-channel default")
                        Spacer()
                        Picker("", selection: $avcIntra8ChMCADefault) {
                            Text("None").tag("")
                            Text(MCAStandardSoundfield.surround71.displayName).tag(MCAStandardSoundfield.surround71.rawValue)
                        }
                        .pickerStyle(.menu)
                        .fixedSize()
                        .labelsHidden()
                    }
                }
            }
        }

        if selectedPreset == .streamCopy {
            settingsCard {
                HStack {
                    Text("Container")
                    Spacer()
                    Picker("", selection: $streamCopyContainer) {
                        ForEach(StreamCopyContainer.allCases) { container in
                            Text(container.rawValue).tag(container.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .labelsHidden()
                    .help("Choose output container format, or keep the source format.")
                }
            }
        }

        if selectedPreset == .proxy {
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Codec")
                        Spacer()
                        Picker("", selection: $proxyCodec) {
                            ForEach(ProxyCodec.allCases) { codec in
                                Text(codec.rawValue).tag(codec.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .labelsHidden()
                        .help("Select the codec for proxy files. HEVC is most efficient, ProRes Proxy is widely compatible, DNx is for Avid workflows.")
                    }
                    HStack {
                        Text("Resolution Limit")
                        Spacer()
                        Picker("", selection: $proxyResolutionLimit) {
                            ForEach(ProxyResolutionLimit.allCases) { res in
                                Text(res.rawValue).tag(res.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        .labelsHidden()
                        .help("Limit proxy resolution. Lower resolutions create smaller files for faster editing.")
                    }
                }
            }
        }

        if selectedPreset == .videoLoop {
            settingsCard {
                Toggle(isOn: $videoLoopDefaultMuted) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mute audio by default")
                            .font(.subheadline)
                        Text("When enabled, new files will be muted automatically when VideoLoop is selected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(SwitchToggleStyle())
            }
        }

        // Subtitle preservation toggle — shown for encoding presets that output video into containers
        if selectedPreset.outputsVideoTrack
            && selectedPreset != .streamCopy
            && selectedPreset != .imageSequence
            && selectedPreset != .dcp
            && selectedPreset != .videoLoop
            && selectedPreset != .videoLoopWithSound
            && selectedPreset != .animatedStill {
            settingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $keepSubtitles) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Keep Subtitles")
                                .font(.subheadline)
                            Text("Copy subtitle streams from the source file into the output")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(SwitchToggleStyle())

                    if keepSubtitles {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                                .font(.caption)
                            Text("Subtitles may be out of sync when trimming. Bitmap subtitles (PGS, DVB) are not supported in MP4/MOV — use MKV instead.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .background(Color.yellow.opacity(0.1))
                        .cornerRadius(6)
                    }
                }
            }
        }

        // Visibility toggle for built-in presets
        if !selectedPreset.isCustom {
            settingsCard {
                Toggle(isOn: visibilityBinding(for: selectedPreset)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show in preset picker")
                            .font(.subheadline)
                        Text(isSelectedPresetDefault
                             ? "The default preset cannot be hidden"
                             : "When disabled, this preset will be hidden from the preset picker")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(SwitchToggleStyle())
                .disabled(isSelectedPresetDefault)
            }
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
            .cornerRadius(10)
    }

    @ViewBuilder
    private var customPresetSection: some View {
        let slot = selectedPreset.customSlotIndex ?? 0
        VStack(alignment: .leading, spacing: 16) {
            // Section header
            Text("Custom Preset Configuration")
                .font(.headline)
                .padding(.top, 8)

            // Activation toggle for all custom presets
            settingsCard {
                Toggle(isOn: Binding(
                    get: { isCustomPresetActiveBinding(for: slot) },
                    set: { setCustomPresetActive($0, slot: slot) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Activate Preset")
                            .font(.subheadline)
                        Text(isSelectedPresetDefault
                             ? "The default preset cannot be deactivated"
                             : "When disabled, this preset will be hidden from the preset picker")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(SwitchToggleStyle())
                .disabled(isSelectedPresetDefault)
            }

            presetNameField(for: slot)

            VStack(alignment: .leading, spacing: 12) {
                Text("Specify the arguments passed to ffmpeg (without including the `ffmpeg` command itself).")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextEditor(text: Binding(
                    get: { customCommand(for: slot) },
                    set: { updateCustomCommand($0, slot: slot) }
                ))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 80)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .focused($focusedCustomCommandSlot, equals: slot)
            }

            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Feature Support")
                        .font(.subheadline.weight(.semibold))

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { applyCrop(for: slot) },
                            set: { updateApplyCrop($0, slot: slot) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apply crop configuration")
                                    .font(.subheadline)
                                Text("When enabled, crop settings will be applied to files using this preset")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(SwitchToggleStyle())

                        Toggle(isOn: Binding(
                            get: { applyAudioRouting(for: slot) },
                            set: { updateApplyAudioRouting($0, slot: slot) }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apply audio routing configuration")
                                    .font(.subheadline)
                                Text("When enabled, audio track routing will be applied to files using this preset")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(SwitchToggleStyle())
                    }
                }
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Output file suffix")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    TextField("_c\(slot + 1)", text: Binding(
                        get: { customSuffix(for: slot) },
                        set: { updateCustomSuffix($0, slot: slot) }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Output extension")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    TextField("mp4", text: Binding(
                        get: { customExtension(for: slot) },
                        set: { updateCustomExtension($0, slot: slot) }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }

            Text("Example: `-c:v libx264 -crf 18 -preset slow -c:a copy` produces `filename\(customSuffix(for: slot)).\(customExtension(for: slot))`.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Helpers (scoped to Presets tab)

    private var defaultPreset: ExportPreset {
        ExportPreset(rawValue: storedDefaultPresetRawValue) ?? .videoLoop
    }

    private var isSelectedPresetDefault: Bool {
        selectedPreset == defaultPreset
    }

    private func setSelectedPresetAsDefault() {
        // Ensure the preset is visible/active before setting as default
        if let slot = selectedPreset.customSlotIndex {
            // Custom preset: activate it
            setCustomPresetActive(true, slot: slot)
        } else {
            // Built-in preset: make it visible
            visibilityBinding(for: selectedPreset).wrappedValue = true
        }
        storedDefaultPresetRawValue = selectedPreset.rawValue
    }

    private func customCommand(for slot: Int) -> String {
        _ = customPresetRefreshToken
        return UserDefaults.standard.string(forKey: AppConstants.customPresetCommandKey(for: slot))
            ?? (AppConstants.defaultCustomPresetCommands.indices.contains(slot) ? AppConstants.defaultCustomPresetCommands[slot] : "-c copy")
    }

    private func customSuffix(for slot: Int) -> String {
        _ = customPresetRefreshToken
        return UserDefaults.standard.string(forKey: AppConstants.customPresetSuffixKey(for: slot))
            ?? (AppConstants.defaultCustomPresetSuffixes.indices.contains(slot) ? AppConstants.defaultCustomPresetSuffixes[slot] : "_c\(slot + 1)")
    }

    private func customExtension(for slot: Int) -> String {
        _ = customPresetRefreshToken
        return UserDefaults.standard.string(forKey: AppConstants.customPresetExtensionKey(for: slot))
            ?? (AppConstants.defaultCustomPresetExtensions.indices.contains(slot) ? AppConstants.defaultCustomPresetExtensions[slot] : "mp4")
    }

    private func applyCrop(for slot: Int) -> Bool {
        _ = customPresetRefreshToken
        return UserDefaults.standard.bool(forKey: AppConstants.customPresetApplyCropKey(for: slot))
    }

    private func applyAudioRouting(for slot: Int) -> Bool {
        _ = customPresetRefreshToken
        return UserDefaults.standard.bool(forKey: AppConstants.customPresetApplyAudioRoutingKey(for: slot))
    }

    private func updateApplyCrop(_ value: Bool, slot: Int) {
        UserDefaults.standard.set(value, forKey: AppConstants.customPresetApplyCropKey(for: slot))
        customPresetRefreshToken = UUID()
    }

    private func updateApplyAudioRouting(_ value: Bool, slot: Int) {
        UserDefaults.standard.set(value, forKey: AppConstants.customPresetApplyAudioRoutingKey(for: slot))
        customPresetRefreshToken = UUID()
    }

    private func isCustomPresetActiveBinding(for slot: Int) -> Bool {
        _ = customPresetRefreshToken
        return UserDefaults.standard.bool(forKey: AppConstants.customPresetActiveKey(for: slot))
    }

    private func setCustomPresetActive(_ value: Bool, slot: Int) {
        UserDefaults.standard.set(value, forKey: AppConstants.customPresetActiveKey(for: slot))
        customPresetRefreshToken = UUID()
    }

    private func visibilityBinding(for preset: ExportPreset) -> Binding<Bool> {
        switch preset {
        case .videoLoop:
            return $videoLoopVisible
        case .videoLoopWithSound:
            return $videoLoopWithSoundVisible
        case .animatedStill:
            return $animatedStillVisible
        case .h264:
            return $h264Visible
        case .h265:
            return $h265Visible
        case .av1:
            return $av1Visible
        case .tvHEVC:
            return $tvHEVCVisible
        case .tvAVCIntra:
            return $tvAVCIntraVisible
        case .prores:
            return $proresVisible
        case .proxy:
            return $proxyVisible
        case .streamCopy:
            return $streamCopyVisible
        case .audioOnly:
            return $audioOnlyVisible
        case .imageSequence:
            return $imageSequenceVisible
        case .dcp:
            return $dcpVisible
        case .imfJ2K:
            return $imfJ2KVisible
        case .imfProRes:
            return $imfProResVisible
        default:
            // Custom presets use activation, not visibility
            return .constant(true)
        }
    }

    private func customNamePrefix(for slot: Int) -> String {
        let prefixes = AppConstants.customPresetPrefixes
        return prefixes.indices.contains(slot) ? prefixes[slot] : "C\(slot + 1):"
    }

    private func customNameSuffix(for slot: Int) -> String {
        _ = customPresetRefreshToken
        let fallback = AppConstants.defaultCustomPresetNameSuffixes.indices.contains(slot)
            ? AppConstants.defaultCustomPresetNameSuffixes[slot]
            : "Custom Preset"
        let prefix = customNamePrefix(for: slot)
        let stored = UserDefaults.standard.string(forKey: AppConstants.customPresetNameKey(for: slot)) ?? fallback
        let sanitized = sanitizeCustomNameSuffix(stored, prefix: prefix, fallback: fallback)
        if sanitized != stored {
            updateStoredNameSuffix(sanitized, slot: slot)
        }
        return sanitized
    }

    private func customDisplayName(for slot: Int) -> String {
        "\(customNamePrefix(for: slot)) \(customNameSuffix(for: slot))"
    }

    private func updateCustomCommand(_ value: String, slot: Int) {
        let defaults = AppConstants.defaultCustomPresetCommands
        let fallback = defaults.indices.contains(slot) ? defaults[slot] : "-c copy"
        let sanitized = sanitizeCustomCommand(value, fallback: fallback)
        UserDefaults.standard.set(sanitized, forKey: AppConstants.customPresetCommandKey(for: slot))
        customPresetRefreshToken = UUID()
    }

    private func updateCustomSuffix(_ value: String, slot: Int) {
        let defaults = AppConstants.defaultCustomPresetSuffixes
        let fallback = defaults.indices.contains(slot) ? defaults[slot] : "_c\(slot + 1)"
        let sanitized = sanitizeCustomSuffix(value, fallback: fallback)
        UserDefaults.standard.set(sanitized, forKey: AppConstants.customPresetSuffixKey(for: slot))
        customPresetRefreshToken = UUID()
    }

    private func updateCustomExtension(_ value: String, slot: Int) {
        let defaults = AppConstants.defaultCustomPresetExtensions
        let fallback = defaults.indices.contains(slot) ? defaults[slot] : "mp4"
        let sanitized = sanitizeCustomExtension(value, fallback: fallback)
        UserDefaults.standard.set(sanitized, forKey: AppConstants.customPresetExtensionKey(for: slot))
        customPresetRefreshToken = UUID()
    }

    private func updateCustomNameSuffix(_ value: String, slot: Int) {
        let fallback = AppConstants.defaultCustomPresetNameSuffixes.indices.contains(slot)
            ? AppConstants.defaultCustomPresetNameSuffixes[slot]
            : "Custom Preset"
        let prefix = customNamePrefix(for: slot)
        let sanitized = sanitizeCustomNameSuffix(value, prefix: prefix, fallback: fallback)
        updateStoredNameSuffix(sanitized, slot: slot)
    }

    private func updateStoredNameSuffix(_ value: String, slot: Int) {
        UserDefaults.standard.set(value, forKey: AppConstants.customPresetNameKey(for: slot))
        customPresetRefreshToken = UUID()
    }

    @ViewBuilder
    private func presetNameField(for slot: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Display name")
                .font(.footnote)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                Text(customNamePrefix(for: slot))
                    .font(.body.monospaced())
                TextField("Custom Preset", text: Binding(
                    get: { customNameSuffix(for: slot) },
                    set: { updateCustomNameSuffix($0, slot: slot) }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func sanitizeCustomSuffix(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        return trimmed.hasPrefix("_") ? trimmed : "_" + trimmed
    }

    private func sanitizeCustomExtension(_ value: String, fallback: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(".") {
            trimmed.removeFirst()
        }
        trimmed = trimmed.replacingOccurrences(of: " ", with: "")
        return trimmed.isEmpty ? fallback : trimmed.lowercased()
    }

    private func sanitizeCustomCommand(_ value: String, fallback: String) -> String {
        let withoutControlCharacters = value.trimmingCharacters(in: .controlCharacters)
        let trimmedWhitespace = withoutControlCharacters.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedWhitespace.isEmpty {
            return fallback
        }
        return withoutControlCharacters
    }

    private func finalizeCustomCommand(for slot: Int) {
        let current = customCommand(for: slot)
        let trimmedTrailing = trimTrailingWhitespace(from: current)
        updateCustomCommand(trimmedTrailing, slot: slot)
    }

    private func trimTrailingWhitespace(from value: String) -> String {
        var result = value
        while let last = result.last, last.isWhitespace || last.isNewline {
            result.removeLast()
        }
        return result
    }

    private func sanitizeCustomNameSuffix(_ value: String, prefix: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let lowercasedPrefix = prefix.lowercased()
        var remainder = trimmed
        if trimmed.lowercased().hasPrefix(lowercasedPrefix) {
            let cutoff = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            remainder = String(trimmed[cutoff...])
        }
        remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder.first == ":" {
            remainder.removeFirst()
            remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let cleaned = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallback : cleaned
    }


}
