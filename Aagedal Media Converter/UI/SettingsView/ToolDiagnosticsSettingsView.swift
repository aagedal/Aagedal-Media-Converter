// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct ToolDiagnosticsSettingsView: View {
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
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
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
