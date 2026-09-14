// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

struct AgentAccessSettingsView: View {
    @AppStorage(AppConstants.localAgentAccessEnabledKey) private var accessEnabled = false
    @State private var connectionStatus = String(localized: "Not tested")
    @State private var isTesting = false
    @State private var isUpdatingAccess = false

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
                Text("Add this stdio server to a local MCP client. Keep the app installed at the same location after configuring the client.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(configuration)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("settings.agentAccess.configuration")

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

    private func apply(enabled: Bool) {
        if enabled {
            isUpdatingAccess = true
            connectionStatus = String(localized: "Testing…")
            Task {
                defer { isUpdatingAccess = false }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        try ApplicationAgentIPCServer.shared.start()
                    }.value

                    guard accessEnabled else {
                        await Task.detached {
                            ApplicationAgentIPCServer.shared.stop()
                        }.value
                        return
                    }
                    connectionStatus = String(localized: "Ready")
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
                await Task.detached(priority: .userInitiated) {
                    ApplicationAgentIPCServer.shared.stop()
                }.value
                isUpdatingAccess = false
            }
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
                    + ": " + error.localizedDescription
            }
        }
    }
}

#Preview {
    AgentAccessSettingsView()
        .frame(width: 700, height: 600)
}
