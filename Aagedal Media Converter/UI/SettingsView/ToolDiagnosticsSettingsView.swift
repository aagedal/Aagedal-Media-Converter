// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct ToolDiagnosticsSettingsView: View {
    var openSettings: (String) -> Void = { _ in }
    @State private var results: [ToolDiagnostic] = []
    @State private var models: [ModelDiagnostic] = []
    @State private var checking = false
    @State private var checkID: UUID?

    var body: some View {
        Form {
            Section {
                Text("Check the active bundled, Homebrew, or custom tools selected in Settings. Each version check has a five-second limit.")
                    .foregroundStyle(.secondary)
                Text("The bundled FFmpeg is sufficient for standard conversions. Optional tools are only needed for their related features; select or install them in Downloads, Upload, Transcription, OCR, or Analytics settings.")
                    .foregroundStyle(.secondary)
                Button(checking ? "Checking Tools…" : "Check Tools") {
                    checking = true
                    results = []
                    models = []
                    checkID = UUID()
                }
                .disabled(checking)
                .accessibilityIdentifier("settings.tools.check")
                if checking { ProgressView().controlSize(.small) }
            } header: {
                Text("Tool Diagnostics")
            }
            ForEach(models) { model in
                Section {
                    if let path = model.path {
                        Text(verbatim: path.path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent("Available", value: model.available ? String(localized: "Yes") : String(localized: "No"))
                    Label(model.message, systemImage: model.available ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(model.available ? Color.secondary : Color.orange)
                    if !model.available {
                        recoveryInstructions(for: model.id)
                    }
                } header: {
                    Text(verbatim: model.name)
                }
                .accessibilityIdentifier("settings.tools.\(model.id)")
            }
            ForEach(results) { result in
                Section {
                    if let path = result.path {
                        Text(verbatim: path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent("Architecture", value: result.architecture)
                    LabeledContent("Executable", value: result.executable ? String(localized: "Yes") : String(localized: "No"))
                    if let version = result.version {
                        Text(verbatim: version).textSelection(.enabled)
                    }
                    if let note = result.note {
                        Text(note).foregroundStyle(.secondary)
                    }
                    if let failure = result.failure {
                        if isUnconfiguredOptionalTool(result) {
                            Label("Optional tool — not installed", systemImage: "info.circle")
                                .foregroundStyle(.secondary)
                        } else {
                            Label(failure, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        recoveryInstructions(for: result.id)
                    }
                } header: {
                    Text(verbatim: result.name)
                }
                .accessibilityIdentifier("settings.tools.\(result.id)")
            }
        }
        .formStyle(.grouped)
        .task(id: checkID) {
            guard let checkID else { return }
            await runChecks(id: checkID)
        }
        .onDisappear { checkID = nil; checking = false }
    }

    private func isUnconfiguredOptionalTool(_ result: ToolDiagnostic) -> Bool {
        guard result.path == nil else { return false }
        let key: String
        switch result.id {
        case "parakeet": key = AppConstants.parakeetCustomPathKey
        case "ssimulacra2": key = AppConstants.ssimulacra2CustomPathKey
        default: return false
        }
        return (UserDefaults.standard.string(forKey: key) ?? "").isEmpty
    }

    @ViewBuilder
    private func recoveryInstructions(for id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch id {
            case "parakeet":
                Text("Parakeet is optional and only needed for Parakeet transcription. Install uv using the linked instructions, then run this command in Terminal:")
                Link("Install uv", destination: URL(string: "https://docs.astral.sh/uv/getting-started/installation/")!)
                CopyableCommandRow(command: "uv tool install parakeet-mlx -U")
                Link("Parakeet installation instructions", destination: URL(string: "https://github.com/senstella/parakeet-mlx#installation")!)
                Text("In Transcription settings, select Parakeet. If it is installed elsewhere, use Custom path to select parakeet-mlx. Download a model before transcribing.")
                Button("Open Transcription Settings") { openSettings("whisper") }
            case "ssimulacra2":
                Text("SSIMULACRA2 is optional and only needed for its quality metric. Install Rust using the linked instructions, then run this command in Terminal:")
                Link("Install Rust", destination: URL(string: "https://www.rust-lang.org/tools/install")!)
                CopyableCommandRow(command: "cargo install ssimulacra2_rs --no-default-features")
                Link("SSIMULACRA2 installation instructions", destination: URL(string: "https://github.com/rust-av/ssimulacra2")!)
                Text("The app looks for ssimulacra2_rs in ~/.cargo/bin, /opt/homebrew/bin, and /usr/local/bin. Standard conversions do not require this tool.")
                Button("Open Analytics Settings") { openSettings("analytics") }
            case "parakeet-model":
                Text("Only Parakeet transcription needs this model. In Transcription settings, select Parakeet, install its tool if needed, then download the selected model or choose an available model.")
                Button("Open Transcription Settings") { openSettings("whisper") }
            case "whisper-model":
                Text("In Transcription settings, select Whisper and download the selected model. For a custom model, select the file again to restore access, or choose an available model.")
                Button("Open Transcription Settings") { openSettings("whisper") }
            case "ytdlp", "deno":
                Text("In Downloads settings, choose App Download and install or update the tool. For Homebrew, follow the installation instructions there; for Custom, select an executable file again.")
                Button("Open Downloads Settings") { openSettings("ytdlp") }
            case "rclone":
                Text("In Upload settings, select App (Bundled) for rclone. If using Homebrew or Custom, check the selected installation and executable path.")
                Button("Open Upload Settings") { openSettings("upload") }
            case "tesseract":
                Text("In OCR settings, select the bundled Tesseract or select an installed custom executable. If the bundled tool is unavailable, reinstall the app.")
                Button("Open OCR Settings") { openSettings("ocr") }
            case "ffmpeg":
                Text("In Downloads settings, select the bundled FFmpeg or select an installed custom executable. If the bundled tool is unavailable, reinstall the app.")
                Button("Open Downloads Settings") { openSettings("ytdlp") }
            default:
                Text("This helper is bundled with the app. Reinstall the app if it is missing or incompatible.")
            }
            Text("After making changes, return here and click Check Tools again.")
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    @MainActor
    private func runChecks(id runID: UUID) async {
        defer { if checkID == runID { checking = false } }
        let diagnostics = ToolDiagnostics()
        do {
            try Task.checkCancellation()
            models = ModelDiagnostics.selectedModels()
            let ytdlp = await YTDLPUpdateService.shared.resolveYTDLPPath()
            let deno = await YTDLPUpdateService.shared.resolveDenoPath()
            let rclone = await RcloneUpdateService.shared.resolveRclonePath()
            let tools: [(String, String, String?, [String]?)] = [
                ("ffmpeg", "FFmpeg", BinaryPathResolver.ffmpegPath, ["-version"]),
                ("ytdlp", "yt-dlp", ytdlp, ["--version"]),
                ("deno", "Deno", deno, ["--version"]),
                ("rclone", "rclone", rclone, ["version"]),
                ("tesseract", "Tesseract", BinaryPathResolver.tesseractPath, ["--version"]),
                ("ssimulacra2", "SSIMULACRA2", BinaryPathResolver.ssimulacra2Path, ["--version"])
            ]
            for (id, name, path, arguments) in tools + ToolDiagnostics.helperChecks {
                try Task.checkCancellation()
                var configuration: HomebrewPythonExecutor.ToolExecutionConfiguration?
                if let path, let arguments, id == "ytdlp" {
                    configuration = HomebrewPythonExecutor.ytDLPExecutionConfiguration(scriptPath: path, arguments: arguments)
                }
                let result = try await diagnostics.check(id: id, name: name, path: path,
                                                         arguments: arguments, configuration: configuration)
                try Task.checkCancellation()
                guard checkID == runID else { return }
                results.append(result)
            }
        } catch {
            // The view's task cancellation also terminates its active subprocess.
        }
    }
}
