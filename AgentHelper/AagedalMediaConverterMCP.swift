// Aagedal Media Converter MCP helper
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreFoundation
import Foundation

private let ipcPortName = "com.aagedal.Aagedal-Media-Converter.agent.v1"
private let ipcSchemaVersion = 1
private let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

@main
private struct AagedalMediaConverterMCP {
    static func main() {
        let server = MCPStdioServer()
        server.run()
    }
}

private final class MCPStdioServer {
    private var clientName = "local-mcp-client"

    func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            autoreleasepool {
                handle(line: line)
            }
        }
    }

    private func handle(line: String) {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              message["jsonrpc"] as? String == "2.0",
              let method = message["method"] as? String else {
            writeError(id: nil, code: -32700, message: "Invalid JSON-RPC message.")
            return
        }

        let id = message["id"]
        switch method {
        case "initialize":
            initialize(message: message, id: id)
        case "notifications/initialized", "notifications/cancelled":
            break
        case "ping":
            writeResult(id: id, result: [:])
        case "tools/list":
            writeResult(id: id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            callTool(message: message, id: id)
        default:
            if id != nil {
                writeError(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    private func initialize(message: [String: Any], id: Any?) {
        let params = message["params"] as? [String: Any]
        let requestedVersion = params?["protocolVersion"] as? String
        if let client = params?["clientInfo"] as? [String: Any],
           let name = client["name"] as? String,
           !name.isEmpty {
            clientName = Self.requesterID(from: name)
        }
        let negotiatedVersion = requestedVersion.flatMap {
            supportedProtocolVersions.contains($0) ? $0 : nil
        } ?? supportedProtocolVersions[0]
        writeResult(id: id, result: [
            "protocolVersion": negotiatedVersion,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": [
                "name": "Aagedal Media Converter",
                "version": "4.5.0"
            ],
            "instructions": "Grant source and destination folder access in Aagedal Media Converter before planning conversions."
        ])
    }

    private func callTool(message: [String: Any], id: Any?) {
        guard let params = message["params"] as? [String: Any],
              let name = params["name"] as? String,
              Self.toolNames.contains(name) else {
            writeError(id: id, code: -32602, message: "Unknown or missing tool name.")
            return
        }
        var arguments = params["arguments"] as? [String: Any] ?? [:]
        if name == "plan_conversion", arguments["requester_id"] == nil {
            arguments["requester_id"] = clientName
        }
        let requestID = UUID()
        let request: [String: Any] = [
            "schemaVersion": ipcSchemaVersion,
            "requestID": requestID.uuidString.lowercased(),
            "tool": name,
            "arguments": arguments
        ]

        do {
            let response = try AppIPCClient().send(request)
            guard let responseID = response["requestID"] as? String,
                  responseID.caseInsensitiveCompare(requestID.uuidString) == .orderedSame else {
                throw HelperError.invalidResponse
            }
            if let failure = response["failure"] as? [String: Any] {
                let message = failure["message"] as? String ?? "The operation failed."
                writeResult(id: id, result: [
                    "content": [["type": "text", "text": message]],
                    "structuredContent": ["error": failure],
                    "isError": true
                ])
                return
            }
            guard let result = response["result"] else { throw HelperError.invalidResponse }
            let prettyData = try JSONSerialization.data(
                withJSONObject: result,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            let text = String(decoding: prettyData, as: UTF8.self)
            writeResult(id: id, result: [
                "content": [["type": "text", "text": text]],
                "structuredContent": result,
                "isError": false
            ])
        } catch {
            let message: String
            if let helperError = error as? HelperError {
                message = helperError.localizedDescription
            } else {
                message = "Could not communicate with Aagedal Media Converter."
            }
            writeResult(id: id, result: [
                "content": [["type": "text", "text": message]],
                "structuredContent": [
                    "error": ["code": "transport_unavailable", "message": message]
                ],
                "isError": true
            ])
        }
    }

    private func writeResult(id: Any?, result: Any) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func writeError(id: Any?, code: Int, message: String) {
        write([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": message]
        ])
    }

    private func write(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: message,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func requesterID(from name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((value.isEmpty ? "local-mcp-client" : value).prefix(64))
    }

    private static let toolNames = Set([
        "inspect_media", "list_presets", "plan_conversion", "submit_conversion", "get_job", "cancel_job"
    ])

    private static var toolDefinitions: [[String: Any]] { [
        [
            "name": "inspect_media",
            "description": "Inspect a local media file for structured stream, duration, rate, and timecode metadata. The file must already have approved read access in the app.",
            "inputSchema": objectSchema(
                properties: ["source_path": pathProperty("Absolute path to the local media file.")],
                required: ["source_path"]
            )
        ],
        [
            "name": "list_presets",
            "description": "List the stable conversion presets supported for local agent access and their currently resolved settings.",
            "inputSchema": objectSchema(properties: [:], required: [])
        ],
        [
            "name": "plan_conversion",
            "description": "Validate sources and destination, capture preset settings, and reserve a deterministic conversion plan without starting work.",
            "inputSchema": objectSchema(
                properties: [
                    "source_paths": [
                        "type": "array",
                        "minItems": 1,
                        "items": pathProperty("Absolute source path.")
                    ],
                    "destination_path": pathProperty("Absolute path to an approved writable folder."),
                    "preset_id": [
                        "type": "string",
                        "enum": ["h264", "hevc", "prores", "proxy", "audio_only", "stream_copy"]
                    ],
                    "request_id": ["type": "string", "format": "uuid"],
                    "idempotency_key": ["type": "string", "minLength": 1, "maxLength": 128]
                ],
                required: ["source_paths", "destination_path", "preset_id"]
            )
        ],
        [
            "name": "submit_conversion",
            "description": "Submit a valid conversion plan to the app-owned queue and return its job immediately.",
            "inputSchema": objectSchema(
                properties: ["plan_id": uuidProperty("Plan identifier returned by plan_conversion.")],
                required: ["plan_id"]
            )
        ],
        [
            "name": "get_job",
            "description": "Get the durable state, progress, diagnostics, and outputs for a conversion job.",
            "inputSchema": objectSchema(
                properties: ["job_id": uuidProperty("Job identifier returned by submit_conversion.")],
                required: ["job_id"]
            )
        ],
        [
            "name": "cancel_job",
            "description": "Request cancellation of a queued or running conversion job.",
            "inputSchema": objectSchema(
                properties: ["job_id": uuidProperty("Job identifier returned by submit_conversion.")],
                required: ["job_id"]
            )
        ]
    ] }

    private static func objectSchema(
        properties: [String: Any],
        required: [String]
    ) -> [String: Any] {
        [
            "type": "object",
            "properties": properties,
            "required": required,
            "additionalProperties": false
        ]
    }

    private static func pathProperty(_ description: String) -> [String: Any] {
        ["type": "string", "description": description, "minLength": 1]
    }

    private static func uuidProperty(_ description: String) -> [String: Any] {
        ["type": "string", "format": "uuid", "description": description]
    }
}

private struct AppIPCClient {
    func send(_ request: [String: Any]) throws -> [String: Any] {
        let requestData = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        var lastStatus: Int32?

        for attempt in 0..<51 {
            if let remote = CFMessagePortCreateRemote(nil, ipcPortName as CFString) {
                var responseData: Unmanaged<CFData>?
                let status = CFMessagePortSendRequest(
                    remote,
                    0,
                    requestData as CFData,
                    5,
                    300,
                    CFRunLoopMode.defaultMode.rawValue,
                    &responseData
                )
                if status == kCFMessagePortSuccess, let responseData {
                    let data = responseData.takeRetainedValue() as Data
                    guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw HelperError.invalidResponse
                    }
                    return response
                }
                lastStatus = status
            }

            if attempt == 0 { try launchApplication() }
            Thread.sleep(forTimeInterval: 0.2)
        }

        if let lastStatus { throw HelperError.transportStatus(lastStatus) }
        throw HelperError.accessDisabled
    }

    private func launchApplication() throws {
        let helperURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let appURL = helperURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard appURL.pathExtension == "app" else { throw HelperError.appBundleNotFound }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let completion = DispatchSemaphore(value: 0)
        var launchError: Error?
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            launchError = error
            completion.signal()
        }
        guard completion.wait(timeout: .now() + 10) == .success else {
            throw HelperError.launchTimedOut
        }
        if launchError != nil { throw HelperError.appLaunchFailed }
    }
}

private enum HelperError: LocalizedError {
    case accessDisabled
    case appBundleNotFound
    case appLaunchFailed
    case launchTimedOut
    case transportStatus(Int32)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .accessDisabled:
            "Local agent access is disabled. Enable it in Aagedal Media Converter Settings."
        case .appBundleNotFound:
            "The MCP helper must run from inside Aagedal Media Converter.app."
        case .appLaunchFailed:
            "Aagedal Media Converter could not be launched."
        case .launchTimedOut:
            "Timed out while launching Aagedal Media Converter."
        case .transportStatus(let status):
            "The connection to Aagedal Media Converter failed with status \(status)."
        case .invalidResponse:
            "Aagedal Media Converter returned an invalid response."
        }
    }
}
