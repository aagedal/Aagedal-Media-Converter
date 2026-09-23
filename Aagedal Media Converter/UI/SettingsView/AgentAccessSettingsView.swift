// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

enum ApplicationAgentMCPClient: String, CaseIterable, Identifiable {
    case claudeDesktop
    case claudeCode
    case codex
    case openCode

    var id: Self { self }

    var name: String {
        switch self {
        case .claudeDesktop: "Claude Desktop"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .openCode: "OpenCode"
        }
    }

    func configuration(helperURL: URL) -> String {
        let quotedPath = "'" + helperURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        switch self {
        case .claudeCode:
            return "claude mcp add --scope user aagedal-media-converter -- \(quotedPath)"
        case .codex:
            return "codex mcp add aagedal-media-converter -- \(quotedPath)"
        case .claudeDesktop:
            return Self.jsonConfiguration([
                "mcpServers": [
                    "aagedal-media-converter": ["command": helperURL.path]
                ]
            ])
        case .openCode:
            return Self.jsonConfiguration([
                "$schema": "https://opencode.ai/config.json",
                "mcp": [
                    "aagedal-media-converter": [
                        "type": "local",
                        "command": [helperURL.path],
                        "enabled": true
                    ]
                ]
            ])
        }
    }

    private static func jsonConfiguration(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct AgentAccessSettingsView: View {
    @AppStorage(AppConstants.localAgentAccessEnabledKey) private var accessEnabled = false
    @State private var selectedClient: ApplicationAgentMCPClient = .claudeDesktop
    @State private var connectionStatus = String(localized: "Not tested")
    @State private var isTesting = false
    @State private var isUpdatingAccess = false
    @State private var approvedSourceFolders: [URL] = []
    @State private var folderAccessError: String?

    private var helperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("aagedal-media-converter-mcp")
    }

    private var configuration: String {
        selectedClient.configuration(helperURL: helperURL)
    }

    private var accessEnabledBinding: Binding<Bool> {
        Binding(
            get: { accessEnabled },
            set: { enabled in
                accessEnabled = enabled
                apply(enabled: enabled)
            }
        )
    }

    var body: some View {
        Form {
            Section("Local agent access") {
                Toggle(
                    "Allow local MCP clients to use Aagedal Media Converter",
                    isOn: accessEnabledBinding
                )
                    .disabled(isUpdatingAccess)
                    .accessibilityIdentifier("settings.agentAccess.enabled")

                Text("When enabled, the signed helper accepts requests from local MCP clients and sends them to this app. The app remains the owner of every accepted conversion.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                LabeledContent("Connection") {
                    HStack {
                        Text(connectionStatus)
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(connectionStatus)
                            .accessibilityIdentifier("settings.agentAccess.connectionStatus")
                        Button("Test Connection") { testConnection() }
                            .disabled(!accessEnabled || isTesting || isUpdatingAccess)
                            .accessibilityIdentifier("settings.agentAccess.test")
                    }
                }
            }

            Section("MCP client setup") {
                Picker("MCP client", selection: $selectedClient) {
                    ForEach(ApplicationAgentMCPClient.allCases) { client in
                        Text(client.name).tag(client)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("settings.agentAccess.client")

                if selectedClient == .claudeDesktop {
                    Text("Add this stdio server to a local MCP client. Keep the app installed at the same location after configuring the client.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if selectedClient == .openCode {
                    Text("Add this entry to your opencode.json configuration, then restart OpenCode. Keep the app installed at the same location.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Run this command in Terminal, then restart the client. Keep the app installed at the same location.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text(configuration)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("settings.agentAccess.configuration")

                HStack {
                    Button("Copy Setup") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(configuration, forType: .string)
                    }
                    .accessibilityIdentifier("settings.agentAccess.copyConfiguration")

                    Button("Show Helper in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([helperURL])
                    }
                    .disabled(!FileManager.default.isExecutableFile(atPath: helperURL.path))
                }
            }

            Section("Approved source folders") {
                Text("Files in these folders and their subfolders are available to local MCP clients. Choose output folders in the app before converting. MCP requests cannot approve new locations.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ForEach(approvedSourceFolders, id: \.absoluteString) { folder in
                    HStack {
                        Text(folder.path)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Remove") {
                            if SecurityScopedBookmarkManager.agentSourceFolders.removeBookmark(for: folder) {
                                reloadApprovedSourceFolders()
                            } else {
                                folderAccessError = String(localized: "The saved folder approvals could not be changed.")
                            }
                        }
                    }
                }

                Button("Add Source Folder…") {
                    chooseSourceFolder()
                }
                .accessibilityIdentifier("settings.agentAccess.addSourceFolder")
            }

            Section("Disabling") {
                Text("Turning access off rejects new connections. Jobs already accepted by the app continue and remain available in job history.")
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Local Agent Access")
        .padding(.horizontal, 12)
        .alert("Could not save folder access", isPresented: Binding(
            get: { folderAccessError != nil },
            set: { if !$0 { folderAccessError = nil } }
        )) {
            Button("OK", role: .cancel) { folderAccessError = nil }
        } message: {
            Text(folderAccessError ?? "")
        }
        .onAppear {
            reloadApprovedSourceFolders()
            if accessEnabled {
                if ApplicationAgentIPCServer.shared.isRunning {
                    connectionStatus = String(localized: "Ready")
                } else {
                    // The pane can appear before the app-launch task has started
                    // the endpoint. Starting is idempotent, so reconcile the
                    // visible toggle with the actual transport instead of
                    // reporting a stale "Not connected" state.
                    apply(enabled: true)
                }
            } else {
                connectionStatus = String(localized: "Not connected")
            }
        }
    }

    private func reloadApprovedSourceFolders() {
        approvedSourceFolders = SecurityScopedBookmarkManager.agentSourceFolders.storedFolderURLs()
    }

    private func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Approve Folder")
        panel.message = String(localized: "Choose a folder whose files and subfolders local MCP clients may read.")
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            let selectedFolder = folder.standardizedFileURL
            guard SecurityScopedBookmarkManager.agentSourceFolders.saveBookmark(for: selectedFolder) else {
                folderAccessError = String(localized: "Select the folder again or choose another location.")
                return
            }
            reloadApprovedSourceFolders()
        }
    }

    private func apply(enabled: Bool) {
        if enabled {
            isUpdatingAccess = true
            connectionStatus = String(localized: "Testing…")
            Task {
                defer { isUpdatingAccess = false }
                do {
                    let running = try await ApplicationAgentAccessLifecycle.shared.reconcile()
                    guard accessEnabled else { return }
                    connectionStatus = running
                        ? String(localized: "Ready")
                        : String(localized: "Not connected")
                } catch {
                    guard accessEnabled else { return }
                    connectionStatus = String(localized: "Could not start")
                        + ": " + error.localizedDescription
                }
            }
        } else {
            isUpdatingAccess = true
            connectionStatus = String(localized: "Disabled")
            Task {
                _ = try? await ApplicationAgentAccessLifecycle.shared.reconcile()
                isUpdatingAccess = false
            }
        }
    }

    private func testConnection() {
        isTesting = true
        connectionStatus = String(localized: "Testing…")
        let helperURL = helperURL
        Task {
            defer { isTesting = false }
            do {
                let succeeded = try await Task.detached {
                    try ApplicationAgentMCPConnectionDiagnostic.test(helperURL: helperURL)
                }.value
                connectionStatus = succeeded
                    ? String(localized: "Ready")
                    : String(localized: "Request failed")
            } catch {
                connectionStatus = String(localized: "Not connected")
                    + ": " + error.localizedDescription
            }
        }
    }
}

/// Checks the same stdio-to-app path that an MCP client uses, rather than a
/// same-process message-port request that cannot detect helper launch failures.
private enum ApplicationAgentMCPConnectionDiagnostic {
    static func test(helperURL: URL) throws -> Bool {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { return false }

        let process = Process()
        process.executableURL = helperURL
        let input = Pipe()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        process.standardInput = input
        process.standardOutput = output
        try process.run()

        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [
                "protocolVersion": "2025-06-18",
                "clientInfo": ["name": "Aagedal Media Converter Diagnostics"]
            ]],
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": [
                "name": "list_presets", "arguments": [:]
            ]]
        ]
        let lines = try messages.map {
            try JSONSerialization.data(withJSONObject: $0) + Data([0x0A])
        }
        input.fileHandleForWriting.write(lines.reduce(Data(), +))
        try input.fileHandleForWriting.close()
        guard finished.wait(timeout: .now() + 15) == .success else {
            process.terminate()
            return false
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return false }

        let responses = try output.fileHandleForReading.readDataToEndOfFile()
            .split(separator: 0x0A)
            .map { try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        guard responses.count == 2,
              let result = responses[1]?["result"] as? [String: Any],
              result["isError"] as? Bool == false,
              let structured = result["structuredContent"] as? [String: Any],
              let presets = structured["presets"] as? [[String: Any]] else {
            return false
        }
        return presets.count == ApplicationPresetID.allCases.count
    }
}

#Preview {
    AgentAccessSettingsView()
        .frame(width: 700, height: 600)
}
