// Aagedal Media Converter
// Copyright 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AppKit

/// Container view for the supported transcription engines.
struct TranscriptionSettingsView: View {
    @AppStorage(AppConstants.defaultTranscriptionEngineKey) private var defaultEngine = AppConstants.defaultTranscriptionEngine
    @AppStorage(AppConstants.embedSubtitlesKey) private var embedSubtitles = AppConstants.defaultEmbedSubtitles

    var body: some View {
        Form {
            Section(header: Text("Default Transcription Engine")) {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Engine:", selection: $defaultEngine) {
                        Text("Whisper (FFmpeg built-in)").tag("whisper")
                        Text("Parakeet (NeMo MLX)").tag("parakeet")
                        Text("Nemotron (NeMo Speech)").tag("nemotron")
                    }
                    .pickerStyle(.menu)

                    Text("The default engine used when enabling transcription on new items. You can override per item in the queue.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Divider()

                    Toggle("Embed subtitles into output file", isOn: $embedSubtitles)
                        .toggleStyle(SwitchToggleStyle())

                    Text("When enabled, the generated SRT will be muxed into the output video file as a subtitle track after transcription completes. The external SRT file is kept as well.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if embedSubtitles {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                                .font(.caption)
                            Text("Not all subtitle formats are compatible with MP4 and MOV containers. SRT subtitles will be converted to mov_text for MP4/MOV. For full compatibility, use MKV as the output format.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(8)
                        .background(Color.yellow.opacity(0.1))
                        .cornerRadius(6)
                    }
                }
                .padding(8)
            }

            if defaultEngine == "whisper" {
                WhisperSettingsView()
            }

            if defaultEngine == "nemotron" {
                NemotronSettingsView()
            }

            if defaultEngine == "parakeet" {
                ParakeetSettingsView()
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    TranscriptionSettingsView()
}

struct NemotronSettingsView: View {
    @AppStorage(AppConstants.nemotronCustomPathKey) private var customPath = ""
    @AppStorage(AppConstants.nemotronLanguageKey) private var language = AppConstants.defaultNemotronLanguage
    @State private var downloading = false
    @State private var downloadTask: Task<Void, Never>?
    @State private var message: String?

    var body: some View {
        Section("Nemotron") {
            Text("Nemotron 3.5 ASR · 0.6B · Multilingual")
                .font(.headline)
            Text("Transcribes locally using NeMo Speech. The base model supports Norwegian Bokmål; Nynorsk requires a fine-tuned model.")
                .font(.caption).foregroundStyle(.secondary)
            Text("NeMo Speech is included with the app. Download the base model to get started.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Language", selection: $language) {
                ForEach(NemotronLanguage.supported) { locale in
                    Text(locale.name).tag(locale.id)
                }
            }
            .pickerStyle(.menu)
            DisclosureGroup("Advanced") {
                HStack {
                    TextField("Custom NeMo Speech executable (optional)", text: $customPath)
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url { customPath = url.path }
                    }
                    if !customPath.isEmpty { Button("Use bundled runtime") { customPath = "" } }
                }
                if BinaryPathResolver.nemotronPath == nil {
                    Text("NeMo Speech is unavailable. Check the custom path or reinstall the app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("The base model downloads on first use. You can also download it now; NeMo Speech verifies and caches the weights.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(downloading ? "Downloading…" : "Download base model") {
                    guard let path = BinaryPathResolver.nemotronPath else { return }
                    downloading = true
                    message = nil
                    downloadTask = Task { @MainActor in
                        defer { downloading = false; downloadTask = nil }
                        do {
                            let request = SubprocessRequest(
                                executableURL: URL(fileURLWithPath: path),
                                arguments: ["pull", AppConstants.defaultNemotronModel],
                                timeout: .seconds(2 * 60 * 60),
                                standardOutputCaptureLimit: 64 * 1024,
                                standardErrorCaptureLimit: 64 * 1024,
                                sensitiveValues: [path]
                            )
                            try await NemotronCLITranscriber.run(request, using: SubprocessRunner())
                            message = "Base model is ready."
                        } catch is CancellationError {
                            message = "Download cancelled."
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                }
                .disabled(downloading || BinaryPathResolver.nemotronPath == nil)
                if downloading {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { downloadTask?.cancel() }
                }
            }
            if let message { Text(message).font(.caption).textSelection(.enabled) }
            Link("Base model and license", destination: URL(string: "https://huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b")!)
        }
        .onAppear {
            if !NemotronLanguage.supported.contains(where: { $0.id == language }) {
                language = AppConstants.defaultNemotronLanguage
            }
        }
        .onDisappear { downloadTask?.cancel() }
    }
}
