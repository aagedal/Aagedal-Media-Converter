// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

enum SubprocessOutputStream: Sendable {
    case standardOutput
    case standardError
}

struct SubprocessOutputChunk: Sendable {
    let stream: SubprocessOutputStream
    let data: Data
}

/// Backpressured access to a running subprocess's standard input. `write` blocks when the child
/// consumes input more slowly than the producer, so callers can stream large media without first
/// buffering it in memory. `finish` is idempotent and sends EOF to the child.
final class SubprocessStandardInputWriter: @unchecked Sendable {
    private let writeOperation: @Sendable (Data) throws -> Void
    private let finishOperation: @Sendable () -> Void

    init(
        write: @escaping @Sendable (Data) throws -> Void,
        finish: @escaping @Sendable () -> Void
    ) {
        writeOperation = write
        finishOperation = finish
    }

    func write(_ data: Data) throws {
        try writeOperation(data)
    }

    func finish() {
        finishOperation()
    }
}

typealias SubprocessStandardInputProducer = @Sendable (SubprocessStandardInputWriter) async -> Void

enum SubprocessTermination: Sendable, Equatable {
    case exited
    case uncaughtSignal
}

struct SubprocessResult: Sendable, Equatable {
    let terminationStatus: Int32
    let termination: SubprocessTermination
    let standardOutput: Data
    let standardError: Data
    let discardedStandardOutputBytes: Int
    let discardedStandardErrorBytes: Int
    let duration: Duration

    var succeeded: Bool {
        termination == .exited && terminationStatus == 0
    }

    var standardOutputText: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    var standardErrorText: String {
        String(decoding: standardError, as: UTF8.self)
    }
}

enum SubprocessPipelineStageFailure: Sendable, Equatable {
    case cancelled
    case timedOut(result: SubprocessResult)
    case failedToStart(reason: String)
    case connectionClosed(reason: String)
    case failed(reason: String)
}

enum SubprocessPipelineStageOutcome: Sendable, Equatable {
    case completed(SubprocessResult)
    case failed(SubprocessPipelineStageFailure)
    /// The consumer exited before the producer reported a terminal result. The producer is
    /// cancelled without being joined so an uncooperative upstream tool cannot delay return.
    case unfinished
}

struct SubprocessPipelineResult: Sendable, Equatable {
    let producer: SubprocessPipelineStageOutcome
    let consumer: SubprocessResult
}

struct SubprocessRequest: Sendable {
    static let defaultCaptureLimit = 256 * 1024

    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]?
    let currentDirectoryURL: URL?
    let standardInput: Data?
    let timeout: Duration?
    let terminationGracePeriod: Duration
    let standardOutputCaptureLimit: Int
    let standardErrorCaptureLimit: Int
    let sensitiveArgumentNames: Set<String>
    let sensitiveValues: Set<String>
    let redactURLs: Bool

    init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        currentDirectoryURL: URL? = nil,
        standardInput: Data? = nil,
        timeout: Duration? = nil,
        terminationGracePeriod: Duration = .seconds(2),
        standardOutputCaptureLimit: Int = SubprocessRequest.defaultCaptureLimit,
        standardErrorCaptureLimit: Int = SubprocessRequest.defaultCaptureLimit,
        sensitiveArgumentNames: Set<String> = [],
        sensitiveValues: Set<String> = [],
        redactURLs: Bool = true
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.standardInput = standardInput
        self.timeout = timeout
        self.terminationGracePeriod = terminationGracePeriod
        self.standardOutputCaptureLimit = max(standardOutputCaptureLimit, 0)
        self.standardErrorCaptureLimit = max(standardErrorCaptureLimit, 0)
        self.sensitiveArgumentNames = sensitiveArgumentNames
        self.sensitiveValues = sensitiveValues
        self.redactURLs = redactURLs
    }

    /// A log-safe command representation. Callers can add tool-specific option names whose
    /// following value is sensitive; URL arguments are redacted by default.
    var redactedCommandDescription: String {
        var redactNext = false
        let redactedArguments = arguments.map { argument -> String in
            if redactNext {
                redactNext = false
                return "<redacted>"
            }

            if sensitiveValues.contains(argument) {
                return "<redacted>"
            }

            if sensitiveArgumentNames.contains(argument) {
                redactNext = true
                return argument
            }

            for option in sensitiveArgumentNames {
                let prefix = option + "="
                if argument.hasPrefix(prefix) {
                    return prefix + "<redacted>"
                }
            }

            if redactURLs, let url = URL(string: argument), url.scheme != nil {
                return "<url>"
            }
            return argument
        }

        let executableDescription = sensitiveValues.contains(executableURL.path)
            ? "<redacted-executable>"
            : executableURL.path
        return ([executableDescription] + redactedArguments)
            .map(Self.shellQuoted)
            .joined(separator: " ")
    }

    /// Redacts values known to be sensitive for this request, as well as URLs that a
    /// command may echo to stderr. The retained tail is intentionally small enough for
    /// logs and user-facing errors while preserving the most recent diagnostic context.
    func redactedDiagnostic(_ diagnostic: String, limit: Int = 8 * 1024) -> String {
        var redacted = diagnostic
        var redactNext = false

        for value in sensitiveValues.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            redacted = redacted.replacingOccurrences(of: value, with: "<redacted>")
        }

        for argument in arguments {
            if redactNext {
                if !argument.isEmpty {
                    redacted = redacted.replacingOccurrences(of: argument, with: "<redacted>")
                }
                redactNext = false
                continue
            }

            if sensitiveArgumentNames.contains(argument) {
                redactNext = true
                continue
            }

            for option in sensitiveArgumentNames {
                let prefix = option + "="
                if argument.hasPrefix(prefix) {
                    let value = String(argument.dropFirst(prefix.count))
                    if !value.isEmpty {
                        redacted = redacted.replacingOccurrences(of: value, with: "<redacted>")
                    }
                }
            }
        }

        if redactURLs {
            let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            redacted = Self.urlExpression.stringByReplacingMatches(
                in: redacted,
                range: range,
                withTemplate: "<url>"
            )
        }

        guard limit > 0 else { return "" }
        guard redacted.count > limit else { return redacted }
        return "…" + redacted.suffix(limit)
    }

    private static let urlExpression = try! NSRegularExpression(
        pattern: #"(?i)\b[a-z][a-z0-9+.-]*://[^\s<>\"']+"#
    )

    private static func shellQuoted(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safeCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/:"))
        if value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    fileprivate func replacingStandardInput(with data: Data) -> SubprocessRequest {
        SubprocessRequest(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL,
            standardInput: data,
            timeout: timeout,
            terminationGracePeriod: terminationGracePeriod,
            standardOutputCaptureLimit: standardOutputCaptureLimit,
            standardErrorCaptureLimit: standardErrorCaptureLimit,
            sensitiveArgumentNames: sensitiveArgumentNames,
            sensitiveValues: sensitiveValues,
            redactURLs: redactURLs
        )
    }
}

enum SubprocessRunnerError: Error, LocalizedError {
    case failedToStart(command: String, underlying: String)
    case timedOut(command: String, result: SubprocessResult)

    var errorDescription: String? {
        switch self {
        case let .failedToStart(command, underlying):
            return "Failed to start \(command): \(underlying)"
        case let .timedOut(command, _):
            return "Timed out while running \(command)"
        }
    }
}

protocol SubprocessRunning: Sendable {
    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult

    func runWithStreamingStandardInput(
        _ request: SubprocessRequest,
        inputProducer: @escaping SubprocessStandardInputProducer,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult
}

extension SubprocessRunning {
    func run(_ request: SubprocessRequest) async throws -> SubprocessResult {
        try await run(request, outputHandler: nil)
    }

    /// Test doubles and simple runners can use this buffered fallback. The production runner
    /// overrides it so large inputs are written directly to the live child's pipe.
    func runWithStreamingStandardInput(
        _ request: SubprocessRequest,
        inputProducer: @escaping SubprocessStandardInputProducer,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        let collector = BufferedStandardInputCollector()
        let writer = SubprocessStandardInputWriter(
            write: collector.append,
            finish: {}
        )
        await inputProducer(writer)
        try Task.checkCancellation()
        return try await run(
            request.replacingStandardInput(with: collector.snapshot()),
            outputHandler: outputHandler
        )
    }

    /// Runs a backpressured producer-to-consumer pipeline. The consumer is launched first, then
    /// every producer stdout chunk is written directly to its stdin while both stderr streams are
    /// drained by their respective runner invocations. Consumer cancellation or timeout cancels
    /// the producer through the streaming-input task without joining an uncooperative producer.
    func runPipeline(
        producer producerRequest: SubprocessRequest,
        consumer consumerRequest: SubprocessRequest,
        producerOutputHandler: (@Sendable (SubprocessOutputChunk) -> Void)? = nil,
        consumerOutputHandler: (@Sendable (SubprocessOutputChunk) -> Void)? = nil
    ) async throws -> SubprocessPipelineResult {
        precondition(
            consumerRequest.standardInput == nil,
            "A pipeline consumer cannot also provide buffered standard input"
        )

        let producerState = SubprocessPipelineProducerState()
        let consumerResult = try await runWithStreamingStandardInput(
            consumerRequest,
            inputProducer: { standardInput in
                let producerTask = Task {
                    try await self.run(producerRequest) { chunk in
                        if case .standardOutput = chunk.stream {
                            do {
                                try standardInput.write(chunk.data)
                            } catch {
                                producerState.recordConnectionFailureAndCancelProducer(
                                    producerRequest.redactedDiagnostic(error.localizedDescription)
                                )
                            }
                        }
                        producerOutputHandler?(chunk)
                    }
                }
                producerState.installProducerTask(producerTask)
                defer { producerState.clearProducerTask() }
                do {
                    let result = try await withTaskCancellationHandler {
                        try await producerTask.value
                    } onCancel: {
                        producerState.cancelProducer()
                    }
                    producerState.finish(with: .completed(result))
                } catch is CancellationError {
                    producerState.finish(with: .failed(.cancelled))
                } catch SubprocessRunnerError.timedOut(_, let result) {
                    producerState.finish(with: .failed(.timedOut(result: result)))
                } catch SubprocessRunnerError.failedToStart(_, let underlying) {
                    producerState.finish(
                        with: .failed(
                            .failedToStart(
                                reason: producerRequest.redactedDiagnostic(underlying)
                            )
                        )
                    )
                } catch {
                    producerState.finish(
                        with: .failed(
                            .failed(
                                reason: producerRequest.redactedDiagnostic(
                                    error.localizedDescription
                                )
                            )
                        )
                    )
                }
                standardInput.finish()
            },
            outputHandler: consumerOutputHandler
        )

        return SubprocessPipelineResult(
            producer: producerState.snapshot(),
            consumer: consumerResult
        )
    }
}

/// Shared process-launch boundary. It drains both output streams while the child runs,
/// bounds retained diagnostics, participates in Swift task cancellation, and terminates
/// descendants before the direct child so wrapper tools do not leave encoders behind.
final class SubprocessRunner: SubprocessRunning, @unchecked Sendable {
    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)? = nil
    ) async throws -> SubprocessResult {
        try await run(
            request,
            streamingInputProducer: nil,
            outputHandler: outputHandler
        )
    }

    func runWithStreamingStandardInput(
        _ request: SubprocessRequest,
        inputProducer: @escaping SubprocessStandardInputProducer,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)? = nil
    ) async throws -> SubprocessResult {
        precondition(request.standardInput == nil, "Use either buffered or streaming standard input, not both")
        return try await run(
            request,
            streamingInputProducer: inputProducer,
            outputHandler: outputHandler
        )
    }

    private func run(
        _ request: SubprocessRequest,
        streamingInputProducer: SubprocessStandardInputProducer?,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        try Task.checkCancellation()

        let execution = SubprocessExecution(
            request: request,
            hasStreamingStandardInput: streamingInputProducer != nil,
            outputHandler: outputHandler
        )

        return try await withTaskCancellationHandler {
            do {
                try execution.start()
            } catch {
                throw SubprocessRunnerError.failedToStart(
                    command: request.redactedCommandDescription,
                    underlying: error.localizedDescription
                )
            }

            if Task.isCancelled {
                execution.terminate(cause: .cancelled)
            }

            if let streamingInputProducer {
                execution.startStreamingStandardInput(streamingInputProducer)
            }

            let timeoutTask = request.timeout.map { timeout in
                Task {
                    do {
                        try await Task.sleep(for: timeout)
                        execution.terminate(cause: .timedOut)
                    } catch {
                        // Normal when the process exits before its deadline.
                    }
                }
            }

            await execution.waitForExit()
            await execution.stopStreamingStandardInput()
            await execution.waitForTerminationCleanup()
            timeoutTask?.cancel()

            let result = execution.finish()
            switch execution.terminationCause {
            case .cancelled:
                throw CancellationError()
            case .timedOut:
                throw SubprocessRunnerError.timedOut(
                    command: request.redactedCommandDescription,
                    result: result
                )
            case nil:
                return result
            }
        } onCancel: {
            execution.terminate(cause: .cancelled)
        }
    }
}

private enum SubprocessTerminationCause: Sendable {
    case cancelled
    case timedOut
}

private final class SubprocessExecution: @unchecked Sendable {
    private let request: SubprocessRequest
    private let outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    private let process = IsolatedProcess()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe: Pipe?
    private let stdoutCollector: BoundedDataCollector
    private let stderrCollector: BoundedDataCollector
    private let lock = NSLock()
    private let stdoutReadLock = NSLock()
    private let stderrReadLock = NSLock()
    private let startInstant = ContinuousClock.now

    private var hasStarted = false
    private var hasExited = false
    private var pendingTermination = false
    private var terminationStarted = false
    private var cause: SubprocessTerminationCause?
    private var terminationCleanupTask: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var stdoutReadsFinished = false
    private var stderrReadsFinished = false
    private var streamingInputTask: Task<Void, Never>?
    private var streamingInputWriter: SubprocessStandardInputWriter?

    init(
        request: SubprocessRequest,
        hasStreamingStandardInput: Bool,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) {
        self.request = request
        self.outputHandler = outputHandler
        stdinPipe = request.standardInput == nil && !hasStreamingStandardInput ? nil : Pipe()
        stdoutCollector = BoundedDataCollector(limit: request.standardOutputCaptureLimit)
        stderrCollector = BoundedDataCollector(limit: request.standardErrorCaptureLimit)
    }

    var terminationCause: SubprocessTerminationCause? {
        lock.withLock { cause }
    }

    func start() throws {
        installReadabilityHandler(
            on: stdoutPipe.fileHandleForReading,
            stream: .standardOutput,
            collector: stdoutCollector,
            readLock: stdoutReadLock
        )
        installReadabilityHandler(
            on: stderrPipe.fileHandleForReading,
            stream: .standardError,
            collector: stderrCollector,
            readLock: stderrReadLock
        )

        process.terminationHandler = { [weak self] _ in
            self?.didExit()
        }

        do {
            try process.run(
                executableURL: request.executableURL,
                arguments: request.arguments,
                environment: request.environment,
                currentDirectoryURL: request.currentDirectoryURL,
                standardInput: stdinPipe,
                standardOutput: stdoutPipe,
                standardError: stderrPipe
            )
        } catch {
            removeReadabilityHandlers()
            throw error
        }

        // The child inherited duplicates of these descriptors. Closing the parent's writer
        // copies ensures the readers observe EOF as soon as the child exits.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        // Likewise, the parent must not retain a reader for the child's stdin pipe. Otherwise a
        // producer blocked in write may never observe EPIPE after the child exits or is killed.
        if let stdinPipe {
            try? stdinPipe.fileHandleForReading.close()
            _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        }

        let shouldTerminate = lock.withLock { () -> Bool in
            hasStarted = true
            guard pendingTermination, !terminationStarted else { return false }
            terminationStarted = true
            return true
        }

        if let input = request.standardInput, let stdinPipe {
            DispatchQueue.global(qos: .utility).async {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: input)
                try? stdinPipe.fileHandleForWriting.close()
            }
        }

        if shouldTerminate {
            terminateProcessTree()
        }
    }

    func startStreamingStandardInput(_ producer: @escaping SubprocessStandardInputProducer) {
        guard request.standardInput == nil, let stdinPipe else { return }
        let finishGate = StandardInputFinishGate()
        let writer = SubprocessStandardInputWriter(
            write: { data in
                try stdinPipe.fileHandleForWriting.write(contentsOf: data)
            },
            finish: {
                if finishGate.claim() {
                    try? stdinPipe.fileHandleForWriting.close()
                }
            }
        )
        let task = Task.detached(priority: .utility) {
            await producer(writer)
            writer.finish()
        }
        let shouldCancel = lock.withLock { () -> Bool in
            streamingInputWriter = writer
            streamingInputTask = task
            return cause != nil || hasExited
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func stopStreamingStandardInput() async {
        let task = lock.withLock { streamingInputTask }
        task?.cancel()
        // Do not join an arbitrary producer here. Closing or killing the child removes the final
        // read end, so a blocked write returns EPIPE; cooperative producers also see cancellation.
        // A producer that ignores both cannot hold subprocess completion or its timeout hostage.
        lock.withLock {
            streamingInputTask = nil
            streamingInputWriter = nil
        }
    }

    func waitForExit() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                if hasExited {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func terminate(cause newCause: SubprocessTerminationCause) {
        let (shouldTerminate, inputTask) = lock.withLock { () -> (Bool, Task<Void, Never>?) in
            guard !hasExited else { return (false, streamingInputTask) }
            if hasStarted, !process.isRunning {
                return (false, streamingInputTask)
            }
            if cause == nil {
                cause = newCause
            }
            if !hasStarted {
                pendingTermination = true
                return (false, streamingInputTask)
            }
            guard !terminationStarted else { return (false, streamingInputTask) }
            terminationStarted = true
            return (true, streamingInputTask)
        }

        inputTask?.cancel()

        if shouldTerminate {
            terminateProcessTree()
        }
    }

    func finish() -> SubprocessResult {
        removeReadabilityHandlers()

        // Collect bytes that arrived between the last readability callback and termination.
        // A descendant could still hold an inherited pipe open, so the final drain is
        // deliberately nonblocking and cannot strand the caller after the direct child exits.
        stdoutReadLock.withLock {
            stdoutReadsFinished = true
            appendRemainingData(
                from: stdoutPipe.fileHandleForReading,
                stream: .standardOutput,
                to: stdoutCollector
            )
        }
        stderrReadLock.withLock {
            stderrReadsFinished = true
            appendRemainingData(
                from: stderrPipe.fileHandleForReading,
                stream: .standardError,
                to: stderrCollector
            )
        }
        let stdout = stdoutCollector.snapshot()
        let stderr = stderrCollector.snapshot()
        let reason = process.termination
        return SubprocessResult(
            terminationStatus: process.terminationStatus,
            termination: reason,
            standardOutput: stdout.data,
            standardError: stderr.data,
            discardedStandardOutputBytes: stdout.discardedByteCount,
            discardedStandardErrorBytes: stderr.discardedByteCount,
            duration: startInstant.duration(to: .now)
        )
    }

    private func installReadabilityHandler(
        on handle: FileHandle,
        stream: SubprocessOutputStream,
        collector: BoundedDataCollector,
        readLock: NSLock
    ) {
        handle.readabilityHandler = { [outputHandler] fileHandle in
            readLock.withLock {
                switch stream {
                case .standardOutput where self.stdoutReadsFinished:
                    return
                case .standardError where self.stderrReadsFinished:
                    return
                default:
                    break
                }

                let data = fileHandle.availableData
                guard !data.isEmpty else { return }
                collector.append(data)
                outputHandler?(SubprocessOutputChunk(stream: stream, data: data))
            }
        }
    }

    private func removeReadabilityHandlers() {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    private func appendRemainingData(
        from handle: FileHandle,
        stream: SubprocessOutputStream,
        to collector: BoundedDataCollector
    ) {
        let descriptor = handle.fileDescriptor
        let currentFlags = fcntl(descriptor, F_GETFL)
        if currentFlags >= 0 {
            _ = fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK)
        }

        while true {
            do {
                guard let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty else {
                    break
                }
                collector.append(data)
                outputHandler?(SubprocessOutputChunk(stream: stream, data: data))
            } catch {
                break
            }
        }
        try? handle.close()
    }

    private func didExit() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !hasExited else { return [] }
            hasExited = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func terminateProcessTree() {
        guard process.isRunning else { return }
        let gracePeriod = request.terminationGracePeriod
        let cleanupTask = Task.detached(priority: .utility) { [process] in
            do {
                try await Task.sleep(for: gracePeriod)
            } catch {
                return
            }

            process.terminateProcessGroup(with: SIGKILL)
        }
        lock.withLock {
            terminationCleanupTask = cleanupTask
        }

        process.terminate()
    }

    func waitForTerminationCleanup() async {
        let cleanupTask = lock.withLock { terminationCleanupTask }
        if let cleanupTask {
            await cleanupTask.value
        }
    }

}

/// Minimal `posix_spawn` wrapper that atomically places each launched tool in a new process group.
/// Group signaling is race-free for ordinary descendants: processes forked after cancellation or
/// reparented after a wrapper exits remain members until they explicitly leave the group.
private final class IsolatedProcess: @unchecked Sendable {
    typealias TerminationHandler = @Sendable (IsolatedProcess) -> Void

    private let lock = NSLock()
    private var processID: pid_t = 0
    private var running = false
    private var status: Int32 = 0
    private var reason: SubprocessTermination = .exited

    var terminationHandler: TerminationHandler?

    var isRunning: Bool {
        lock.withLock { running }
    }

    var terminationStatus: Int32 {
        lock.withLock { status }
    }

    var termination: SubprocessTermination {
        lock.withLock { reason }
    }

    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        currentDirectoryURL: URL?,
        standardInput: Pipe?,
        standardOutput: Pipe,
        standardError: Pipe
    ) throws {
        var fileActions: posix_spawn_file_actions_t?
        try Self.check(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        var attributes: posix_spawnattr_t?
        try Self.check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }

        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        try Self.check(posix_spawnattr_setsigmask(&attributes, &signalMask))
        try Self.check(
            posix_spawnattr_setflags(
                &attributes,
                Int16(
                    POSIX_SPAWN_SETPGROUP
                        | POSIX_SPAWN_SETSIGMASK
                        | POSIX_SPAWN_CLOEXEC_DEFAULT
                )
            )
        )
        // A zero pgroup asks posix_spawn to use the child's PID as its process-group ID.
        try Self.check(posix_spawnattr_setpgroup(&attributes, 0))

        if let currentDirectoryURL {
            try currentDirectoryURL.withUnsafeFileSystemRepresentation { path in
                guard let path else { throw POSIXError(.EINVAL) }
                if #available(macOS 26.0, *) {
                    try Self.check(posix_spawn_file_actions_addchdir(&fileActions, path))
                } else {
                    try Self.check(posix_spawn_file_actions_addchdir_np(&fileActions, path))
                }
            }
        }

        if let standardInput {
            try Self.addPipe(
                standardInput,
                childDescriptor: STDIN_FILENO,
                childUsesReadEnd: true,
                actions: &fileActions
            )
        } else {
            try Self.check(
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDIN_FILENO,
                    "/dev/null",
                    O_RDONLY,
                    0
                )
            )
        }
        try Self.addPipe(
            standardOutput,
            childDescriptor: STDOUT_FILENO,
            childUsesReadEnd: false,
            actions: &fileActions
        )
        try Self.addPipe(
            standardError,
            childDescriptor: STDERR_FILENO,
            childUsesReadEnd: false,
            actions: &fileActions
        )

        let argumentStorage = ([executableURL.path] + arguments).map { strdup($0) }
        guard argumentStorage.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        defer { argumentStorage.forEach { free($0) } }
        var argumentVector = argumentStorage.map { $0.map(UnsafeMutablePointer.init) }
        argumentVector.append(nil)

        let environmentValues = environment ?? ProcessInfo.processInfo.environment
        let environmentStorage = environmentValues.map { strdup("\($0.key)=\($0.value)") }
        guard environmentStorage.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        defer { environmentStorage.forEach { free($0) } }
        var environmentVector = environmentStorage.map { $0.map(UnsafeMutablePointer.init) }
        environmentVector.append(nil)

        var spawnedPID: pid_t = 0
        let spawnResult = executableURL.withUnsafeFileSystemRepresentation { executablePath in
            guard let executablePath else { return EINVAL }
            return posix_spawn(
                &spawnedPID,
                executablePath,
                &fileActions,
                &attributes,
                &argumentVector,
                &environmentVector
            )
        }
        try Self.check(spawnResult)

        lock.withLock {
            processID = spawnedPID
            running = true
        }
        let processIDToWaitFor = spawnedPID
        DispatchQueue.global(qos: .utility).async { [self] in
            waitForTermination(of: processIDToWaitFor)
        }
    }

    func terminate() {
        terminateProcessGroup(with: SIGTERM)
    }

    func terminateProcessGroup(with signal: Int32) {
        let groupID = lock.withLock { processID }
        guard groupID > 0 else { return }
        _ = Darwin.kill(-groupID, signal)
    }

    private func waitForTermination(of spawnedPID: pid_t) {
        var waitStatus: Int32 = 0
        var result: pid_t
        repeat {
            result = Darwin.waitpid(spawnedPID, &waitStatus, 0)
        } while result == -1 && errno == EINTR

        let handler = lock.withLock { () -> TerminationHandler? in
            guard running else { return nil }
            running = false
            if result == spawnedPID {
                let terminatingSignal = waitStatus & 0x7f
                if terminatingSignal == 0 {
                    status = (waitStatus >> 8) & 0xff
                    reason = .exited
                } else {
                    status = terminatingSignal
                    reason = .uncaughtSignal
                }
            } else {
                status = -1
                reason = .uncaughtSignal
            }
            return terminationHandler
        }
        handler?(self)
    }

    private static func addPipe(
        _ pipe: Pipe,
        childDescriptor: Int32,
        childUsesReadEnd: Bool,
        actions: inout posix_spawn_file_actions_t?
    ) throws {
        let readDescriptor = pipe.fileHandleForReading.fileDescriptor
        let writeDescriptor = pipe.fileHandleForWriting.fileDescriptor
        let sourceDescriptor = childUsesReadEnd ? readDescriptor : writeDescriptor
        try check(posix_spawn_file_actions_adddup2(&actions, sourceDescriptor, childDescriptor))
        if readDescriptor != childDescriptor {
            try check(posix_spawn_file_actions_addclose(&actions, readDescriptor))
        }
        if writeDescriptor != childDescriptor {
            try check(posix_spawn_file_actions_addclose(&actions, writeDescriptor))
        }
    }

    private static func check(_ result: Int32) throws {
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL)
        }
    }
}

private final class BoundedDataCollector: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var discardedByteCount = 0

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ newData: Data) {
        lock.withLock {
            guard limit > 0 else {
                discardedByteCount += newData.count
                return
            }

            data.append(newData)
            if data.count > limit {
                let excess = data.count - limit
                data.removeFirst(excess)
                discardedByteCount += excess
            }
        }
    }

    func snapshot() -> (data: Data, discardedByteCount: Int) {
        lock.withLock { (data, discardedByteCount) }
    }
}

private final class BufferedStandardInputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        lock.withLock {
            data.append(newData)
        }
    }

    func snapshot() -> Data {
        lock.withLock { data }
    }
}

private final class StandardInputFinishGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false

    func claim() -> Bool {
        lock.withLock {
            guard !isFinished else { return false }
            isFinished = true
            return true
        }
    }
}

private final class SubprocessPipelineProducerState: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: SubprocessPipelineStageOutcome?
    private var connectionFailure: String?
    private var producerTask: Task<SubprocessResult, Error>?
    private var producerCancellationRequested = false

    func installProducerTask(_ task: Task<SubprocessResult, Error>) {
        let shouldCancel = lock.withLock { () -> Bool in
            producerTask = task
            return producerCancellationRequested
        }
        if shouldCancel {
            task.cancel()
        }
    }

    func clearProducerTask() {
        lock.withLock {
            producerTask = nil
        }
    }

    func cancelProducer() {
        let task = lock.withLock { () -> Task<SubprocessResult, Error>? in
            producerCancellationRequested = true
            return producerTask
        }
        task?.cancel()
    }

    func recordConnectionFailureAndCancelProducer(_ reason: String) {
        let task = lock.withLock { () -> Task<SubprocessResult, Error>? in
            if connectionFailure == nil {
                connectionFailure = reason
            }
            producerCancellationRequested = true
            return producerTask
        }
        task?.cancel()
    }

    func finish(with outcome: SubprocessPipelineStageOutcome) {
        lock.withLock {
            guard self.outcome == nil else { return }
            self.outcome = outcome
        }
    }

    func snapshot() -> SubprocessPipelineStageOutcome {
        lock.withLock {
            if let connectionFailure {
                return .failed(.connectionClosed(reason: connectionFailure))
            }
            return outcome ?? .unfinished
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
