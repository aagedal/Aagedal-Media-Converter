// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Standalone window that validates any DCP folder (ours or another tool's).
struct DCPValidatorView: View {
    @State private var directory: URL?
    @State private var verifyHashes = true
    @State private var report: DCPValidationReport?
    @State private var progress: Double = 0
    @State private var status = ""
    @State private var task: Task<Void, Never>?
    @State private var isTargeted = false
    @State private var showInfo = false
    @State private var runID = UUID()

    private var isRunning: Bool { task != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if let report {
                summary(report)
                issueList(report)
            } else if !isRunning {
                dropTarget
            }
        }
        .padding()
        .frame(minWidth: 620, minHeight: 420)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted, perform: handleDrop)
        .onDisappear { task?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button("Choose DCP Folder…", action: chooseFolder)
                .disabled(isRunning)
            Toggle("Verify hashes", isOn: $verifyHashes)
                .help("Re-read every file and compare its SHA-1 with the packing list. Slow for long features.")
                .disabled(isRunning)
            Spacer()
            if isRunning {
                Button("Cancel") { task?.cancel() }
            } else if let directory {
                Button("Validate Again") { start(directory) }
            }
            if let report {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy report")
                .disabled(isRunning)
            }
        }
    }

    private var dropTarget: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Drop a DCP folder here")
                .font(.headline)
            Text("Checks the ASSETMAP, packing list and composition playlists, the MXF essence and JPEG 2000 codestreams, and the SMPTE Bv2.1 profile, along the lines of DCP-o-matic's verifier.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
        )
    }

    @ViewBuilder
    private func summary(_ report: DCPValidationReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                let errors = report.count(.error)
                Image(systemName: errors > 0 ? "xmark.octagon.fill" : (report.count(.warning) > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"))
                    .foregroundStyle(errors > 0 ? .red : (report.count(.warning) > 0 ? .orange : .green))
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text(report.directory.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(report.cancelled ? "Cancelled — partial results" : report.summaryLine)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Show info", isOn: $showInfo).toggleStyle(.checkbox)
            }
            ForEach(report.compositions) { composition in
                Text(compositionLine(composition))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func compositionLine(_ composition: DCPCompositionSummary) -> String {
        var parts = ["\(composition.title) — \(composition.standard) \(composition.contentKind)",
                     "\(composition.reelCount) reel(s)",
                     "\(composition.durationFrames) frames @ \(composition.editRate)"]
        if let size = composition.pictureSize { parts.append(size) }
        if let channels = composition.soundChannels { parts.append("\(channels) ch") }
        if composition.encrypted { parts.append("encrypted") }
        return parts.joined(separator: " · ")
    }

    private func issueList(_ report: DCPValidationReport) -> some View {
        let issues = report.issues
            .filter { showInfo || $0.severity != .info }
            .sorted { $0.severity < $1.severity }
        return List(issues) { issue in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol(for: issue.severity))
                    .foregroundStyle(color(for: issue.severity))
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.message)
                        .textSelection(.enabled)
                    Text([issue.severity.label, issue.code, issue.file].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .overlay {
            if issues.isEmpty {
                Text(report.cancelled ? "No issues found before cancelling." : "No issues found.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func symbol(for severity: DCPValidationIssue.Severity) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .bv21: return "list.bullet.clipboard"
        case .info: return "info.circle"
        }
    }

    private func color(for severity: DCPValidationIssue.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .bv21: return .yellow
        case .info: return .secondary
        }
    }

    // MARK: - Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Validate")
        panel.message = String(localized: "Choose the DCP folder (the one containing ASSETMAP.xml).")
        if panel.runModal() == .OK, let url = panel.url {
            start(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isRunning, let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
                // Accept a dropped ASSETMAP/CPL file as shorthand for its folder.
                start(isDirectory.boolValue ? url : url.deletingLastPathComponent())
            }
        }
        return true
    }

    private func start(_ url: URL) {
        task?.cancel()
        directory = url
        report = nil
        progress = 0
        status = ""
        let options = DCPValidator.Options(verifyHashes: verifyHashes)
        let id = UUID()
        runID = id
        task = Task {
            let result = await DCPValidator.validate(directory: url, options: options) { fraction, text in
                Task { @MainActor in
                    guard runID == id else { return }
                    progress = fraction
                    status = text
                }
            }
            // A superseded run must not overwrite the newer one's state.
            guard runID == id else { return }
            report = result
            task = nil
        }
    }
}
