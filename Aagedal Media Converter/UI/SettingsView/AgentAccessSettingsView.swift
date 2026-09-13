// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

struct AgentAccessSettingsView: View {
    @AppStorage(AppConstants.localAgentAccessEnabledKey) private var accessEnabled = false
    @State private var connectionStatus = String(localized: "Not tested")
    @State private var isTesting = false

    private var helperURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("aagedal-media-converter-mcp")
    }

    private var configuration: String {
        let value = [
            "mcpServers": [
                "aagedal-media-converter": ["command": helperURL.path]
            ]
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    var body: some View {
        Form {
            Section("Local agent access") {
                Toggle("Allow local MCP clients to use Aagedal Media Converter", isOn: $accessEnabled)
                    .accessibilityIdentifier("settings.agentAccess.enabled")
                    .onChange(of: accessEnabled) { _, enabled in
                        apply(enabled: enabled)
                    }

                Text("When enabled, the signed helper accepts requests from local MCP clients and sends them to this app. The app remains the owner of every accepted conversion.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                LabeledContent("Connection") {
                    HStack {
                        Text(connectionStatus)
                            .foregroundStyle(.secondary)
                        Button("Test Connection") { testConnection() }
                            .disabled(!accessEnabled || isTesting)
                            .accessibilityIdentifier("settings.agentAccess.test")
                    }
                }
            }

            Section("MCP client setup") {
                Text("Add this stdio server to a local MCP client. Keep the app installed at the same location after configuring the client.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(configuration)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

                HStack {
                    Button("Copy Configuration") {
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

            Section("File access and disabling") {
                Text("Import source files and choose output folders in the app before an agent uses them. Agent requests cannot grant or expand file access.")
                    .font(.callout)
                Text("Turning access off rejects new connections. Jobs already accepted by the app continue and remain available in job history.")
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Local Agent Access")
        .padding(.horizontal, 12)
        .onAppear {
            connectionStatus = accessEnabled && ApplicationAgentIPCServer.shared.isRunning
                ? String(localized: "Ready")
                : String(localized: "Not connected")
        }
    }

    private func apply(enabled: Bool) {
        if enabled {
            do {
                try ApplicationAgentIPCServer.shared.start()
                connectionStatus = String(localized: "Ready")
            } catch {
                connectionStatus = String(localized: "Could not start")
            }
        } else {
            ApplicationAgentIPCServer.shared.stop()
            connectionStatus = String(localized: "Disabled")
        }
    }

    private func testConnection() {
        isTesting = true
        connectionStatus = String(localized: "Testing…")
        Task {
            defer { isTesting = false }
            do {
                let response = try await Task.detached {
                    try ApplicationAgentIPCClient().send(
                        ApplicationAgentIPCRequest(tool: .listPresets),
                        receiveTimeout: 10
                    )
                }.value
                connectionStatus = response.failure == nil
                    ? String(localized: "Ready")
                    : String(localized: "Request failed")
            } catch {
                connectionStatus = String(localized: "Not connected")
            }
        }
    }
}

#Preview {
    AgentAccessSettingsView()
        .frame(width: 700, height: 600)
}
