// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreFoundation
import Foundation

enum ApplicationAgentToolName: String, CaseIterable, Codable, Sendable {
    case inspectMedia = "inspect_media"
    case listMedia = "list_media"
    case listPresets = "list_presets"
    case listJobs = "list_jobs"
    case getAppStatus = "get_app_status"
    case planConversion = "plan_conversion"
    case getPlan = "get_plan"
    case submitConversion = "submit_conversion"
    case getJob = "get_job"
    case waitForJob = "wait_for_job"
    case cancelJob = "cancel_job"
}

/// JSON values shared by the MCP adapter and the app without exposing raw probe
/// output or coupling the helper executable to the app target's Swift module.
enum ApplicationAgentJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: Self].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "The value is not valid JSON."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    init<T: Encodable>(encoding value: T) throws {
        self = try JSONDecoder().decode(Self.self, from: JSONEncoder.applicationAgent.encode(value))
    }
}

struct ApplicationAgentIPCRequest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let requestID: UUID
    let tool: ApplicationAgentToolName
    let arguments: [String: ApplicationAgentJSONValue]

    init(
        schemaVersion: Int = currentSchemaVersion,
        requestID: UUID = UUID(),
        tool: ApplicationAgentToolName,
        arguments: [String: ApplicationAgentJSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.tool = tool
        self.arguments = arguments
    }
}

struct ApplicationAgentIPCResponse: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let requestID: UUID
    let result: ApplicationAgentJSONValue?
    let failure: ApplicationAgentToolFailure?

    static func success<T: Encodable>(
        requestID: UUID,
        value: T
    ) throws -> Self {
        Self(
            schemaVersion: currentSchemaVersion,
            requestID: requestID,
            result: try ApplicationAgentJSONValue(encoding: value),
            failure: nil
        )
    }

    static func failed(
        requestID: UUID,
        code: ApplicationJobErrorCode,
        message: String
    ) -> Self {
        Self(
            schemaVersion: currentSchemaVersion,
            requestID: requestID,
            result: nil,
            failure: ApplicationAgentToolFailure(code: code, message: message)
        )
    }
}

struct ApplicationAgentRequestDispatcher: Sendable {
    private let tools: ApplicationAgentTools

    init(tools: ApplicationAgentTools = .shared) {
        self.tools = tools
    }

    func response(to request: ApplicationAgentIPCRequest) async -> ApplicationAgentIPCResponse {
        guard request.schemaVersion == ApplicationAgentIPCRequest.currentSchemaVersion else {
            return .failed(
                requestID: request.requestID,
                code: .unsupportedSchema,
                message: "IPC schema version \(request.schemaVersion) is not supported."
            )
        }

        do {
            switch request.tool {
            case .inspectMedia:
                try request.arguments.validateKeys(["source_path"])
                let sourceURL = try request.arguments.requiredFileURL(named: "source_path")
                return try .success(
                    requestID: request.requestID,
                    value: await tools.inspectMedia(at: sourceURL)
                )

            case .listMedia:
                try request.arguments.validateKeys(["folder_path", "name_contains", "extensions", "offset", "limit"])
                let folderURL = try request.arguments.optionalString(named: "folder_path")
                    .map { try Self.fileURL(path: $0, argument: "folder_path") }
                return try .success(
                    requestID: request.requestID,
                    value: try tools.listMedia(
                        folderURL: folderURL,
                        nameContains: try request.arguments.optionalString(named: "name_contains"),
                        extensions: try request.arguments.optionalStringArray(named: "extensions"),
                        offset: try request.arguments.optionalInteger(named: "offset") ?? 0,
                        limit: try request.arguments.optionalInteger(named: "limit") ?? 100
                    )
                )

            case .listPresets:
                try request.arguments.validateKeys([])
                return try .success(requestID: request.requestID, value: tools.listPresets())

            case .listJobs:
                try request.arguments.validateKeys(["offset", "limit"])
                let offset = try request.arguments.optionalInteger(named: "offset") ?? 0
                let limit = try request.arguments.optionalInteger(named: "limit") ?? 100
                return try .success(
                    requestID: request.requestID,
                    value: await tools.listJobs(offset: offset, limit: limit)
                )

            case .getAppStatus:
                try request.arguments.validateKeys([])
                return try .success(
                    requestID: request.requestID,
                    value: await tools.getAppStatus()
                )

            case .planConversion:
                try request.arguments.validateKeys([
                    "source_paths", "destination_path", "preset_id", "request_id",
                    "requester_id", "idempotency_key"
                ])
                let sourceURLs = try request.arguments.requiredStringArray(named: "source_paths")
                    .map { try Self.fileURL(path: $0, argument: "source_paths") }
                let destinationURL = try request.arguments.optionalString(named: "destination_path")
                    .map { try Self.fileURL(path: $0, argument: "destination_path") }
                let presetRaw = try request.arguments.requiredString(named: "preset_id")
                guard let presetID = ApplicationPresetID(rawValue: presetRaw) else {
                    throw ApplicationAgentTransportError.invalidArguments(
                        "preset_id must name one of the presets returned by list_presets."
                    )
                }
                let requestID = try request.arguments.optionalUUID(named: "request_id") ?? UUID()
                let input = ApplicationPlanConversionInput(
                    requestID: requestID,
                    requesterID: try request.arguments.requiredString(named: "requester_id"),
                    sourceURLs: sourceURLs,
                    destinationFolderURL: destinationURL,
                    presetID: presetID,
                    idempotencyKey: try request.arguments.optionalString(named: "idempotency_key")
                )
                return try .success(
                    requestID: request.requestID,
                    value: await tools.planConversion(input)
                )

            case .getPlan:
                try request.arguments.validateKeys(["plan_id"])
                let planID = try ApplicationPlanID(
                    request.arguments.requiredUUID(named: "plan_id")
                )
                return try .success(
                    requestID: request.requestID,
                    value: await tools.getPlan(planID: planID)
                )

            case .submitConversion:
                try request.arguments.validateKeys(["plan_id"])
                let planID = try ApplicationPlanID(
                    request.arguments.requiredUUID(named: "plan_id")
                )
                return try .success(
                    requestID: request.requestID,
                    value: await tools.submitConversion(planID: planID)
                )

            case .getJob:
                try request.arguments.validateKeys(["job_id"])
                let jobID = try ApplicationJobID(
                    request.arguments.requiredUUID(named: "job_id")
                )
                return try .success(
                    requestID: request.requestID,
                    value: await tools.getJobForAgent(jobID: jobID)
                )

            case .waitForJob:
                try request.arguments.validateKeys(["job_id", "known_state", "timeout_seconds"])
                let jobID = try ApplicationJobID(
                    request.arguments.requiredUUID(named: "job_id")
                )
                let knownState: ApplicationJobState?
                if let raw = try request.arguments.optionalString(named: "known_state") {
                    guard let parsed = ApplicationJobState(rawValue: raw) else {
                        throw ApplicationAgentTransportError.invalidArguments(
                            "known_state must be a job state returned by get_job."
                        )
                    }
                    knownState = parsed
                } else {
                    knownState = nil
                }
                let timeout = try request.arguments.optionalInteger(named: "timeout_seconds") ?? 30
                return try .success(
                    requestID: request.requestID,
                    value: await tools.waitForJob(
                        jobID: jobID, knownState: knownState, timeoutSeconds: timeout
                    )
                )

            case .cancelJob:
                try request.arguments.validateKeys(["job_id"])
                let jobID = try ApplicationJobID(
                    request.arguments.requiredUUID(named: "job_id")
                )
                return try .success(
                    requestID: request.requestID,
                    value: await tools.cancelJob(jobID: jobID)
                )
            }
        } catch let error as ApplicationAgentTransportError {
            return .failed(
                requestID: request.requestID,
                code: .invalidArguments,
                message: error.localizedDescription
            )
        } catch {
            let failure = ApplicationAgentToolFailure(error: error)
            return .failed(
                requestID: request.requestID,
                code: failure.code,
                message: failure.message
            )
        }
    }

    private static func fileURL(path: String, argument: String) throws -> URL {
        guard NSString(string: path).isAbsolutePath else {
            throw ApplicationAgentTransportError.invalidArguments(
                "\(argument) must contain absolute local paths."
            )
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}

enum ApplicationAgentTransportError: LocalizedError, Equatable, Sendable {
    case invalidArguments(String)
    case portUnavailable
    case sendFailed(Int32)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): message
        case .portUnavailable: "Local agent access is disabled or the app is unavailable."
        case .sendFailed(let status): "The app transport failed with status \(status)."
        case .invalidResponse: "The app returned an invalid transport response."
        }
    }
}

extension Dictionary where Key == String, Value == ApplicationAgentJSONValue {
    fileprivate func validateKeys(_ allowedKeys: Set<String>) throws {
        let unexpectedKeys = Set(keys).subtracting(allowedKeys)
        guard unexpectedKeys.isEmpty else {
            throw ApplicationAgentTransportError.invalidArguments(
                "Unexpected argument: \(unexpectedKeys.sorted().joined(separator: ", "))."
            )
        }
    }

    fileprivate func requiredString(named name: String) throws -> String {
        guard case .string(let value)? = self[name], !value.isEmpty else {
            throw ApplicationAgentTransportError.invalidArguments(
                "\(name) must be a non-empty string."
            )
        }
        return value
    }

    fileprivate func optionalString(named name: String) throws -> String? {
        guard let value = self[name] else { return nil }
        guard case .string(let string) = value, !string.isEmpty else {
            throw ApplicationAgentTransportError.invalidArguments(
                "\(name) must be a non-empty string when supplied."
            )
        }
        return string
    }

    fileprivate func optionalInteger(named name: String) throws -> Int? {
        guard let value = self[name] else { return nil }
        guard case .integer(let integer) = value, let result = Int(exactly: integer) else {
            throw ApplicationAgentTransportError.invalidArguments(
                "\(name) must be an integer."
            )
        }
        return result
    }

    fileprivate func requiredStringArray(named name: String) throws -> [String] {
        guard case .array(let values)? = self[name], !values.isEmpty else {
            throw ApplicationAgentTransportError.invalidArguments(
                "\(name) must be a non-empty array of strings."
            )
        }
        return try values.map { value in
            guard case .string(let string) = value, !string.isEmpty else {
                throw ApplicationAgentTransportError.invalidArguments(
                    "\(name) must contain only non-empty strings."
                )
            }
            return string
        }
    }

    fileprivate func optionalStringArray(named name: String) throws -> [String]? {
        guard let value = self[name] else { return nil }
        guard case .array(let values) = value else {
            throw ApplicationAgentTransportError.invalidArguments("\(name) must be an array of strings.")
        }
        return try values.map { value in
            guard case .string(let string) = value, !string.isEmpty else {
                throw ApplicationAgentTransportError.invalidArguments("\(name) must contain only non-empty strings.")
            }
            return string
        }
    }

    fileprivate func requiredFileURL(named name: String) throws -> URL {
        let path = try requiredString(named: name)
        guard NSString(string: path).isAbsolutePath else {
            throw ApplicationAgentTransportError.invalidArguments(
                "\(name) must be an absolute local path."
            )
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    fileprivate func requiredUUID(named name: String) throws -> UUID {
        guard let value = try optionalUUID(named: name) else {
            throw ApplicationAgentTransportError.invalidArguments(
                "\(name) must be a UUID string."
            )
        }
        return value
    }

    fileprivate func optionalUUID(named name: String) throws -> UUID? {
        guard let value = self[name] else { return nil }
        guard case .string(let rawValue) = value, let uuid = UUID(uuidString: rawValue) else {
            throw ApplicationAgentTransportError.invalidArguments(
                "\(name) must be a UUID string."
            )
        }
        return uuid
    }
}

extension JSONEncoder {
    fileprivate static var applicationAgent: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var applicationAgent: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Serializes startup and Settings changes. A delayed startup must re-read the
/// current opt-in preference rather than reopen an endpoint the user disabled.
actor ApplicationAgentAccessLifecycle {
    static let shared = ApplicationAgentAccessLifecycle(
        isEnabled: { UserDefaults.standard.bool(forKey: AppConstants.localAgentAccessEnabledKey) },
        start: { try ApplicationAgentIPCServer.shared.start() },
        stop: { ApplicationAgentIPCServer.shared.stop() }
    )

    private let isEnabled: @Sendable () -> Bool
    private let start: @Sendable () throws -> Void
    private let stop: @Sendable () -> Void

    init(
        isEnabled: @escaping @Sendable () -> Bool,
        start: @escaping @Sendable () throws -> Void,
        stop: @escaping @Sendable () -> Void
    ) {
        self.isEnabled = isEnabled
        self.start = start
        self.stop = stop
    }

    @discardableResult
    func reconcile() throws -> Bool {
        guard isEnabled() else {
            stop()
            return false
        }
        do {
            try start()
        } catch {
            if !isEnabled() { stop() }
            throw error
        }
        // The preference can change while the server's run loop is starting.
        guard isEnabled() else {
            stop()
            return false
        }
        return true
    }
}

/// The app-side endpoint for the bundled stdio helper. CFMessagePort keeps the
/// prototype runtime-free and scoped to the logged-in user's launch session.
/// The opt-in preference controls whether the endpoint exists at all.
final class ApplicationAgentIPCServer: @unchecked Sendable {
    static let defaultPortName = "com.aagedal.Aagedal-Media-Converter.agent.v1"
    static var runtimePortName: String {
#if DEBUG
        if let identifier = ProcessInfo.processInfo.environment["AMC_UI_TEST_AGENT_PORT_ID"],
           UUID(uuidString: identifier) != nil {
            return "com.aagedal.tests.agent.\(identifier)"
        }
#endif
        return defaultPortName
    }
    static let shared = ApplicationAgentIPCServer(portName: runtimePortName)

    private let portName: String
    private let dispatcher: ApplicationAgentRequestDispatcher
    private let lock = NSLock()
    private let serverQueue = DispatchQueue(label: "com.aagedal.media-converter.agent-ipc")
    private let serverLifetime = DispatchGroup()
    private var port: CFMessagePort?
    private var runLoop: CFRunLoop?
    private var isStarting = false

    init(
        portName: String = ApplicationAgentIPCServer.defaultPortName,
        dispatcher: ApplicationAgentRequestDispatcher = ApplicationAgentRequestDispatcher()
    ) {
        self.portName = portName
        self.dispatcher = dispatcher
    }

    var isRunning: Bool {
        lock.withLock { port.map(CFMessagePortIsValid) ?? false }
    }

    func start() throws {
        let action = lock.withLock {
            if let port, CFMessagePortIsValid(port) {
                return ApplicationAgentServerStartAction.alreadyRunning
            }
            guard !isStarting else {
                return ApplicationAgentServerStartAction.waitForPreviousLifetime
            }
            isStarting = true
            serverLifetime.enter()
            return ApplicationAgentServerStartAction.start
        }
        switch action {
        case .alreadyRunning:
            return
        case .waitForPreviousLifetime:
            if serverLifetime.wait(timeout: .now() + 2) == .success {
                try start()
                return
            }
            if isRunning { return }
            throw ApplicationAgentTransportError.portUnavailable
        case .start:
            break
        }

        let ready = DispatchSemaphore(value: 0)
        let result = ApplicationAgentLockedResult<Result<Void, Error>>()
        serverQueue.async { [self] in
            defer {
                lock.withLock {
                    port = nil
                    runLoop = nil
                    isStarting = false
                }
                serverLifetime.leave()
            }
            var context = CFMessagePortContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            var shouldFreeInfo = DarwinBoolean(false)
            guard let localPort = CFMessagePortCreateLocal(
                nil,
                portName as CFString,
                applicationAgentMessagePortCallback,
                &context,
                &shouldFreeInfo
            ) else {
                result.store(.failure(ApplicationAgentTransportError.portUnavailable))
                ready.signal()
                return
            }
            let currentRunLoop = CFRunLoopGetCurrent()
            lock.withLock {
                port = localPort
                runLoop = currentRunLoop
            }
            let source = CFMessagePortCreateRunLoopSource(nil, localPort, 0)
            CFRunLoopAddSource(currentRunLoop, source, .defaultMode)
            result.store(.success(()))
            ready.signal()
            CFRunLoopRun()
            CFMessagePortInvalidate(localPort)
        }

        guard ready.wait(timeout: .now() + 2) == .success,
              let startResult = result.value else {
            throw ApplicationAgentTransportError.portUnavailable
        }
        try startResult.get()
    }

    func stop() {
        let state = lock.withLock { (port, runLoop) }
        if let port = state.0 { CFMessagePortInvalidate(port) }
        if let runLoop = state.1 { CFRunLoopStop(runLoop) }
        _ = serverLifetime.wait(timeout: .now() + 2)
    }

    fileprivate func responseData(for data: Data) -> Data {
        let requestID = (try? JSONDecoder.applicationAgent.decode(
            ApplicationAgentIPCRequest.self,
            from: data
        ).requestID) ?? UUID()
        do {
            let request = try JSONDecoder.applicationAgent.decode(
                ApplicationAgentIPCRequest.self,
                from: data
            )
            let response = awaitResponse(to: request)
            return try JSONEncoder.applicationAgent.encode(response)
        } catch {
            let response = ApplicationAgentIPCResponse.failed(
                requestID: requestID,
                code: .invalidArguments,
                message: "The helper sent an invalid IPC request."
            )
            return (try? JSONEncoder.applicationAgent.encode(response)) ?? Data()
        }
    }

    private func awaitResponse(to request: ApplicationAgentIPCRequest) -> ApplicationAgentIPCResponse {
        let completion = DispatchSemaphore(value: 0)
        let result = ApplicationAgentLockedResult<ApplicationAgentIPCResponse>()
        Task { [dispatcher] in
            result.store(await dispatcher.response(to: request))
            completion.signal()
        }
        completion.wait()
        return result.value ?? .failed(
            requestID: request.requestID,
            code: .internalError,
            message: "The app did not produce a transport response."
        )
    }
}

private enum ApplicationAgentServerStartAction {
    case alreadyRunning
    case waitForPreviousLifetime
    case start
}

private func applicationAgentMessagePortCallback(
    _ local: CFMessagePort?,
    _ messageID: Int32,
    _ data: CFData?,
    _ info: UnsafeMutableRawPointer?
) -> Unmanaged<CFData>? {
    guard messageID == 0, let data, let info else { return nil }
    let server = Unmanaged<ApplicationAgentIPCServer>.fromOpaque(info).takeUnretainedValue()
    let response = server.responseData(for: data as Data)
    return Unmanaged.passRetained(response as CFData)
}

private final class ApplicationAgentLockedResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value?

    var value: Value? {
        lock.withLock { storedValue }
    }

    func store(_ value: Value) {
        lock.withLock { storedValue = value }
    }
}

struct ApplicationAgentIPCClient: Sendable {
    let portName: String

    init(portName: String = ApplicationAgentIPCServer.runtimePortName) {
        self.portName = portName
    }

    func send(
        _ request: ApplicationAgentIPCRequest,
        sendTimeout: TimeInterval = 5,
        receiveTimeout: TimeInterval = 300
    ) throws -> ApplicationAgentIPCResponse {
        guard let remote = CFMessagePortCreateRemote(nil, portName as CFString) else {
            throw ApplicationAgentTransportError.portUnavailable
        }
        let requestData = try JSONEncoder.applicationAgent.encode(request)
        var responseData: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(
            remote,
            0,
            requestData as CFData,
            sendTimeout,
            receiveTimeout,
            CFRunLoopMode.defaultMode.rawValue,
            &responseData
        )
        guard status == kCFMessagePortSuccess else {
            throw ApplicationAgentTransportError.sendFailed(status)
        }
        guard let responseData else { throw ApplicationAgentTransportError.invalidResponse }
        let response = try JSONDecoder.applicationAgent.decode(
            ApplicationAgentIPCResponse.self,
            from: responseData.takeRetainedValue() as Data
        )
        guard response.requestID == request.requestID,
              response.schemaVersion == ApplicationAgentIPCResponse.currentSchemaVersion,
              (response.result == nil) != (response.failure == nil) else {
            throw ApplicationAgentTransportError.invalidResponse
        }
        return response
    }
}
