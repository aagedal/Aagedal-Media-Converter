import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class ToolDiagnosticsTests: XCTestCase {
    func testArchitectureHeadersAndMalformedUniversalCounts() {
        XCTAssertEqual(ToolDiagnostics.architecture(header: Data([0xcf, 0xfa, 0xed, 0xfe, 12, 0, 0, 1])), "arm64")
        XCTAssertEqual(ToolDiagnostics.architecture(header: Data([0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1])), "x86_64")
        var universal: [UInt8] = [0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 2]
        universal += [1, 0, 0, 12] + Array(repeating: 0, count: 16)
        universal += [1, 0, 0, 7] + Array(repeating: 0, count: 16)
        XCTAssertEqual(ToolDiagnostics.architecture(header: Data(universal)), "arm64, x86_64")
        universal[7] = 255
        XCTAssertEqual(ToolDiagnostics.architecture(header: Data(universal)), String(localized: "Unknown"))
        XCTAssertEqual(ToolDiagnostics.architecture(header: Data([0x23, 0x21])), String(localized: "Script (interpreter-dependent)"))
        XCTAssertEqual(ToolDiagnostics.architecture(header: Data()), String(localized: "Unknown"))
    }

    func testMissingAndNonExecutableToolsDoNotLaunch() async throws {
        let runner = DiagnosticRunner(output: "unused")
        let diagnostics = ToolDiagnostics(runner: runner)
        let missing = try await diagnostics.check(id: "test", name: "Test", path: nil)
        XCTAssertFalse(missing.executable)
        XCTAssertNotNil(missing.failure)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let directoryResult = try await diagnostics.check(id: "directory", name: "Directory", path: directory.path, arguments: nil)
        XCTAssertFalse(directoryResult.executable)
        XCTAssertNotNil(directoryResult.failure)
        let file = directory.appendingPathComponent("tool")
        try Data("tool".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let nonExecutable = try await diagnostics.check(id: "test", name: "Test", path: file.path)
        XCTAssertFalse(nonExecutable.executable)
        let requests = await runner.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testSuccessfulProbeIsBoundedAndUsesFirstVersionLine() async throws {
        let runner = DiagnosticRunner(output: "Tool 1.0\nBuild details\n")
        let result = try await ToolDiagnostics(runner: runner).check(id: "tool", name: "Tool", path: "/usr/bin/true")
        XCTAssertEqual(result.version, "Tool 1.0")
        XCTAssertNil(result.failure)
        let requests = await runner.requests
        XCTAssertEqual(requests.first?.timeout, .seconds(5))
        XCTAssertEqual(requests.first?.standardOutputCaptureLimit, 16 * 1024)
        XCTAssertEqual(requests.first?.standardErrorCaptureLimit, 16 * 1024)
    }

    func testNonzeroAndTruncatedOutputNeverAppearSuccessful() async throws {
        for runner in [DiagnosticRunner(output: "misleading version", status: 1),
                       DiagnosticRunner(output: "partial version", discarded: 10)] {
            let result = try await ToolDiagnostics(runner: runner).check(id: "tool", name: "Tool", path: "/usr/bin/true")
            XCTAssertNil(result.version)
            XCTAssertNotNil(result.failure)
        }
    }

    func testLaunchFailureAndTimeoutHaveDistinctRecoveryMessages() async throws {
        let launch = try await ToolDiagnostics(runner: DiagnosticRunner(output: "", failure: "launch"))
            .check(id: "tool", name: "Tool", path: "/usr/bin/true")
        let timeout = try await ToolDiagnostics(runner: DiagnosticRunner(output: "", failure: "timeout"))
            .check(id: "tool", name: "Tool", path: "/usr/bin/true")
        XCTAssertEqual(launch.failure, String(localized: "The tool could not be launched. Check its architecture, permissions, interpreter, and dependencies."))
        XCTAssertEqual(timeout.failure, String(localized: "The tool could not complete its version check within five seconds. Check its permissions and dependencies."))
        XCTAssertNil(launch.version)
        XCTAssertNil(timeout.version)
    }

    func testAvailabilityOnlyProbeDoesNotLaunchOrClaimVersionValidation() async throws {
        let runner = DiagnosticRunner(output: "must not launch")
        let diagnostics = ToolDiagnostics(runner: runner)
        let available = try await diagnostics.check(id: "avmenc", name: "AV2 encoder",
                                                     path: "/usr/bin/true", arguments: nil)
        XCTAssertTrue(available.executable)
        XCTAssertNil(available.version)
        XCTAssertNil(available.failure)
        XCTAssertNotNil(available.note)
        let missing = try await diagnostics.check(id: "avmenc", name: "AV2 encoder",
                                                   path: nil, arguments: nil)
        XCTAssertFalse(missing.executable)
        XCTAssertNotNil(missing.failure)
        XCTAssertNil(missing.note)
        let requests = await runner.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testHelperChecksUseOnlyVerifiedVersionFlags() {
        let checks = ToolDiagnostics.helperChecks
        XCTAssertEqual(Set(checks.map(\.id)),
                       Set(["bmxtranswrap", "mxf2raw", "raw2bmx", "asdcp-wrap", "avmenc", "avmdec", "parakeet"]))
        for check in checks {
            switch check.id {
            case "bmxtranswrap", "mxf2raw", "raw2bmx": XCTAssertEqual(check.arguments, ["--version"])
            case "asdcp-wrap": XCTAssertEqual(check.arguments, ["-V"])
            default: XCTAssertNil(check.arguments)
            }
        }
    }

    func testCancellationDoesNotBecomeToolFailure() async throws {
        let runner = DiagnosticRunner(output: "", cancel: true)
        do {
            _ = try await ToolDiagnostics(runner: runner).check(id: "tool", name: "Tool", path: "/usr/bin/true")
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
    }
}

private actor DiagnosticRunner: SubprocessRunning {
    let output: String
    let status: Int32
    let discarded: Int
    let cancel: Bool
    let failure: String?
    var requests: [SubprocessRequest] = []

    init(output: String, status: Int32 = 0, discarded: Int = 0, cancel: Bool = false, failure: String? = nil) {
        self.output = output
        self.status = status
        self.discarded = discarded
        self.cancel = cancel
        self.failure = failure
    }

    func run(_ request: SubprocessRequest, outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?) async throws -> SubprocessResult {
        requests.append(request)
        if cancel { throw CancellationError() }
        let result = SubprocessResult(terminationStatus: status, termination: .exited,
                                standardOutput: Data(output.utf8), standardError: Data(),
                                discardedStandardOutputBytes: discarded, discardedStandardErrorBytes: 0,
                                duration: .zero)
        if failure == "launch" { throw SubprocessRunnerError.failedToStart(command: "tool", underlying: "not loadable") }
        if failure == "timeout" { throw SubprocessRunnerError.timedOut(command: "tool", result: result) }
        return result
    }
}
