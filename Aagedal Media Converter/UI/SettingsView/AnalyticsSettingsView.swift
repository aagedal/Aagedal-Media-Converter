// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct AnalyticsSettingsView: View {
    var showsAutomation = true

    @AppStorage(AppConstants.analyticsVMAFModelKey) private var vmafModel = AppConstants.defaultAnalyticsVMAFModel
    @AppStorage(AppConstants.analyticsAutoRunKey) private var autoRunAfterConversion = false
    @AppStorage(AppConstants.analyticsAutoExportKey) private var autoExport = false
    @AppStorage(AppConstants.analyticsAutoExportFormatKey) private var autoExportFormat = AppConstants.defaultAnalyticsAutoExportFormat
    @AppStorage(AppConstants.ssimulacra2MaxFramesKey) private var ssimulacra2MaxFrames = AppConstants.defaultSSIMULACRA2MaxFrames

    @State private var enabledMetrics: Set<String> = []

    private var isSSIMULACRA2Enabled: Bool {
        enabledMetrics.contains(QualityMetric.ssimulacra2.rawValue)
    }

    var body: some View {
        Form {
            if showsAutomation { automationSection }
            metricsSection
            vmafSettingsSection
        }
        .formStyle(.grouped)
        .onAppear {
            loadEnabledMetrics()
        }
    }

    // MARK: - Automation Section

    private var automationSection: some View {
        Section(header: Text("Automation")) {
            Toggle("Automatically run analytics after conversion", isOn: $autoRunAfterConversion)
                .toggleStyle(SwitchToggleStyle())
            Text("When enabled, quality analytics will run on each file immediately after encoding completes.")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Auto-export analytics results", isOn: $autoExport)
                .toggleStyle(SwitchToggleStyle())

            if autoExport {
                Picker("Export Format", selection: $autoExportFormat) {
                    ForEach(AnalyticsExportFormat.allCases, id: \.self) { format in
                        Text(format.displayName).tag(format.rawValue)
                    }
                }

                Text("Analytics results will be saved next to the encoded file after each analysis completes.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Quality Metrics Section

    private var metricsSection: some View {
        Section(header: Text("Quality Metrics")) {
            ForEach(QualityMetric.allCases, id: \.self) { metric in
                metricToggle(for: metric)
            }
        }
    }

    private func metricToggle(for metric: QualityMetric) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { enabledMetrics.contains(metric.rawValue) },
                set: { enabled in
                    if enabled {
                        enabledMetrics.insert(metric.rawValue)
                    } else {
                        enabledMetrics.remove(metric.rawValue)
                    }
                    saveEnabledMetrics()
                }
            )) {
                Text(metric.displayName)
            }
            .toggleStyle(SwitchToggleStyle())
            .accessibilityIdentifier("analysis.metric.\(metric.rawValue)")

            Text(LocalizedStringKey(aboutText(for: metric)))
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 20)

            if metric == .ssimulacra2 {
                Label("Slow \u{2014} extracts and compares individual frames", systemImage: "tortoise.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.leading, 20)

                if isSSIMULACRA2Enabled {
                    ssimulacra2InlineSettings
                        .padding(.leading, 20)
                        .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - SSIMULACRA2 Inline Settings

    private var ssimulacra2InlineSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Included with the app. No additional installation is needed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !BinaryPathResolver.isSSIMULACRA2Available {
                Label("The bundled analysis tool is missing. Reinstall the app to restore it.", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // Frame sampling
            Stepper("Max Frames: \(ssimulacra2MaxFrames)", value: $ssimulacra2MaxFrames, in: 5...500, step: 5)
                .font(.caption)
                .accessibilityIdentifier("analysis.ssimulacra2.frames")

            Text("Number of frames sampled evenly across the video for comparison. More frames gives higher accuracy but takes longer.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - VMAF Settings Section

    private var vmafSettingsSection: some View {
        Section(header: Text("VMAF Settings")) {
            Picker("VMAF Model", selection: $vmafModel) {
                ForEach(VMAFModel.allCases, id: \.self) { model in
                    Text(LocalizedStringKey(model.displayName)).tag(model.rawValue)
                }
            }

            .accessibilityIdentifier("analysis.vmaf.model")

            if let model = VMAFModel(rawValue: vmafModel) {
                Text(LocalizedStringKey(model.description))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - About Text

    private func aboutText(for metric: QualityMetric) -> String {
        switch metric {
        case .vmaf:
            return "Video Multi-Method Assessment Fusion, developed by Netflix. Predicts perceived quality on a 0-100 scale. Scores above 93 are considered excellent."
        case .psnr:
            return "Peak Signal-to-Noise Ratio. Traditional mathematical metric measured in dB. Higher values indicate better quality. Typical range: 30-50 dB."
        case .xpsnr:
            return "Extended PSNR by Fraunhofer HHI. Perceptually weighted PSNR metric measured in dB. Values above 42 dB are considered visually lossless."
        case .ssimulacra2:
            return "Perceptual quality metric by Cloudflare. Measures structural similarity on a 0-100 scale. Scores above 70 indicate good quality. Included with the app."
        }
    }

    // MARK: - Persistence

    private func loadEnabledMetrics() {
        let saved = UserDefaults.standard.stringArray(forKey: AppConstants.analyticsEnabledMetricsKey)
            ?? AppConstants.defaultAnalyticsEnabledMetrics
        enabledMetrics = Set(saved)
    }

    private func saveEnabledMetrics() {
        UserDefaults.standard.set(Array(enabledMetrics), forKey: AppConstants.analyticsEnabledMetricsKey)
    }
}

#Preview {
    AnalyticsSettingsView()
}
