//
//  Aagedal_VideoLoop_Converter_2_0Tests.swift
//  Aagedal VideoLoop Converter 2.0Tests
//
//  Created by Truls Aagedal on 30/06/2024.
//

import Darwin
import AVFoundation
import os
import XCTest
@testable import Aagedal_Media_Converter

final class Aagedal_Media_Converter_Tests: XCTestCase {

    func testQueueFailureDiagnosticsIncludesAllFailedStages() throws {
        let details = try XCTUnwrap(QueueFailureDiagnostics.details(
            downloadError: "download detail", conversionFailed: true,
            conversionError: "encode detail", subtitleStatus: .failed("subtitle detail"),
            uploadStatus: .failed("upload detail"), analyticsStatus: .failed("analysis detail")
        ))
        for message in ["download detail", "encode detail", "subtitle detail", "upload detail", "analysis detail"] {
            XCTAssertTrue(details.contains(message))
        }
        XCTAssertNil(QueueFailureDiagnostics.details(
            downloadError: nil, conversionFailed: false, conversionError: "stale error",
            subtitleStatus: .notQueued, uploadStatus: .cancelled, analyticsStatus: .completed
        ))
    }

    func testQueueFailureDiagnosticsKeepsFailuresWithoutTechnicalMessages() throws {
        let details = try XCTUnwrap(QueueFailureDiagnostics.details(
            downloadError: nil, conversionFailed: true, conversionError: nil,
            subtitleStatus: .notQueued, uploadStatus: .notQueued, analyticsStatus: .notQueued
        ))
        XCTAssertFalse(details.isEmpty)
    }

    func testCopiedQueueDiagnosticsRedactsKnownPathsAndRemoteCredentials() {
        let report = QueueFailureDiagnostics.report(
            details: "Failed /Users/person/Secret Clip.mov to /Volumes/Private/output.mov; https://user:password@example.com/file?token=secret; decoder returned 42",
            appVersion: "4.3 (123)", systemVersion: "macOS test", preset: "H.264",
            privateValues: ["/Users/person/Secret Clip.mov", "/Volumes/Private/output.mov", ""]
        )
        for privateText in ["Secret Clip", "/Users/person", "/Volumes/Private", "password", "token=secret", "example.com"] {
            XCTAssertFalse(report.contains(privateText))
        }
        XCTAssertTrue(report.contains("4.3 (123)"))
        XCTAssertTrue(report.contains("macOS test"))
        XCTAssertTrue(report.contains("H.264"))
        XCTAssertTrue(report.contains("decoder returned 42"))
    }

    func testSettingsMonitorCreatesDirectoryAndOpensDescriptor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("settings", isDirectory: true)

        let fd = try SettingsSyncService.openMonitoringDirectory(directory)
        defer { close(fd) }

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertNotEqual(fcntl(fd, F_GETFD), -1)
        XCTAssertNotEqual(fcntl(fd, F_GETFD) & FD_CLOEXEC, 0)
    }

    func testSettingsMonitorReportsBlockedDirectoryWithoutReplacingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("settings")
        let original = Data("existing user file".utf8)
        try original.write(to: blocker)

        XCTAssertThrowsError(try SettingsSyncService.openMonitoringDirectory(blocker.appendingPathComponent("nested"))) { error in
            guard case SettingsSyncService.SyncError.monitoringFailed(let details) = error else {
                return XCTFail("Expected actionable monitoring error, got \(error)")
            }
            XCTAssertFalse(details.isEmpty)
            XCTAssertTrue(error.localizedDescription.contains("choose another sync location"))
        }
        XCTAssertEqual(try Data(contentsOf: blocker), original)
    }


    func testSettingsSnapshotDecoderAcceptsCurrentFormat() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let source = SettingsSnapshot(
            defaults: ["example": .string("value")],
            modifiedAt: date
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let decoded = try SettingsSyncService.decodeSnapshot(encoder.encode(source))

        XCTAssertEqual(decoded.schemaVersion, SettingsSnapshot.currentSchemaVersion)
        XCTAssertEqual(decoded.modifiedAt, date)
        XCTAssertEqual(decoded.defaults, source.defaults)
    }

    func testSettingsSnapshotDecoderRejectsMalformedFileWithActionableError() {
        XCTAssertThrowsError(
            try SettingsSyncService.decodeSnapshot(Data("not settings JSON".utf8))
        ) { error in
            guard case SettingsSyncService.SyncError.invalidFile = error else {
                return XCTFail("Expected invalid-file error, got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("restore a backup"))
        }
    }

    func testSettingsSnapshotDecoderRejectsNewerSchemaWithoutApplyingIt() throws {
        let data = Data("""
        {
          "schemaVersion": \(SettingsSnapshot.currentSchemaVersion + 1),
          "appVersion": "future",
          "deviceName": "Future Mac",
          "modifiedAt": "2026-09-05T10:00:00Z",
          "defaults": {}
        }
        """.utf8)

        XCTAssertThrowsError(try SettingsSyncService.decodeSnapshot(data)) { error in
            guard case SettingsSyncService.SyncError.unsupportedSchema(let version) = error else {
                return XCTFail("Expected unsupported-schema error, got \(error)")
            }
            XCTAssertEqual(version, SettingsSnapshot.currentSchemaVersion + 1)
        }
    }

    func testSubprocessRunnerCapturesOutputAndStructuredExit() async throws {
        let result = try await SubprocessRunner().run(
            SubprocessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'hello'; printf 'warning' >&2"]
            )
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertEqual(result.termination, .exited)
        XCTAssertEqual(result.standardOutputText, "hello")
        XCTAssertEqual(result.standardErrorText, "warning")
        XCTAssertEqual(result.discardedStandardOutputBytes, 0)
        XCTAssertEqual(result.discardedStandardErrorBytes, 0)
    }

    func testSubprocessRunnerReturnsNonzeroExitAsResult() async throws {
        let result = try await SubprocessRunner().run(
            SubprocessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'diagnostic' >&2; exit 23"]
            )
        )

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.terminationStatus, 23)
        XCTAssertEqual(result.termination, .exited)
        XCTAssertEqual(result.standardErrorText, "diagnostic")
    }

    func testSubprocessRunnerWritesStandardInput() async throws {
        let input = Data("secret supplied over stdin\n".utf8)
        let result = try await SubprocessRunner().run(
            SubprocessRequest(
                executableURL: URL(fileURLWithPath: "/bin/cat"),
                standardInput: input
            )
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutput, input)
    }

    func testSubprocessRunnerStreamsStandardInputWithoutPrebuffering() async throws {
        let firstChunkWasRead = AsyncTestGate()
        let recorder = SubprocessChunkRecorder()
        let result = try await SubprocessRunner().runWithStreamingStandardInput(
            SubprocessRequest(executableURL: URL(fileURLWithPath: "/bin/cat")),
            inputProducer: { standardInput in
                try? standardInput.write(Data("first\n".utf8))
                await firstChunkWasRead.wait()
                try? standardInput.write(Data("second\n".utf8))
                standardInput.finish()
            },
            outputHandler: { chunk in
                recorder.append(chunk)
                if recorder.standardOutput.starts(with: Data("first\n".utf8)) {
                    firstChunkWasRead.open()
                }
            }
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutputText, "first\nsecond\n")
    }

    func testSubprocessRunnerDoesNotJoinUncooperativeStreamingProducerAfterChildExit() async throws {
        let releaseProducer = AsyncTestGate()
        defer { releaseProducer.open() }
        let start = ContinuousClock.now

        let result = try await SubprocessRunner().runWithStreamingStandardInput(
            SubprocessRequest(executableURL: URL(fileURLWithPath: "/usr/bin/true")),
            inputProducer: { _ in
                await releaseProducer.wait()
            },
            outputHandler: nil
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testSubprocessRunnerStreamingInputTimeoutUnblocksBackpressuredProducer() async throws {
        let producerFinished = expectation(description: "Streaming producer stopped")
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30"],
            timeout: .milliseconds(200),
            terminationGracePeriod: .milliseconds(100)
        )
        let start = ContinuousClock.now

        do {
            _ = try await SubprocessRunner().runWithStreamingStandardInput(
                request,
                inputProducer: { standardInput in
                    defer { producerFinished.fulfill() }
                    let chunk = Data(repeating: 0xA5, count: 1024 * 1024)
                    while !Task.isCancelled {
                        do {
                            try standardInput.write(chunk)
                        } catch {
                            break
                        }
                    }
                },
                outputHandler: nil
            )
            XCTFail("Expected the subprocess to time out")
        } catch SubprocessRunnerError.timedOut {
            // Expected.
        }

        await fulfillment(of: [producerFinished], timeout: 2)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testSubprocessRunnerCancellationStopsBackpressuredStreamingProducer() async throws {
        let producerStarted = expectation(description: "Streaming producer started")
        let producerFinished = expectation(description: "Streaming producer stopped")
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30"],
            terminationGracePeriod: .milliseconds(100)
        )
        let task = Task {
            try await SubprocessRunner().runWithStreamingStandardInput(
                request,
                inputProducer: { standardInput in
                    producerStarted.fulfill()
                    defer { producerFinished.fulfill() }
                    let chunk = Data(repeating: 0x5A, count: 1024 * 1024)
                    while !Task.isCancelled {
                        do {
                            try standardInput.write(chunk)
                        } catch {
                            break
                        }
                    }
                },
                outputHandler: nil
            )
        }
        await fulfillment(of: [producerStarted], timeout: 2)

        let cancelStart = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        await fulfillment(of: [producerFinished], timeout: 2)
        XCTAssertLessThan(cancelStart.duration(to: .now), .seconds(2))
    }

    func testSubprocessRunnerPipelineStreamsProducerOutputAndDrainsBothTools() async throws {
        let producerChunks = SubprocessChunkRecorder()
        let consumerChunks = SubprocessChunkRecorder()
        let result = try await SubprocessRunner().runPipeline(
            producer: SubprocessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "dd if=/dev/zero bs=65536 count=8 2>/dev/null; printf 'producer warning' >&2"
                ],
                standardOutputCaptureLimit: 0,
                standardErrorCaptureLimit: 64
            ),
            consumer: SubprocessRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/wc"),
                arguments: ["-c"],
                standardOutputCaptureLimit: 64,
                standardErrorCaptureLimit: 64
            ),
            producerOutputHandler: { producerChunks.append($0) },
            consumerOutputHandler: { consumerChunks.append($0) }
        )

        guard case .completed(let producerResult) = result.producer else {
            return XCTFail("Expected the pipeline producer to complete")
        }
        XCTAssertTrue(producerResult.succeeded)
        XCTAssertEqual(producerResult.standardOutput.count, 0)
        XCTAssertEqual(producerResult.discardedStandardOutputBytes, 8 * 65_536)
        XCTAssertEqual(producerResult.standardErrorText, "producer warning")
        XCTAssertTrue(result.consumer.succeeded)
        XCTAssertEqual(
            result.consumer.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines),
            String(8 * 65_536)
        )
        XCTAssertEqual(producerChunks.standardOutput.count, 8 * 65_536)
        XCTAssertEqual(String(decoding: producerChunks.standardError, as: UTF8.self), "producer warning")
        XCTAssertEqual(consumerChunks.standardOutput, result.consumer.standardOutput)
    }

    func testSubprocessRunnerPipelineReturnsProducerFailureAfterSendingEOF() async throws {
        let privatePath = "/private/media/secret.mov"
        let producerRequest = SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'partial'; printf 'cannot read \(privatePath)' >&2; exit 7"],
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 256,
            sensitiveValues: [privatePath]
        )
        let result = try await SubprocessRunner().runPipeline(
            producer: producerRequest,
            consumer: SubprocessRequest(executableURL: URL(fileURLWithPath: "/bin/cat"))
        )

        guard case .completed(let producerResult) = result.producer else {
            return XCTFail("Expected the failed producer to return its structured result")
        }
        XCTAssertEqual(producerResult.terminationStatus, 7)
        XCTAssertEqual(result.consumer.standardOutputText, "partial")
        XCTAssertTrue(result.consumer.succeeded)
        XCTAssertFalse(
            producerRequest.redactedDiagnostic(producerResult.standardErrorText).contains(privatePath)
        )
    }

    func testSubprocessRunnerPipelineReportsProducerLaunchFailure() async throws {
        let missingPath = "/private/tools/missing-producer"
        let result = try await SubprocessRunner().runPipeline(
            producer: SubprocessRequest(
                executableURL: URL(fileURLWithPath: missingPath),
                sensitiveValues: [missingPath]
            ),
            consumer: SubprocessRequest(executableURL: URL(fileURLWithPath: "/bin/cat"))
        )

        guard case .failed(.failedToStart(let reason)) = result.producer else {
            return XCTFail("Expected a producer launch failure")
        }
        XCTAssertTrue(result.consumer.succeeded)
        XCTAssertFalse(reason.contains(missingPath))
    }

    func testSubprocessRunnerPipelineConsumerTimeoutCancelsProducer() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubprocessPipelineTimeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let producerPIDURL = temporaryDirectory.appendingPathComponent("producer.pid")
        let producerRequest = SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "printf '%s' $$ > \"$1\"; while :; do printf '0123456789'; done",
                "pipeline-producer",
                producerPIDURL.path
            ],
            terminationGracePeriod: .milliseconds(100),
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 64,
            sensitiveValues: [producerPIDURL.path]
        )
        let consumerRequest = SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30"],
            timeout: .milliseconds(200),
            terminationGracePeriod: .milliseconds(100),
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 64
        )
        let start = ContinuousClock.now

        do {
            _ = try await SubprocessRunner().runPipeline(
                producer: producerRequest,
                consumer: consumerRequest
            )
            XCTFail("Expected the pipeline consumer to time out")
        } catch SubprocessRunnerError.timedOut {
            // Expected.
        }

        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        let pidText = try String(contentsOf: producerPIDURL, encoding: .utf8)
        let producerPID = try XCTUnwrap(pid_t(pidText))
        try await Task.sleep(for: .milliseconds(300))
        let probeResult = Darwin.kill(producerPID, 0)
        let probeError = errno
        XCTAssertEqual(probeResult, -1, "Pipeline producer survived consumer timeout")
        XCTAssertEqual(probeError, ESRCH)
    }

    func testSubprocessRunnerPipelineBrokenConnectionStopsProducerPromptly() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubprocessPipelineBrokenPipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let producerPIDURL = temporaryDirectory.appendingPathComponent("producer.pid")
        let pipelineTask = Task {
            try await SubprocessRunner().runPipeline(
                producer: SubprocessRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        "printf '%s' $$ > \"$1\"; while :; do printf '0123456789'; done",
                        "pipeline-producer",
                        producerPIDURL.path
                    ],
                    terminationGracePeriod: .milliseconds(100),
                    standardOutputCaptureLimit: 0,
                    standardErrorCaptureLimit: 64,
                    sensitiveValues: [producerPIDURL.path]
                ),
                consumer: SubprocessRequest(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "exec 0<&-; sleep 30"],
                    terminationGracePeriod: .milliseconds(100),
                    standardOutputCaptureLimit: 0,
                    standardErrorCaptureLimit: 64
                )
            )
        }

        let pidDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: producerPIDURL.path),
              ContinuousClock.now < pidDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pidText = try String(contentsOf: producerPIDURL, encoding: .utf8)
        let producerPID = try XCTUnwrap(pid_t(pidText))
        let exitDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while Darwin.kill(producerPID, 0) == 0, ContinuousClock.now < exitDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(Darwin.kill(producerPID, 0), -1, "Producer survived a closed pipeline")
        XCTAssertEqual(errno, ESRCH)

        pipelineTask.cancel()
        do {
            _ = try await pipelineTask.value
            XCTFail("Expected cancellation while the consumer was still alive")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testSubprocessRunnerDeliversEveryCapturedByteToIncrementalHandler() async throws {
        let recorder = SubprocessChunkRecorder()
        let result = try await SubprocessRunner().run(
            SubprocessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "i=0; while [ $i -lt 2000 ]; do printf '%04d\\n' $i; i=$((i + 1)); done"]
            )
        ) { chunk in
            recorder.append(chunk)
        }

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(recorder.standardOutput, result.standardOutput)
        XCTAssertEqual(recorder.standardError, result.standardError)
    }

    func testSubprocessRunnerDrainsBothStreamsAndBoundsCapturedTails() async throws {
        let script = """
        i=0
        while [ "$i" -lt 3000 ]; do
          printf 'out-%04d-abcdefghijklmnop\n' "$i"
          printf 'err-%04d-abcdefghijklmnop\n' "$i" >&2
          i=$((i + 1))
        done
        """
        let result = try await SubprocessRunner().run(
            SubprocessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script],
                standardOutputCaptureLimit: 4096,
                standardErrorCaptureLimit: 4096
            )
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertGreaterThan(result.discardedStandardOutputBytes, 0)
        XCTAssertGreaterThan(result.discardedStandardErrorBytes, 0)
        XCTAssertLessThanOrEqual(result.standardOutput.count, 4096)
        XCTAssertLessThanOrEqual(result.standardError.count, 4096)
        XCTAssertTrue(result.standardOutputText.contains("out-2999"))
        XCTAssertTrue(result.standardErrorText.contains("err-2999"))
    }

    func testSubprocessRunnerDoesNotWaitForPipeInheritedByExitedChildDescendant() async throws {
        let start = ContinuousClock.now
        let result = try await SubprocessRunner().run(
            SubprocessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 5 & child=$!; printf '%s\\n' \"$child\"; exit 0"]
            )
        )
        let childText = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(pid_t(childText))
        defer { _ = Darwin.kill(childPID, SIGKILL) }

        XCTAssertTrue(result.succeeded)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testSubprocessRunnerLaunchesChildInDedicatedProcessGroup() async throws {
        let result = try await SubprocessRunner().run(
            SubprocessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c",
                    "printf '%s %s\\n' \"$$\" \"$(ps -o pgid= -p $$ | tr -d ' ')\""
                ]
            )
        )

        let identifiers = result.standardOutputText.split(whereSeparator: { $0.isWhitespace })
            .compactMap { pid_t($0) }
        XCTAssertEqual(identifiers.count, 2)
        XCTAssertEqual(identifiers.first, identifiers.last)
        XCTAssertNotEqual(identifiers.first, Darwin.getpgrp())
    }

    func testSubprocessRunnerPosixSpawnPreservesEnvironmentAndCurrentDirectory() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubprocessSpawn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try Data().write(to: temporaryDirectory.appendingPathComponent("cwd-marker"))

        let result = try await SubprocessRunner().run(
            SubprocessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "test -f cwd-marker && printf '%s' \"$SPAWN_TEST_VALUE\""],
                environment: ["SPAWN_TEST_VALUE": "inherited"],
                currentDirectoryURL: temporaryDirectory
            )
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutputText, "inherited")
    }

    func testSubprocessRunnerTimeoutTerminatesDescendant() async throws {
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30 & child=$!; printf '%s\\n' \"$child\"; wait \"$child\""],
            timeout: .milliseconds(200),
            terminationGracePeriod: .milliseconds(100)
        )
        let start = ContinuousClock.now

        do {
            _ = try await SubprocessRunner().run(request)
            XCTFail("Expected the subprocess to time out")
        } catch let error as SubprocessRunnerError {
            guard case let .timedOut(_, result) = error else {
                return XCTFail("Expected a timeout error, got \(error)")
            }
            let childText = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
            let childPID = try XCTUnwrap(pid_t(childText))
            let reapDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while Darwin.kill(childPID, 0) == 0, ContinuousClock.now < reapDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(Darwin.kill(childPID, 0), -1, "The descendant process was still running")
            XCTAssertEqual(errno, ESRCH)
        }

        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testSubprocessRunnerEscalatesForTermIgnoringDescendantAfterWrapperExits() async throws {
        let script = """
        /bin/sh -c 'trap "" TERM; printf "%s\\n" "$$"; while :; do sleep 1; done' &
        wait "$!"
        """
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            // Deadlines include shell startup. Allow loaded parallel test workers time to
            // install the trap; cancellation coverage below explicitly waits for readiness.
            timeout: .seconds(2),
            terminationGracePeriod: .milliseconds(100)
        )

        do {
            _ = try await SubprocessRunner().run(request)
            XCTFail("Expected the subprocess to time out")
        } catch let error as SubprocessRunnerError {
            guard case let .timedOut(_, result) = error else {
                return XCTFail("Expected a timeout error, got \(error)")
            }
            XCTAssertEqual(result.terminationStatus, SIGTERM, "The wrapper should exit before escalation")
            let childText = result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
            let childPID = try XCTUnwrap(pid_t(childText))
            let reapDeadline = ContinuousClock.now.advanced(by: .seconds(1))
            while Darwin.kill(childPID, 0) == 0, ContinuousClock.now < reapDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(Darwin.kill(childPID, 0), -1, "The TERM-ignoring descendant survived escalation")
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testSubprocessRunnerCancellationEscalatesForReadyTermIgnoringDescendant() async throws {
        let ready = expectation(description: "Descendant installed its TERM trap")
        let recorder = SubprocessChunkRecorder()
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", """
            /bin/sh -c 'trap "" TERM; printf "%s\\n" "$$"; while :; do sleep 1; done' &
            wait "$!"
            """],
            terminationGracePeriod: .milliseconds(100)
        )
        let task = Task {
            try await SubprocessRunner().run(request) { chunk in
                recorder.append(chunk)
                // Only the descendant writes stdout, after installing its trap. A newline
                // completes its PID even if pipe delivery splits the write across chunks.
                if chunk.stream == .standardOutput, chunk.data.contains(0x0A) {
                    ready.fulfill()
                }
            }
        }
        defer { task.cancel() }
        await fulfillment(of: [ready], timeout: 10)

        let cancelStart = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected after the wrapper exits on TERM and the descendant requires KILL.
        }
        XCTAssertLessThan(cancelStart.duration(to: .now), .seconds(2))

        let childText = String(decoding: recorder.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(pid_t(childText))
        let reapDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while Darwin.kill(childPID, 0) == 0, ContinuousClock.now < reapDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(Darwin.kill(childPID, 0), -1, "The ready TERM-ignoring descendant survived cancellation")
        XCTAssertEqual(errno, ESRCH)
    }

    func testSubprocessRunnerCancellationStopsPromptly() async throws {
        let ready = expectation(description: "Subprocess became ready")
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30 & child=$!; printf 'ready\\n'; wait \"$child\""],
            terminationGracePeriod: .milliseconds(100)
        )
        let task = Task {
            try await SubprocessRunner().run(request) { chunk in
                if chunk.stream == .standardOutput,
                   String(decoding: chunk.data, as: UTF8.self).contains("ready") {
                    ready.fulfill()
                }
            }
        }
        await fulfillment(of: [ready], timeout: 2)

        let cancelStart = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertLessThan(cancelStart.duration(to: .now), .seconds(2))
    }

    func testSubprocessRequestRedactsURLsAndSensitiveArguments() {
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/tool"),
            arguments: [
                "--cookies-from-browser", "Safari:Personal",
                "--token=top-secret",
                "https://example.com/watch?v=private"
            ],
            sensitiveArgumentNames: ["--cookies-from-browser", "--token"]
        )

        let description = request.redactedCommandDescription
        XCTAssertFalse(description.contains("Safari:Personal"))
        XCTAssertFalse(description.contains("top-secret"))
        XCTAssertFalse(description.contains("example.com"))
        XCTAssertTrue(description.contains("--cookies-from-browser"))
        XCTAssertTrue(description.contains("--token=<redacted>"))
        XCTAssertTrue(description.contains("<url>"))
    }

    func testSubprocessRequestRedactsSensitiveValuesAndURLsFromDiagnostics() {
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/tool"),
            arguments: [
                "--cookies-from-browser", "Safari:Personal",
                "https://user:password@example.com/watch?signed=private"
            ],
            sensitiveArgumentNames: ["--cookies-from-browser"],
            sensitiveValues: ["environment-secret"]
        )

        let diagnostic = request.redactedDiagnostic(
            "Failed Safari:Personal environment-secret while reading https://user:password@example.com/watch?signed=private"
        )
        XCTAssertEqual(diagnostic, "Failed <redacted> <redacted> while reading <url>")
    }

    func testSubprocessRequestRedactsOverlappingSensitiveValuesLongestFirst() {
        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/tool"),
            sensitiveValues: ["ABC", "ABCDEF"]
        )

        let diagnostic = request.redactedDiagnostic("keys ABCDEF and ABC")

        XCTAssertEqual(diagnostic, "keys <redacted> and <redacted>")
        XCTAssertFalse(diagnostic.contains("DEF"))
    }

    func testWhisperCapabilityProbeUsesBoundedSharedRequestsAndCachesResult() async throws {
        let privateFFmpegPath = "/private/tools/ffmpeg"
        let runner = SequencedRecordingSubprocessRunner { _, request, _ in
            try await Task.sleep(for: .milliseconds(20))
            if request.arguments.contains("-filters") {
                return successfulSubprocessResult(
                    standardOutput: " ... whisper          A->A       Whisper transcription\n"
                )
            }
            return successfulSubprocessResult(
                standardOutput: "ffmpeg version 8.1.1-custom Copyright\n"
            )
        }
        let service = WhisperUpdateService(
            subprocessRunner: runner,
            ffmpegPathProvider: { privateFFmpegPath }
        )

        async let firstValue = service.capabilitySnapshot()
        async let secondValue = service.capabilitySnapshot()
        let (first, second) = try await (firstValue, secondValue)

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first,
            WhisperCapabilitySnapshot(isAvailable: true, ffmpegVersion: "8.1.1-custom")
        )
        XCTAssertEqual(
            first.installationStatus,
            .installed(version: "FFmpeg 8.1.1-custom (built-in)")
        )

        let requests = runner.requests
        XCTAssertEqual(requests.count, 2, "Concurrent callers should share one probe pair")
        XCTAssertEqual(Set(requests.map(\.arguments)), [
            ["-hide_banner", "-filters"],
            ["-version"]
        ])
        for request in requests {
            XCTAssertEqual(request.executableURL.path, privateFFmpegPath)
            XCTAssertEqual(request.timeout, WhisperUpdateService.probeTimeout)
            XCTAssertEqual(
                request.standardOutputCaptureLimit,
                WhisperUpdateService.standardOutputCaptureLimit
            )
            XCTAssertEqual(
                request.standardErrorCaptureLimit,
                WhisperUpdateService.standardErrorCaptureLimit
            )
            XCTAssertFalse(request.redactedCommandDescription.contains(privateFFmpegPath))
        }

        let cached = try await service.capabilitySnapshot()
        XCTAssertEqual(cached, first)
        XCTAssertEqual(runner.requests.count, 2, "Cached reads must not launch another probe")

        let refreshed = try await service.refreshCapabilitySnapshot()
        XCTAssertEqual(refreshed, first)
        XCTAssertEqual(runner.requests.count, 4, "An explicit refresh should launch one new probe pair")
    }

    func testWhisperCapabilityProbeRejectsNonzeroAndTruncatedOutput() async throws {
        let runner = SequencedRecordingSubprocessRunner { _, request, _ in
            if request.arguments.contains("-filters") {
                return successfulSubprocessResult(
                    standardOutput: "whisper",
                    standardError: "filter probe failed",
                    terminationStatus: 7
                )
            }
            return SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data("ffmpeg version incomplete\n".utf8),
                standardError: Data(),
                discardedStandardOutputBytes: 1,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(10)
            )
        }
        let service = WhisperUpdateService(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" }
        )

        let snapshot = try await service.capabilitySnapshot()

        XCTAssertEqual(snapshot, WhisperCapabilitySnapshot(isAvailable: false, ffmpegVersion: "unknown"))
        XCTAssertEqual(snapshot.installationStatus, .notInstalled)
    }

    func testWhisperCapabilityProbeMapsTimeoutAndMissingBinaryToUnavailable() async throws {
        let timeoutRunner = SequencedRecordingSubprocessRunner { _, request, _ in
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: successfulSubprocessResult(terminationStatus: SIGKILL)
            )
        }
        let timedOutService = WhisperUpdateService(
            subprocessRunner: timeoutRunner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" }
        )

        let timedOutSnapshot = try await timedOutService.capabilitySnapshot()
        XCTAssertEqual(
            timedOutSnapshot,
            WhisperCapabilitySnapshot(isAvailable: false, ffmpegVersion: "unknown")
        )
        XCTAssertEqual(timeoutRunner.requests.count, 2)

        let missingRunner = RecordingSubprocessRunner { _, _ in
            XCTFail("A missing FFmpeg path must not launch a subprocess")
            return successfulSubprocessResult()
        }
        let missingService = WhisperUpdateService(
            subprocessRunner: missingRunner,
            ffmpegPathProvider: { nil }
        )

        let missingSnapshot = try await missingService.capabilitySnapshot()
        XCTAssertEqual(
            missingSnapshot,
            WhisperCapabilitySnapshot(isAvailable: false, ffmpegVersion: "unknown")
        )
        XCTAssertNil(missingRunner.lastRequest)
    }

    func testWhisperCapabilityWaiterCancellationDoesNotCancelSharedProbe() async throws {
        let runner = SequencedRecordingSubprocessRunner { _, request, _ in
            try await Task.sleep(for: .milliseconds(100))
            if request.arguments.contains("-filters") {
                return successfulSubprocessResult(standardOutput: "whisper\n")
            }
            return successfulSubprocessResult(standardOutput: "ffmpeg version 8.1.1\n")
        }
        let service = WhisperUpdateService(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" }
        )
        let cancelledWaiter = Task {
            try await service.capabilitySnapshot()
        }
        while runner.requests.count < 2 {
            await Task.yield()
        }

        cancelledWaiter.cancel()
        do {
            _ = try await cancelledWaiter.value
            XCTFail("Expected the individual waiter to be cancelled")
        } catch is CancellationError {
            // Expected. The shared probe remains useful to other callers.
        }

        let sharedSnapshot = try await service.capabilitySnapshot()
        XCTAssertEqual(
            sharedSnapshot,
            WhisperCapabilitySnapshot(isAvailable: true, ffmpegVersion: "8.1.1")
        )
        XCTAssertEqual(runner.requests.count, 2)
    }

    func testBinaryVersionProbeUsesBoundedRunnerAndExplicitOutputStream() async throws {
        let runner = SequencedRecordingSubprocessRunner { index, _, _ in
            switch index {
            case 0:
                return successfulSubprocessResult(
                    standardOutput: "ffmpeg version 8.0\nconfiguration details\n"
                )
            case 1:
                return successfulSubprocessResult(
                    standardOutput: "tesseract 5.5.1\n leptonica-1.85.0\n"
                )
            default:
                return successfulSubprocessResult(
                    standardError: "tool 2.0\ndiagnostic details\n"
                )
            }
        }
        let probe = BinaryVersionProbe(subprocessRunner: runner)

        let ffmpegVersion = await probe.firstLine(
            at: "/private/tools/ffmpeg",
            arguments: ["-version"],
            outputStream: .standardOutput
        )
        let tesseractVersion = await probe.firstLine(
            at: "/private/tools/tesseract",
            arguments: ["--version"],
            outputStream: .standardOutput
        )
        let stderrVersion = await probe.firstLine(
            at: "/private/tools/stderr-tool",
            arguments: ["--version"],
            outputStream: .standardError
        )

        XCTAssertEqual(ffmpegVersion, "ffmpeg version 8.0")
        XCTAssertEqual(tesseractVersion, "tesseract 5.5.1")
        XCTAssertEqual(stderrVersion, "tool 2.0")
        let requests = runner.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].arguments, ["-version"])
        XCTAssertEqual(requests[1].arguments, ["--version"])
        XCTAssertEqual(requests[2].arguments, ["--version"])
        for request in requests {
            XCTAssertEqual(request.timeout, .seconds(5))
            XCTAssertEqual(request.standardOutputCaptureLimit, 64 * 1024)
            XCTAssertEqual(request.standardErrorCaptureLimit, 64 * 1024)
            XCTAssertFalse(request.redactedCommandDescription.contains("/private/tools"))
        }
    }

    func testBinaryVersionProbeRejectsNonzeroTruncatedAndEmptyOutput() async {
        let runner = SequencedRecordingSubprocessRunner { index, _, _ in
            switch index {
            case 0:
                return successfulSubprocessResult(
                    standardOutput: "tool 1.0\n",
                    terminationStatus: 2
                )
            case 1:
                return SubprocessResult(
                    terminationStatus: 0,
                    termination: .exited,
                    standardOutput: Data(),
                    standardError: Data("tool 1.0".utf8),
                    discardedStandardOutputBytes: 0,
                    discardedStandardErrorBytes: 1,
                    duration: .milliseconds(10)
                )
            default:
                return successfulSubprocessResult(standardOutput: "\nsecond line")
            }
        }
        let probe = BinaryVersionProbe(subprocessRunner: runner)

        let nonzero = await probe.firstLine(
            at: "/tool",
            arguments: ["--version"],
            outputStream: .standardOutput
        )
        let truncated = await probe.firstLine(
            at: "/tool",
            arguments: ["--version"],
            outputStream: .standardError
        )
        let empty = await probe.firstLine(
            at: "/tool",
            arguments: ["--version"],
            outputStream: .standardOutput
        )

        XCTAssertNil(nonzero)
        XCTAssertNil(truncated)
        XCTAssertNil(empty)
    }

    func testBinaryVersionProbeMapsTimeoutAndParentCancellationToNil() async {
        let timeoutRunner = RecordingSubprocessRunner { request, _ in
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: successfulSubprocessResult(terminationStatus: SIGKILL)
            )
        }
        let timeoutVersion = await BinaryVersionProbe(subprocessRunner: timeoutRunner).firstLine(
            at: "/tool",
            arguments: ["--version"],
            outputStream: .standardOutput
        )
        XCTAssertNil(timeoutVersion)

        let blockingRunner = CountingBlockingSubprocessRunner()
        let probe = BinaryVersionProbe(subprocessRunner: blockingRunner)
        let task = Task {
            await probe.firstLine(
                at: "/tool",
                arguments: ["--version"],
                outputStream: .standardOutput
            )
        }
        await blockingRunner.waitUntilStarted(count: 1)
        task.cancel()

        let cancelledVersion = await task.value
        XCTAssertNil(cancelledVersion)
        XCTAssertEqual(blockingRunner.cancelledCount, 1)
    }

    func testScreenshotCaptureSubprocessUsesBoundedRedactedRequestAndRequiresOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotCapture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let executableURL = URL(fileURLWithPath: "/private/tools/ffmpeg")
        let sourceURL = temporaryDirectory.appendingPathComponent("private source.mov")
        let outputURL = temporaryDirectory.appendingPathComponent("private screenshot.png")
        let arguments = ["-i", sourceURL.path, "-frames:v", "1", outputURL.path]
        let runner = RecordingSubprocessRunner { _, _ in
            try Data("image data".utf8).write(to: outputURL)
            return successfulSubprocessResult()
        }

        try await ScreenshotCaptureSubprocess(subprocessRunner: runner).run(
            executable: executableURL,
            arguments: arguments,
            sourceURL: sourceURL,
            outputURL: outputURL
        )

        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.arguments, arguments)
        XCTAssertEqual(request.timeout, .seconds(30 * 60))
        XCTAssertEqual(request.standardOutputCaptureLimit, 0)
        XCTAssertEqual(request.standardErrorCaptureLimit, 256 * 1024)
        XCTAssertFalse(request.redactedCommandDescription.contains(executableURL.path))
        XCTAssertFalse(request.redactedCommandDescription.contains(sourceURL.path))
        XCTAssertFalse(request.redactedCommandDescription.contains(outputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testScreenshotCaptureSubprocessRedactsFailureAndRemovesPartialOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotFailure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("private source.mov")
        let outputURL = temporaryDirectory.appendingPathComponent("private screenshot.png")
        let runner = RecordingSubprocessRunner { _, _ in
            try Data("partial image".utf8).write(to: outputURL)
            return successfulSubprocessResult(
                standardError: "Could not read \(sourceURL.path) or write \(outputURL.path)",
                terminationStatus: 7
            )
        }

        do {
            try await ScreenshotCaptureSubprocess(subprocessRunner: runner).run(
                executable: URL(fileURLWithPath: "/private/tools/ffmpeg"),
                arguments: ["-i", sourceURL.path, outputURL.path],
                sourceURL: sourceURL,
                outputURL: outputURL
            )
            XCTFail("Expected screenshot capture to fail")
        } catch let error as PreviewPlayerController.ScreenshotError {
            let description = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(description.contains("<redacted>"))
            XCTAssertFalse(description.contains(sourceURL.path))
            XCTAssertFalse(description.contains(outputURL.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testScreenshotCaptureSubprocessRejectsMissingAndEmptyOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotOutput-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("source.mov")
        let missingOutputURL = temporaryDirectory.appendingPathComponent("missing.png")
        let emptyOutputURL = temporaryDirectory.appendingPathComponent("empty.png")
        let runner = SequencedRecordingSubprocessRunner { index, _, _ in
            if index == 1 {
                XCTAssertTrue(FileManager.default.createFile(atPath: emptyOutputURL.path, contents: Data()))
            }
            return successfulSubprocessResult()
        }
        let subprocess = ScreenshotCaptureSubprocess(subprocessRunner: runner)

        for outputURL in [missingOutputURL, emptyOutputURL] {
            do {
                try await subprocess.run(
                    executable: URL(fileURLWithPath: "/private/tools/ffmpeg"),
                    arguments: ["-i", sourceURL.path, outputURL.path],
                    sourceURL: sourceURL,
                    outputURL: outputURL
                )
                XCTFail("Expected missing or empty output to fail")
            } catch let error as PreviewPlayerController.ScreenshotError {
                guard case .outputUnavailable = error else {
                    return XCTFail("Expected outputUnavailable, got \(error)")
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        }
    }

    func testScreenshotCaptureSubprocessMapsTimeoutAndPropagatesCancellation() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotCancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("source.mov")
        let outputURL = temporaryDirectory.appendingPathComponent("output.png")
        let executableURL = URL(fileURLWithPath: "/private/tools/ffmpeg")
        let arguments = ["-i", sourceURL.path, outputURL.path]
        let timeoutRunner = RecordingSubprocessRunner { request, _ in
            try Data("partial image".utf8).write(to: outputURL)
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: successfulSubprocessResult(terminationStatus: SIGKILL)
            )
        }

        do {
            try await ScreenshotCaptureSubprocess(subprocessRunner: timeoutRunner).run(
                executable: executableURL,
                arguments: arguments,
                sourceURL: sourceURL,
                outputURL: outputURL
            )
            XCTFail("Expected timeout")
        } catch let error as PreviewPlayerController.ScreenshotError {
            XCTAssertEqual(
                error.errorDescription,
                "FFmpeg failed: Screenshot capture timed out after 30 minutes."
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))

        let blockingRunner = CountingBlockingSubprocessRunner()
        let task = Task {
            try await ScreenshotCaptureSubprocess(subprocessRunner: blockingRunner).run(
                executable: executableURL,
                arguments: arguments,
                sourceURL: sourceURL,
                outputURL: outputURL
            )
        }
        await blockingRunner.waitUntilStarted(count: 1)
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(blockingRunner.cancelledCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testScreenshotOutputPublisherAtomicallyPreservesExistingDestination() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotPublish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let stagedURL = temporaryDirectory.appendingPathComponent(".staged.png")
        let preferredURL = temporaryDirectory.appendingPathComponent("frame.png")
        try Data("new screenshot".utf8).write(to: stagedURL)
        try Data("existing screenshot".utf8).write(to: preferredURL)

        let publishedURL = try ScreenshotOutputPublisher.publish(
            stagedURL: stagedURL,
            preferredURL: preferredURL
        )

        XCTAssertEqual(publishedURL.lastPathComponent, "frame_1.png")
        XCTAssertEqual(try Data(contentsOf: preferredURL), Data("existing screenshot".utf8))
        XCTAssertEqual(try Data(contentsOf: publishedURL), Data("new screenshot".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    @MainActor
    func testPreviewControllerTeardownCancelsActiveScreenshotCapture() async throws {
        let blockingRunner = CountingBlockingSubprocessRunner()
        let sourceURL = URL(fileURLWithPath: "/private/media/source.mov")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotTeardown-\(UUID().uuidString).png")
        let item = VideoItem(
            url: sourceURL,
            name: sourceURL.lastPathComponent,
            size: 0,
            duration: "00:00:01",
            status: .waiting,
            progress: 0,
            eta: nil,
            outputURL: nil
        )
        let controller = PreviewPlayerController(
            videoItem: item,
            screenshotCaptureSubprocess: ScreenshotCaptureSubprocess(
                subprocessRunner: blockingRunner
            )
        )
        let captureTask = Task { @MainActor in
            try await controller.runFFmpegCapture(
                executable: URL(fileURLWithPath: "/private/tools/ffmpeg"),
                arguments: ["-i", sourceURL.path, outputURL.path],
                outputURL: outputURL
            )
        }
        await blockingRunner.waitUntilStarted(count: 1)

        controller.teardown()

        do {
            try await captureTask.value
            XCTFail("Expected teardown to cancel screenshot capture")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(blockingRunner.cancelledCount, 1)
        XCTAssertNil(controller.screenshotCaptureTask)
        XCTAssertNil(controller.screenshotCaptureOperationID)
    }

    @MainActor
    func testPreviewControllerTeardownRejectsLateScreenshotSuccess() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScreenshotLateSuccess-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("source.mov")
        let outputURL = temporaryDirectory.appendingPathComponent("staged.png")
        let item = VideoItem(
            url: sourceURL,
            name: sourceURL.lastPathComponent,
            size: 0,
            duration: "00:00:01",
            status: .waiting,
            progress: 0,
            eta: nil,
            outputURL: nil
        )
        let runner = ControllableBMXSubprocessRunner()
        let controller = PreviewPlayerController(
            videoItem: item,
            screenshotCaptureSubprocess: ScreenshotCaptureSubprocess(subprocessRunner: runner)
        )
        let captureTask = Task { @MainActor in
            try await controller.runFFmpegCapture(
                executable: URL(fileURLWithPath: "/private/tools/ffmpeg"),
                arguments: ["-i", sourceURL.path, "-o", outputURL.path],
                outputURL: outputURL
            )
        }
        await runner.waitUntilStarted(count: 1)

        controller.teardown()
        runner.releaseFirst()

        do {
            try await captureTask.value
            XCTFail("Expected stale success to be treated as cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertNil(controller.screenshotCaptureTask)
        XCTAssertNil(controller.screenshotCaptureOperationID)
    }

    func testMergePreparationUsesBoundedRunnerAndRequiresNonemptyOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergePreparation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("private source.mov")
        let outputURL = temporaryDirectory.appendingPathComponent("private output.mov")
        let executablePath = "/private/tools/ffmpeg"
        let runner = RecordingSubprocessRunner { _, _ in
            try Data("prepared media".utf8).write(to: outputURL)
            return successfulSubprocessResult()
        }
        let subprocess = MergePreparationSubprocess(subprocessRunner: runner)

        let succeeded = await subprocess.runFFmpeg(
            at: executablePath,
            arguments: ["-y", "-i", sourceURL.path, "-c", "copy", outputURL.path],
            outputURL: outputURL,
            context: "trim private source.mov"
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(try Data(contentsOf: outputURL), Data("prepared media".utf8))
        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.executableURL.path, executablePath)
        XCTAssertEqual(request.timeout, .seconds(12 * 60 * 60))
        XCTAssertEqual(request.standardOutputCaptureLimit, 0)
        XCTAssertEqual(request.standardErrorCaptureLimit, 256 * 1024)
        XCTAssertFalse(request.redactedCommandDescription.contains(executablePath))
        XCTAssertFalse(request.redactedCommandDescription.contains(sourceURL.path))
        XCTAssertFalse(request.redactedCommandDescription.contains(outputURL.path))
    }

    func testMergePreparationRemovesPartialOutputAfterFailureAndTimeout() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergePreparationFailure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let outputURL = temporaryDirectory.appendingPathComponent("partial.mov")
        let arguments = ["-i", "/private/media/source.mov", outputURL.path]

        let failureRunner = RecordingSubprocessRunner { _, _ in
            try Data("partial".utf8).write(to: outputURL)
            return successfulSubprocessResult(
                standardError: "failed /private/media/source.mov at https://example.com/private",
                terminationStatus: 7
            )
        }
        let failureSucceeded = await MergePreparationSubprocess(subprocessRunner: failureRunner).runFFmpeg(
            at: "/private/tools/ffmpeg",
            arguments: arguments,
            outputURL: outputURL,
            context: "conform private source.mov"
        )
        XCTAssertFalse(failureSucceeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))

        let timeoutRunner = RecordingSubprocessRunner { request, _ in
            try Data("partial".utf8).write(to: outputURL)
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: successfulSubprocessResult(terminationStatus: SIGKILL)
            )
        }
        let timeoutSucceeded = await MergePreparationSubprocess(subprocessRunner: timeoutRunner).runFFmpeg(
            at: "/private/tools/ffmpeg",
            arguments: arguments,
            outputURL: outputURL,
            context: "conform private source.mov"
        )
        XCTAssertFalse(timeoutSucceeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))

        let missingOutputRunner = RecordingSubprocessRunner { _, _ in
            successfulSubprocessResult()
        }
        let missingOutputSucceeded = await MergePreparationSubprocess(
            subprocessRunner: missingOutputRunner
        ).runFFmpeg(
            at: "/private/tools/ffmpeg",
            arguments: arguments,
            outputURL: outputURL,
            context: "trim private source.mov"
        )
        XCTAssertFalse(missingOutputSucceeded)

        let emptyOutputRunner = RecordingSubprocessRunner { _, _ in
            try Data().write(to: outputURL)
            return successfulSubprocessResult()
        }
        let emptyOutputSucceeded = await MergePreparationSubprocess(
            subprocessRunner: emptyOutputRunner
        ).runFFmpeg(
            at: "/private/tools/ffmpeg",
            arguments: arguments,
            outputURL: outputURL,
            context: "trim private source.mov"
        )
        XCTAssertFalse(emptyOutputSucceeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testMergePreparationCancellationReachesSharedRunnerAndRemovesPartialOutput() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergePreparationCancellation-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try Data("partial".utf8).write(to: outputURL)
        let runner = CountingBlockingSubprocessRunner()
        let subprocess = MergePreparationSubprocess(subprocessRunner: runner)
        let task = Task {
            await subprocess.runFFmpeg(
                at: "/private/tools/ffmpeg",
                arguments: ["-i", "/private/media/source.mov", outputURL.path],
                outputURL: outputURL,
                context: "trim private source.mov"
            )
        }

        await runner.waitUntilStarted(count: 1)
        task.cancel()

        let succeeded = await task.value
        XCTAssertFalse(succeeded)
        XCTAssertEqual(runner.cancelledCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testImageSequenceDetectionDerivesFrameRateFromAssociatedAudioAsynchronously() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AsyncImageSequence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstFrame = directory.appendingPathComponent("render_0001.png")
        let secondFrame = directory.appendingPathComponent("render_0002.png")
        let audio = directory.appendingPathComponent("render.wav")
        try Data([0x01]).write(to: firstFrame)
        try Data([0x02]).write(to: secondFrame)
        try Data([0x03]).write(to: audio)

        let sequences = await ImageSequenceDetector.detectSequences(inFolder: directory) { url in
            XCTAssertEqual(url.standardizedFileURL, audio.standardizedFileURL)
            return 0.5
        }

        let sequence = try XCTUnwrap(sequences.first)
        XCTAssertEqual(sequences.count, 1)
        XCTAssertEqual(sequence.associatedAudioURL?.standardizedFileURL, audio.standardizedFileURL)
        XCTAssertEqual(sequence.frameCount, 2)
        XCTAssertEqual(sequence.frameRate, 4, accuracy: 0.001)

        let frameOnlyGrantSequences = await ImageSequenceDetector.detectSequences(
            inFolder: directory,
            detectsAssociatedAudio: false
        ) { _ in
            XCTFail("A frame-only grant must not probe sibling audio")
            return 0.5
        }
        XCTAssertNil(try XCTUnwrap(frameOnlyGrantSequences.first).associatedAudioURL)
    }

    func testImageSequenceDetectionDeadlineReturnsPromptlyWhenDurationProbeDoesNotCooperate() async throws {
        let savedFrameRate = UserDefaults.standard.object(forKey: AppConstants.imageSequenceFrameRateKey)
        UserDefaults.standard.set(24.0, forKey: AppConstants.imageSequenceFrameRateKey)
        defer {
            if let savedFrameRate {
                UserDefaults.standard.set(savedFrameRate, forKey: AppConstants.imageSequenceFrameRateKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AppConstants.imageSequenceFrameRateKey)
            }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CancelledImageSequence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data([0x01]).write(to: directory.appendingPathComponent("render_0001.png"))
        try Data([0x02]).write(to: directory.appendingPathComponent("render_0002.png"))
        try Data([0x03]).write(to: directory.appendingPathComponent("render.wav"))

        let probeStarted = DispatchSemaphore(value: 0)
        let releaseProbe = DispatchSemaphore(value: 0)
        defer { releaseProbe.signal() }
        let scopeRecorder = SecurityScopeRecorder()
        let start = ContinuousClock.now

        let sequences = await ImageSequenceDetector.detectSequences(
            inFolder: directory,
            audioDurationTimeout: .milliseconds(50),
            securityScopedAccessURL: directory,
            securityScope: ImageSequenceDetector.SecurityScope(
                start: scopeRecorder.start,
                stop: scopeRecorder.stop
            )
        ) { _ in
            await withCheckedContinuation { continuation in
                probeStarted.signal()
                DispatchQueue.global(qos: .utility).async {
                    releaseProbe.wait()
                    continuation.resume(returning: 30)
                }
            }
        }

        XCTAssertEqual(probeStarted.wait(timeout: .now() + 1), .success)
        let sequence = try XCTUnwrap(sequences.first)
        XCTAssertEqual(sequence.frameRate, 24, accuracy: 0.001)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(scopeRecorder.startedURLs, [directory])
        XCTAssertTrue(scopeRecorder.stoppedURLs.isEmpty)

        releaseProbe.signal()
        for _ in 0..<100 where scopeRecorder.stoppedURLs.isEmpty {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(scopeRecorder.stoppedURLs, [directory])
    }

    @MainActor
    func testFileImportTaskCoordinatorCancelAllCancelsOwnedTasks() async {
        let runner = CountingBlockingSubprocessRunner()
        let coordinator = FileImportTaskCoordinator()
        coordinator.start {
            _ = try? await runner.run(
                SubprocessRequest(executableURL: URL(fileURLWithPath: "/usr/bin/true"))
            )
        }

        await runner.waitUntilStarted(count: 1)
        coordinator.cancelAll()
        for _ in 0..<100 where runner.cancelledCount == 0 {
            try? await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertEqual(runner.cancelledCount, 1)
    }

    func testBlockingOperationDeadlineReturnsImmediateOperationResult() async {
        let result = await BlockingOperationDeadline.run(
            timeout: .seconds(1),
            timeoutResult: false
        ) {
            true
        }

        XCTAssertTrue(result)
    }

    func testBlockingOperationDeadlineReturnsPromptlyWhenOperationStalls() async {
        let releaseOperation = DispatchSemaphore(value: 0)
        defer { releaseOperation.signal() }
        let start = ContinuousClock.now

        let result = await BlockingOperationDeadline.run(
            timeout: .milliseconds(50),
            timeoutResult: false
        ) {
            releaseOperation.wait()
            return true
        }

        XCTAssertFalse(result)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testBlockingOperationDeadlineIgnoresCompletionAfterTimeout() async {
        let operationStarted = DispatchSemaphore(value: 0)
        let releaseOperation = DispatchSemaphore(value: 0)
        let operationFinished = DispatchSemaphore(value: 0)
        defer { releaseOperation.signal() }

        let task = Task {
            await BlockingOperationDeadline.run(
                timeout: .milliseconds(50),
                timeoutResult: false
            ) {
                operationStarted.signal()
                releaseOperation.wait()
                operationFinished.signal()
                return true
            }
        }

        XCTAssertEqual(operationStarted.wait(timeout: .now() + 1), .success)
        let result = await task.value
        XCTAssertFalse(result)

        releaseOperation.signal()
        XCTAssertEqual(operationFinished.wait(timeout: .now() + 1), .success)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(result)
    }

    func testNonJoiningTaskDeadlineReturnsImmediateOperationResult() async throws {
        let result = try await NonJoiningTaskDeadline.run(timeout: .seconds(1)) {
            42
        }

        XCTAssertEqual(result, 42)
    }

    func testNonJoiningTaskDeadlineReturnsPromptlyAndIgnoresLateCompletion() async {
        let operationStarted = DispatchSemaphore(value: 0)
        let releaseOperation = DispatchSemaphore(value: 0)
        let operationFinished = DispatchSemaphore(value: 0)
        defer { releaseOperation.signal() }
        let start = ContinuousClock.now

        do {
            _ = try await NonJoiningTaskDeadline.run(timeout: .milliseconds(50)) {
                await withCheckedContinuation { continuation in
                    operationStarted.signal()
                    DispatchQueue.global(qos: .utility).async {
                        releaseOperation.wait()
                        operationFinished.signal()
                        continuation.resume(returning: 42)
                    }
                }
            }
            XCTFail("Expected the deadline to expire")
        } catch NonJoiningTaskDeadlineError.timedOut {
            // Expected.
        } catch {
            XCTFail("Expected a deadline error, got \(error)")
        }

        XCTAssertEqual(operationStarted.wait(timeout: .now() + 1), .success)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))

        releaseOperation.signal()
        XCTAssertEqual(operationFinished.wait(timeout: .now() + 1), .success)
        try? await Task.sleep(for: .milliseconds(20))
    }

    func testNonJoiningTaskDeadlineParentCancellationReturnsPromptly() async {
        let operationStarted = DispatchSemaphore(value: 0)
        let releaseOperation = DispatchSemaphore(value: 0)
        defer { releaseOperation.signal() }

        let task = Task {
            try await NonJoiningTaskDeadline.run(timeout: .seconds(10)) {
                await withCheckedContinuation { continuation in
                    operationStarted.signal()
                    DispatchQueue.global(qos: .utility).async {
                        releaseOperation.wait()
                        continuation.resume(returning: 42)
                    }
                }
            }
        }

        XCTAssertEqual(operationStarted.wait(timeout: .now() + 1), .success)
        let start = ContinuousClock.now
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testWhisperModelDownloadUsesExplicitNetworkDeadlines() {
        let configuration = URLSessionWhisperModelDownloadOperation.makeConfiguration()

        XCTAssertEqual(configuration.timeoutIntervalForRequest, 60)
        XCTAssertEqual(
            configuration.timeoutIntervalForResource,
            URLSessionWhisperModelDownloadOperation.resourceTimeout
        )
        XCTAssertEqual(URLSessionWhisperModelDownloadOperation.resourceTimeout, 12 * 60 * 60)
    }

    func testParakeetModelDownloadsUseExplicitNetworkDeadlines() {
        let metadataConfiguration = URLSessionParakeetModelMetadataOperation.makeConfiguration()
        let fileConfiguration = URLSessionParakeetFileDownloadOperation.makeConfiguration()

        XCTAssertEqual(metadataConfiguration.timeoutIntervalForRequest, 60)
        XCTAssertEqual(
            metadataConfiguration.timeoutIntervalForResource,
            URLSessionParakeetModelMetadataOperation.resourceTimeout
        )
        XCTAssertEqual(URLSessionParakeetModelMetadataOperation.resourceTimeout, 5 * 60)
        XCTAssertEqual(URLSessionParakeetModelMetadataOperation.maximumResponseBytes, 4 * 1_024 * 1_024)
        XCTAssertEqual(fileConfiguration.timeoutIntervalForRequest, 60)
        XCTAssertEqual(
            fileConfiguration.timeoutIntervalForResource,
            URLSessionParakeetFileDownloadOperation.resourceTimeout
        )
        XCTAssertEqual(URLSessionParakeetFileDownloadOperation.resourceTimeout, 12 * 60 * 60)
    }

    func testParakeetModelDownloadStagesCompleteCacheAndPublishesProgress() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-manager-success-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let model = ParakeetModel.allModels[0]
        let configDownload = root.appendingPathComponent("config.download")
        let weightsDownload = root.appendingPathComponent("weights.download")
        try Data("config".utf8).write(to: configDownload)
        try Data("weights".utf8).write(to: weightsDownload)
        let metadata = ParakeetModelMetadata(
            sha: "commit123",
            siblings: [
                ParakeetModelMetadata.File(
                    rfilename: "config.json",
                    size: 6,
                    lfs: nil
                ),
                ParakeetModelMetadata.File(
                    rfilename: "subdir/model.safetensors",
                    size: 7,
                    lfs: .init(
                        sha256: "9a129038d9a00aed0cf6a7ea059ca50a813449061ab87848cf1a13eafdf33b2c"
                    )
                ),
            ]
        )
        let configOperation = ControlledParakeetFileDownloadOperation()
        let weightsOperation = ControlledParakeetFileDownloadOperation()
        let operations = ParakeetFileDownloadOperationQueue([configOperation, weightsOperation])
        let recorder = ParakeetModelProgressRecorder()
        let manager = ParakeetModelManager(
            cacheDirectory: root.appendingPathComponent("hub", isDirectory: true),
            isParakeetInstalled: { true },
            metadataOperationFactory: { sourceURL in
                XCTAssertEqual(
                    URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "blobs" })?.value,
                    "true"
                )
                return ImmediateParakeetMetadataOperation(metadata: metadata)
            },
            fileDownloadOperationFactory: { _, _ in operations.next() }
        )

        let task = Task {
            try await manager.downloadModel(model) { recorder.record($0) }
        }
        await configOperation.waitUntilStarted()
        configOperation.emitProgress(bytesWritten: 3, totalExpected: 6)
        configOperation.succeed(
            temporaryURL: configDownload,
            expectedContentLength: 6,
            eTag: "\"configetag\""
        )
        await weightsOperation.waitUntilStarted()
        weightsOperation.succeed(
            temporaryURL: weightsDownload,
            expectedContentLength: 7,
            eTag: nil
        )
        try await task.value
        await recorder.waitUntilCompleted()

        let cache = manager.modelCachePath(for: model)
        XCTAssertEqual(
            try String(contentsOf: cache.appendingPathComponent("refs/main"), encoding: .utf8),
            "commit123"
        )
        XCTAssertEqual(
            try Data(contentsOf: cache.appendingPathComponent("blobs/configetag")),
            Data("config".utf8)
        )
        XCTAssertEqual(
            try Data(
                contentsOf: cache.appendingPathComponent(
                    "blobs/9a129038d9a00aed0cf6a7ea059ca50a813449061ab87848cf1a13eafdf33b2c"
                )
            ),
            Data("weights".utf8)
        )
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: cache.appendingPathComponent(
                    "snapshots/commit123/subdir/model.safetensors"
                ).path
            ),
            "../../../blobs/9a129038d9a00aed0cf6a7ea059ca50a813449061ab87848cf1a13eafdf33b2c"
        )
        XCTAssertTrue(recorder.fractions.contains { abs($0 - (3.0 / 13.0)) < 0.0001 })
        XCTAssertEqual(recorder.fractions.last, 1)
        XCTAssertFalse(
            (try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("hub").path))
                .contains { $0.hasPrefix(".parakeet-download-") }
        )
    }

    func testParakeetModelDownloadRejectsChecksumMismatchWithoutPublishing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-manager-checksum-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = ParakeetModel.allModels[0]
        let downloadedFile = root.appendingPathComponent("corrupt.download")
        try Data("corrupt".utf8).write(to: downloadedFile)
        let metadata = ParakeetModelMetadata(
            sha: "testcommit",
            siblings: [
                ParakeetModelMetadata.File(
                    rfilename: "model.safetensors",
                    size: 7,
                    lfs: .init(sha256: String(repeating: "0", count: 64))
                )
            ]
        )
        let operation = ControlledParakeetFileDownloadOperation()
        let manager = ParakeetModelManager(
            cacheDirectory: root.appendingPathComponent("hub", isDirectory: true),
            isParakeetInstalled: { true },
            metadataOperationFactory: { _ in ImmediateParakeetMetadataOperation(metadata: metadata) },
            fileDownloadOperationFactory: { _, _ in operation }
        )

        let task = Task { try await manager.downloadModel(model) { _ in } }
        await operation.waitUntilStarted()
        operation.succeed(
            temporaryURL: downloadedFile,
            expectedContentLength: 7,
            eTag: nil
        )

        do {
            try await task.value
            XCTFail("Expected checksum verification to fail")
        } catch let error as ParakeetModelDownloadError {
            XCTAssertTrue(error.localizedDescription.contains("checksum verification"))
        }
        XCTAssertFalse(manager.isModelDownloaded(model))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadedFile.path))
    }

    func testParakeetModelDownloadRejectsTruncatedNonLFSFileWithoutPublishing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-manager-truncated-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = ParakeetModel.allModels[0]
        let downloadedFile = root.appendingPathComponent("config.download")
        try Data("tiny".utf8).write(to: downloadedFile)
        let metadata = ParakeetModelMetadata(
            sha: "testcommit",
            siblings: [
                ParakeetModelMetadata.File(
                    rfilename: "config.json",
                    size: 8,
                    lfs: nil
                )
            ]
        )
        let operation = ControlledParakeetFileDownloadOperation()
        let cacheDirectory = root.appendingPathComponent("hub", isDirectory: true)
        let manager = ParakeetModelManager(
            cacheDirectory: cacheDirectory,
            isParakeetInstalled: { true },
            metadataOperationFactory: { _ in ImmediateParakeetMetadataOperation(metadata: metadata) },
            fileDownloadOperationFactory: { _, _ in operation }
        )

        let task = Task { try await manager.downloadModel(model) { _ in } }
        await operation.waitUntilStarted()
        operation.succeed(
            temporaryURL: downloadedFile,
            expectedContentLength: 8,
            eTag: "configetag"
        )

        do {
            try await task.value
            XCTFail("Expected truncated non-LFS content to fail size validation")
        } catch let error as ParakeetModelDownloadError {
            XCTAssertTrue(error.localizedDescription.contains("unexpected size"))
        } catch {
            XCTFail("Expected a Parakeet download error, got \(error)")
        }

        let cache = manager.modelCachePath(for: model)
        XCTAssertFalse(manager.isModelDownloaded(model))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("refs/main").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadedFile.path))
        if FileManager.default.fileExists(atPath: cacheDirectory.path) {
            XCTAssertFalse(
                (try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path))
                    .contains { $0.hasPrefix(".parakeet-download-") }
            )
        }
    }

    func testParakeetModelMetadataCancellationIsPromptAndTargeted() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-manager-metadata-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ParakeetModel.allModels[0]
        let metadataOperation = ControlledParakeetMetadataOperation()
        let manager = ParakeetModelManager(
            cacheDirectory: root,
            isParakeetInstalled: { true },
            metadataOperationFactory: { _ in metadataOperation },
            fileDownloadOperationFactory: { _, _ in
                XCTFail("A file download should not start after metadata cancellation")
                return ControlledParakeetFileDownloadOperation()
            }
        )
        let task = Task { try await manager.downloadModel(model) { _ in } }
        await metadataOperation.waitUntilStarted()

        let start = ContinuousClock.now
        await manager.cancelDownload(for: model)
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }

        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(metadataOperation.cancellationCount, 1)
        let status = await manager.getModelStatus(model)
        XCTAssertEqual(status, .notDownloaded)
    }

    func testParakeetModelManagerExposesActiveDownloadAndRejectsDuplicateCaller() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-manager-active-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ParakeetModel.allModels[0]
        let metadata = makeParakeetMetadata(fileName: "model.bin")
        let fileOperation = ControlledParakeetFileDownloadOperation()
        let manager = ParakeetModelManager(
            cacheDirectory: root,
            isParakeetInstalled: { true },
            metadataOperationFactory: { _ in ImmediateParakeetMetadataOperation(metadata: metadata) },
            fileDownloadOperationFactory: { _, _ in fileOperation }
        )
        let task = Task { try await manager.downloadModel(model) { _ in } }
        await fileOperation.waitUntilStarted()
        fileOperation.emitProgress(bytesWritten: 2, totalExpected: 4)

        let activeStatus = await manager.getModelStatus(model)
        XCTAssertEqual(activeStatus, .downloading)
        for _ in 0..<100 {
            if await manager.getDownloadProgress(model) != nil { break }
            await Task.yield()
        }
        let progress = await manager.getDownloadProgress(model)
        XCTAssertEqual(progress?.currentFileFraction, 0.5)

        do {
            try await manager.downloadModel(model) { _ in }
            XCTFail("Expected a duplicate caller to be rejected")
        } catch ParakeetModelDownloadError.downloadAlreadyInProgress {
            // Expected.
        } catch {
            XCTFail("Expected an already-in-progress error, got \(error)")
        }

        await manager.cancelDownload(for: model)
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
    }

    func testParakeetModelManagerPreservesTerminalFailureForRecreatedSettings() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-manager-terminal-state-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ParakeetModel.allModels[0]
        let metadata = makeParakeetMetadata(fileName: "model.bin")
        let fileOperation = ControlledParakeetFileDownloadOperation()
        let manager = ParakeetModelManager(
            cacheDirectory: root,
            isParakeetInstalled: { true },
            metadataOperationFactory: { _ in ImmediateParakeetMetadataOperation(metadata: metadata) },
            fileDownloadOperationFactory: { _, _ in fileOperation }
        )
        let task = Task { try await manager.downloadModel(model) { _ in } }
        await fileOperation.waitUntilStarted()
        fileOperation.fail(with: URLError(.networkConnectionLost))

        do {
            try await task.value
            XCTFail("Expected the download to fail")
        } catch is URLError {
            // Expected.
        } catch {
            XCTFail("Expected the original network failure, got \(error)")
        }

        let preservedFailure = await manager.takeDownloadFailure(model)
        XCTAssertNotNil(preservedFailure)
        XCTAssertTrue(preservedFailure?.isEmpty == false)
        let consumedFailure = await manager.takeDownloadFailure(model)
        XCTAssertNil(consumedFailure)
    }

    func testParakeetModelDownloadAtomicallyReplacesIncompleteCache() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-manager-cache-replace-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = ParakeetModel.allModels[0]
        let hub = root.appendingPathComponent("hub", isDirectory: true)
        let existingCache = hub.appendingPathComponent("models--" + model.id.replacingOccurrences(of: "/", with: "--"))
        try FileManager.default.createDirectory(at: existingCache, withIntermediateDirectories: true)
        let staleFile = existingCache.appendingPathComponent("stale-partial-download")
        try Data("stale".utf8).write(to: staleFile)

        let metadata = makeParakeetMetadata(fileName: "model.bin")
        let downloadedFile = root.appendingPathComponent("model.download")
        try Data("complete".utf8).write(to: downloadedFile)
        let fileOperation = ControlledParakeetFileDownloadOperation()
        let manager = ParakeetModelManager(
            cacheDirectory: hub,
            isParakeetInstalled: { true },
            metadataOperationFactory: { _ in ImmediateParakeetMetadataOperation(metadata: metadata) },
            fileDownloadOperationFactory: { _, _ in fileOperation }
        )

        let task = Task { try await manager.downloadModel(model) { _ in } }
        await fileOperation.waitUntilStarted()
        fileOperation.succeed(
            temporaryURL: downloadedFile,
            expectedContentLength: 8,
            eTag: "complete"
        )
        try await task.value

        XCTAssertTrue(manager.isModelDownloaded(model))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFile.path))
        XCTAssertEqual(
            try Data(contentsOf: existingCache.appendingPathComponent("blobs/complete")),
            Data("complete".utf8)
        )
    }

    func testParakeetModelDownloadMapsLateFailureAfterTargetedCancellation() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-manager-late-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ParakeetModel.allModels[0]
        let metadata = makeParakeetMetadata(fileName: "model.bin")
        let fileOperation = ControlledParakeetFileDownloadOperation(honorsCancellation: false)
        let manager = ParakeetModelManager(
            cacheDirectory: root,
            isParakeetInstalled: { true },
            metadataOperationFactory: { _ in ImmediateParakeetMetadataOperation(metadata: metadata) },
            fileDownloadOperationFactory: { _, _ in fileOperation }
        )
        let task = Task { try await manager.downloadModel(model) { _ in } }
        await fileOperation.waitUntilStarted()
        await manager.cancelDownload(for: model)
        fileOperation.fail(with: URLError(.networkConnectionLost))

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: a late network failure must retain the user's cancellation outcome.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
    }

    func testParakeetModelDownloadRejectsUnsafeRemotePathBeforeFileDownload() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-manager-unsafe-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ParakeetModel.allModels[0]
        let metadata = makeParakeetMetadata(fileName: "../outside.bin")
        let manager = ParakeetModelManager(
            cacheDirectory: root,
            isParakeetInstalled: { true },
            metadataOperationFactory: { _ in ImmediateParakeetMetadataOperation(metadata: metadata) },
            fileDownloadOperationFactory: { _, _ in
                XCTFail("Unsafe metadata must be rejected before starting a file download")
                return ControlledParakeetFileDownloadOperation()
            }
        )

        do {
            try await manager.downloadModel(model) { _ in }
            XCTFail("Expected unsafe metadata to be rejected")
        } catch let error as ParakeetModelDownloadError {
            XCTAssertTrue(error.localizedDescription.contains("unsafe file path"))
        } catch {
            XCTFail("Expected a Parakeet download error, got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("outside.bin").path))
        XCTAssertFalse(manager.isModelDownloaded(model))
    }

    func testParakeetModelDownloadParentCancellationStopsActiveFile() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-manager-parent-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ParakeetModel.allModels[0]
        let metadata = makeParakeetMetadata(fileName: "model.bin")
        let fileOperation = ControlledParakeetFileDownloadOperation()
        let manager = ParakeetModelManager(
            cacheDirectory: root,
            isParakeetInstalled: { true },
            metadataOperationFactory: { _ in ImmediateParakeetMetadataOperation(metadata: metadata) },
            fileDownloadOperationFactory: { _, _ in fileOperation }
        )
        let task = Task { try await manager.downloadModel(model) { _ in } }
        await fileOperation.waitUntilStarted()

        let start = ContinuousClock.now
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }

        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(fileOperation.cancellationCount, 1)
        XCTAssertFalse(manager.isModelDownloaded(model))
    }

    func testParakeetModelCancellationDoesNotStopAnotherModel() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-manager-isolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstModel = ParakeetModel.allModels[0]
        let secondModel = ParakeetModel.allModels[1]
        let metadata = makeParakeetMetadata(fileName: "model.bin")
        let firstOperation = ControlledParakeetFileDownloadOperation()
        let secondOperation = ControlledParakeetFileDownloadOperation()
        let secondFile = root.appendingPathComponent("second.download")
        try Data("second".utf8).write(to: secondFile)
        let manager = ParakeetModelManager(
            cacheDirectory: root.appendingPathComponent("hub", isDirectory: true),
            isParakeetInstalled: { true },
            metadataOperationFactory: { _ in ImmediateParakeetMetadataOperation(metadata: metadata) },
            fileDownloadOperationFactory: { url, _ in
                url.absoluteString.contains(firstModel.id) ? firstOperation : secondOperation
            }
        )

        let firstTask = Task { try await manager.downloadModel(firstModel) { _ in } }
        let secondTask = Task { try await manager.downloadModel(secondModel) { _ in } }
        await firstOperation.waitUntilStarted()
        await secondOperation.waitUntilStarted()
        await manager.cancelDownload(for: firstModel)
        secondOperation.succeed(temporaryURL: secondFile, expectedContentLength: 6, eTag: "second")

        do {
            try await firstTask.value
            XCTFail("Expected the first model download to be cancelled")
        } catch is CancellationError {
            // Expected.
        }
        try await secondTask.value

        XCTAssertEqual(firstOperation.cancellationCount, 1)
        XCTAssertEqual(secondOperation.cancellationCount, 0)
        XCTAssertFalse(manager.isModelDownloaded(firstModel))
        XCTAssertTrue(manager.isModelDownloaded(secondModel))
    }

    func testParakeetModelLateCancelledAttemptCannotReplaceRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parakeet-manager-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let model = ParakeetModel.allModels[0]
        let metadata = makeParakeetMetadata(fileName: "model.bin")
        let firstFile = root.appendingPathComponent("first.download")
        let secondFile = root.appendingPathComponent("second.download")
        try Data("first".utf8).write(to: firstFile)
        try Data("second".utf8).write(to: secondFile)
        let firstOperation = ControlledParakeetFileDownloadOperation(honorsCancellation: false)
        let secondOperation = ControlledParakeetFileDownloadOperation()
        let operations = ParakeetFileDownloadOperationQueue([firstOperation, secondOperation])
        let manager = ParakeetModelManager(
            cacheDirectory: root.appendingPathComponent("hub", isDirectory: true),
            isParakeetInstalled: { true },
            metadataOperationFactory: { _ in ImmediateParakeetMetadataOperation(metadata: metadata) },
            fileDownloadOperationFactory: { _, _ in operations.next() }
        )

        let firstTask = Task { try await manager.downloadModel(model) { _ in } }
        await firstOperation.waitUntilStarted()
        await manager.cancelDownload(for: model)

        let retryTask = Task { try await manager.downloadModel(model) { _ in } }
        await secondOperation.waitUntilStarted()
        secondOperation.succeed(temporaryURL: secondFile, expectedContentLength: 6, eTag: "second")
        try await retryTask.value

        firstOperation.succeed(temporaryURL: firstFile, expectedContentLength: 5, eTag: "first")
        do {
            try await firstTask.value
            XCTFail("Expected the cancelled attempt to reject its late result")
        } catch is CancellationError {
            // Expected.
        }

        let installedBlob = manager.modelCachePath(for: model).appendingPathComponent("blobs/second")
        XCTAssertEqual(try Data(contentsOf: installedBlob), Data("second".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFile.path))
        XCTAssertEqual(firstOperation.cancellationCount, 1)
    }

    func testWhisperModelDownloadPublishesOwnedTemporaryFileAndProgress() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-manager-success-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloadedFile = root.appendingPathComponent("download.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("model-data".utf8).write(to: downloadedFile)

        let operation = ControlledWhisperModelDownloadOperation()
        let recorder = WhisperProgressRecorder()
        let manager = WhisperModelManager(
            modelsDirectory: root.appendingPathComponent("models", isDirectory: true),
            operationFactory: { _, _ in operation }
        )

        let task = Task {
            try await manager.downloadModel(.base) { value in
                recorder.record(value)
            }
        }
        await operation.waitUntilStarted()
        operation.emitProgress(0.35)
        await recorder.waitUntilContains(0.35)
        operation.succeed(with: downloadedFile)
        try await task.value

        let installedURL = manager.modelPath(for: .base)
        XCTAssertEqual(try Data(contentsOf: installedURL), Data("model-data".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadedFile.path))
        XCTAssertEqual(recorder.values.last, 1)
        XCTAssertTrue(recorder.values.contains(0.35))
        let status = await manager.getModelStatus(.base)
        XCTAssertEqual(status, .downloaded)
    }

    func testWhisperModelDownloadParentCancellationStopsOperationPromptly() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-manager-parent-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let operation = ControlledWhisperModelDownloadOperation()
        let manager = WhisperModelManager(
            modelsDirectory: root,
            operationFactory: { _, _ in operation }
        )
        let task = Task {
            try await manager.downloadModel(.base) { _ in }
        }
        await operation.waitUntilStarted()

        let start = ContinuousClock.now
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected the model download to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }

        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(operation.cancellationCount, 1)
        let status = await manager.getModelStatus(.base)
        XCTAssertEqual(status, .notDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.modelPath(for: .base).path))
    }

    func testWhisperModelDownloadLateCancelledAttemptCannotReplaceRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper-manager-retry-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstFile = root.appendingPathComponent("first.bin")
        let secondFile = root.appendingPathComponent("second.bin")
        try Data("first".utf8).write(to: firstFile)
        try Data("second".utf8).write(to: secondFile)

        let firstOperation = ControlledWhisperModelDownloadOperation(honorsCancellation: false)
        let secondOperation = ControlledWhisperModelDownloadOperation()
        let operations = WhisperModelDownloadOperationQueue([firstOperation, secondOperation])
        let manager = WhisperModelManager(
            modelsDirectory: root.appendingPathComponent("models", isDirectory: true),
            operationFactory: { _, _ in operations.next() }
        )

        let firstTask = Task { try await manager.downloadModel(.base) { _ in } }
        await firstOperation.waitUntilStarted()
        await manager.cancelDownload(for: .base)

        let retryTask = Task { try await manager.downloadModel(.base) { _ in } }
        await secondOperation.waitUntilStarted()
        secondOperation.succeed(with: secondFile)
        try await retryTask.value

        firstOperation.succeed(with: firstFile)
        do {
            try await firstTask.value
            XCTFail("Expected the cancelled attempt to reject its late result")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: manager.modelPath(for: .base)), Data("second".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFile.path))
        XCTAssertEqual(firstOperation.cancellationCount, 1)
    }

    func testCaptureWriterFinalizationReturnsAfterImmediateCallback() async throws {
        try await CaptureWriterFinalization.wait(timeout: .seconds(1)) { completion in
            completion()
        }
    }

    func testCaptureWriterFinalizationDoesNotJoinMissingOrLateCallback() async {
        let callbackRegistered = DispatchSemaphore(value: 0)
        let lateCompletion = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
        let start = ContinuousClock.now

        do {
            try await CaptureWriterFinalization.wait(timeout: .milliseconds(50)) { completion in
                lateCompletion.withLock { $0 = completion }
                callbackRegistered.signal()
            }
            XCTFail("Expected finalization timeout")
        } catch CaptureWriterFinalizationError.timedOut {
            // Expected.
        } catch {
            XCTFail("Expected finalization timeout, got \(error)")
        }

        XCTAssertEqual(callbackRegistered.wait(timeout: .now() + 1), .success)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))

        // A late AVFoundation callback must only finish the detached losing operation;
        // it must not resume the already-completed caller a second time.
        let callback = lateCompletion.withLock { completion -> (@Sendable () -> Void)? in
            let callback = completion
            completion = nil
            return callback
        }
        callback?()
        try? await Task.sleep(for: .milliseconds(20))
    }

    func testCaptureWriterFinalizationParentCancellationReturnsPromptly() async {
        let callbackRegistered = DispatchSemaphore(value: 0)
        let lateCompletion = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
        let task = Task {
            try await CaptureWriterFinalization.wait(timeout: .seconds(10)) { completion in
                lateCompletion.withLock { $0 = completion }
                callbackRegistered.signal()
            }
        }

        XCTAssertEqual(callbackRegistered.wait(timeout: .now() + 1), .success)
        let start = ContinuousClock.now
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))

        let callback = lateCompletion.withLock { completion -> (@Sendable () -> Void)? in
            let callback = completion
            completion = nil
            return callback
        }
        callback?()
    }

    @MainActor
    func testPreviewReadyStatusBoundsMetadataAndInitialSeek() async throws {
        let url = URL(fileURLWithPath: "/private/stalled-preview.mov")
        let video = VideoItem(url: url, name: "Preview", size: 0, duration: "00:00:01",
                              status: .waiting, progress: 0, eta: nil, outputURL: nil)
        let controller = PreviewPlayerController(videoItem: video)
        let item = AVPlayerItem(url: url)
        controller.player = AVPlayer(playerItem: item)
        let releaseMetadata = DispatchSemaphore(value: 0)
        let releaseSeek = DispatchSemaphore(value: 0)
        defer {
            releaseMetadata.signal()
            releaseSeek.signal()
            controller.teardown()
        }
        let started = ContinuousClock.now
        controller.prepareReadyPlayerItem(item, startTime: 0, timeout: .milliseconds(30), verify: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    releaseMetadata.wait()
                    continuation.resume(returning: true)
                }
            }
        }, seek: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    releaseSeek.wait()
                    continuation.resume(returning: true)
                }
            }
        })
        let task = try XCTUnwrap(controller.playerItemStatusTask)
        await task.value
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        XCTAssertTrue(controller.isReady)
        XCTAssertNil(controller.playerItemStatusTask)
    }

    @MainActor
    func testPreviewStatusRemovalCancelsWorkAndRejectsLateUnsupportedResult() async throws {
        let url = URL(fileURLWithPath: "/private/replaced-preview.mov")
        let video = VideoItem(url: url, name: "Preview", size: 0, duration: "00:00:01",
                              status: .waiting, progress: 0, eta: nil, outputURL: nil)
        let controller = PreviewPlayerController(videoItem: video)
        let item = AVPlayerItem(url: url)
        controller.player = AVPlayer(playerItem: item)
        let probeStarted = expectation(description: "Metadata inspection started")
        let probeFinished = expectation(description: "Late metadata inspection finished")
        let release = DispatchSemaphore(value: 0)
        defer { controller.teardown() }
        controller.prepareReadyPlayerItem(item, startTime: 0, verify: {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    probeStarted.fulfill()
                    release.wait()
                    probeFinished.fulfill()
                    continuation.resume(returning: false)
                }
            }
        }, seek: { true })
        let task = try XCTUnwrap(controller.playerItemStatusTask)
        await fulfillment(of: [probeStarted], timeout: 1)
        controller.removePlayerItemStatusObserver()
        let replacement = AVPlayer()
        controller.player = replacement
        let started = ContinuousClock.now
        await task.value
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        release.signal()
        await fulfillment(of: [probeFinished], timeout: 1)
        XCTAssertTrue(controller.player === replacement)
        XCTAssertFalse(controller.useMPV)
        XCTAssertFalse(controller.isReady)
        XCTAssertNil(controller.playerItemStatusTask)
    }

    func testBoundedVideoMetadataProbeReturnsSuccessfulResult() async throws {
        let expected = videoMetadata(timecode: "01:02:03:04", frameRate: 25)

        let actual = try await BoundedVideoMetadataProbe.metadata(
            for: URL(fileURLWithPath: "/private/success.mov"),
            timeout: .seconds(1)
        ) { _ in expected }

        XCTAssertEqual(actual, expected)
    }

    func testBoundedVideoMetadataProbeDoesNotJoinTimedOutRead() async {
        let probeStarted = DispatchSemaphore(value: 0)
        let releaseProbe = DispatchSemaphore(value: 0)
        defer { releaseProbe.signal() }
        let start = ContinuousClock.now

        do {
            _ = try await BoundedVideoMetadataProbe.metadata(
                for: URL(fileURLWithPath: "/private/stalled.mov"),
                timeout: .milliseconds(50)
            ) { _ in
                try await withCheckedThrowingContinuation { continuation in
                    probeStarted.signal()
                    DispatchQueue.global(qos: .utility).async {
                        releaseProbe.wait()
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
            XCTFail("Expected metadata timeout")
        } catch NonJoiningTaskDeadlineError.timedOut {
            // Expected.
        } catch {
            XCTFail("Expected deadline error, got \(error)")
        }

        XCTAssertEqual(probeStarted.wait(timeout: .now() + 1), .success)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testDeinterlacePlanningDoesNotJoinTimedOutMetadataProbe() async {
        let probeStarted = DispatchSemaphore(value: 0)
        let releaseProbe = DispatchSemaphore(value: 0)
        defer { releaseProbe.signal() }
        var arguments = ["-vf", "yadif=0,scale=1920:1080"]
        let start = ContinuousClock.now

        await FFMPEGCommandBuilder.adjustDeinterlaceFilter(
            inputURL: URL(fileURLWithPath: "/private/stalled-deinterlace.mov"),
            ffmpegArgs: &arguments,
            metadataTimeout: .milliseconds(50)
        ) { _ in
            try await withCheckedThrowingContinuation { continuation in
                probeStarted.signal()
                DispatchQueue.global(qos: .utility).async {
                    releaseProbe.wait()
                    continuation.resume(throwing: CancellationError())
                }
            }
        }

        XCTAssertEqual(probeStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(arguments, ["-vf", "scale=1920:1080"])
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testFFMPEGProbeFacadeDoesNotJoinTimedOutRawMetadataReads() async {
        let probeStarted = DispatchSemaphore(value: 0)
        let releaseProbe = DispatchSemaphore(value: 0)
        defer {
            for _ in 0..<4 {
                releaseProbe.signal()
            }
        }
        let url = URL(fileURLWithPath: "/private/stalled.mov")
        let start = ContinuousClock.now

        async let audioStreams = FFMPEGProbeService.fetchAudioStreams(
            for: url,
            timeout: .milliseconds(50)
        ) { _ in
            try await withCheckedThrowingContinuation { continuation in
                probeStarted.signal()
                DispatchQueue.global(qos: .utility).async {
                    releaseProbe.wait()
                    continuation.resume(throwing: CancellationError())
                }
            }
        }
        async let duration = FFMPEGProbeService.getVideoDuration(
            for: url,
            timeout: .milliseconds(50)
        ) { _ in
            try await withCheckedThrowingContinuation { continuation in
                probeStarted.signal()
                DispatchQueue.global(qos: .utility).async {
                    releaseProbe.wait()
                    continuation.resume(throwing: CancellationError())
                }
            }
        }
        async let chapters = FFMPEGProbeService.fetchChapters(
            for: url,
            timeout: .milliseconds(50)
        ) { _ in
            try await withCheckedThrowingContinuation { continuation in
                probeStarted.signal()
                DispatchQueue.global(qos: .utility).async {
                    releaseProbe.wait()
                    continuation.resume(throwing: CancellationError())
                }
            }
        }
        async let verification = FFMPEGProbeService.verifyOutputStreams(
            for: url,
            timeout: .milliseconds(50)
        ) { _ in
            try await withCheckedThrowingContinuation { continuation in
                probeStarted.signal()
                DispatchQueue.global(qos: .utility).async {
                    releaseProbe.wait()
                    continuation.resume(throwing: CancellationError())
                }
            }
        }

        let results = await (audioStreams, duration, chapters, verification)

        for _ in 0..<4 {
            XCTAssertEqual(probeStarted.wait(timeout: .now() + 1), .success)
        }
        XCTAssertNil(results.0)
        XCTAssertNil(results.1)
        XCTAssertTrue(results.2.isEmpty)
        XCTAssertNil(results.3)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testBoundedVideoMetadataBatchUsesOneConcurrentDeadlineWindow() async throws {
        let urls = (0..<10).map { URL(fileURLWithPath: "/private/stalled-\($0).mov") }
        let expected = videoMetadata(timecode: nil, frameRate: 25)
        let start = ContinuousClock.now

        let metadata = try await BoundedVideoMetadataProbe.availableMetadata(
            for: urls,
            timeout: .milliseconds(100)
        ) { _ in
            try await Task.sleep(for: .seconds(10))
            return expected
        }

        XCTAssertTrue(metadata.isEmpty)
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(500))
    }

    @MainActor
    func testPreviewAudioDiscoveryDoesNotJoinTimedOutMetadataProbe() async {
        let url = URL(fileURLWithPath: "/private/stalled-player-audio.mov")
        let item = VideoItem(
            url: url,
            name: url.lastPathComponent,
            size: 0,
            duration: "--:--",
            thumbnailData: nil,
            status: .waiting,
            progress: 0,
            eta: nil,
            outputURL: nil
        )
        let controller = PreviewPlayerController(videoItem: item)
        let probeStarted = DispatchSemaphore(value: 0)
        let releaseProbe = DispatchSemaphore(value: 0)
        defer { releaseProbe.signal() }
        let start = ContinuousClock.now

        do {
            _ = try await controller.determineAudioStreamOrder(
                for: item,
                metadataTimeout: .milliseconds(50)
            ) { _ in
                try await withCheckedThrowingContinuation { continuation in
                    probeStarted.signal()
                    DispatchQueue.global(qos: .utility).async {
                        releaseProbe.wait()
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
            XCTFail("Expected metadata timeout")
        } catch NonJoiningTaskDeadlineError.timedOut {
            // Expected.
        } catch {
            XCTFail("Expected deadline error, got \(error)")
        }

        XCTAssertEqual(probeStarted.wait(timeout: .now() + 1), .success)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testMergeCompatibilityMetadataProbePreservesParentCancellation() async {
        let firstURL = URL(fileURLWithPath: "/private/merge-a.mov")
        let secondURL = URL(fileURLWithPath: "/private/merge-b.mov")
        let items = [firstURL, secondURL].map {
            VideoItem(
                url: $0,
                name: $0.lastPathComponent,
                size: 0,
                duration: "--:--",
                thumbnailData: nil,
                status: .waiting,
                progress: 0,
                eta: nil,
                outputURL: nil
            )
        }
        let probeStarted = DispatchSemaphore(value: 0)
        let releaseProbe = DispatchSemaphore(value: 0)
        defer { releaseProbe.signal() }

        let task = Task {
            await ConversionManager.shared.evaluateMergeCompatibility(
                for: items,
                preset: .streamCopy,
                metadataTimeout: .seconds(10)
            ) { _ in
                try await withCheckedThrowingContinuation { continuation in
                    probeStarted.signal()
                    DispatchQueue.global(qos: .utility).async {
                        releaseProbe.wait()
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
        }

        XCTAssertEqual(probeStarted.wait(timeout: .now() + 1), .success)
        let start = ContinuousClock.now
        task.cancel()

        guard case .cancelled = await task.value else {
            return XCTFail("Expected cancelled compatibility result")
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testMergeCompatibilityDistinguishesUnavailableMetadataFromMissingVideo() {
        let firstURL = URL(fileURLWithPath: "/private/merge-a.mov")
        let secondURL = URL(fileURLWithPath: "/private/merge-b.mov")
        let items = [firstURL, secondURL].map {
            VideoItem(
                url: $0,
                name: $0.lastPathComponent,
                size: 0,
                duration: "--:--",
                thumbnailData: nil,
                status: .waiting,
                progress: 0,
                eta: nil,
                outputURL: nil
            )
        }

        let result = ConversionManager.checkMergeCompatibility(items: items, metadata: [:])

        guard case .metadataUnavailable(let unavailableItem) = result else {
            return XCTFail("Expected unavailable metadata instead of a missing-video result")
        }
        XCTAssertEqual(unavailableItem.id, items[0].id)
    }

    func testVideoMetadataFallbackDoesNotJoinTimedOutFullProbe() async {
        let releaseFullProbe = DispatchSemaphore(value: 0)
        defer { releaseFullProbe.signal() }
        let expectedInfo = EssentialVideoInfo(
            duration: 12.5,
            hasVideoStream: true,
            videoStreamCount: 1,
            hasAudioStream: true,
            primaryCodec: "h264",
            width: 1920,
            height: 1080
        )
        let start = ContinuousClock.now

        let outcome = await VideoFileUtils.fetchVideoMetadataWithFallback(
            for: URL(fileURLWithPath: "/private/stalled.mov"),
            timeout: .milliseconds(50),
            metadataProbe: { _ in
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        releaseFullProbe.wait()
                        continuation.resume(throwing: CancellationError())
                    }
                }
            },
            essentialInfoProbe: { _ in expectedInfo }
        )

        guard case .essentialOnly(let info) = outcome else {
            return XCTFail("Expected the bounded essential-info fallback")
        }
        XCTAssertEqual(info.duration, expectedInfo.duration)
        XCTAssertEqual(info.hasVideoStream, expectedInfo.hasVideoStream)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testPlayerMetadataFetchDoesNotJoinTimedOutProbe() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StalledPlayerMetadata-\(UUID().uuidString).mov")
        try Data([0x00]).write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let releaseProbe = DispatchSemaphore(value: 0)
        defer { releaseProbe.signal() }
        let start = ContinuousClock.now

        let metadata = await VideoFileUtils.fetchMetadata(
            for: temporaryURL,
            timeout: .milliseconds(50)
        ) { _ in
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    releaseProbe.wait()
                    continuation.resume(throwing: CancellationError())
                }
            }
        }

        XCTAssertNil(metadata)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testC2PAMetadataFetchDoesNotJoinTimedOutProbe() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("StalledC2PAMetadata-\(UUID().uuidString).mov")
        try Data([0x00]).write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let probeStarted = DispatchSemaphore(value: 0)
        let releaseProbe = DispatchSemaphore(value: 0)
        defer { releaseProbe.signal() }
        let start = ContinuousClock.now

        let metadata = await VideoFileUtils.fetchC2PAMetadata(
            for: temporaryURL,
            timeout: .milliseconds(50)
        ) { _ in
            try await withCheckedThrowingContinuation { continuation in
                probeStarted.signal()
                DispatchQueue.global(qos: .utility).async {
                    releaseProbe.wait()
                    continuation.resume(throwing: CancellationError())
                }
            }
        }

        XCTAssertEqual(probeStarted.wait(timeout: .now() + 1), .success)
        XCTAssertNil(metadata)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testCameraMetadataFetchParentCancellationReturnsPromptly() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CancelledCameraMetadata-\(UUID().uuidString).mov")
        try Data([0x00]).write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let probeStarted = DispatchSemaphore(value: 0)
        let releaseProbe = DispatchSemaphore(value: 0)
        defer { releaseProbe.signal() }
        let task = Task {
            await VideoFileUtils.fetchCameraMetadata(
                for: temporaryURL,
                timeout: .seconds(10)
            ) { _ in
                try await withCheckedThrowingContinuation { continuation in
                    probeStarted.signal()
                    DispatchQueue.global(qos: .utility).async {
                        releaseProbe.wait()
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
        }

        XCTAssertEqual(probeStarted.wait(timeout: .now() + 1), .success)
        let start = ContinuousClock.now
        task.cancel()

        let metadata = await task.value
        XCTAssertNil(metadata)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testRowThumbnailFetchDoesNotJoinTimedOutProbe() async {
        let probeStarted = DispatchSemaphore(value: 0)
        let releaseProbe = DispatchSemaphore(value: 0)
        defer { releaseProbe.signal() }
        let start = ContinuousClock.now

        let thumbnail = await VideoFileUtils.fetchRowThumbnail(
            for: URL(fileURLWithPath: "/private/stalled-thumbnail.mov"),
            timeout: .milliseconds(50)
        ) { _, _ in
            await withCheckedContinuation { continuation in
                probeStarted.signal()
                DispatchQueue.global(qos: .utility).async {
                    releaseProbe.wait()
                    continuation.resume(returning: Data([0x01]))
                }
            }
        }

        XCTAssertEqual(probeStarted.wait(timeout: .now() + 1), .success)
        XCTAssertNil(thumbnail)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testRowThumbnailFetchParentCancellationReturnsPromptly() async {
        let probeStarted = DispatchSemaphore(value: 0)
        let releaseProbe = DispatchSemaphore(value: 0)
        defer { releaseProbe.signal() }
        let task = Task {
            await VideoFileUtils.fetchRowThumbnail(
                for: URL(fileURLWithPath: "/private/cancelled-thumbnail.mov"),
                timeout: .seconds(10)
            ) { _, _ in
                await withCheckedContinuation { continuation in
                    probeStarted.signal()
                    DispatchQueue.global(qos: .utility).async {
                        releaseProbe.wait()
                        continuation.resume(returning: Data([0x01]))
                    }
                }
            }
        }

        XCTAssertEqual(probeStarted.wait(timeout: .now() + 1), .success)
        let start = ContinuousClock.now
        task.cancel()

        let thumbnail = await task.value
        XCTAssertNil(thumbnail)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testYTDLPVersionProbeUsesBoundedRunnerAndParsesToolVersions() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YTDLPVersionProbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let ytdlpURL = temporaryDirectory.appendingPathComponent("private yt-dlp")
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: ytdlpURL)
        let runner = SequencedRecordingSubprocessRunner { index, _, _ in
            switch index {
            case 0:
                return successfulSubprocessResult(
                    standardOutput: "deno 2.4.1 (stable, aarch64-apple-darwin)\nv8 13.7\n"
                )
            default:
                return successfulSubprocessResult(standardOutput: "2026.09.01\n")
            }
        }
        let probe = YTDLPVersionProbe(subprocessRunner: runner)

        let denoVersion = await probe.denoVersion(at: "/private/tools/deno")
        let ytdlpVersion = await probe.ytdlpVersion(at: ytdlpURL.path)

        XCTAssertEqual(denoVersion, "2.4.1")
        XCTAssertEqual(ytdlpVersion, "2026.09.01")
        let requests = runner.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].executableURL.path, "/private/tools/deno")
        XCTAssertEqual(requests[0].arguments, ["--version"])
        XCTAssertEqual(requests[1].executableURL, ytdlpURL)
        XCTAssertEqual(requests[1].arguments, ["--version"])
        for request in requests {
            XCTAssertEqual(request.timeout, .seconds(3))
            XCTAssertEqual(request.standardOutputCaptureLimit, 64 * 1024)
            XCTAssertEqual(request.standardErrorCaptureLimit, 64 * 1024)
            XCTAssertFalse(request.redactedCommandDescription.contains("private"))
        }
    }

    func testYTDLPVersionProbeRejectsNonzeroTruncatedAndFailedRuns() async {
        let nonzeroRunner = RecordingSubprocessRunner { _, _ in
            successfulSubprocessResult(standardOutput: "deno 9.9.9\n", terminationStatus: 7)
        }
        let nonzeroVersion = await YTDLPVersionProbe(subprocessRunner: nonzeroRunner)
            .denoVersion(at: "/deno")
        XCTAssertNil(nonzeroVersion)

        let truncatedRunner = RecordingSubprocessRunner { _, _ in
            SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data("2026.09.01".utf8),
                standardError: Data(),
                discardedStandardOutputBytes: 1,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(10)
            )
        }
        let truncatedVersion = await YTDLPVersionProbe(subprocessRunner: truncatedRunner)
            .ytdlpVersion(at: "/yt-dlp")
        XCTAssertNil(truncatedVersion)

        let failedRunner = RecordingSubprocessRunner { request, _ in
            throw SubprocessRunnerError.failedToStart(
                command: request.redactedCommandDescription,
                underlying: "fixture launch failure"
            )
        }
        let failedVersion = await YTDLPVersionProbe(subprocessRunner: failedRunner)
            .denoVersion(at: "/deno")
        XCTAssertNil(failedVersion)
    }

    func testYTDLPVersionProbeMapsTimeoutAndParentCancellationToNil() async {
        let timeoutRunner = RecordingSubprocessRunner { request, _ in
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: successfulSubprocessResult(terminationStatus: SIGKILL)
            )
        }
        let timeoutVersion = await YTDLPVersionProbe(subprocessRunner: timeoutRunner)
            .denoVersion(at: "/deno")
        XCTAssertNil(timeoutVersion)

        let blockingRunner = CountingBlockingSubprocessRunner()
        let probe = YTDLPVersionProbe(subprocessRunner: blockingRunner)
        let task = Task { await probe.denoVersion(at: "/deno") }
        await blockingRunner.waitUntilStarted(count: 1)
        task.cancel()

        let cancelledVersion = await task.value
        XCTAssertNil(cancelledVersion)
        XCTAssertEqual(blockingRunner.cancelledCount, 1)
    }

    func testYTDLPWarmUpUsesOwnedBoundedRunnerWithDiscardedOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YTDLPWarmUp-\(UUID().uuidString)", isDirectory: true)
        let ytdlpURL = temporaryDirectory.appendingPathComponent("private yt-dlp")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: ytdlpURL)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = RecordingSubprocessRunner { _, _ in
            successfulSubprocessResult(standardOutput: "2026.09.03\n")
        }

        let result = try await YTDLPWarmUpRunner(subprocessRunner: runner).run(at: ytdlpURL.path)

        XCTAssertTrue(result.succeeded)
        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.executableURL, ytdlpURL)
        XCTAssertEqual(request.arguments, ["--version"])
        XCTAssertEqual(request.timeout, .seconds(30))
        XCTAssertEqual(request.standardOutputCaptureLimit, 0)
        XCTAssertEqual(request.standardErrorCaptureLimit, 0)
        XCTAssertFalse(request.redactedCommandDescription.contains(ytdlpURL.path))
    }

    func testYTDLPWarmUpSupersessionAndParentCancellationReachRunner() async {
        let runner = CountingBlockingSubprocessRunner()
        let service = YTDLPUpdateService(subprocessRunner: runner)

        let firstTask = Task {
            try await service.runYTDLPWarmUp(at: "/private/first-yt-dlp")
        }
        await runner.waitUntilStarted(count: 1)

        let secondTask = Task {
            try await service.runYTDLPWarmUp(at: "/private/second-yt-dlp")
        }
        await runner.waitUntilStarted(count: 2)

        do {
            _ = try await firstTask.value
            XCTFail("Expected the superseded warm-up to be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected supersession error: \(error)")
        }

        secondTask.cancel()
        do {
            _ = try await secondTask.value
            XCTFail("Expected parent cancellation to stop the current warm-up")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected parent-cancellation error: \(error)")
        }

        XCTAssertEqual(runner.cancelledCount, 2)
    }

    func testDenoArchiveExtractorUsesBoundedRunnerAndTransfersScratchOwnership() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DenoArchiveExtractorPolicy-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = temporaryDirectory.appendingPathComponent("private deno archive.zip")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try Data("archive fixture".utf8).write(to: archiveURL)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = RecordingSubprocessRunner { request, _ in
            let extractionDirectory = URL(fileURLWithPath: request.arguments[2], isDirectory: true)
            try Data("deno fixture".utf8).write(
                to: extractionDirectory.appendingPathComponent("deno")
            )
            return successfulSubprocessResult()
        }
        let extractor = DenoArchiveExtractor(subprocessRunner: runner)

        let extraction = try await extractor.extract(
            from: archiveURL,
            temporaryDirectory: temporaryDirectory
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: extraction.binaryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extraction.workingDirectoryURL.path))

        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.executableURL.path, "/usr/bin/ditto")
        XCTAssertEqual(request.arguments[0...1], ["-xk", archiveURL.path])
        XCTAssertEqual(request.arguments[2], extraction.workingDirectoryURL.path)
        XCTAssertEqual(request.timeout, .seconds(5 * 60))
        XCTAssertEqual(request.standardOutputCaptureLimit, 0)
        XCTAssertEqual(request.standardErrorCaptureLimit, 64 * 1024)
        XCTAssertFalse(request.redactedCommandDescription.contains(archiveURL.path))
        XCTAssertFalse(request.redactedCommandDescription.contains(extraction.workingDirectoryURL.path))

        try FileManager.default.removeItem(at: extraction.workingDirectoryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: extraction.workingDirectoryURL.path))
    }

    func testDenoArchiveExtractorFindsBinaryInOneLevelNestedDirectory() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DenoArchiveExtractorNested-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = RecordingSubprocessRunner { request, _ in
            let extractionDirectory = URL(fileURLWithPath: request.arguments[2], isDirectory: true)
            let nestedDirectory = extractionDirectory.appendingPathComponent("deno-release", isDirectory: true)
            try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
            try Data("deno fixture".utf8).write(to: nestedDirectory.appendingPathComponent("deno"))
            return successfulSubprocessResult()
        }

        let extraction = try await DenoArchiveExtractor(subprocessRunner: runner).extract(
            from: temporaryDirectory.appendingPathComponent("archive.zip"),
            temporaryDirectory: temporaryDirectory
        )
        defer { try? FileManager.default.removeItem(at: extraction.workingDirectoryURL) }

        XCTAssertEqual(extraction.binaryURL.lastPathComponent, "deno")
        XCTAssertEqual(extraction.binaryURL.deletingLastPathComponent().lastPathComponent, "deno-release")
    }

    func testDenoArchiveExtractorMapsFailuresAndCleansScratchDirectories() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DenoArchiveExtractorFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let archiveURL = temporaryDirectory.appendingPathComponent("archive.zip")

        let nonzeroRunner = RecordingSubprocessRunner { _, _ in
            successfulSubprocessResult(terminationStatus: 9)
        }
        do {
            _ = try await DenoArchiveExtractor(subprocessRunner: nonzeroRunner).extract(
                from: archiveURL,
                temporaryDirectory: temporaryDirectory
            )
            XCTFail("Expected nonzero extraction to fail")
        } catch YTDLPUpdateError.extractionFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected nonzero extraction error: \(error)")
        }

        let missingBinaryRunner = RecordingSubprocessRunner { _, _ in
            successfulSubprocessResult()
        }
        do {
            _ = try await DenoArchiveExtractor(subprocessRunner: missingBinaryRunner).extract(
                from: archiveURL,
                temporaryDirectory: temporaryDirectory
            )
            XCTFail("Expected a missing extracted binary to fail")
        } catch YTDLPUpdateError.binaryNotFound {
            // Expected.
        } catch {
            XCTFail("Unexpected missing-binary error: \(error)")
        }

        let timeoutRunner = RecordingSubprocessRunner { request, _ in
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: successfulSubprocessResult(terminationStatus: SIGKILL)
            )
        }
        do {
            _ = try await DenoArchiveExtractor(subprocessRunner: timeoutRunner).extract(
                from: archiveURL,
                temporaryDirectory: temporaryDirectory
            )
            XCTFail("Expected a timed-out extraction to fail")
        } catch YTDLPUpdateError.extractionFailed {
            // Expected.
        } catch {
            XCTFail("Unexpected timeout error: \(error)")
        }

        let remainingEntries = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(remainingEntries.isEmpty, "Failed extraction left scratch artifacts: \(remainingEntries)")
    }

    func testDenoArchiveExtractionIsCancelledByServiceDownloadControlAndCleansScratch() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DenoArchiveExtractorCancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = CountingBlockingSubprocessRunner()
        let service = YTDLPUpdateService(subprocessRunner: runner)
        let task = Task {
            try await service.extractDenoArchive(
                from: temporaryDirectory.appendingPathComponent("archive.zip"),
                temporaryDirectory: temporaryDirectory
            )
        }
        await runner.waitUntilStarted(count: 1)
        await service.cancelDownload(.deno)

        do {
            _ = try await task.value
            XCTFail("Expected extraction cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }

        XCTAssertEqual(runner.cancelledCount, 1)
        let remainingEntries = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(remainingEntries.isEmpty, "Cancelled extraction left scratch artifacts: \(remainingEntries)")
    }

    func testDenoRuntimeInstallerAtomicallyReplacesExistingRuntime() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DenoRuntimeInstallerSuccess-\(UUID().uuidString)", isDirectory: true)
        let extractionDirectory = temporaryDirectory.appendingPathComponent("extraction", isDirectory: true)
        let destinationURL = temporaryDirectory.appendingPathComponent("installed/deno")
        try FileManager.default.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let binaryURL = extractionDirectory.appendingPathComponent("deno")
        try Data("new runtime".utf8).write(to: binaryURL)
        try Data("old runtime".utf8).write(to: destinationURL)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try DenoRuntimeInstaller().install(
            DenoArchiveExtraction(
                binaryURL: binaryURL,
                workingDirectoryURL: extractionDirectory
            ),
            at: destinationURL
        )

        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("new runtime".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertFalse(FileManager.default.fileExists(atPath: binaryURL.path))
    }

    func testDenoRuntimeInstallerCancellationBeforePublicationPreservesExistingRuntime() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DenoRuntimeInstallerCancellation-\(UUID().uuidString)", isDirectory: true)
        let extractionDirectory = temporaryDirectory.appendingPathComponent("extraction", isDirectory: true)
        let destinationURL = temporaryDirectory.appendingPathComponent("installed/deno")
        try FileManager.default.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let binaryURL = extractionDirectory.appendingPathComponent("deno")
        try Data("new runtime".utf8).write(to: binaryURL)
        try Data("old runtime".utf8).write(to: destinationURL)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let publicationReached = DispatchSemaphore(value: 0)
        let releasePublication = DispatchSemaphore(value: 0)
        let installer = DenoRuntimeInstaller {
            publicationReached.signal()
            releasePublication.wait()
        }
        let task = Task {
            try installer.install(
                DenoArchiveExtraction(
                    binaryURL: binaryURL,
                    workingDirectoryURL: extractionDirectory
                ),
                at: destinationURL
            )
        }

        XCTAssertEqual(publicationReached.wait(timeout: .now() + 1), .success)
        task.cancel()
        releasePublication.signal()

        do {
            try await task.value
            XCTFail("Expected publication cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected publication error: \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("old runtime".utf8))
        let installedEntries = try FileManager.default.contentsOfDirectory(
            at: destinationURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(installedEntries.map(\.lastPathComponent), ["deno"])
    }

    func testDenoArchiveHasherCancellationStopsBetweenChunks() async throws {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DenoArchiveHasher-\(UUID().uuidString)")
        try Data(repeating: 0xA5, count: 2 * 1024 * 1024).write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let firstChunkReached = DispatchSemaphore(value: 0)
        let releaseChunk = DispatchSemaphore(value: 0)
        let invocationCounter = LockedInvocationCounter()
        let hasher = DenoArchiveHasher {
            if invocationCounter.incrementAndIsFirst() {
                firstChunkReached.signal()
                releaseChunk.wait()
            }
        }
        let task = Task { try await hasher.hash(temporaryURL) }

        XCTAssertEqual(firstChunkReached.wait(timeout: .now() + 1), .success)
        task.cancel()
        releaseChunk.signal()

        do {
            _ = try await task.value
            XCTFail("Expected hashing cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected hashing error: \(error)")
        }
    }

    func testURLSessionTaskCancellationRemembersCancellationBeforeRegistration() {
        let cancellation = URLSessionTaskCancellation()
        let task = URLSession.shared.dataTask(
            with: URL(string: "https://cancellation.invalid/fixture")!
        )

        cancellation.cancel()
        cancellation.register(task)

        XCTAssertTrue(task.state == .canceling || task.state == .completed)
    }

    func testPreviewMediaFactsReuseSuccessfulRichMetadataWithoutFallback() async throws {
        let expectedMetadata = videoMetadata(timecode: nil, frameRate: 25)
        let generator = PreviewAssetGenerator(
            metadataProbe: { _ in expectedMetadata },
            essentialInfoProbe: { _ in
                XCTFail("Rich metadata should satisfy the preview preflight")
                return EssentialVideoInfo(
                    duration: 1,
                    hasVideoStream: false,
                    videoStreamCount: 0,
                    hasAudioStream: true,
                    primaryCodec: nil,
                    width: nil,
                    height: nil
                )
            }
        )

        let facts = try await generator.resolveMediaFacts(
            for: URL(fileURLWithPath: "/private/preview.mov")
        )

        XCTAssertEqual(facts.metadata, expectedMetadata)
        XCTAssertEqual(facts.duration, 60)
        XCTAssertTrue(facts.hasVideoStream)
    }

    func testPreviewMediaFactsUseBoundedEssentialFallbackForUnsupportedMetadata() async throws {
        let expectedInfo = EssentialVideoInfo(
            duration: 12.5,
            hasVideoStream: false,
            videoStreamCount: 0,
            hasAudioStream: true,
            primaryCodec: nil,
            width: nil,
            height: nil
        )
        let generator = PreviewAssetGenerator(
            metadataProbe: { _ in throw VideoMetadataError.unsupportedContainer },
            essentialInfoProbe: { _ in expectedInfo }
        )

        let facts = try await generator.resolveMediaFacts(
            for: URL(fileURLWithPath: "/private/preview.wav")
        )

        XCTAssertNil(facts.metadata)
        XCTAssertEqual(facts.duration, expectedInfo.duration)
        XCTAssertFalse(facts.hasVideoStream)
    }

    func testPreviewMediaFactsPreserveRichMetadataWhenEssentialFallbackSuppliesDuration() async throws {
        let expectedMetadata = videoMetadata(timecode: nil, frameRate: 25, duration: nil)
        let expectedInfo = EssentialVideoInfo(
            duration: 8.25,
            hasVideoStream: false,
            videoStreamCount: 0,
            hasAudioStream: false,
            primaryCodec: nil,
            width: nil,
            height: nil
        )
        let generator = PreviewAssetGenerator(
            metadataProbe: { _ in expectedMetadata },
            essentialInfoProbe: { _ in expectedInfo }
        )

        let facts = try await generator.resolveMediaFacts(
            for: URL(fileURLWithPath: "/private/preview-missing-duration.mov")
        )

        XCTAssertEqual(facts.metadata, expectedMetadata)
        XCTAssertEqual(facts.duration, expectedInfo.duration)
        XCTAssertTrue(facts.hasVideoStream)
    }

    func testPreviewMediaFactsDoNotReenterOrJoinTimedOutMetadataProbe() async {
        let probeStarted = DispatchSemaphore(value: 0)
        let releaseProbe = DispatchSemaphore(value: 0)
        defer { releaseProbe.signal() }
        let generator = PreviewAssetGenerator(
            metadataTimeout: .milliseconds(50),
            metadataProbe: { _ in
                try await withCheckedThrowingContinuation { continuation in
                    probeStarted.signal()
                    DispatchQueue.global(qos: .utility).async {
                        releaseProbe.wait()
                        continuation.resume(throwing: CancellationError())
                    }
                }
            },
            essentialInfoProbe: { _ in
                XCTFail("A timed-out rich probe must not immediately re-enter the parser")
                return EssentialVideoInfo(
                    duration: 1,
                    hasVideoStream: true,
                    videoStreamCount: 1,
                    hasAudioStream: false,
                    primaryCodec: "h264",
                    width: 640,
                    height: 360
                )
            }
        )
        let start = ContinuousClock.now

        do {
            _ = try await generator.resolveMediaFacts(
                for: URL(fileURLWithPath: "/private/stalled-preview.mov")
            )
            XCTFail("Expected the preview metadata deadline to expire")
        } catch NonJoiningTaskDeadlineError.timedOut {
            // Expected.
        } catch {
            XCTFail("Expected a deadline error, got \(error)")
        }

        XCTAssertEqual(probeStarted.wait(timeout: .now() + 1), .success)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testPreviewMediaFactsCancellationReturnsPromptly() async {
        let probeStarted = DispatchSemaphore(value: 0)
        let releaseProbe = DispatchSemaphore(value: 0)
        defer { releaseProbe.signal() }
        let generator = PreviewAssetGenerator(
            metadataTimeout: .seconds(10),
            metadataProbe: { _ in
                try await withCheckedThrowingContinuation { continuation in
                    probeStarted.signal()
                    DispatchQueue.global(qos: .utility).async {
                        releaseProbe.wait()
                        continuation.resume(throwing: CancellationError())
                    }
                }
            }
        )
        let task = Task {
            try await generator.resolveMediaFacts(
                for: URL(fileURLWithPath: "/private/cancelled-preview.mov")
            )
        }

        XCTAssertEqual(probeStarted.wait(timeout: .now() + 1), .success)
        let start = ContinuousClock.now
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected preview media discovery cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected cancellation, got \(error)")
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testPreviewAssetGeneratorUsesSharedRunnerWithBoundedRedactedPolicy() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewRunnerPolicy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("secret source.mov")
        let destinationURL = temporaryDirectory.appendingPathComponent("secret thumbnail.png")
        let executableURL = URL(fileURLWithPath: "/private/tools/ffmpeg")
        let runner = RecordingSubprocessRunner { _, _ in
            try Data("preview".utf8).write(to: destinationURL)
            return successfulSubprocessResult()
        }
        let generator = PreviewAssetGenerator(subprocessRunner: runner)

        try await generator.runProcess(
            executable: executableURL,
            arguments: ["-hide_banner", "-i", sourceURL.path, "-y", destinationURL.path],
            forURL: sourceURL,
            outputURL: destinationURL
        )

        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.executableURL, executableURL)
        XCTAssertEqual(request.timeout, .seconds(30 * 60))
        XCTAssertEqual(request.standardOutputCaptureLimit, 0)
        XCTAssertEqual(request.standardErrorCaptureLimit, 256 * 1024)
        XCTAssertFalse(request.redactedCommandDescription.contains(executableURL.path))
        XCTAssertFalse(request.redactedCommandDescription.contains(sourceURL.path))
        XCTAssertFalse(request.redactedCommandDescription.contains(destinationURL.path))
    }

    func testPreviewAssetGeneratorReturnsBoundedRedactedFailureAndMapsTimeout() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewRunnerFailure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("private.mov")
        let destinationURL = temporaryDirectory.appendingPathComponent("private.png")
        let longDiagnostic = String(repeating: "x", count: 10_000)
            + " failed \(sourceURL.path) while writing \(destinationURL.path) from https://example.com/private"
        let failureRunner = RecordingSubprocessRunner { _, _ in
            try Data("partial".utf8).write(to: destinationURL)
            return successfulSubprocessResult(standardError: longDiagnostic, terminationStatus: 9)
        }
        let failureGenerator = PreviewAssetGenerator(subprocessRunner: failureRunner)

        do {
            try await failureGenerator.runProcess(
                executable: URL(fileURLWithPath: "/private/tools/ffmpeg"),
                arguments: ["-i", sourceURL.path, destinationURL.path],
                forURL: sourceURL,
                outputURL: destinationURL
            )
            XCTFail("Expected preview generation to fail")
        } catch let error as PreviewAssetError {
            let message = error.localizedDescription
            XCTAssertLessThanOrEqual(message.count, 8_256)
            XCTAssertTrue(message.contains("<redacted>"), message)
            XCTAssertTrue(message.contains("<url>"), message)
            XCTAssertFalse(message.contains(sourceURL.path), message)
            XCTAssertFalse(message.contains(destinationURL.path), message)
            XCTAssertFalse(message.contains("example.com"), message)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
        }

        let timeoutRunner = RecordingSubprocessRunner { request, _ in
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: successfulSubprocessResult(terminationStatus: SIGKILL)
            )
        }
        let timeoutGenerator = PreviewAssetGenerator(subprocessRunner: timeoutRunner)

        do {
            try await timeoutGenerator.runProcess(
                executable: URL(fileURLWithPath: "/private/tools/ffmpeg"),
                arguments: ["-i", sourceURL.path, destinationURL.path],
                forURL: sourceURL,
                outputURL: destinationURL
            )
            XCTFail("Expected preview generation to time out")
        } catch let error as PreviewAssetError {
            XCTAssertEqual(
                error.localizedDescription,
                "Failed to generate preview assets: Preview subprocess timed out after 30 minutes."
            )
        }
    }

    func testPreviewAssetGeneratorTargetedCancellationStopsSharedRunner() async throws {
        let sourceURL = URL(fileURLWithPath: "/private/media/source.mov")
        let outputURL = URL(fileURLWithPath: "/private/cache/output.png")
        let runner = CountingBlockingSubprocessRunner()
        let generator = PreviewAssetGenerator(subprocessRunner: runner)
        let task = Task {
            try await generator.runProcess(
                executable: URL(fileURLWithPath: "/private/tools/ffmpeg"),
                arguments: ["-i", sourceURL.path, outputURL.path],
                forURL: sourceURL,
                outputURL: outputURL
            )
        }

        await runner.waitUntilStarted(count: 1)
        await generator.cancelGeneration(for: sourceURL)

        do {
            try await task.value
            XCTFail("Expected preview generation cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(runner.cancelledCount, 1)
    }

    func testPreviewAssetGeneratorTerminateAllStopsEveryTrackedRunnerTask() async throws {
        let runner = CountingBlockingSubprocessRunner()
        let generator = PreviewAssetGenerator(subprocessRunner: runner)
        let firstSource = URL(fileURLWithPath: "/private/media/first.mov")
        let secondSource = URL(fileURLWithPath: "/private/media/second.mov")
        let firstOutput = URL(fileURLWithPath: "/private/cache/first.png")
        let secondOutput = URL(fileURLWithPath: "/private/cache/second.png")
        let firstTask = Task {
            try await generator.runProcess(
                executable: URL(fileURLWithPath: "/private/tools/ffmpeg"),
                arguments: ["-i", firstSource.path, firstOutput.path],
                forURL: firstSource,
                outputURL: firstOutput
            )
        }
        let secondTask = Task {
            try await generator.runProcess(
                executable: URL(fileURLWithPath: "/private/tools/ffmpeg"),
                arguments: ["-i", secondSource.path, secondOutput.path],
                forURL: secondSource,
                outputURL: secondOutput
            )
        }

        await runner.waitUntilStarted(count: 2)
        await generator.terminateAllProcesses()

        for task in [firstTask, secondTask] {
            do {
                try await task.value
                XCTFail("Expected app-termination cancellation")
            } catch is CancellationError {
                // Expected.
            }
        }
        XCTAssertEqual(runner.cancelledCount, 2)
    }

    @MainActor
    func testApplicationTerminationGateCoalescesRepeatedQuitRequests() async {
        let cleanup = DeferredTerminationCleanup()
        let reply = expectation(description: "AppKit termination reply")
        let replyCount = OSAllocatedUnfairLock(initialState: 0)
        let gate = ApplicationTerminationGate(timeout: .seconds(1)) {
            await cleanup.run()
        }

        let firstReply = gate.requestTermination {
            replyCount.withLock { $0 += 1 }
            reply.fulfill()
        }
        let repeatedReply = gate.requestTermination {
            XCTFail("A repeated quit request must not install a second reply")
        }

        XCTAssertEqual(firstReply, .terminateLater)
        XCTAssertEqual(repeatedReply, .terminateLater)
        await cleanup.waitUntilStarted()
        XCTAssertEqual(cleanup.startedCount, 1)

        cleanup.release()
        await fulfillment(of: [reply], timeout: 1)
        XCTAssertEqual(replyCount.withLock { $0 }, 1)
    }

    @MainActor
    func testApplicationTerminationGateRepliesWithoutJoiningStalledCleanup() async {
        let cleanup = DeferredTerminationCleanup()
        let reply = expectation(description: "Bounded AppKit termination reply")
        let gate = ApplicationTerminationGate(timeout: .milliseconds(20)) {
            await cleanup.run()
        }
        let start = ContinuousClock.now

        XCTAssertEqual(
            gate.requestTermination { reply.fulfill() },
            .terminateLater
        )
        await cleanup.waitUntilStarted()
        await fulfillment(of: [reply], timeout: 1)

        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        cleanup.release()
    }

    func testBMXRewrapUsesSharedRunnerWithBoundedPolicyAndSplitProgress() async throws {
        let fixture = try makeBMXFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let progressValues = OSAllocatedUnfairLock<[Double]>(initialState: [])
        let bmxPath = "/private/tools/bmxtranswrap"
        let runner = RecordingSubprocessRunner { request, outputHandler in
            outputHandler?(SubprocessOutputChunk(stream: .standardOutput, data: Data("12".utf8)))
            outputHandler?(SubprocessOutputChunk(stream: .standardError, data: Data("ignored 77%\n".utf8)))
            outputHandler?(SubprocessOutputChunk(stream: .standardOutput, data: Data(".5%\r99%".utf8)))
            try Data("rewrapped".utf8).write(to: XCTUnwrap(bmxOutputURL(in: request)))
            return successfulSubprocessResult()
        }
        let service = BMXService(
            subprocessRunner: runner,
            bmxtranswrapPathProvider: { bmxPath },
            mxf2rawPathProvider: { "/private/tools/mxf2raw" }
        )

        let result = await service.rewrapToIMFOP1a(
            inputURL: fixture.input,
            outputURL: fixture.output,
            colorPrimaries: "bt2020",
            transferCharacteristic: "st2084",
            codingEquations: "bt2020",
            clipName: "Fixture"
        ) { value in
            progressValues.withLock { $0.append(value) }
        }

        XCTAssertTrue(result.success)
        XCTAssertEqual(progressValues.withLock { $0 }, [0.125, 0.99, 1.0])
        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.executableURL.path, bmxPath)
        XCTAssertEqual(request.arguments, [
            "-t", "op1a",
            "--color-prim", "bt2020",
            "--transfer-ch", "st2084",
            "--coding-eq", "bt2020",
            "--clip", "Fixture",
            "-o", fixture.output.path,
            "-p",
            fixture.input.path,
        ])
        XCTAssertEqual(request.timeout, .seconds(12 * 60 * 60))
        XCTAssertEqual(request.standardOutputCaptureLimit, 0)
        XCTAssertEqual(request.standardErrorCaptureLimit, 256 * 1024)
        XCTAssertFalse(request.redactedCommandDescription.contains(bmxPath))
        XCTAssertFalse(request.redactedCommandDescription.contains(fixture.input.path))
        XCTAssertFalse(request.redactedCommandDescription.contains(fixture.output.path))
        XCTAssertFalse(request.redactedCommandDescription.contains("Fixture"))
    }

    func testBMXRewrapReturnsBoundedRedactedFailure() async throws {
        let fixture = try makeBMXFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = RecordingSubprocessRunner { request, _ in
            try Data("partial".utf8).write(to: XCTUnwrap(bmxOutputURL(in: request)))
            return successfulSubprocessResult(
                standardError: String(repeating: "x", count: 10_000)
                    + " failed \(fixture.input.path) at https://example.com/private",
                terminationStatus: 9
            )
        }
        let service = BMXService(
            subprocessRunner: runner,
            bmxtranswrapPathProvider: { "/private/tools/bmxtranswrap" }
        )

        let result = await service.rewrapToOP1a(
            inputURL: fixture.input,
            outputURL: fixture.output
        ) { _ in }

        XCTAssertFalse(result.success)
        XCTAssertLessThanOrEqual(result.stderr.count, 8_193)
        XCTAssertTrue(result.stderr.contains("<redacted>"), result.stderr)
        XCTAssertTrue(result.stderr.contains("<url>"), result.stderr)
        XCTAssertFalse(result.stderr.contains(fixture.input.path), result.stderr)
        XCTAssertFalse(result.stderr.contains("example.com"), result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
    }

    func testBMXRewrapRejectsSuccessfulExitWithoutOutput() async throws {
        let fixture = try makeBMXFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = RecordingSubprocessRunner { _, _ in
            successfulSubprocessResult()
        }
        let service = BMXService(
            subprocessRunner: runner,
            bmxtranswrapPathProvider: { "/private/tools/bmxtranswrap" }
        )

        let result = await service.rewrapToOP1a(
            inputURL: fixture.input,
            outputURL: fixture.output
        ) { _ in }

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.stderr, "bmxtranswrap did not produce a valid output file")
    }

    func testBMXRewrapMapsTimeoutAndExplicitCancellation() async throws {
        let fixture = try makeBMXFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let timeoutRunner = RecordingSubprocessRunner { request, _ in
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: SubprocessResult(
                    terminationStatus: SIGKILL,
                    termination: .uncaughtSignal,
                    standardOutput: Data(),
                    standardError: Data(),
                    discardedStandardOutputBytes: 0,
                    discardedStandardErrorBytes: 0,
                    duration: .seconds(12 * 60 * 60)
                )
            )
        }
        let timeoutService = BMXService(
            subprocessRunner: timeoutRunner,
            bmxtranswrapPathProvider: { "/private/tools/bmxtranswrap" }
        )
        let timeoutResult = await timeoutService.rewrapToOP1a(
            inputURL: fixture.input,
            outputURL: fixture.output
        ) { _ in }
        XCTAssertFalse(timeoutResult.success)
        XCTAssertEqual(timeoutResult.stderr, "bmxtranswrap exceeded the 12-hour processing limit")

        let blockingRunner = CountingBlockingSubprocessRunner()
        let cancellationService = BMXService(
            subprocessRunner: blockingRunner,
            bmxtranswrapPathProvider: { "/private/tools/bmxtranswrap" }
        )
        let task = Task {
            await cancellationService.rewrapToOP1a(
                inputURL: fixture.input,
                outputURL: fixture.output
            ) { _ in }
        }
        await blockingRunner.waitUntilStarted(count: 1)
        await cancellationService.cancel()
        let cancelledResult = await task.value
        XCTAssertFalse(cancelledResult.success)
        XCTAssertTrue(cancelledResult.cancelled)
        XCTAssertEqual(cancelledResult.stderr, "bmxtranswrap cancelled")
        XCTAssertEqual(blockingRunner.cancelledCount, 1)

        let stubbornRunner = ControllableBMXSubprocessRunner()
        let stubbornService = BMXService(
            subprocessRunner: stubbornRunner,
            bmxtranswrapPathProvider: { "/private/tools/bmxtranswrap" }
        )
        let stubbornTask = Task {
            await stubbornService.rewrapToOP1a(
                inputURL: fixture.input,
                outputURL: fixture.output,
                operationID: stubbornRunner.firstOperationID
            ) { _ in }
        }
        await stubbornRunner.waitUntilStarted(count: 1)
        await stubbornService.cancel(operationID: stubbornRunner.firstOperationID)
        _ = await stubbornService.finishCancellationTracking(operationID: stubbornRunner.firstOperationID)
        stubbornRunner.releaseFirst()
        let stubbornResult = await stubbornTask.value
        XCTAssertTrue(stubbornResult.cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
    }

    func testBMXRemembersTargetedCancellationBeforeRunnerRegistration() async throws {
        let fixture = try makeBMXFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let operationID = UUID()
        let runner = RecordingSubprocessRunner { _, _ in
            XCTFail("A pre-cancelled BMX operation must not launch")
            return successfulSubprocessResult()
        }
        let service = BMXService(
            subprocessRunner: runner,
            bmxtranswrapPathProvider: { "/private/tools/bmxtranswrap" }
        )
        await service.prepareCancellationTracking(operationID: operationID)
        await service.cancel(operationID: operationID)

        let result = await service.rewrapToOP1a(
            inputURL: fixture.input,
            outputURL: fixture.output,
            operationID: operationID
        ) { _ in }

        XCTAssertTrue(result.cancelled)
        XCTAssertNil(runner.lastRequest)
    }

    func testBMXSerializesOverlappingRewrapsThroughOutputValidation() async throws {
        let fixture = try makeBMXFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = ControllableBMXSubprocessRunner()
        let service = BMXService(
            subprocessRunner: runner,
            bmxtranswrapPathProvider: { "/private/tools/bmxtranswrap" }
        )
        let firstTask = Task {
            await service.rewrapToOP1a(
                inputURL: fixture.input,
                outputURL: fixture.output
            ) { _ in }
        }
        await runner.waitUntilStarted(count: 1)
        let secondTask = Task {
            await service.rewrapToOP1a(
                inputURL: fixture.input,
                outputURL: fixture.directory.appendingPathComponent("second.mxf"),
                operationID: runner.secondOperationID
            ) { _ in }
        }

        let queueDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await service.isWaitingForTranswrapSlot(operationID: runner.secondOperationID)),
              ContinuousClock.now < queueDeadline {
            await Task.yield()
        }
        XCTAssertEqual(runner.startedCount, 1)
        runner.releaseFirst()
        let firstResult = await firstTask.value
        let secondResult = await secondTask.value
        XCTAssertTrue(firstResult.success)
        XCTAssertTrue(secondResult.success)
        XCTAssertEqual(runner.startedCount, 2)
    }

    func testBMXQueuedCancellationReturnsBeforeActiveRewrapCompletes() async throws {
        let fixture = try makeBMXFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = ControllableBMXSubprocessRunner()
        let service = BMXService(
            subprocessRunner: runner,
            bmxtranswrapPathProvider: { "/private/tools/bmxtranswrap" }
        )
        let firstTask = Task {
            await service.rewrapToOP1a(
                inputURL: fixture.input,
                outputURL: fixture.output,
                operationID: runner.firstOperationID
            ) { _ in }
        }
        await runner.waitUntilStarted(count: 1)
        await service.prepareCancellationTracking(operationID: runner.secondOperationID)
        let secondTask = Task {
            await service.rewrapToOP1a(
                inputURL: fixture.input,
                outputURL: fixture.directory.appendingPathComponent("cancelled-second.mxf"),
                operationID: runner.secondOperationID
            ) { _ in }
        }
        let queueDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await service.isWaitingForTranswrapSlot(operationID: runner.secondOperationID)),
              ContinuousClock.now < queueDeadline {
            await Task.yield()
        }
        let isQueued = await service.isWaitingForTranswrapSlot(operationID: runner.secondOperationID)
        XCTAssertTrue(isQueued)

        await service.cancel(operationID: runner.secondOperationID)
        let secondFinished = expectation(description: "queued BMX cancellation returns promptly")
        Task {
            _ = await secondTask.value
            secondFinished.fulfill()
        }
        await fulfillment(of: [secondFinished], timeout: 1.0)
        let cancelledResult = await secondTask.value
        XCTAssertTrue(cancelledResult.cancelled)
        XCTAssertEqual(runner.startedCount, 1)

        runner.releaseFirst()
        let firstResult = await firstTask.value
        XCTAssertTrue(firstResult.success)
    }

    func testBMXMXFProbesUseSharedRunnerAndParseMCALabels() async throws {
        let fixture = try makeBMXFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let xml = """
        <bmx><clip><tracks><track index="0">
          <essence_kind>Sound</essence_kind>
          <sound_descriptor><channel_count>2</channel_count><sampling_rate>48000/1</sampling_rate></sound_descriptor>
          <mca_labels>
            <channel_label><mca_channel_id>1</mca_channel_id><tag_symbol>chL</tag_symbol><tag_name>Left</tag_name></channel_label>
            <channel_label><mca_channel_id>2</mca_channel_id><tag_symbol>chR</tag_symbol><tag_name>Right</tag_name></channel_label>
            <soundfield_group><tag_symbol>sgST</tag_symbol><tag_name>Stereo</tag_name></soundfield_group>
            <group_of_soundfield_group><tag_symbol>aeDX</tag_symbol><tag_name>Dialog</tag_name></group_of_soundfield_group>
          </mca_labels>
        </track></tracks></clip></bmx>
        """
        let runner = SequencedRecordingSubprocessRunner { index, _, _ in
            if index == 0 {
                return successfulSubprocessResult(standardOutput: "Operational Pattern: OP-1a\n")
            }
            return successfulSubprocessResult(standardOutput: xml)
        }
        let mxf2rawPath = "/private/tools/mxf2raw"
        let service = BMXService(
            subprocessRunner: runner,
            mxf2rawPathProvider: { mxf2rawPath }
        )

        let isOP1a = await service.isOP1a(url: fixture.input)
        XCTAssertTrue(isOP1a)
        let probedLabels = await service.getAudioTrackLabels(url: fixture.input)
        let labels = try XCTUnwrap(probedLabels)
        let track = try XCTUnwrap(labels.first)
        XCTAssertEqual(track.trackNumber, 1)
        XCTAssertEqual(track.channelCount, 2)
        XCTAssertEqual(track.sampleRate, 48_000)
        XCTAssertEqual(track.soundfieldGroup, "Stereo")
        XCTAssertEqual(track.audioElement, "Dialog")
        XCTAssertEqual(track.channelLabels, ["Left", "Right"])

        let requests = runner.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].arguments, ["--info", fixture.input.path])
        XCTAssertEqual(requests[0].timeout, .seconds(5 * 60))
        XCTAssertEqual(requests[0].standardOutputCaptureLimit, 4 * 1024 * 1024)
        XCTAssertEqual(requests[1].arguments, [
            "--info", "--info-format", "xml", "--mca-detail", fixture.input.path,
        ])
        XCTAssertEqual(requests[1].standardOutputCaptureLimit, 16 * 1024 * 1024)
        XCTAssertEqual(requests[1].standardErrorCaptureLimit, 256 * 1024)
        XCTAssertFalse(requests[1].redactedCommandDescription.contains(mxf2rawPath))
        XCTAssertFalse(requests[1].redactedCommandDescription.contains(fixture.input.path))

        let truncatedRunner = RecordingSubprocessRunner { _, _ in
            SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data("Operational Pattern: OP-1a".utf8),
                standardError: Data(),
                discardedStandardOutputBytes: 1,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(10)
            )
        }
        let truncatedService = BMXService(
            subprocessRunner: truncatedRunner,
            mxf2rawPathProvider: { mxf2rawPath }
        )
        let truncatedInfo = await truncatedService.getMXFInfo(url: fixture.input)
        XCTAssertNil(truncatedInfo)
    }

    func testAnalyticsServiceUsesSharedRunnerWithBoundedPolicyAndSplitProgress() async throws {
        let fixture = try makeAnalyticsFixtureFiles()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let progressValues = OSAllocatedUnfairLock<[Double]>(initialState: [])
        let stderr = """
        Duration: 00:00:10.00, start: 0.000000, bitrate: 1000 kb/s
        frame=25 fps=0.0 time=00:00:05.00 bitrate=N/A speed=10x
        [Parsed_psnr_0 @ fixture] PSNR y:38.12 u:42.34 v:43.56 average:39.01 min:25.67 max:48.90
        """
        let runner = RecordingSubprocessRunner { _, outputHandler in
            for text in [
                "Duration: 00:00:",
                "10.00\rframe=25 fps=0.0 time=00:00:05",
                ".00\r"
            ] {
                outputHandler?(SubprocessOutputChunk(stream: .standardError, data: Data(text.utf8)))
            }
            return successfulSubprocessResult(standardError: stderr)
        }
        let ffmpegPath = "/private/tools/analytics ffmpeg"
        let service = AnalyticsService(
            subprocessRunner: runner,
            ffmpegPathProvider: { ffmpegPath }
        )

        let results = try await service.runAnalytics(
            sourceFile: fixture.source,
            encodedFile: fixture.encoded,
            enabledMetrics: [.psnr],
            vmafModel: .vmaf_v0_6_1
        ) { metric, progress in
            XCTAssertEqual(metric, .psnr)
            progressValues.withLock { $0.append(progress) }
        }

        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.metric, .psnr)
        XCTAssertEqual(result.overallScore, 39.01, accuracy: 0.0001)
        XCTAssertEqual(result.channelScores?["Y"], 38.12)
        XCTAssertEqual(result.min, 25.67)
        XCTAssertEqual(result.max, 48.90)

        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.executableURL.path, ffmpegPath)
        XCTAssertEqual(request.arguments, [
            "-nostdin",
            "-i", fixture.encoded.path,
            "-i", fixture.source.path,
            "-filter_complex", "[1:v][0:v]scale2ref=flags=bicubic[ref][dist];[dist][ref]psnr",
            "-f", "null", "-"
        ])
        XCTAssertEqual(request.timeout, .seconds(12 * 60 * 60))
        XCTAssertEqual(request.standardOutputCaptureLimit, 0)
        XCTAssertEqual(request.standardErrorCaptureLimit, 256 * 1024)
        XCTAssertFalse(request.redactedCommandDescription.contains(ffmpegPath))
        XCTAssertFalse(request.redactedCommandDescription.contains(fixture.source.path))
        XCTAssertFalse(request.redactedCommandDescription.contains(fixture.encoded.path))
        XCTAssertEqual(progressValues.withLock { $0 }, [0.5, 1.0])
    }

    func testAnalyticsServiceParsesVMAFAndCleansItsTemporaryLog() async throws {
        let fixture = try makeAnalyticsFixtureFiles()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recordedLogPath = OSAllocatedUnfairLock<String?>(initialState: nil)
        let runner = RecordingSubprocessRunner { request, _ in
            let filter = try XCTUnwrap(request.arguments.first(where: { $0.contains("log_path=") }))
            let pathStart = try XCTUnwrap(filter.range(of: "log_path=")?.upperBound)
            let pathEnd = try XCTUnwrap(filter.range(of: ":log_fmt=json", range: pathStart..<filter.endIndex)?.lowerBound)
            let path = String(filter[pathStart..<pathEnd]).replacingOccurrences(of: "\\:", with: ":")
            recordedLogPath.withLock { $0 = path }
            let json = """
            {"pooled_metrics":{"vmaf":{"mean":94.25,"min":88.5,"max":99.1}}}
            """
            try Data(json.utf8).write(to: URL(fileURLWithPath: path))
            return successfulSubprocessResult()
        }
        let service = AnalyticsService(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" }
        )

        let results = try await service.runAnalytics(
            sourceFile: fixture.source,
            encodedFile: fixture.encoded,
            enabledMetrics: [.vmaf],
            vmafModel: .vmaf_v0_6_1neg
        ) { _, _ in }

        let result = try XCTUnwrap(results.first)
        XCTAssertEqual(result.overallScore, 94.25)
        XCTAssertEqual(result.min, 88.5)
        XCTAssertEqual(result.max, 99.1)
        let logPath = try XCTUnwrap(recordedLogPath.withLock { $0 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: logPath))
        XCTAssertTrue(runner.lastRequest?.arguments.contains(where: { $0.contains("model=version=vmaf_v0.6.1neg") }) == true)
    }

    func testAnalyticsServiceRunsSSIMULACRAFrameToolsThroughSharedRunner() async throws {
        let fixture = try makeAnalyticsFixtureFiles()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let ffmpegPath = "/private/tools/ffmpeg"
        let ssimulacra2Path = "/private/tools/ssimulacra2_rs"
        let runner = SequencedRecordingSubprocessRunner { index, _, _ in
            switch index {
            case 0, 1:
                return successfulSubprocessResult()
            case 2:
                return successfulSubprocessResult(standardOutput: "Score: 97.53500802\n")
            default:
                XCTFail("Unexpected analytics subprocess \(index)")
                return successfulSubprocessResult()
            }
        }
        let service = AnalyticsService(
            subprocessRunner: runner,
            ffmpegPathProvider: { ffmpegPath },
            ssimulacra2PathProvider: { ssimulacra2Path },
            mediaInfoProvider: StubAnalyticsMediaInfoProvider(
                duration: 10,
                resolution: (width: 640, height: 360)
            )
        )

        let results = try await service.runAnalytics(
            sourceFile: fixture.source,
            encodedFile: fixture.encoded,
            enabledMetrics: [.ssimulacra2],
            vmafModel: .vmaf_v0_6_1,
            ssimulacra2MaxFrames: 1
        ) { _, _ in }

        XCTAssertEqual(results.first?.overallScore, 97.53500802)
        let requests = runner.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].executableURL.path, ffmpegPath)
        XCTAssertEqual(requests[0].timeout, .seconds(10 * 60))
        XCTAssertEqual(requests[0].standardOutputCaptureLimit, 0)
        XCTAssertEqual(requests[1].executableURL.path, ffmpegPath)
        XCTAssertTrue(requests[1].arguments.contains("scale=640:360"))
        XCTAssertEqual(requests[2].executableURL.path, ssimulacra2Path)
        XCTAssertEqual(requests[2].arguments.first, "image")
        XCTAssertEqual(requests[2].timeout, .seconds(2 * 60))
        XCTAssertEqual(requests[2].standardOutputCaptureLimit, 4 * 1024)
        XCTAssertFalse(requests[2].redactedCommandDescription.contains(ssimulacra2Path))
    }

    func testAnalyticsMediaInfoDiscoveryDoesNotJoinTimedOutProvider() async throws {
        let fixture = try makeAnalyticsFixtureFiles()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let durationStarted = DispatchSemaphore(value: 0)
        let releaseDuration = DispatchSemaphore(value: 0)
        defer { releaseDuration.signal() }
        let runner = RecordingSubprocessRunner { _, _ in
            XCTFail("Media-info timeout should stop analytics before launching a subprocess")
            return successfulSubprocessResult()
        }
        let provider = ClosureAnalyticsMediaInfoProvider(
            duration: { _ in
                await withCheckedContinuation { continuation in
                    durationStarted.signal()
                    DispatchQueue.global(qos: .utility).async {
                        releaseDuration.wait()
                        continuation.resume(returning: 1)
                    }
                }
            },
            resolution: { _ in (width: 640, height: 360) }
        )
        let service = AnalyticsService(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" },
            ssimulacra2PathProvider: { "/private/tools/ssimulacra2_rs" },
            mediaInfoProvider: provider,
            mediaInfoTimeout: .milliseconds(50)
        )
        let start = ContinuousClock.now

        do {
            _ = try await service.runAnalytics(
                sourceFile: fixture.source,
                encodedFile: fixture.encoded,
                enabledMetrics: [.ssimulacra2],
                vmafModel: .vmaf_v0_6_1,
                ssimulacra2MaxFrames: 1
            ) { _, _ in }
            XCTFail("Expected media duration discovery to time out")
        } catch let AnalyticsError.metricFailed(metric, reason) {
            XCTAssertEqual(metric, .ssimulacra2)
            XCTAssertEqual(reason, "Media duration discovery exceeded the 15-second limit")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(durationStarted.wait(timeout: .now() + 1), .success)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertNil(runner.lastRequest)
    }

    func testAnalyticsResolutionDiscoveryDoesNotJoinTimedOutProvider() async throws {
        let fixture = try makeAnalyticsFixtureFiles()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let resolutionStarted = DispatchSemaphore(value: 0)
        let releaseResolution = DispatchSemaphore(value: 0)
        defer { releaseResolution.signal() }
        let runner = RecordingSubprocessRunner { _, _ in
            XCTFail("Media-info timeout should stop analytics before launching a subprocess")
            return successfulSubprocessResult()
        }
        let provider = ClosureAnalyticsMediaInfoProvider(
            duration: { _ in 1 },
            resolution: { _ in
                await withCheckedContinuation { continuation in
                    resolutionStarted.signal()
                    DispatchQueue.global(qos: .utility).async {
                        releaseResolution.wait()
                        continuation.resume(returning: (width: 640, height: 360))
                    }
                }
            }
        )
        let service = AnalyticsService(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" },
            ssimulacra2PathProvider: { "/private/tools/ssimulacra2_rs" },
            mediaInfoProvider: provider,
            mediaInfoTimeout: .milliseconds(50)
        )
        let start = ContinuousClock.now

        do {
            _ = try await service.runAnalytics(
                sourceFile: fixture.source,
                encodedFile: fixture.encoded,
                enabledMetrics: [.ssimulacra2],
                vmafModel: .vmaf_v0_6_1,
                ssimulacra2MaxFrames: 1
            ) { _, _ in }
            XCTFail("Expected media resolution discovery to time out")
        } catch let AnalyticsError.metricFailed(metric, reason) {
            XCTAssertEqual(metric, .ssimulacra2)
            XCTAssertEqual(reason, "Media resolution discovery exceeded the 15-second limit")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(resolutionStarted.wait(timeout: .now() + 1), .success)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertNil(runner.lastRequest)
    }

    func testAnalyticsServiceRedactsFailedFFmpegDiagnostics() async throws {
        let fixture = try makeAnalyticsFixtureFiles()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = RecordingSubprocessRunner { _, _ in
            SubprocessResult(
                terminationStatus: 7,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data("Could not open \(fixture.source.path) or \(fixture.encoded.path)".utf8),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(10)
            )
        }
        let service = AnalyticsService(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" }
        )

        do {
            _ = try await service.runAnalytics(
                sourceFile: fixture.source,
                encodedFile: fixture.encoded,
                enabledMetrics: [.psnr],
                vmafModel: .vmaf_v0_6_1
            ) { _, _ in }
            XCTFail("Expected analytics to fail")
        } catch let AnalyticsError.metricFailed(metric, reason) {
            XCTAssertEqual(metric, .psnr)
            XCTAssertTrue(reason.contains("FFmpeg exited 7"))
            XCTAssertTrue(reason.contains("<redacted>"))
            XCTAssertFalse(reason.contains(fixture.source.path))
            XCTAssertFalse(reason.contains(fixture.encoded.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAnalyticsServiceCancellationReachesSharedRunner() async throws {
        let fixture = try makeAnalyticsFixtureFiles()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = BlockingSubprocessRunner()
        let service = AnalyticsService(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" }
        )
        let analyticsTask = Task {
            try await service.runAnalytics(
                sourceFile: fixture.source,
                encodedFile: fixture.encoded,
                enabledMetrics: [.psnr],
                vmafModel: .vmaf_v0_6_1
            ) { _, _ in }
        }

        await runner.waitUntilStarted()
        await service.cancelAnalysis()

        do {
            _ = try await analyticsTask.value
            XCTFail("Expected analytics cancellation")
        } catch AnalyticsError.cancelled {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAnalyticsServiceTimeoutIsActionableAndPathSafe() async throws {
        let fixture = try makeAnalyticsFixtureFiles()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = RecordingSubprocessRunner { request, _ in
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: SubprocessResult(
                    terminationStatus: SIGTERM,
                    termination: .uncaughtSignal,
                    standardOutput: Data(),
                    standardError: Data(fixture.source.path.utf8),
                    discardedStandardOutputBytes: 0,
                    discardedStandardErrorBytes: 0,
                    duration: .seconds(12 * 60 * 60)
                )
            )
        }
        let service = AnalyticsService(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" }
        )

        do {
            _ = try await service.runAnalytics(
                sourceFile: fixture.source,
                encodedFile: fixture.encoded,
                enabledMetrics: [.xpsnr],
                vmafModel: .vmaf_v0_6_1
            ) { _, _ in }
            XCTFail("Expected analytics timeout")
        } catch let AnalyticsError.metricFailed(metric, reason) {
            XCTAssertEqual(metric, .xpsnr)
            XCTAssertEqual(reason, "FFmpeg exceeded the 12-hour analytics limit")
            XCTAssertFalse(reason.contains(fixture.source.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStartingNewAnalyticsCancelsOnlySupersededAttempt() async throws {
        let fixture = try makeAnalyticsFixtureFiles()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let firstStarted = expectation(description: "First analytics attempt started")
        let psnrSummary = "[Parsed_psnr_0 @ fixture] PSNR y:38.12 u:42.34 v:43.56 average:39.01 min:25.67 max:48.90"
        let runner = SequencedRecordingSubprocessRunner { index, _, _ in
            if index == 0 {
                firstStarted.fulfill()
                try await Task.sleep(for: .seconds(30))
            }
            return successfulSubprocessResult(standardError: psnrSummary)
        }
        let service = AnalyticsService(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" }
        )
        let firstTask = Task {
            try await service.runAnalytics(
                sourceFile: fixture.source,
                encodedFile: fixture.encoded,
                enabledMetrics: [.psnr],
                vmafModel: .vmaf_v0_6_1
            ) { _, _ in }
        }
        await fulfillment(of: [firstStarted], timeout: 2)

        let secondResults = try await service.runAnalytics(
            sourceFile: fixture.source,
            encodedFile: fixture.encoded,
            enabledMetrics: [.psnr],
            vmafModel: .vmaf_v0_6_1
        ) { _, _ in }

        XCTAssertEqual(secondResults.first?.overallScore, 39.01)
        do {
            _ = try await firstTask.value
            XCTFail("Expected the superseded analytics attempt to be cancelled")
        } catch AnalyticsError.cancelled {
            // Expected.
        } catch {
            XCTFail("Unexpected first-attempt error: \(error)")
        }
    }

    func testRcloneBinaryVerifierUsesSharedRunnerWithBoundedVersionProbePolicy() async throws {
        let binaryPath = "/private/tools/custom rclone"
        let runner = RecordingSubprocessRunner { _, _ in
            SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data("rclone v1.70.3\n- os/version: fixture\n".utf8),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(10)
            )
        }

        let version = await RcloneBinaryVerifier.versionString(
            of: binaryPath,
            subprocessRunner: runner
        )

        XCTAssertEqual(version, "rclone v1.70.3")
        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.executableURL.path, binaryPath)
        XCTAssertEqual(request.arguments, ["--version"])
        XCTAssertEqual(request.timeout, .seconds(5))
        XCTAssertEqual(request.standardOutputCaptureLimit, 8 * 1024)
        XCTAssertEqual(request.standardErrorCaptureLimit, 8 * 1024)
        XCTAssertFalse(request.redactedCommandDescription.contains(binaryPath))
    }

    func testRcloneBinaryVerifierRejectsNonzeroAndUnexpectedOutput() async {
        let nonzeroRunner = RecordingSubprocessRunner { _, _ in
            SubprocessResult(
                terminationStatus: 7,
                termination: .exited,
                standardOutput: Data("rclone v1.70.3\n".utf8),
                standardError: Data("probe failed".utf8),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(10)
            )
        }
        let unexpectedRunner = RecordingSubprocessRunner { _, _ in
            SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data("not-rclone 1.0\n".utf8),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(10)
            )
        }

        let nonzeroVersion = await RcloneBinaryVerifier.versionString(
            of: "/private/tools/rclone",
            subprocessRunner: nonzeroRunner
        )
        let unexpectedVersion = await RcloneBinaryVerifier.versionString(
            of: "/private/tools/rclone",
            subprocessRunner: unexpectedRunner
        )

        XCTAssertNil(nonzeroVersion)
        XCTAssertNil(unexpectedVersion)
    }

    func testRcloneBinaryVerifierCancellationReachesSharedRunner() async {
        let runner = BlockingSubprocessRunner()
        let probeTask = Task {
            await RcloneBinaryVerifier.versionString(
                of: "/private/tools/rclone",
                subprocessRunner: runner
            )
        }

        await runner.waitUntilStarted()
        probeTask.cancel()

        let version = await probeTask.value
        XCTAssertNil(version)
    }

    func testRcloneUpdateServiceUsesInjectedRunnerForActiveVersion() async throws {
        let defaults = UserDefaults.standard
        let originalSource = defaults.object(forKey: AppConstants.rcloneBinarySourceKey)
        let originalCustomPath = defaults.object(forKey: AppConstants.rcloneCustomPathKey)
        defer {
            if let originalSource {
                defaults.set(originalSource, forKey: AppConstants.rcloneBinarySourceKey)
            } else {
                defaults.removeObject(forKey: AppConstants.rcloneBinarySourceKey)
            }
            if let originalCustomPath {
                defaults.set(originalCustomPath, forKey: AppConstants.rcloneCustomPathKey)
            } else {
                defaults.removeObject(forKey: AppConstants.rcloneCustomPathKey)
            }
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rclone-version-fixture-\(UUID().uuidString)")
        try Data().write(to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        defaults.set(BinarySourceSelection.custom.rawValue, forKey: AppConstants.rcloneBinarySourceKey)
        defaults.set(temporaryURL.path, forKey: AppConstants.rcloneCustomPathKey)

        let runner = RecordingSubprocessRunner { _, _ in
            SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data("rclone v1.70.3-beta\n".utf8),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(10)
            )
        }
        let service = RcloneUpdateService(subprocessRunner: runner)

        let version = await service.getCurrentVersion()

        XCTAssertEqual(version, "v1.70.3")
        XCTAssertEqual(runner.lastRequest?.executableURL.path, temporaryURL.path)
    }

    func testWaveformPCMDecoderUsesSharedRunnerPolicyAndProducesBands() async throws {
        let inputURL = URL(fileURLWithPath: "/private/fixture/secret audio.wav")
        let runner = RecordingSubprocessRunner { request, _ in
            let outputPath = try XCTUnwrap(request.arguments.last)
            let samples = (0..<4_096).map { index in
                Float(sin(Double(index) * 0.05))
            }
            let data = samples.withUnsafeBytes { Data($0) }
            try data.write(to: URL(fileURLWithPath: outputPath))
            return SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(20)
            )
        }

        let bands = try await WaveformPCMDecoder.decode(
            url: inputURL,
            ffmpegPath: "/private/fixture/ffmpeg",
            frameRate: 2,
            duration: 1,
            bandCount: 8,
            subprocessRunner: runner
        )

        XCTAssertEqual(bands.bandCount, 8)
        XCTAssertEqual(bands.frameCount, 2)
        XCTAssertEqual(bands.magnitudes.count, 2)
        XCTAssertEqual(bands.magnitudes.first?.count, 8)
        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.executableURL.path, "/private/fixture/ffmpeg")
        XCTAssertEqual(request.timeout, .seconds(12 * 60 * 60))
        XCTAssertEqual(request.standardOutputCaptureLimit, 0)
        XCTAssertEqual(request.standardErrorCaptureLimit, 64 * 1024)
        XCTAssertTrue(request.arguments.contains(inputURL.path))
        XCTAssertFalse(request.redactedCommandDescription.contains(inputURL.path))
        XCTAssertFalse(request.redactedCommandDescription.contains(try XCTUnwrap(request.arguments.last)))
    }

    func testNativeWaveformRendererUsesSharedRunnerAndProducesImage() async throws {
        let inputURL = URL(fileURLWithPath: "/private/fixture/preview audio.wav")
        let runner = RecordingSubprocessRunner { request, _ in
            let outputPath = try XCTUnwrap(request.arguments.last)
            let samples = (0..<800).map { index in
                Float(sin(Double(index) * 0.1))
            }
            let data = samples.withUnsafeBytes { Data($0) }
            try data.write(to: URL(fileURLWithPath: outputPath))
            return SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(20)
            )
        }

        let image = try await NativeWaveformRenderer.generateWaveform(
            url: inputURL,
            ffmpegPath: "/private/fixture/ffmpeg",
            streamIndex: 2,
            duration: 1,
            width: 32,
            height: 40,
            subprocessRunner: runner
        )

        XCTAssertEqual(image.size.width, 400)
        XCTAssertEqual(image.size.height, 40)
        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.timeout, .seconds(12 * 60 * 60))
        XCTAssertEqual(request.standardOutputCaptureLimit, 0)
        XCTAssertEqual(request.standardErrorCaptureLimit, 64 * 1024)
        XCTAssertTrue(request.arguments.contains("0:a:2"))
        XCTAssertFalse(request.redactedCommandDescription.contains(inputURL.path))
        XCTAssertFalse(request.redactedCommandDescription.contains(try XCTUnwrap(request.arguments.last)))
    }

    func testNativeWaveformRendererProducesPerChannelImagesThroughSharedRunner() async throws {
        let runner = RecordingSubprocessRunner { request, _ in
            let outputPath = try XCTUnwrap(request.arguments.last)
            let samples = (0..<1_600).map { index in
                Float(sin(Double(index) * 0.1))
            }
            let data = samples.withUnsafeBytes { Data($0) }
            try data.write(to: URL(fileURLWithPath: outputPath))
            return SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(20)
            )
        }

        let (images, labels) = try await NativeWaveformRenderer.generatePerChannelWaveforms(
            url: URL(fileURLWithPath: "/private/fixture/stereo.wav"),
            ffmpegPath: "/private/fixture/ffmpeg",
            streamIndex: 1,
            channelCount: 2,
            channelLayout: "stereo",
            duration: 1,
            width: 32,
            heightPerChannel: 30,
            subprocessRunner: runner
        )

        XCTAssertEqual(images.count, 2)
        XCTAssertEqual(images.map(\.size.width), [800, 800])
        XCTAssertEqual(images.map(\.size.height), [30, 30])
        XCTAssertEqual(labels, ["Left", "Right"])
        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertTrue(request.arguments.contains("0:a:1"))
        XCTAssertFalse(request.arguments.contains("-ac"))
    }

    func testWaveformPCMDecoderBoundsAndRedactsFailureDiagnostic() async throws {
        let inputURL = URL(fileURLWithPath: "/private/fixture/secret audio.wav")
        let runner = RecordingSubprocessRunner { request, _ in
            let outputPath = request.arguments.last ?? "/private/fixture/output.raw"
            let repeated = String(repeating: "x", count: 3_000)
            let diagnostic = "\(repeated) failed \(inputURL.path) \(outputPath) https://example.com/private"
            return SubprocessResult(
                terminationStatus: 7,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(diagnostic.utf8),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(20)
            )
        }

        do {
            _ = try await WaveformPCMDecoder.decode(
                url: inputURL,
                ffmpegPath: "/private/fixture/ffmpeg",
                frameRate: 1,
                duration: 1,
                subprocessRunner: runner
            )
            XCTFail("Expected decode failure")
        } catch let error as WaveformPCMDecoderError {
            guard case let .decodeFailed(diagnostic) = error else {
                return XCTFail("Expected decodeFailed, got \(error)")
            }
            XCTAssertLessThanOrEqual(diagnostic.count, 2_001)
            XCTAssertTrue(diagnostic.contains("<redacted>"), diagnostic)
            XCTAssertTrue(diagnostic.contains("<url>"), diagnostic)
            XCTAssertFalse(diagnostic.contains(inputURL.path), diagnostic)
            XCTAssertFalse(diagnostic.contains("example.com"), diagnostic)
        }
    }

    func testNativeWaveformRendererMapsRunnerTimeout() async throws {
        let runner = RecordingSubprocessRunner { request, _ in
            let result = SubprocessResult(
                terminationStatus: SIGKILL,
                termination: .uncaughtSignal,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .seconds(12 * 60 * 60)
            )
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: result
            )
        }

        do {
            _ = try await NativeWaveformRenderer.generateWaveform(
                url: URL(fileURLWithPath: "/private/fixture/audio.wav"),
                ffmpegPath: "/private/fixture/ffmpeg",
                streamIndex: 0,
                duration: 1,
                width: 400,
                height: 40,
                subprocessRunner: runner
            )
            XCTFail("Expected timeout")
        } catch let error as PreviewAssetError {
            XCTAssertTrue(error.localizedDescription.contains("timed out"), error.localizedDescription)
        }
    }

    func testWaveformPCMDecoderMapsRunnerTimeout() async throws {
        let runner = RecordingSubprocessRunner { request, _ in
            let result = SubprocessResult(
                terminationStatus: SIGKILL,
                termination: .uncaughtSignal,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .seconds(12 * 60 * 60)
            )
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: result
            )
        }

        do {
            _ = try await WaveformPCMDecoder.decode(
                url: URL(fileURLWithPath: "/private/fixture/audio.wav"),
                ffmpegPath: "/private/fixture/ffmpeg",
                frameRate: 1,
                duration: 1,
                subprocessRunner: runner
            )
            XCTFail("Expected timeout")
        } catch let error as WaveformPCMDecoderError {
            guard case let .decodeFailed(message) = error else {
                return XCTFail("Expected decodeFailed, got \(error)")
            }
            XCTAssertEqual(message, "FFmpeg audio decode timed out")
        }
    }

    func testNativeWaveformRendererRedactsNonzeroFailure() async throws {
        let inputURL = URL(fileURLWithPath: "/private/fixture/secret preview.wav")
        let runner = RecordingSubprocessRunner { request, _ in
            let outputPath = request.arguments.last ?? "/private/fixture/output.raw"
            let diagnostic = "failed \(inputURL.path) \(outputPath) https://example.com/private"
            return SubprocessResult(
                terminationStatus: 9,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(diagnostic.utf8),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(20)
            )
        }

        do {
            _ = try await NativeWaveformRenderer.generateWaveform(
                url: inputURL,
                ffmpegPath: "/private/fixture/ffmpeg",
                streamIndex: 0,
                duration: 1,
                width: 400,
                height: 40,
                subprocessRunner: runner
            )
            XCTFail("Expected process failure")
        } catch let error as PreviewAssetError {
            let diagnostic = error.localizedDescription
            XCTAssertTrue(diagnostic.contains("<redacted>"), diagnostic)
            XCTAssertTrue(diagnostic.contains("<url>"), diagnostic)
            XCTAssertFalse(diagnostic.contains(inputURL.path), diagnostic)
            XCTAssertFalse(diagnostic.contains("example.com"), diagnostic)
        }
    }

    func testWaveformPCMDecoderRedactsCustomExecutableOnLaunchFailure() async throws {
        let ffmpegPath = "/Users/fixture/Private Tools/ffmpeg"
        let runner = RecordingSubprocessRunner { request, _ in
            throw SubprocessRunnerError.failedToStart(
                command: request.redactedCommandDescription,
                underlying: "Could not launch \(request.executableURL.path)"
            )
        }

        do {
            _ = try await WaveformPCMDecoder.decode(
                url: URL(fileURLWithPath: "/private/fixture/audio.wav"),
                ffmpegPath: ffmpegPath,
                frameRate: 1,
                duration: 1,
                subprocessRunner: runner
            )
            XCTFail("Expected launch failure")
        } catch let error as WaveformPCMDecoderError {
            guard case let .decodeFailed(diagnostic) = error else {
                return XCTFail("Expected decodeFailed, got \(error)")
            }
            XCTAssertTrue(diagnostic.contains("<redacted-executable>"), diagnostic)
            XCTAssertTrue(diagnostic.contains("<redacted>"), diagnostic)
            XCTAssertFalse(diagnostic.contains(ffmpegPath), diagnostic)
        }
    }

    func testWaveformPCMDecoderCancellationReachesSharedRunner() async throws {
        let runner = BlockingSubprocessRunner()
        let task = Task {
            try await WaveformPCMDecoder.decode(
                url: URL(fileURLWithPath: "/private/fixture/audio.wav"),
                ffmpegPath: "/private/fixture/ffmpeg",
                frameRate: 1,
                duration: 1,
                subprocessRunner: runner
            )
        }

        await runner.waitUntilStarted()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testTesseractOCREngineUsesSharedRunnerWithDeadlineAndEnvironment() async throws {
        let runner = RecordingSubprocessRunner { _, _ in
            SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data("recognized text\n".utf8),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(20)
            )
        }
        let engine = TesseractOCREngine(
            tesseractPath: "/fixture/tesseract",
            tessdataPrefix: "/fixture/tessdata",
            subprocessRunner: runner
        )
        let imageURL = URL(fileURLWithPath: "/private/tmp/subtitle frame.png")

        let text = try await engine.recognize(pngURL: imageURL, language: "nor+eng")

        XCTAssertEqual(text, "recognized text\n")
        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.executableURL.path, "/fixture/tesseract")
        XCTAssertEqual(request.arguments, [imageURL.path, "stdout", "--psm", "6", "-l", "nor+eng"])
        XCTAssertEqual(request.environment?["TESSDATA_PREFIX"], "/fixture/tessdata")
        XCTAssertEqual(request.timeout, .seconds(10))
        XCTAssertEqual(request.standardOutputCaptureLimit, 256 * 1024)
        XCTAssertEqual(request.standardErrorCaptureLimit, 256 * 1024)
        XCTAssertFalse(request.redactedCommandDescription.contains(imageURL.path))
    }

    func testTesseractOCREngineMapsTimeoutToActionableError() async throws {
        let runner = RecordingSubprocessRunner { request, _ in
            let result = SubprocessResult(
                terminationStatus: SIGTERM,
                termination: .uncaughtSignal,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .seconds(10)
            )
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: result
            )
        }
        let engine = TesseractOCREngine(
            tesseractPath: "/fixture/tesseract",
            tessdataPrefix: nil,
            subprocessRunner: runner
        )

        do {
            _ = try await engine.recognize(
                pngURL: URL(fileURLWithPath: "/private/tmp/frame.png"),
                language: "eng"
            )
            XCTFail("Expected timeout")
        } catch let error as TesseractOCREngineError {
            guard case .timedOut = error else {
                return XCTFail("Expected timedOut, got \(error)")
            }
            XCTAssertEqual(error.errorDescription, "tesseract exceeded the 10-second per-frame limit")
        }
    }

    func testTesseractOCREngineBoundsAndRedactsFailureDiagnostic() async throws {
        let imageURL = URL(fileURLWithPath: "/private/tmp/private-frame.png")
        let runner = RecordingSubprocessRunner { _, _ in
            let diagnostic = "failed to read \(imageURL.path) from https://example.com/private"
            return SubprocessResult(
                terminationStatus: 7,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(diagnostic.utf8),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(20)
            )
        }
        let engine = TesseractOCREngine(
            tesseractPath: "/fixture/tesseract",
            tessdataPrefix: nil,
            subprocessRunner: runner
        )

        do {
            _ = try await engine.recognize(pngURL: imageURL, language: "eng")
            XCTFail("Expected process failure")
        } catch let error as TesseractOCREngineError {
            guard case let .processFailed(exitCode, diagnostic) = error else {
                return XCTFail("Expected processFailed, got \(error)")
            }
            XCTAssertEqual(exitCode, 7)
            XCTAssertTrue(diagnostic.contains("<redacted>"))
            XCTAssertTrue(diagnostic.contains("<url>"))
            XCTAssertFalse(diagnostic.contains(imageURL.path))
            XCTAssertFalse(diagnostic.contains("example.com"))
        }
    }

    func testTesseractOCREngineRejectsTruncatedRecognitionOutput() async throws {
        let runner = RecordingSubprocessRunner { _, _ in
            SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data("tail".utf8),
                standardError: Data(),
                discardedStandardOutputBytes: 1,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(20)
            )
        }
        let engine = TesseractOCREngine(
            tesseractPath: "/fixture/tesseract",
            tessdataPrefix: nil,
            subprocessRunner: runner
        )

        do {
            _ = try await engine.recognize(
                pngURL: URL(fileURLWithPath: "/private/tmp/frame.png"),
                language: "eng"
            )
            XCTFail("Expected oversized-output failure")
        } catch let error as TesseractOCREngineError {
            guard case .outputTooLarge = error else {
                return XCTFail("Expected outputTooLarge, got \(error)")
            }
        }
    }

    func testTesseractOCREnginePropagatesTaskCancellation() async throws {
        let runner = BlockingSubprocessRunner()
        let engine = TesseractOCREngine(
            tesseractPath: "/fixture/tesseract",
            tessdataPrefix: nil,
            subprocessRunner: runner
        )
        let recognitionTask = Task {
            try await engine.recognize(
                pngURL: URL(fileURLWithPath: "/private/tmp/frame.png"),
                language: "eng"
            )
        }

        await runner.waitUntilStarted()
        recognitionTask.cancel()

        do {
            _ = try await recognitionTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testVisionOCREngineLoadsPixelsBeforeCallingBoundedPerformer() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionOCR-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let imageURL = temporaryDirectory.appendingPathComponent("frame.png")
        let expectedData = Data("fixture pixels".utf8)
        try expectedData.write(to: imageURL)
        let invocation = OSAllocatedUnfairLock(
            initialState: Optional<(data: Data, languages: [String], correction: Bool)>.none
        )
        let engine = VisionOCREngine(
            usesLanguageCorrection: false,
            perFrameTimeout: .seconds(1)
        ) { data, languages, correction in
            invocation.withLock { $0 = (data, languages, correction) }
            return "recognized text"
        }

        let text = try await engine.recognize(pngURL: imageURL, language: "nor")

        XCTAssertEqual(text, "recognized text")
        let recorded = try XCTUnwrap(invocation.withLock { $0 })
        XCTAssertEqual(recorded.data, expectedData)
        XCTAssertEqual(recorded.languages, ["nb-NO", "nn-NO"])
        XCTAssertFalse(recorded.correction)
    }

    func testVisionOCREngineDoesNotJoinTimedOutRecognition() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionOCR-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let imageURL = temporaryDirectory.appendingPathComponent("frame.png")
        try Data("fixture pixels".utf8).write(to: imageURL)
        let recognitionStarted = DispatchSemaphore(value: 0)
        let releaseRecognition = DispatchSemaphore(value: 0)
        let recognitionFinished = DispatchSemaphore(value: 0)
        defer { releaseRecognition.signal() }
        let engine = VisionOCREngine(perFrameTimeout: .milliseconds(50)) { _, _, _ in
            try await withCheckedThrowingContinuation { continuation in
                recognitionStarted.signal()
                DispatchQueue.global(qos: .utility).async {
                    releaseRecognition.wait()
                    recognitionFinished.signal()
                    continuation.resume(returning: "late text")
                }
            }
        }
        let start = ContinuousClock.now

        do {
            _ = try await engine.recognize(pngURL: imageURL, language: "eng")
            XCTFail("Expected Vision recognition timeout")
        } catch let error as VisionOCREngineError {
            guard case .timedOut = error else {
                return XCTFail("Expected timedOut, got \(error)")
            }
            XCTAssertEqual(
                error.errorDescription,
                "Apple Vision exceeded the 0.05-second per-frame limit"
            )
        }

        XCTAssertEqual(recognitionStarted.wait(timeout: .now() + 1), .success)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        releaseRecognition.signal()
        XCTAssertEqual(recognitionFinished.wait(timeout: .now() + 1), .success)
        try? await Task.sleep(for: .milliseconds(20))
    }

    func testVisionOCREngineParentCancellationReturnsPromptly() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VisionOCR-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let imageURL = temporaryDirectory.appendingPathComponent("frame.png")
        try Data("fixture pixels".utf8).write(to: imageURL)
        let recognitionStarted = DispatchSemaphore(value: 0)
        let releaseRecognition = DispatchSemaphore(value: 0)
        defer { releaseRecognition.signal() }
        let engine = VisionOCREngine(perFrameTimeout: .seconds(10)) { _, _, _ in
            try await withCheckedThrowingContinuation { continuation in
                recognitionStarted.signal()
                DispatchQueue.global(qos: .utility).async {
                    releaseRecognition.wait()
                    continuation.resume(returning: "late text")
                }
            }
        }
        let task = Task {
            try await engine.recognize(pngURL: imageURL, language: "eng")
        }

        XCTAssertEqual(recognitionStarted.wait(timeout: .now() + 1), .success)
        let start = ContinuousClock.now
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected Vision recognition cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testTesseractSubtitleExtractorUsesSharedRunnerWithDeadlineAndRedaction() async throws {
        let runner = RecordingSubprocessRunner { _, _ in
            SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(20)
            )
        }
        let extractor = TesseractSubtitleStreamExtractor(subprocessRunner: runner)
        let source = "/private/media/secret source.mkv"
        let output = "/private/tmp/secret output.sup"

        try await extractor.extract(
            source: source,
            streamIndex: 2,
            outputPath: output,
            ffmpegPath: "/fixture/ffmpeg"
        )

        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.executableURL.path, "/fixture/ffmpeg")
        XCTAssertEqual(
            request.arguments,
            ["-y", "-i", source, "-map", "0:s:2", "-c", "copy", output]
        )
        XCTAssertEqual(request.timeout, .seconds(30 * 60))
        XCTAssertEqual(request.standardOutputCaptureLimit, 0)
        XCTAssertEqual(request.standardErrorCaptureLimit, 256 * 1024)
        XCTAssertFalse(request.redactedCommandDescription.contains(source))
        XCTAssertFalse(request.redactedCommandDescription.contains(output))
    }

    func testTesseractSubtitleExtractorReassemblesSplitProgressOutput() async throws {
        let progressReported = expectation(description: "split FFmpeg progress parsed")
        let runner = RecordingSubprocessRunner { _, outputHandler in
            outputHandler?(SubprocessOutputChunk(
                stream: .standardError,
                data: Data("Duration: 00:00:10.00, start: 0.000000\nframe=1 time=00:00:".utf8)
            ))
            outputHandler?(SubprocessOutputChunk(
                stream: .standardError,
                data: Data("05.00 bitrate=0.0kbits/s\r".utf8)
            ))
            return SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(20)
            )
        }
        let extractor = TesseractSubtitleStreamExtractor(subprocessRunner: runner)
        let reportedProgress = OSAllocatedUnfairLock<Double?>(initialState: nil)

        try await extractor.extract(
            source: "/private/media/input.mkv",
            streamIndex: 0,
            outputPath: "/private/tmp/output.sup",
            ffmpegPath: "/fixture/ffmpeg"
        ) { progress in
            reportedProgress.withLock { $0 = progress }
            progressReported.fulfill()
        }

        await fulfillment(of: [progressReported], timeout: 1.0)
        XCTAssertEqual(
            try XCTUnwrap(reportedProgress.withLock { $0 }),
            0.5,
            accuracy: 0.001
        )
    }

    func testTesseractSubtitleExtractorMapsTimeoutToActionableError() async throws {
        let runner = RecordingSubprocessRunner { request, _ in
            let result = SubprocessResult(
                terminationStatus: SIGTERM,
                termination: .uncaughtSignal,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .seconds(30 * 60)
            )
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: result
            )
        }
        let extractor = TesseractSubtitleStreamExtractor(subprocessRunner: runner)

        do {
            try await extractor.extract(
                source: "/private/media/input.mkv",
                streamIndex: 0,
                outputPath: "/private/tmp/output.sup",
                ffmpegPath: "/fixture/ffmpeg"
            )
            XCTFail("Expected timeout")
        } catch let error as TesseractServiceError {
            guard case .extractionFailed(let detail) = error else {
                return XCTFail("Expected extractionFailed, got \(error)")
            }
            XCTAssertEqual(detail, "FFmpeg exceeded the 30-minute subtitle extraction limit")
        }
    }

    func testTesseractSubtitleExtractorBoundsAndRedactsFailureDiagnostic() async throws {
        let source = "/private/media/private-source.mkv"
        let output = "/private/tmp/private-output.sup"
        let runner = RecordingSubprocessRunner { _, _ in
            let diagnostic = String(repeating: "x", count: 400)
                + " failed \(source) -> \(output) at https://example.com/private"
            return SubprocessResult(
                terminationStatus: 9,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(diagnostic.utf8),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(20)
            )
        }
        let extractor = TesseractSubtitleStreamExtractor(subprocessRunner: runner)

        do {
            try await extractor.extract(
                source: source,
                streamIndex: 0,
                outputPath: output,
                ffmpegPath: "/fixture/ffmpeg"
            )
            XCTFail("Expected process failure")
        } catch let error as TesseractServiceError {
            guard case .extractionFailed(let detail) = error else {
                return XCTFail("Expected extractionFailed, got \(error)")
            }
            XCTAssertTrue(detail.hasPrefix("FFmpeg exited 9: …"), detail)
            XCTAssertTrue(detail.contains("<redacted>"), detail)
            XCTAssertTrue(detail.contains("<url>"), detail)
            XCTAssertFalse(detail.contains(source), detail)
            XCTAssertFalse(detail.contains(output), detail)
            XCTAssertFalse(detail.contains("example.com"), detail)
            XCTAssertLessThanOrEqual(detail.count, 319)
        }
    }

    func testTesseractSubtitleExtractorPropagatesTaskCancellation() async throws {
        let runner = BlockingSubprocessRunner()
        let extractor = TesseractSubtitleStreamExtractor(subprocessRunner: runner)
        let extractionTask = Task {
            try await extractor.extract(
                source: "/private/media/input.mkv",
                streamIndex: 0,
                outputPath: "/private/tmp/output.sup",
                ffmpegPath: "/fixture/ffmpeg"
            )
        }

        await runner.waitUntilStarted()
        extractionTask.cancel()

        do {
            _ = try await extractionTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testTesseractServiceCancelGenerationCancelsOnlyMatchingOverlappingExtraction() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TesseractServiceCancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let firstSourceURL = temporaryDirectory.appendingPathComponent("first.mkv")
        let secondSourceURL = temporaryDirectory.appendingPathComponent("second.mkv")
        try Data().write(to: firstSourceURL)
        try Data().write(to: secondSourceURL)
        let runner = CountingBlockingSubprocessRunner()
        let service = TesseractService(subprocessRunner: runner)
        let firstOperationID = UUID()
        let secondOperationID = UUID()

        try await withPresetSettingsAsync([
            AppConstants.ocrEngineKey: OCREngineKind.appleVision.rawValue
        ]) {
            let firstGenerationTask = Task {
                try await service.generateSubtitles(
                    sourceFile: firstSourceURL,
                    outputDirectory: temporaryDirectory,
                    operationID: firstOperationID,
                    subtitleStreamIndex: 0,
                    codec: "hdmv_pgs_subtitle",
                    language: "eng"
                ) { _ in }
            }
            let secondGenerationTask = Task {
                try await service.generateSubtitles(
                    sourceFile: secondSourceURL,
                    outputDirectory: temporaryDirectory,
                    operationID: secondOperationID,
                    subtitleStreamIndex: 0,
                    codec: "hdmv_pgs_subtitle",
                    language: "eng"
                ) { _ in }
            }

            await runner.waitUntilStarted(count: 2)
            await service.cancelGeneration(operationID: firstOperationID)

            do {
                _ = try await firstGenerationTask.value
                XCTFail("Expected service cancellation")
            } catch let error as TesseractServiceError {
                guard case .cancelled = error else {
                    return XCTFail("Expected cancelled, got \(error)")
                }
            }
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(runner.cancelledCount, 1)

            await service.cancelGeneration(operationID: secondOperationID)
            do {
                _ = try await secondGenerationTask.value
                XCTFail("Expected second service cancellation")
            } catch let error as TesseractServiceError {
                guard case .cancelled = error else {
                    return XCTFail("Expected cancelled, got \(error)")
                }
            }
            XCTAssertEqual(runner.cancelledCount, 2)
        }
    }

    func testWhisperTranscriberUsesSharedRunnerWithDeadlineRedactionAndSplitProgress() async throws {
        let progressValues = OSAllocatedUnfairLock<[Double]>(initialState: [])
        let runner = RecordingSubprocessRunner { _, outputHandler in
            outputHandler?(SubprocessOutputChunk(
                stream: .standardError,
                data: Data("Duration: 00:00".utf8)
            ))
            outputHandler?(SubprocessOutputChunk(
                stream: .standardError,
                data: Data(":10.00\rframe=12 time=00:00:05".utf8)
            ))
            outputHandler?(SubprocessOutputChunk(
                stream: .standardError,
                data: Data(".00 speed=1.0x".utf8)
            ))
            return SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .seconds(5)
            )
        }
        let transcriber = WhisperFFmpegTranscriber(subprocessRunner: runner)
        let input = URL(fileURLWithPath: "/private/media/source: secret.mov")
        let model = URL(fileURLWithPath: "/private/models/model's:v1.bin")
        let output = URL(fileURLWithPath: "/private/output/subtitles: secret.srt")

        try await transcriber.transcribe(
            inputFile: input,
            modelPath: model,
            outputFile: output,
            ffmpegPath: "/fixture/ffmpeg",
            language: "nb",
            audioStreamIndex: 3
        ) { update in
            progressValues.withLock { $0.append(update.percentage) }
        }

        let request = try XCTUnwrap(runner.lastRequest)
        let filter = WhisperFFmpegTranscriber.filter(
            modelPath: model.path,
            outputPath: output.path,
            language: "nb"
        )
        XCTAssertEqual(request.executableURL.path, "/fixture/ffmpeg")
        XCTAssertEqual(request.arguments, [
            "-nostdin", "-i", input.path,
            "-map", "0:3",
            "-af", filter,
            "-f", "null", "-"
        ])
        XCTAssertEqual(request.timeout, .seconds(12 * 60 * 60))
        XCTAssertEqual(request.standardOutputCaptureLimit, 0)
        XCTAssertEqual(request.standardErrorCaptureLimit, 256 * 1024)
        XCTAssertFalse(request.redactedCommandDescription.contains(input.path))
        XCTAssertFalse(request.redactedCommandDescription.contains(model.path))
        XCTAssertFalse(request.redactedCommandDescription.contains(output.path))
        XCTAssertEqual(progressValues.withLock { $0 }, [0.5])
    }

    func testWhisperFilterEscapingRoundTripsThroughBundledFFmpegParser() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperFilterEscaping-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let modelPath = temporaryDirectory.appendingPathComponent(
            "model:comma,semi;bracket[one]slash\\quote'apost.bin"
        )
        let destinationPath = temporaryDirectory.appendingPathComponent(
            "dest:comma,semi;bracket[two]slash\\quote'apost.srt"
        )
        let filter = WhisperFFmpegTranscriber.filter(
            modelPath: modelPath.path,
            outputPath: destinationPath.path,
            language: "auto"
        )
        let result = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: ffmpegExecutableURL,
            arguments: [
                "-hide_banner", "-loglevel", "debug",
                "-f", "lavfi", "-i", "anullsrc=d=0.01",
                "-af", filter,
                "-f", "null", "-"
            ],
            timeout: .seconds(10),
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 512 * 1024
        ))

        XCTAssertFalse(result.succeeded)
        let diagnostic = result.standardErrorText
        XCTAssertTrue(diagnostic.contains("Setting 'model' to value '\(modelPath.path)'"), diagnostic)
        XCTAssertTrue(
            diagnostic.contains("Setting 'destination' to value '\(destinationPath.path)'"),
            diagnostic
        )
        XCTAssertFalse(diagnostic.contains("Error parsing filter"), diagnostic)
        XCTAssertFalse(diagnostic.contains("Error parsing filterchain"), diagnostic)
        XCTAssertFalse(diagnostic.contains("No option name near"), diagnostic)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationPath.path))
    }

    func testWhisperTranscriberMapsTimeoutToActionableError() async throws {
        let runner = RecordingSubprocessRunner { request, _ in
            let result = SubprocessResult(
                terminationStatus: SIGTERM,
                termination: .uncaughtSignal,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .seconds(12 * 60 * 60)
            )
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: result
            )
        }
        let transcriber = WhisperFFmpegTranscriber(subprocessRunner: runner)

        do {
            try await transcriber.transcribe(
                inputFile: URL(fileURLWithPath: "/private/media/source.mov"),
                modelPath: URL(fileURLWithPath: "/private/models/model.bin"),
                outputFile: URL(fileURLWithPath: "/private/output/subtitles.srt"),
                ffmpegPath: "/fixture/ffmpeg",
                language: "auto",
                audioStreamIndex: nil
            ) { _ in }
            XCTFail("Expected timeout")
        } catch let error as WhisperServiceError {
            guard case let .transcriptionFailed(message) = error else {
                return XCTFail("Expected transcriptionFailed, got \(error)")
            }
            XCTAssertEqual(message, "FFmpeg exceeded the 12-hour transcription limit")
        }
    }

    func testWhisperTranscriberBoundsAndRedactsFailureDiagnostic() async throws {
        let input = URL(fileURLWithPath: "/private/media/private source.mov")
        let model = URL(fileURLWithPath: "/private/models/private model.bin")
        let output = URL(fileURLWithPath: "/private/output/private subtitles.srt")
        let runner = RecordingSubprocessRunner { _, _ in
            let diagnostic = "failed \(input.path) \(model.path) \(output.path) https://example.com/private"
            return SubprocessResult(
                terminationStatus: 9,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(diagnostic.utf8),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .seconds(1)
            )
        }
        let transcriber = WhisperFFmpegTranscriber(subprocessRunner: runner)

        do {
            try await transcriber.transcribe(
                inputFile: input,
                modelPath: model,
                outputFile: output,
                ffmpegPath: "/fixture/ffmpeg",
                language: "auto",
                audioStreamIndex: nil
            ) { _ in }
            XCTFail("Expected process failure")
        } catch let error as WhisperServiceError {
            guard case let .transcriptionFailed(message) = error else {
                return XCTFail("Expected transcriptionFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("FFmpeg exited 9"))
            XCTAssertTrue(message.contains("<redacted>"))
            XCTAssertTrue(message.contains("<url>"))
            XCTAssertFalse(message.contains(input.path))
            XCTAssertFalse(message.contains(model.path))
            XCTAssertFalse(message.contains(output.path))
            XCTAssertFalse(message.contains("example.com"))
            XCTAssertLessThanOrEqual(message.count, 550)
        }
    }

    func testWhisperTranscriberPropagatesTaskCancellation() async throws {
        let runner = BlockingSubprocessRunner()
        let transcriber = WhisperFFmpegTranscriber(subprocessRunner: runner)
        let transcriptionTask = Task {
            try await transcriber.transcribe(
                inputFile: URL(fileURLWithPath: "/private/media/source.mov"),
                modelPath: URL(fileURLWithPath: "/private/models/model.bin"),
                outputFile: URL(fileURLWithPath: "/private/output/subtitles.srt"),
                ffmpegPath: "/fixture/ffmpeg",
                language: "auto",
                audioStreamIndex: nil
            ) { _ in }
        }

        await runner.waitUntilStarted()
        transcriptionTask.cancel()

        do {
            try await transcriptionTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testWhisperServiceCancelGenerationCancelsOnlyMatchingOverlappingTranscription() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperServiceCancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = CountingBlockingSubprocessRunner()
        let modelProvider = StubWhisperModelProvider(
            path: temporaryDirectory.appendingPathComponent("model.bin")
        )
        let service = WhisperService(
            modelManager: modelProvider,
            subprocessRunner: runner,
            ffmpegPathProvider: { "/fixture/ffmpeg" }
        )
        let firstInput = temporaryDirectory.appendingPathComponent("first.mov")
        let secondInput = temporaryDirectory.appendingPathComponent("second.mov")
        let firstOperationID = UUID()
        let secondOperationID = UUID()

        let firstTask = Task {
            try await service.generateSubtitles(
                inputFile: firstInput,
                outputDirectory: temporaryDirectory,
                model: .base,
                language: "auto",
                operationID: firstOperationID
            ) { _ in }
        }
        let secondTask = Task {
            try await service.generateSubtitles(
                inputFile: secondInput,
                outputDirectory: temporaryDirectory,
                model: .base,
                language: "auto",
                operationID: secondOperationID
            ) { _ in }
        }

        await runner.waitUntilStarted(count: 2)
        await service.cancelGeneration(operationID: firstOperationID)

        do {
            _ = try await firstTask.value
            XCTFail("Expected service cancellation")
        } catch let error as WhisperServiceError {
            guard case .cancelled = error else {
                return XCTFail("Expected cancelled, got \(error)")
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(runner.cancelledCount, 1)

        await service.cancelGeneration(operationID: secondOperationID)
        do {
            _ = try await secondTask.value
            XCTFail("Expected second service cancellation")
        } catch let error as WhisperServiceError {
            guard case .cancelled = error else {
                return XCTFail("Expected cancelled, got \(error)")
            }
        }
        XCTAssertEqual(runner.cancelledCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: temporaryDirectory.appendingPathComponent("first.srt").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: temporaryDirectory.appendingPathComponent("second.srt").path
        ))
    }

    func testWhisperServiceRemembersCancellationThatArrivesBeforeRegistration() async throws {
        let operationID = UUID()
        let runner = RecordingSubprocessRunner { _, _ in
            XCTFail("Cancelled operation must not launch FFmpeg")
            return SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .zero
            )
        }
        let service = WhisperService(
            modelManager: StubWhisperModelProvider(
                path: URL(fileURLWithPath: "/fixture/model.bin")
            ),
            subprocessRunner: runner,
            ffmpegPathProvider: { "/fixture/ffmpeg" }
        )
        await service.cancelGeneration(operationID: operationID)

        do {
            _ = try await service.generateSubtitles(
                inputFile: URL(fileURLWithPath: "/fixture/input.mov"),
                outputDirectory: URL(fileURLWithPath: "/fixture"),
                model: .base,
                language: "auto",
                operationID: operationID
            ) { _ in }
            XCTFail("Expected cancellation")
        } catch let error as WhisperServiceError {
            guard case .cancelled = error else {
                return XCTFail("Expected cancelled, got \(error)")
            }
        }
        XCTAssertNil(runner.lastRequest)
    }

    func testTesseractServiceRemembersCancellationThatArrivesBeforeRegistration() async throws {
        let operationID = UUID()
        let runner = RecordingSubprocessRunner { _, _ in
            XCTFail("Cancelled operation must not launch FFmpeg")
            return SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .zero
            )
        }
        let service = TesseractService(subprocessRunner: runner)
        await service.cancelGeneration(operationID: operationID)

        do {
            _ = try await service.generateSubtitles(
                sourceFile: URL(fileURLWithPath: "/fixture/input.mkv"),
                outputDirectory: URL(fileURLWithPath: "/fixture"),
                operationID: operationID,
                subtitleStreamIndex: 0,
                codec: "hdmv_pgs_subtitle",
                language: "eng"
            ) { _ in }
            XCTFail("Expected cancellation")
        } catch let error as TesseractServiceError {
            guard case .cancelled = error else {
                return XCTFail("Expected cancelled, got \(error)")
            }
        }
        XCTAssertNil(runner.lastRequest)
    }

    func testWhisperServiceReservesDistinctOutputsForConcurrentSameBasenameRuns() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperServiceConcurrentOutput-\(UUID().uuidString)")
        let firstInputDirectory = temporaryDirectory.appendingPathComponent("video")
        let secondInputDirectory = temporaryDirectory.appendingPathComponent("audio")
        let outputDirectory = temporaryDirectory.appendingPathComponent("output")
        for directory in [firstInputDirectory, secondInputDirectory, outputDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = CoordinatedWhisperOutputRunner(expectedCount: 2)
        let service = WhisperService(
            modelManager: StubWhisperModelProvider(
                path: temporaryDirectory.appendingPathComponent("model.bin")
            ),
            subprocessRunner: runner,
            ffmpegPathProvider: { "/fixture/ffmpeg" }
        )
        let firstTask = Task {
            try await service.generateSubtitles(
                inputFile: firstInputDirectory.appendingPathComponent("clip.mov"),
                outputDirectory: outputDirectory,
                model: .base,
                language: "auto",
                operationID: UUID()
            ) { _ in }
        }
        let secondTask = Task {
            try await service.generateSubtitles(
                inputFile: secondInputDirectory.appendingPathComponent("clip.wav"),
                outputDirectory: outputDirectory,
                model: .base,
                language: "auto",
                operationID: UUID()
            ) { _ in }
        }

        let firstOutput = try await firstTask.value
        let secondOutput = try await secondTask.value

        XCTAssertEqual(Set([firstOutput.lastPathComponent, secondOutput.lastPathComponent]), Set([
            "clip.srt", "clip.whisper.srt"
        ]))
        XCTAssertNotEqual(
            try String(contentsOf: firstOutput, encoding: .utf8),
            try String(contentsOf: secondOutput, encoding: .utf8)
        )
    }

    func testWhisperServiceUsesShortStagingNameForLongBasename() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperServiceLongName-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let baseName = String(repeating: "a", count: 245)
        let runner = CoordinatedWhisperOutputRunner(expectedCount: 2)
        let service = WhisperService(
            modelManager: StubWhisperModelProvider(
                path: temporaryDirectory.appendingPathComponent("model.bin")
            ),
            subprocessRunner: runner,
            ffmpegPathProvider: { "/fixture/ffmpeg" }
        )

        let firstTask = Task {
            try await service.generateSubtitles(
                inputFile: temporaryDirectory.appendingPathComponent(baseName + ".mov"),
                outputDirectory: temporaryDirectory,
                model: .base,
                language: "auto",
                operationID: UUID()
            ) { _ in }
        }
        let secondTask = Task {
            try await service.generateSubtitles(
                inputFile: temporaryDirectory.appendingPathComponent(baseName + ".wav"),
                outputDirectory: temporaryDirectory,
                model: .base,
                language: "auto",
                operationID: UUID()
            ) { _ in }
        }

        let firstOutput = try await firstTask.value
        let secondOutput = try await secondTask.value
        let outputs = [firstOutput, secondOutput]
        XCTAssertEqual(Set(outputs.map(\.lastPathComponent)).count, 2)
        XCTAssertTrue(outputs.contains { $0.lastPathComponent == baseName + ".srt" })
        for output in outputs {
            XCTAssertLessThanOrEqual(output.lastPathComponent.utf8.count, 255)
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func testWhisperServiceFailedRerunPreservesExistingSubtitle() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperServicePreserve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let input = temporaryDirectory.appendingPathComponent("clip.mov")
        let existingSubtitle = temporaryDirectory.appendingPathComponent("clip.srt")
        try "existing subtitle".write(to: existingSubtitle, atomically: true, encoding: .utf8)
        let runner = RecordingSubprocessRunner { _, _ in
            SubprocessResult(
                terminationStatus: 7,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data("filter failed".utf8),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(10)
            )
        }
        let service = WhisperService(
            modelManager: StubWhisperModelProvider(
                path: temporaryDirectory.appendingPathComponent("model.bin")
            ),
            subprocessRunner: runner,
            ffmpegPathProvider: { "/fixture/ffmpeg" }
        )

        do {
            _ = try await service.generateSubtitles(
                inputFile: input,
                outputDirectory: temporaryDirectory,
                model: .base,
                language: "auto",
                operationID: UUID()
            ) { _ in }
            XCTFail("Expected transcription failure")
        } catch let error as WhisperServiceError {
            guard case .transcriptionFailed = error else {
                return XCTFail("Expected transcriptionFailed, got \(error)")
            }
        }

        XCTAssertEqual(
            try String(contentsOf: existingSubtitle, encoding: .utf8),
            "existing subtitle"
        )
        let stagedFiles = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
            .filter { $0.contains(".whisper-") }
        XCTAssertTrue(stagedFiles.isEmpty)
    }

    func testWhisperServicePublishesStagedSubtitleOverExistingOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperServicePublish-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let input = temporaryDirectory.appendingPathComponent("clip.mov")
        let existingSubtitle = temporaryDirectory.appendingPathComponent("clip.srt")
        try "existing subtitle".write(to: existingSubtitle, atomically: true, encoding: .utf8)
        let runner = RecordingSubprocessRunner { request, _ in
            let stagedURL = try XCTUnwrap(whisperDestinationURL(in: request))
            try "1\n00:00:00,000 --> 00:00:01,000\nNew text\n".write(
                to: stagedURL,
                atomically: true,
                encoding: .utf8
            )
            return SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(10)
            )
        }
        let service = WhisperService(
            modelManager: StubWhisperModelProvider(
                path: temporaryDirectory.appendingPathComponent("model.bin")
            ),
            subprocessRunner: runner,
            ffmpegPathProvider: { "/fixture/ffmpeg" }
        )

        let result = try await service.generateSubtitles(
            inputFile: input,
            outputDirectory: temporaryDirectory,
            model: .base,
            language: "auto",
            operationID: UUID()
        ) { _ in }

        XCTAssertEqual(result, existingSubtitle)
        XCTAssertTrue(try String(contentsOf: existingSubtitle, encoding: .utf8).contains("New text"))
        let stagedFiles = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
            .filter { $0.contains(".whisper-") }
        XCTAssertTrue(stagedFiles.isEmpty)
    }

    func testWhisperServiceMapsLateParentCancellationBeforePublishingOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperServiceLateCancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = DeferredSuccessfulWhisperRunner()
        let service = WhisperService(
            modelManager: StubWhisperModelProvider(
                path: temporaryDirectory.appendingPathComponent("model.bin")
            ),
            subprocessRunner: runner,
            ffmpegPathProvider: { "/fixture/ffmpeg" }
        )
        let input = temporaryDirectory.appendingPathComponent("clip.mov")
        let generationTask = Task {
            try await service.generateSubtitles(
                inputFile: input,
                outputDirectory: temporaryDirectory,
                model: .base,
                language: "auto",
                operationID: UUID()
            ) { _ in }
        }

        await runner.waitUntilStarted()
        generationTask.cancel()
        runner.release()

        do {
            _ = try await generationTask.value
            XCTFail("Expected cancellation")
        } catch let error as WhisperServiceError {
            guard case .cancelled = error else {
                return XCTFail("Expected cancelled, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: temporaryDirectory.appendingPathComponent("clip.srt").path
        ))
        let stagedFiles = try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
            .filter { $0.contains(".whisper-") }
        XCTAssertTrue(stagedFiles.isEmpty)
    }

    func testParakeetTranscriberUsesSharedRunnerWithDeadlineRedactionAndSplitProgress() async throws {
        let progressValues = OSAllocatedUnfairLock<[Double]>(initialState: [])
        let runner = RecordingSubprocessRunner { _, outputHandler in
            outputHandler?(SubprocessOutputChunk(
                stream: .standardError,
                data: Data("Processing chunk 1/".utf8)
            ))
            outputHandler?(SubprocessOutputChunk(
                stream: .standardOutput,
                data: Data("unrelated stdout\n".utf8)
            ))
            outputHandler?(SubprocessOutputChunk(
                stream: .standardError,
                data: Data("4\n".utf8)
            ))
            outputHandler?(SubprocessOutputChunk(
                stream: .standardOutput,
                data: Data("Progress 50.0%".utf8)
            ))
            return SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .seconds(2)
            )
        }
        let transcriber = ParakeetCLITranscriber(subprocessRunner: runner)
        let input = URL(fileURLWithPath: "/private/media/private input.wav")
        let output = URL(fileURLWithPath: "/private/output/private staging")

        try await transcriber.transcribe(
            inputFile: input,
            outputDirectory: output,
            parakeetPath: "/fixture/parakeet-mlx",
            ffmpegPath: "/fixture/tools/ffmpeg",
            modelID: "mlx-community/parakeet-fixture",
            chunkDuration: 120,
            overlapDuration: 12
        ) { update in
            progressValues.withLock { $0.append(update.percentage) }
        }

        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.executableURL.path, "/fixture/parakeet-mlx")
        XCTAssertEqual(request.arguments, [
            input.path,
            "--output-format", "srt",
            "--output-dir", output.path,
            "--model", "mlx-community/parakeet-fixture",
            "--chunk-duration", "120",
            "--overlap-duration", "12"
        ])
        XCTAssertEqual(request.timeout, .seconds(12 * 60 * 60))
        XCTAssertEqual(request.standardOutputCaptureLimit, 256 * 1024)
        XCTAssertEqual(request.standardErrorCaptureLimit, 256 * 1024)
        XCTAssertTrue(request.environment?["PATH"]?.contains("/fixture/tools") == true)
        XCTAssertFalse(request.redactedCommandDescription.contains(input.path))
        XCTAssertFalse(request.redactedCommandDescription.contains(output.path))
        XCTAssertEqual(progressValues.withLock { $0 }, [0.25, 0.5])
    }

    func testParakeetTranscriberMapsTimeoutAndRedactsFailureDiagnostics() async throws {
        let input = URL(fileURLWithPath: "/private/media/private input.wav")
        let output = URL(fileURLWithPath: "/private/output/private staging")
        let timeoutRunner = RecordingSubprocessRunner { request, _ in
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: SubprocessResult(
                    terminationStatus: SIGTERM,
                    termination: .uncaughtSignal,
                    standardOutput: Data(),
                    standardError: Data(),
                    discardedStandardOutputBytes: 0,
                    discardedStandardErrorBytes: 0,
                    duration: .seconds(12 * 60 * 60)
                )
            )
        }
        let timeoutTranscriber = ParakeetCLITranscriber(subprocessRunner: timeoutRunner)

        do {
            try await timeoutTranscriber.transcribe(
                inputFile: input,
                outputDirectory: output,
                parakeetPath: "/fixture/parakeet-mlx",
                ffmpegPath: nil,
                modelID: "fixture",
                chunkDuration: AppConstants.defaultParakeetChunkDuration,
                overlapDuration: AppConstants.defaultParakeetOverlapDuration
            ) { _ in }
            XCTFail("Expected timeout")
        } catch let error as ParakeetServiceError {
            guard case let .transcriptionFailed(message) = error else {
                return XCTFail("Expected transcriptionFailed, got \(error)")
            }
            XCTAssertEqual(message, "parakeet-mlx exceeded the 12-hour transcription limit")
        }

        let failureRunner = RecordingSubprocessRunner { _, _ in
            let diagnostic = "failed \(input.path) in \(output.path) at https://example.com/private"
            return SubprocessResult(
                terminationStatus: 9,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(diagnostic.utf8),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .seconds(1)
            )
        }
        let failureTranscriber = ParakeetCLITranscriber(subprocessRunner: failureRunner)
        do {
            try await failureTranscriber.transcribe(
                inputFile: input,
                outputDirectory: output,
                parakeetPath: "/fixture/parakeet-mlx",
                ffmpegPath: nil,
                modelID: "fixture",
                chunkDuration: 0,
                overlapDuration: 0
            ) { _ in }
            XCTFail("Expected process failure")
        } catch let error as ParakeetServiceError {
            guard case let .transcriptionFailed(message) = error else {
                return XCTFail("Expected transcriptionFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("parakeet-mlx exited 9"))
            XCTAssertTrue(message.contains("<redacted>"))
            XCTAssertTrue(message.contains("<url>"))
            XCTAssertFalse(message.contains(input.path))
            XCTAssertFalse(message.contains(output.path))
            XCTAssertFalse(message.contains("example.com"))
            XCTAssertLessThanOrEqual(message.count, 550)
        }
    }

    func testParakeetAudioExtractorUsesSharedRunnerAndRedactsPaths() async throws {
        let runner = RecordingSubprocessRunner { _, _ in
            SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .seconds(1)
            )
        }
        let extractor = ParakeetAudioExtractor(subprocessRunner: runner)
        let input = URL(fileURLWithPath: "/private/media/private source.mov")
        let output = URL(fileURLWithPath: "/private/tmp/private audio.wav")

        try await extractor.extract(
            inputFile: input,
            outputFile: output,
            ffmpegPath: "/fixture/ffmpeg",
            audioStreamIndex: 3
        )

        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.arguments, [
            "-y", "-nostdin", "-i", input.path, "-map", "0:3",
            "-acodec", "pcm_s16le", "-ar", "16000", "-ac", "1", output.path
        ])
        XCTAssertEqual(request.timeout, .seconds(2 * 60 * 60))
        XCTAssertEqual(request.standardOutputCaptureLimit, 0)
        XCTAssertEqual(request.standardErrorCaptureLimit, 256 * 1024)
        XCTAssertFalse(request.redactedCommandDescription.contains(input.path))
        XCTAssertFalse(request.redactedCommandDescription.contains(output.path))
    }

    func testParakeetServiceCancelGenerationCancelsOnlyMatchingOverlappingRun() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParakeetCancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = CountingBlockingSubprocessRunner()
        let service = fixtureParakeetService(runner: runner)
        let firstOperationID = UUID()
        let secondOperationID = UUID()
        let firstTask = Task {
            try await service.generateSubtitles(
                inputFile: temporaryDirectory.appendingPathComponent("first.mov"),
                outputDirectory: temporaryDirectory,
                model: ParakeetModel.allModels[0],
                language: "en",
                operationID: firstOperationID
            ) { _ in }
        }
        let secondTask = Task {
            try await service.generateSubtitles(
                inputFile: temporaryDirectory.appendingPathComponent("second.mov"),
                outputDirectory: temporaryDirectory,
                model: ParakeetModel.allModels[0],
                language: "en",
                operationID: secondOperationID
            ) { _ in }
        }

        await runner.waitUntilStarted(count: 2)
        await service.cancelGeneration(operationID: firstOperationID)
        do {
            _ = try await firstTask.value
            XCTFail("Expected first run cancellation")
        } catch let error as ParakeetServiceError {
            guard case .cancelled = error else { return XCTFail("Expected cancelled, got \(error)") }
        }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(runner.cancelledCount, 1)

        await service.cancelGeneration(operationID: secondOperationID)
        do {
            _ = try await secondTask.value
            XCTFail("Expected second run cancellation")
        } catch let error as ParakeetServiceError {
            guard case .cancelled = error else { return XCTFail("Expected cancelled, got \(error)") }
        }
        XCTAssertEqual(runner.cancelledCount, 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
            .filter { $0.hasPrefix(".parakeet-") }.isEmpty)
    }

    func testParakeetServiceRemembersCancellationBeforeRegistration() async throws {
        let operationID = UUID()
        let runner = RecordingSubprocessRunner { _, _ in
            XCTFail("Cancelled operation must not launch parakeet-mlx")
            return SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .zero
            )
        }
        let service = fixtureParakeetService(runner: runner)
        await service.cancelGeneration(operationID: operationID)

        do {
            _ = try await service.generateSubtitles(
                inputFile: URL(fileURLWithPath: "/fixture/input.mov"),
                outputDirectory: URL(fileURLWithPath: "/fixture"),
                model: ParakeetModel.allModels[0],
                language: "en",
                operationID: operationID
            ) { _ in }
            XCTFail("Expected cancellation")
        } catch let error as ParakeetServiceError {
            guard case .cancelled = error else { return XCTFail("Expected cancelled, got \(error)") }
        }
        XCTAssertNil(runner.lastRequest)
    }

    func testParakeetServiceFailedRerunPreservesExistingSubtitle() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParakeetPreserve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let existingSubtitle = temporaryDirectory.appendingPathComponent("clip.srt")
        try "existing subtitle".write(to: existingSubtitle, atomically: true, encoding: .utf8)
        let runner = RecordingSubprocessRunner { _, _ in
            SubprocessResult(
                terminationStatus: 7,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data("transcription failed".utf8),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(10)
            )
        }
        let service = fixtureParakeetService(runner: runner)

        do {
            _ = try await service.generateSubtitles(
                inputFile: temporaryDirectory.appendingPathComponent("clip.mov"),
                outputDirectory: temporaryDirectory,
                model: ParakeetModel.allModels[0],
                language: "en",
                operationID: UUID()
            ) { _ in }
            XCTFail("Expected transcription failure")
        } catch let error as ParakeetServiceError {
            guard case .transcriptionFailed = error else {
                return XCTFail("Expected transcriptionFailed, got \(error)")
            }
        }

        XCTAssertEqual(try String(contentsOf: existingSubtitle, encoding: .utf8), "existing subtitle")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
            .filter { $0.hasPrefix(".parakeet-") }.isEmpty)
    }

    func testParakeetServiceMapsLateParentCancellationBeforePublishingOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParakeetLateCancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = DeferredSuccessfulParakeetRunner()
        let service = fixtureParakeetService(runner: runner)
        let generationTask = Task {
            try await service.generateSubtitles(
                inputFile: temporaryDirectory.appendingPathComponent("clip.mov"),
                outputDirectory: temporaryDirectory,
                model: ParakeetModel.allModels[0],
                language: "en",
                operationID: UUID()
            ) { _ in }
        }

        await runner.waitUntilStarted()
        generationTask.cancel()
        runner.release()

        do {
            _ = try await generationTask.value
            XCTFail("Expected cancellation")
        } catch let error as ParakeetServiceError {
            guard case .cancelled = error else { return XCTFail("Expected cancelled, got \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: temporaryDirectory.appendingPathComponent("clip.srt").path
        ))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
            .filter { $0.hasPrefix(".parakeet-") }.isEmpty)
    }

    func testParakeetServicePublishesStagedOutputAndReservesConcurrentDestinations() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParakeetPublishing-\(UUID().uuidString)")
        let firstInputDirectory = temporaryDirectory.appendingPathComponent("video")
        let secondInputDirectory = temporaryDirectory.appendingPathComponent("audio")
        let outputDirectory = temporaryDirectory.appendingPathComponent("output")
        for directory in [firstInputDirectory, secondInputDirectory, outputDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = CoordinatedParakeetOutputRunner(expectedCount: 2)
        let service = fixtureParakeetService(runner: runner)
        let firstTask = Task {
            try await service.generateSubtitles(
                inputFile: firstInputDirectory.appendingPathComponent("clip.mov"),
                outputDirectory: outputDirectory,
                model: ParakeetModel.allModels[0],
                language: "en",
                operationID: UUID()
            ) { _ in }
        }
        let secondTask = Task {
            try await service.generateSubtitles(
                inputFile: secondInputDirectory.appendingPathComponent("clip.wav"),
                outputDirectory: outputDirectory,
                model: ParakeetModel.allModels[0],
                language: "en",
                operationID: UUID()
            ) { _ in }
        }

        let outputs = try await [firstTask.value, secondTask.value]
        XCTAssertEqual(Set(outputs.map(\.lastPathComponent)), Set(["clip.srt", "clip.parakeet.srt"]))
        XCTAssertNotEqual(
            try String(contentsOf: outputs[0], encoding: .utf8),
            try String(contentsOf: outputs[1], encoding: .utf8)
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)
            .filter { $0.hasPrefix(".parakeet-") }.isEmpty)
    }

    func testQueueSubtitleCancellationFindsAndInvalidatesGroupedItem() {
        let operationID = UUID()
        var item = VideoItem(
            url: URL(fileURLWithPath: "/fixture/grouped.mov"),
            name: "grouped.mov",
            size: 0,
            duration: "00:01:00",
            status: .done,
            progress: 1,
            eta: nil,
            outputURL: nil
        )
        item.subtitleMethod = .whisper
        item.subtitleStatus = .generating(progress: 0.5)
        item.subtitleOperationID = operationID
        let itemID = item.id
        var droppedFiles: [VideoItem] = []
        var encodingGroups = [EncodingGroup(name: "Group", items: [item])]

        let target = QueueSubtitleCancellationState.takeTarget(
            itemID: itemID,
            droppedFiles: &droppedFiles,
            encodingGroups: &encodingGroups
        )

        XCTAssertEqual(target, QueueSubtitleCancellationTarget(
            method: .whisper,
            operationID: operationID
        ))
        XCTAssertEqual(encodingGroups[0].items[0].subtitleStatus, .notQueued)
        XCTAssertNil(encodingGroups[0].items[0].subtitleOperationID)
    }

    @MainActor
    func testSubtitleEmbeddingCommitRejectsSupersededAttempt() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubtitleEmbeddingStale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let videoURL = temporaryDirectory.appendingPathComponent("video.mov")
        let stagedURL = temporaryDirectory.appendingPathComponent("staged.mov")
        try Data("original".utf8).write(to: videoURL)
        try Data("stale embed".utf8).write(to: stagedURL)
        var markedComplete = false

        let published = try SubtitleEmbeddingCommit.publishIfCurrent(
            temporaryURL: stagedURL,
            destinationURL: videoURL,
            isCurrent: { false },
            didPublish: { markedComplete = true }
        )

        XCTAssertFalse(published)
        XCTAssertFalse(markedComplete)
        XCTAssertEqual(try String(contentsOf: videoURL, encoding: .utf8), "original")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
    }

    @MainActor
    func testSubtitleEmbeddingCommitPreservesVideoWhenReplacementFails() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubtitleEmbeddingFailure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let videoURL = temporaryDirectory.appendingPathComponent("video.mov")
        let missingStagedURL = temporaryDirectory.appendingPathComponent("missing.mov")
        try Data("original".utf8).write(to: videoURL)
        var markedComplete = false

        XCTAssertThrowsError(try SubtitleEmbeddingCommit.publishIfCurrent(
            temporaryURL: missingStagedURL,
            destinationURL: videoURL,
            isCurrent: { true },
            didPublish: { markedComplete = true }
        ))
        XCTAssertFalse(markedComplete)
        XCTAssertEqual(try String(contentsOf: videoURL, encoding: .utf8), "original")
    }

    func testSubtitleEmbeddingSubprocessUsesBoundedRedactedRequestAndValidatesOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubtitleEmbeddingPolicy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let videoURL = temporaryDirectory.appendingPathComponent("private video.mov")
        let srtURL = temporaryDirectory.appendingPathComponent("private video.eng.srt")
        let stagedURL = temporaryDirectory.appendingPathComponent("private staged.mov")
        try Data("original".utf8).write(to: videoURL)
        try Data("subtitle".utf8).write(to: srtURL)
        let runner = RecordingSubprocessRunner { request, _ in
            try Data("embedded".utf8).write(to: stagedURL)
            return successfulSubprocessResult()
        }

        try await SubtitleEmbeddingSubprocess(subprocessRunner: runner).run(
            ffmpegPath: "/private/tools/ffmpeg",
            srtURL: srtURL,
            videoURL: videoURL,
            stagedURL: stagedURL,
            subtitleCodec: "mov_text",
            languageCode: "eng"
        )

        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.executableURL.path, "/private/tools/ffmpeg")
        XCTAssertEqual(request.arguments, [
            "-y", "-i", videoURL.path, "-i", srtURL.path,
            "-map", "0", "-map", "1:s", "-c", "copy",
            "-c:s", "mov_text", "-metadata:s:s:0", "language=eng",
            stagedURL.path,
        ])
        XCTAssertEqual(request.timeout, .seconds(12 * 60 * 60))
        XCTAssertEqual(request.standardOutputCaptureLimit, 0)
        XCTAssertEqual(request.standardErrorCaptureLimit, 256 * 1024)
        XCTAssertFalse(request.redactedCommandDescription.contains("private video"))
        XCTAssertFalse(request.redactedCommandDescription.contains("/private/tools/ffmpeg"))
        XCTAssertEqual(try String(contentsOf: stagedURL, encoding: .utf8), "embedded")
    }

    func testSubtitleEmbeddingSubprocessCleansPartialOutputAndRedactsFailure() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SubtitleEmbeddingFailure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let videoURL = temporaryDirectory.appendingPathComponent("private video.mov")
        let srtURL = temporaryDirectory.appendingPathComponent("private subtitle.srt")
        let stagedURL = temporaryDirectory.appendingPathComponent("private staged.mov")
        try Data("original".utf8).write(to: videoURL)
        try Data("subtitle".utf8).write(to: srtURL)
        let runner = RecordingSubprocessRunner { _, _ in
            try Data("partial".utf8).write(to: stagedURL)
            return successfulSubprocessResult(
                standardError: "failed for \(videoURL.path) and \(srtURL.path)",
                terminationStatus: 9
            )
        }

        do {
            try await SubtitleEmbeddingSubprocess(subprocessRunner: runner).run(
                ffmpegPath: "/private/tools/ffmpeg",
                srtURL: srtURL,
                videoURL: videoURL,
                stagedURL: stagedURL,
                subtitleCodec: "mov_text",
                languageCode: nil
            )
            XCTFail("Expected subtitle embedding to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("exit code 9"))
            XCTAssertFalse(error.localizedDescription.contains(videoURL.path))
            XCTAssertFalse(error.localizedDescription.contains(srtURL.path))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertEqual(try String(contentsOf: videoURL, encoding: .utf8), "original")
    }

    func testAttachedSubtitleEmbeddingPublishesAtomically() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachedSubtitleEmbedding-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let videoURL = temporaryDirectory.appendingPathComponent("video.mkv")
        let srtURL = temporaryDirectory.appendingPathComponent("video.nor.srt")
        try Data("original".utf8).write(to: videoURL)
        try Data("subtitle".utf8).write(to: srtURL)
        let runner = RecordingSubprocessRunner { request, _ in
            try Data("embedded".utf8).write(to: URL(fileURLWithPath: request.arguments.last!))
            return successfulSubprocessResult()
        }
        let manager = ConversionManager(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" }
        )

        await manager.embedSubtitlesForAttachedFile(
            srtURL: srtURL,
            videoURL: videoURL,
            itemID: UUID()
        )

        XCTAssertEqual(try String(contentsOf: videoURL, encoding: .utf8), "embedded")
        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertTrue(request.arguments.contains("srt"))
        XCTAssertTrue(request.arguments.contains("language=nor"))
    }

    func testAttachedSubtitleEmbeddingCancellationStopsRunnerAndPreservesOriginal() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachedSubtitleCancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let videoURL = temporaryDirectory.appendingPathComponent("video.mov")
        let srtURL = temporaryDirectory.appendingPathComponent("video.srt")
        try Data("original".utf8).write(to: videoURL)
        try Data("subtitle".utf8).write(to: srtURL)
        let runner = CountingBlockingSubprocessRunner()
        let manager = ConversionManager(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" }
        )
        let itemID = UUID()
        let embeddingTask = Task {
            await manager.embedSubtitlesForAttachedFile(
                srtURL: srtURL,
                videoURL: videoURL,
                itemID: itemID
            )
        }

        await runner.waitUntilStarted(count: 1)
        await manager.cancelSubtitleEmbedding(itemID: itemID, operationID: nil)
        await embeddingTask.value

        XCTAssertEqual(runner.cancelledCount, 1)
        XCTAssertEqual(try String(contentsOf: videoURL, encoding: .utf8), "original")
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".subtitle-embed-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testSupersededAttachedSubtitleEmbeddingCannotPublishLateSuccess() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttachedSubtitleSupersession-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let videoURL = temporaryDirectory.appendingPathComponent("video.mov")
        let firstSRT = temporaryDirectory.appendingPathComponent("first.srt")
        let secondSRT = temporaryDirectory.appendingPathComponent("second.srt")
        try Data("original".utf8).write(to: videoURL)
        try Data("first".utf8).write(to: firstSRT)
        try Data("second".utf8).write(to: secondSRT)
        let runner = SupersedingSubtitleSubprocessRunner()
        let manager = ConversionManager(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" }
        )
        let itemID = UUID()

        let firstTask = Task {
            await manager.embedSubtitlesForAttachedFile(
                srtURL: firstSRT,
                videoURL: videoURL,
                itemID: itemID
            )
        }
        await runner.waitUntilStarted(count: 1)

        let secondTask = Task {
            await manager.embedSubtitlesForAttachedFile(
                srtURL: secondSRT,
                videoURL: videoURL,
                itemID: itemID
            )
        }
        await runner.waitUntilStarted(count: 2)
        await secondTask.value
        XCTAssertEqual(try String(contentsOf: videoURL, encoding: .utf8), "embedded-2")

        await runner.releaseFirst()
        await firstTask.value

        XCTAssertEqual(try String(contentsOf: videoURL, encoding: .utf8), "embedded-2")
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".subtitle-embed-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testRcloneEnvironmentDropsInheritedRemoteConfiguration() {
        let environment = RcloneService.sanitizedEnvironment(
            base: [
                "PATH": "/usr/bin",
                "RCLONE_CONFIG": "/private/config",
                "RCLONE_CONFIG_UPLOAD_PASS": "inherited-secret",
                "RCLONE_CONFIG_OTHER_TYPE": "s3"
            ],
            overrides: [
                "RCLONE_CONFIG_UPLOAD_TYPE": "sftp",
                "RCLONE_CONFIG_UPLOAD_HOST": "media.example"
            ]
        )

        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["RCLONE_CONFIG"], "/dev/null")
        XCTAssertEqual(environment["RCLONE_CONFIG_UPLOAD_TYPE"], "sftp")
        XCTAssertEqual(environment["RCLONE_CONFIG_UPLOAD_HOST"], "media.example")
        XCTAssertNil(environment["RCLONE_CONFIG_UPLOAD_PASS"])
        XCTAssertNil(environment["RCLONE_CONFIG_OTHER_TYPE"])
    }

    func testRcloneUploadUsesRunnerAndParsesSplitAndFinalProgressLines() async throws {
        let runner = RecordingSubprocessRunner { _, outputHandler in
            outputHandler?(
                SubprocessOutputChunk(
                    stream: .standardError,
                    data: Data("Transferred: 1 MiB / 2 MiB, 50%, 4 MiB/s, ".utf8)
                )
            )
            outputHandler?(
                SubprocessOutputChunk(
                    stream: .standardError,
                    data: Data("ETA 1s\n".utf8)
                )
            )
            outputHandler?(
                SubprocessOutputChunk(
                    stream: .standardOutput,
                    data: Data("Transferred: 2 MiB / 2 MiB, 100%, 5 MiB/s, ETA 0s".utf8)
                )
            )
            return SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .seconds(3)
            )
        }
        let service = RcloneService(
            updateService: StubRcloneUpdateService(path: "/usr/bin/rclone-fixture"),
            subprocessRunner: runner
        )
        let callbacks = RcloneCallbackRecorder()
        let localURL = URL(fileURLWithPath: "/private/tmp/Secret Clip.mov")
        let config = UploadConfig(
            server: "media.example",
            port: 22,
            username: "editor",
            remotePath: "/deliveries",
            backendType: .sftp,
            sftpKeyFilePath: "/private/keys/upload-key"
        )

        let result = try await service.upload(
            localFile: localURL,
            config: config,
            progress: { value, speed in callbacks.record(value: value, speed: speed) }
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.remotePath, "/deliveries/Secret Clip.mov")
        XCTAssertEqual(result.bytesTransferred, 2 * 1024 * 1024)
        XCTAssertEqual(result.duration, 3, accuracy: 0.001)
        XCTAssertTrue(callbacks.values.contains(0.5))
        XCTAssertEqual(callbacks.values.last, 1.0)

        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.executableURL.path, "/usr/bin/rclone-fixture")
        XCTAssertEqual(request.timeout, .seconds(6 * 60 * 60))
        XCTAssertTrue(request.arguments.containsAdjacent("copy", localURL.path))
        XCTAssertEqual(request.environment?["RCLONE_CONFIG_UPLOAD_TYPE"], "sftp")
        XCTAssertEqual(request.environment?["RCLONE_CONFIG_UPLOAD_KEY_FILE"], "/private/keys/upload-key")
        XCTAssertEqual(request.environment?["RCLONE_CONFIG"], "/dev/null")
        XCTAssertFalse(request.redactedCommandDescription.contains(localURL.path))
        XCTAssertFalse(request.redactedCommandDescription.contains("upload:/deliveries"))
        XCTAssertFalse(request.redactedDiagnostic("leaked /private/keys/upload-key").contains("upload-key"))
    }

    func testRcloneUploadRedactsConnectionFailureDetails() async throws {
        let localURL = URL(fileURLWithPath: "/private/tmp/Secret.mov")
        let diagnostic = "Failed: connection refused at sftp://user:password@example.com/private for \(localURL.path)\n"
        let runner = RecordingSubprocessRunner { _, outputHandler in
            outputHandler?(
                SubprocessOutputChunk(stream: .standardError, data: Data(diagnostic.utf8))
            )
            return SubprocessResult(
                terminationStatus: 1,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(diagnostic.utf8),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .seconds(1)
            )
        }
        let service = RcloneService(
            updateService: StubRcloneUpdateService(path: "/usr/bin/rclone-fixture"),
            subprocessRunner: runner
        )
        let config = UploadConfig(
            server: "media.example",
            port: 22,
            username: "editor",
            remotePath: "/deliveries",
            backendType: .sftp,
            sftpKeyFilePath: "/private/keys/upload-key"
        )

        do {
            _ = try await service.upload(localFile: localURL, config: config, progress: { _, _ in })
            XCTFail("Expected connection failure")
        } catch let error as UploadError {
            guard case let .connectionFailed(message) = error else {
                return XCTFail("Expected connectionFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("<url>"))
            XCTAssertTrue(message.contains("<redacted>"))
            XCTAssertFalse(message.contains("example.com"))
            XCTAssertFalse(message.contains("password"))
            XCTAssertFalse(message.contains(localURL.path))
        }
    }

    func testRcloneObscureUsesRunnerStdinAndRedactsPassword() async throws {
        let password = "correct horse battery staple"
        let runner = RecordingSubprocessRunner { _, _ in
            SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data("obscured-value\n".utf8),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(10)
            )
        }
        let service = RcloneService(
            updateService: StubRcloneUpdateService(path: "/usr/bin/rclone-fixture"),
            subprocessRunner: runner
        )

        let obscured = try await service.obscurePassword(password, rclonePath: "/usr/bin/rclone-fixture")

        XCTAssertEqual(obscured, "obscured-value")
        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.arguments, ["obscure", "-"])
        XCTAssertEqual(request.standardInput, Data((password + "\n").utf8))
        XCTAssertEqual(request.timeout, .seconds(5))
        XCTAssertFalse(request.redactedDiagnostic("echoed \(password)").contains(password))
        XCTAssertFalse(request.redactedCommandDescription.contains(password))
    }

    func testRcloneObscureMapsRunnerTimeout() async throws {
        let runner = RecordingSubprocessRunner { request, _ in
            let result = SubprocessResult(
                terminationStatus: SIGTERM,
                termination: .uncaughtSignal,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .seconds(5)
            )
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: result
            )
        }
        let service = RcloneService(
            updateService: StubRcloneUpdateService(path: "/usr/bin/rclone-fixture"),
            subprocessRunner: runner
        )

        do {
            _ = try await service.obscurePassword("secret", rclonePath: "/usr/bin/rclone-fixture")
            XCTFail("Expected timeout")
        } catch let error as UploadError {
            guard case let .uploadFailed(message) = error else {
                return XCTFail("Expected uploadFailed, got \(error)")
            }
            XCTAssertEqual(message, "Failed to obscure password: timed out")
        }
    }

    func testRcloneConnectionTestUsesRunnerDeadlineAndMapsAuthentication() async throws {
        let diagnostic = "530 Login incorrect\n"
        let runner = RecordingSubprocessRunner { _, _ in
            SubprocessResult(
                terminationStatus: 1,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(diagnostic.utf8),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .seconds(1)
            )
        }
        let service = RcloneService(
            updateService: StubRcloneUpdateService(path: "/usr/bin/rclone-fixture"),
            subprocessRunner: runner
        )
        let config = UploadConfig(
            server: "media.example",
            port: 22,
            username: "editor",
            remotePath: "/deliveries",
            backendType: .sftp,
            sftpKeyFilePath: "/private/keys/upload-key"
        )

        do {
            _ = try await service.testConnection(config: config)
            XCTFail("Expected authentication failure")
        } catch let error as UploadError {
            guard case .authenticationFailed = error else {
                return XCTFail("Expected authenticationFailed, got \(error)")
            }
        }

        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.arguments.first, "lsd")
        XCTAssertEqual(request.timeout, .seconds(60))
        XCTAssertEqual(request.standardOutputCaptureLimit, 0)
    }

    func testConcurrentRcloneUploadsCancelOnlyTheirOwnRunnerInvocation() async throws {
        let runner = SelectiveRcloneRunner()
        let service = RcloneService(
            updateService: StubRcloneUpdateService(path: "/usr/bin/rclone-fixture"),
            subprocessRunner: runner
        )
        let config = UploadConfig(
            server: "media.example",
            port: 22,
            username: "editor",
            remotePath: "/deliveries",
            backendType: .sftp,
            sftpKeyFilePath: "/private/keys/upload-key"
        )
        let cancelledURL = URL(fileURLWithPath: "/private/tmp/cancel.mov")
        let completedURL = URL(fileURLWithPath: "/private/tmp/complete.mov")
        let cancelledTask = Task {
            try await service.upload(localFile: cancelledURL, config: config, progress: { _, _ in })
        }
        let completedTask = Task {
            try await service.upload(localFile: completedURL, config: config, progress: { _, _ in })
        }

        await runner.waitUntilStarted(count: 2)
        cancelledTask.cancel()

        let completedResult = try await completedTask.value
        XCTAssertTrue(completedResult.success)
        do {
            _ = try await cancelledTask.value
            XCTFail("Expected the selected upload to be cancelled")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(runner.cancelledPaths, [cancelledURL.path])
    }

    func testYTDLPDownloadUsesRunnerAndParsesSplitProgressAndOutputLines() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YTDLPServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputURL = temporaryDirectory.appendingPathComponent("Great Clip.mp4")
        let runner = RecordingSubprocessRunner { request, outputHandler in
            try Data("fixture".utf8).write(to: outputURL)
            outputHandler?(
                SubprocessOutputChunk(
                    stream: .standardError,
                    data: Data("[download] Destination: Great ".utf8)
                )
            )
            outputHandler?(
                SubprocessOutputChunk(
                    stream: .standardError,
                    data: Data("Clip.mp4\n[download]  42.5% of 10MiB at 2MiB/s\n".utf8)
                )
            )
            let pathData = Data((outputURL.path + "\n").utf8)
            let splitIndex = pathData.index(pathData.startIndex, offsetBy: pathData.count / 2)
            outputHandler?(
                SubprocessOutputChunk(stream: .standardOutput, data: pathData[..<splitIndex])
            )
            outputHandler?(
                SubprocessOutputChunk(stream: .standardOutput, data: pathData[splitIndex...])
            )
            return SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .zero
            )
        }
        let callbacks = YTDLPCallbackRecorder()
        let service = YTDLPService(
            updateService: StubYTDLPUpdateService(path: "/bin/sh"),
            subprocessRunner: runner
        )

        let result = try await service.download(
            url: "https://example.com/watch?v=private",
            outputFolder: temporaryDirectory,
            progress: { value, _, _ in callbacks.recordProgress(value) },
            titleUpdate: { callbacks.recordTitle($0) }
        )

        XCTAssertEqual(result.outputURL, outputURL)
        XCTAssertEqual(result.title, "Great Clip")
        XCTAssertEqual(callbacks.titles, ["Great Clip"])
        XCTAssertEqual(callbacks.progressValues.first ?? 0, 0.425, accuracy: 0.0001)
        XCTAssertEqual(callbacks.progressValues.last, 1.0)

        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.currentDirectoryURL, temporaryDirectory)
        XCTAssertTrue(request.arguments.containsAdjacent("--", "https://example.com/watch?v=private"))
        XCTAssertFalse(request.redactedCommandDescription.contains("example.com"))
    }

    func testYTDLPDownloadControlMapsUserCancellation() async throws {
        let runner = BlockingSubprocessRunner()
        let service = YTDLPService(
            updateService: StubYTDLPUpdateService(path: "/bin/sh"),
            subprocessRunner: runner
        )
        let control = YTDLPDownloadControl()
        let downloadTask = Task {
            try await service.download(
                url: "https://example.com/watch?v=private",
                outputFolder: FileManager.default.temporaryDirectory,
                control: control,
                progress: { _, _, _ in }
            )
        }

        await runner.waitUntilStarted()
        XCTAssertTrue(control.cancel())

        do {
            _ = try await downloadTask.value
            XCTFail("Expected user cancellation")
        } catch let error as YTDLPError {
            guard case .cancelled = error else {
                return XCTFail("Expected cancelled, got \(error)")
            }
        }
    }

    func testYTDLPDownloadRedactsURLFromFailureDiagnostic() async throws {
        let diagnostic = "ERROR: failed while requesting https://example.com/watch?signed=private\n"
        let runner = RecordingSubprocessRunner { _, outputHandler in
            outputHandler?(
                SubprocessOutputChunk(stream: .standardError, data: Data(diagnostic.utf8))
            )
            return SubprocessResult(
                terminationStatus: 1,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(diagnostic.utf8),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .zero
            )
        }
        let service = YTDLPService(
            updateService: StubYTDLPUpdateService(path: "/bin/sh"),
            subprocessRunner: runner
        )

        do {
            _ = try await service.download(
                url: "https://example.com/watch?signed=private",
                outputFolder: FileManager.default.temporaryDirectory,
                progress: { _, _, _ in }
            )
            XCTFail("Expected a download failure")
        } catch let error as YTDLPError {
            guard case let .downloadFailed(message) = error else {
                return XCTFail("Expected downloadFailed, got \(error)")
            }
            XCTAssertEqual(message, "failed while requesting <url>")
            XCTAssertFalse(message.contains("example.com"))
        }
    }

    func testYTDLPDownloadMapsParentTaskCancellation() async throws {
        let runner = BlockingSubprocessRunner()
        let service = YTDLPService(
            updateService: StubYTDLPUpdateService(path: "/bin/sh"),
            subprocessRunner: runner
        )
        let downloadTask = Task {
            try await service.download(
                url: "https://example.com/watch?v=private",
                outputFolder: FileManager.default.temporaryDirectory,
                progress: { _, _, _ in }
            )
        }

        await runner.waitUntilStarted()
        downloadTask.cancel()

        do {
            _ = try await downloadTask.value
            XCTFail("Expected parent-task cancellation")
        } catch let error as YTDLPError {
            guard case .cancelled = error else {
                return XCTFail("Expected cancelled, got \(error)")
            }
        }
    }

    func testYTDLPDownloadControlPreservesLiveStopReason() async throws {
        let runner = BlockingSubprocessRunner()
        let service = YTDLPService(
            updateService: StubYTDLPUpdateService(path: "/bin/sh"),
            subprocessRunner: runner
        )
        let control = YTDLPDownloadControl()
        let downloadTask = Task {
            try await service.download(
                url: "https://example.com/live",
                outputFolder: FileManager.default.temporaryDirectory,
                liveFromStart: true,
                control: control,
                progress: { _, _, _ in }
            )
        }

        await runner.waitUntilStarted()
        XCTAssertTrue(control.stopLiveRecording())

        do {
            _ = try await downloadTask.value
            XCTFail("Expected live recording stop")
        } catch let error as YTDLPError {
            guard case .liveRecordingStopped = error else {
                return XCTFail("Expected liveRecordingStopped, got \(error)")
            }
        }
    }

    func testParsingDurationSupportsVariableFractionalSecondPrecision() throws {
        XCTAssertEqual(
            try XCTUnwrap(ParsingUtils.parseDuration(from: "Duration: 00:00:01.5")),
            1.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(ParsingUtils.parseDuration(from: "Duration: 01:02:03.123456")),
            3_723.123_456,
            accuracy: 0.000_001
        )
    }

    func testParsingTimeProgressSupportsVariableFractionalSecondPrecision() throws {
        let progress = try XCTUnwrap(
            ParsingUtils.parseTimeProgress(
                from: "frame=1 time=00:00:01.5 speed=1.0x",
                totalDuration: 3
            )
        )

        XCTAssertEqual(progress.0, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(progress.1, "00:00:01")
    }

    func testAnamorphicCropReplacesDarDesqueezeWithExplicitSquarePixelNormalization() throws {
        var args = presetVideoArguments()

        FFMPEGCommandBuilder.applyCropToVideoFilter(
            &args,
            cropConfig: centeredSquareCropForAnamorphicHD(),
            sourceWidth: 1440,
            sourceHeight: 1080,
            pixelAspectRatio: 4.0 / 3.0
        )

        let filterChain = try videoFilter(in: args)
        XCTAssertTrue(filterChain.hasPrefix("crop=810:1080:315:0,scale=1080:1080,setsar=1/1"))
        XCTAssertFalse(filterChain.contains("trunc(ih*dar"))
        XCTAssertTrue(filterChain.hasSuffix("scale=w='if(lte(iw,ih),1080,-2)':h='if(lte(iw,ih),-2,1080)'"))
    }

    func testSquarePixelCropReplacesRedundantDarDesqueeze() throws {
        var args = presetVideoArguments()
        let crop = CropConfig(normalizedRect: CropRect(x: 0.25, y: 0, width: 0.5, height: 1))

        FFMPEGCommandBuilder.applyCropToVideoFilter(
            &args,
            cropConfig: crop,
            sourceWidth: 1920,
            sourceHeight: 1080,
            pixelAspectRatio: 1
        )

        let filterChain = try videoFilter(in: args)
        XCTAssertTrue(filterChain.hasPrefix("crop=960:1080:480:0,setsar=1/1"))
        XCTAssertFalse(filterChain.contains("trunc(ih*dar"))
    }

    func testCropPreservesDarDesqueezeWhenPixelAspectRatioIsUnavailable() throws {
        var args = presetVideoArguments()

        FFMPEGCommandBuilder.applyCropToVideoFilter(
            &args,
            cropConfig: centeredSquareCropForAnamorphicHD(),
            sourceWidth: 1440,
            sourceHeight: 1080,
            pixelAspectRatio: nil
        )

        let filterChain = try videoFilter(in: args)
        let cropRange = try XCTUnwrap(filterChain.range(of: "crop=810:1080:315:0"))
        let desqueezeRange = try XCTUnwrap(filterChain.range(of: "scale='trunc(ih*dar"))
        XCTAssertLessThan(cropRange.lowerBound, desqueezeRange.lowerBound)
    }

    func testInactiveCropDoesNotAddVideoFilter() {
        var args = ["-c:v", "libx264"]

        FFMPEGCommandBuilder.applyCropToVideoFilter(
            &args,
            cropConfig: CropConfig(normalizedRect: .fullFrame),
            sourceWidth: 1920,
            sourceHeight: 1080,
            pixelAspectRatio: 1
        )

        XCTAssertEqual(args, ["-c:v", "libx264"])
    }

    func testStreamCopyDoesNotApplyCrop() {
        var args = ["-c:v", "copy"]
        let originalArgs = args

        FFMPEGCommandBuilder.applyCropToVideoFilter(
            &args,
            cropConfig: CropConfig(normalizedRect: CropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)),
            sourceWidth: 1920,
            sourceHeight: 1080,
            pixelAspectRatio: 1
        )

        XCTAssertEqual(args, originalArgs)
    }

    func testOddCropDimensionsAreRoundedToCodecSafeEvenValues() throws {
        var args: [String] = []
        let crop = CropConfig(normalizedRect: CropRect(x: 0.1, y: 0.1, width: 0.501, height: 0.501))

        FFMPEGCommandBuilder.applyCropToVideoFilter(
            &args,
            cropConfig: crop,
            sourceWidth: 1919,
            sourceHeight: 1079,
            pixelAspectRatio: 1.5
        )

        XCTAssertEqual(
            try videoFilter(in: args),
            "crop=960:540:192:108,scale=1440:540,setsar=1/1"
        )
    }

    func testGeneratedAnamorphicFixtureProducesSquarePixelsAndExpectedCrop() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterCropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureURL = temporaryDirectory.appendingPathComponent("anamorphic-fixture.nut")
        let outputURL = temporaryDirectory.appendingPathComponent("cropped.rgb")

        // Red and blue guard bands surround the green crop target. The stored frame is
        // 1440x1080 SAR 4:3, so the centered 810x1080 crop is a 1:1 display region.
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi",
            "-i", "color=c=black:s=1440x1080:r=1,drawbox=x=0:y=0:w=315:h=1080:c=red:t=fill,drawbox=x=315:y=0:w=810:h=1080:c=lime:t=fill,drawbox=x=1125:y=0:w=315:h=1080:c=blue:t=fill,setsar=4/3",
            "-frames:v", "1", "-c:v", "ffv1", fixtureURL.path
        ])

        var args = presetVideoArguments()
        FFMPEGCommandBuilder.applyCropToVideoFilter(
            &args,
            cropConfig: centeredSquareCropForAnamorphicHD(),
            sourceWidth: 1440,
            sourceHeight: 1080,
            pixelAspectRatio: 4.0 / 3.0
        )
        let filterChain = try videoFilter(in: args)

        let conversionLog = try runFFmpeg([
            "-hide_banner", "-loglevel", "info", "-y", "-i", fixtureURL.path,
            "-vf", "\(filterChain),showinfo", "-frames:v", "1",
            "-pix_fmt", "rgb24", "-f", "rawvideo", outputURL.path
        ])

        XCTAssertTrue(conversionLog.contains("sar:1/1 s:1080x1080"), conversionLog)
        XCTAssertTrue(conversionLog.contains("[SAR 1:1 DAR 1:1]"), conversionLog)

        let pixels = try Data(contentsOf: outputURL)
        XCTAssertEqual(pixels.count, 1080 * 1080 * 3)

        let centerPixelOffset = ((540 * 1080) + 540) * 3
        XCTAssertLessThan(pixels[centerPixelOffset], 30)
        XCTAssertGreaterThan(pixels[centerPixelOffset + 1], 140)
        XCTAssertLessThan(pixels[centerPixelOffset + 2], 30)
    }

    func testGeneratedVideoAudioFixtureRunsCoreConverterAndValidatesOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterCoreConversionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureURL = temporaryDirectory.appendingPathComponent("source.mkv")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=24:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le",
            fixtureURL.path
        ])

        let outputBaseURL = temporaryDirectory.appendingPathComponent("converted")
        let result = try await withPresetSettingsAsync([:]) {
            await runConversion(ConversionRequest(
                inputURL: fixtureURL,
                outputURL: outputBaseURL,
                preset: .h264,
                includeDateTag: false,
                expectedDuration: 1
            ))
        }
        XCTAssertTrue(result.success, result.errorReason ?? "Conversion failed without a reason")

        let outputURL = outputBaseURL.appendingPathExtension(ExportPreset.h264.outputExtension(for: fixtureURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertGreaterThan((try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, 0)

        let probedStreams = await FFMPEGProbeService.verifyOutputStreams(for: outputURL)
        let streams = try XCTUnwrap(probedStreams)
        XCTAssertEqual(streams.videoStreamCount, 1)
        XCTAssertEqual(streams.audioStreamCount, 1)

        let info = try await VideoMetadataService.shared.fetchEssentialInfo(for: outputURL)
        XCTAssertEqual(info.width, 64)
        XCTAssertEqual(info.height, 48)
        XCTAssertEqual(info.duration, 1, accuracy: 0.15)
    }

    func testCoreConverterUsesSharedRunnerPolicyAndReassemblesSplitProgress() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FFmpegRunnerPolicy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let progressValues = OSAllocatedUnfairLock<[Double]>(initialState: [])
        let halfProgressReported = expectation(description: "FFmpeg half progress reported")
        let runner = RecordingSubprocessRunner { request, outputHandler in
            outputHandler?(SubprocessOutputChunk(
                stream: .standardError,
                data: Data("frame= 150 fps=30 time=00:00:0".utf8)
            ))
            outputHandler?(SubprocessOutputChunk(
                stream: .standardError,
                data: Data("5.00 speed=1.0x\r".utf8)
            ))
            let outputPath = try XCTUnwrap(request.arguments.last)
            let outputURL = URL(fileURLWithPath: outputPath)
            try Data("encoded fixture".utf8).write(to: outputURL)
            return SubprocessResult(
                terminationStatus: 0,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data(),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(20)
            )
        }
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/fixture/private/ffmpeg" }
        )
        let inputURL = temporaryDirectory.appendingPathComponent("private source.mov")
        let outputBaseURL = temporaryDirectory.appendingPathComponent("private output")
        let result = await runConversion(
            ConversionRequest(
                inputURL: inputURL,
                outputURL: outputBaseURL,
                preset: .h264,
                includeDateTag: false,
                expectedDuration: 10,
                customInputArguments: [
                    "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=30:duration=10"
                ]
            ),
            using: converter,
            progressUpdate: { progress, _ in
                progressValues.withLock { $0.append(progress) }
                if abs(progress - 0.5) < 0.001 {
                    halfProgressReported.fulfill()
                }
            }
        )

        XCTAssertTrue(result.success, result.errorReason ?? "Conversion failed without a reason")
        await fulfillment(of: [halfProgressReported], timeout: 1.0)
        XCTAssertTrue(progressValues.withLock { values in
            values.contains { abs($0 - 0.5) < 0.001 }
        })

        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.executableURL.path, "/fixture/private/ffmpeg")
        XCTAssertEqual(request.timeout, .seconds(7 * 24 * 60 * 60))
        XCTAssertEqual(request.standardOutputCaptureLimit, 0)
        XCTAssertEqual(request.standardErrorCaptureLimit, 512 * 1024)
        XCTAssertFalse(request.redactedCommandDescription.contains(inputURL.path))
        XCTAssertFalse(request.redactedCommandDescription.contains(outputBaseURL.path))
    }

    func testCoreConverterRedactsPrivatePathsFromRunnerFailure() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FFmpegRunnerRedaction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("secret source.mov")
        let outputBaseURL = temporaryDirectory.appendingPathComponent("secret output")
        let runner = RecordingSubprocessRunner { request, _ in
            let outputPath = request.arguments.last ?? outputBaseURL.path
            return SubprocessResult(
                terminationStatus: 7,
                termination: .exited,
                standardOutput: Data(),
                standardError: Data("Error opening \(inputURL.path); could not write \(outputPath)".utf8),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .milliseconds(20)
            )
        }
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/fixture/ffmpeg" }
        )
        let result = await runConversion(
            ConversionRequest(
                inputURL: inputURL,
                outputURL: outputBaseURL,
                preset: .h264,
                includeDateTag: false
            ),
            using: converter
        )

        XCTAssertFalse(result.success)
        let reason = try XCTUnwrap(result.errorReason)
        XCTAssertTrue(reason.contains("<redacted>"), reason)
        XCTAssertFalse(reason.contains(inputURL.path), reason)
        XCTAssertFalse(reason.contains(outputBaseURL.path), reason)
        let outputURL = outputBaseURL.appendingPathExtension("mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testCoreConverterMapsRunnerTimeoutAndCleansReservedOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FFmpegRunnerTimeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = RecordingSubprocessRunner { request, _ in
            let result = SubprocessResult(
                terminationStatus: SIGKILL,
                termination: .uncaughtSignal,
                standardOutput: Data(),
                standardError: Data("timed out".utf8),
                discardedStandardOutputBytes: 0,
                discardedStandardErrorBytes: 0,
                duration: .seconds(7 * 24 * 60 * 60)
            )
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: result
            )
        }
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/fixture/ffmpeg" }
        )
        let outputBaseURL = temporaryDirectory.appendingPathComponent("output")
        let result = await runConversion(
            ConversionRequest(
                inputURL: temporaryDirectory.appendingPathComponent("input.mov"),
                outputURL: outputBaseURL,
                preset: .h264,
                includeDateTag: false
            ),
            using: converter
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorReason, "FFmpeg conversion timed out after 7 days")
        let outputURL = outputBaseURL.appendingPathExtension("mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testAV2SourceDecodeUsesBoundedRedactedPipelineAndReassemblesProgress() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AV2DecodePipelinePolicy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("private source.ivf")
        try makeTestIVFData().write(to: inputURL)
        let outputBaseURL = temporaryDirectory.appendingPathComponent("private output")
        let outputURL = outputBaseURL.appendingPathExtension("mp4")
        defer { FileSafetyUtils.unregisterCreatedFile(outputURL) }
        let ffmpegPath = "/private/tools/ffmpeg"
        let avmdecPath = temporaryDirectory.appendingPathComponent("avmdec").path
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: avmdecPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: avmdecPath)
        let decodedY4M = Data("YUV4MPEG2 W2 H2 F24:1 Ip A1:1 C420\nFRAME\nfixture".utf8)
        let progressValues = OSAllocatedUnfairLock<[Double]>(initialState: [])
        let runner = SequencedRecordingSubprocessRunner { _, request, outputHandler in
            if request.executableURL.path == avmdecPath {
                outputHandler?(SubprocessOutputChunk(stream: .standardOutput, data: decodedY4M))
                return successfulSubprocessResult()
            }

            XCTAssertEqual(request.standardInput, decodedY4M)
            outputHandler?(SubprocessOutputChunk(
                stream: .standardError,
                data: Data("frame= 12 fps=24 time=00:00:0".utf8)
            ))
            outputHandler?(SubprocessOutputChunk(
                stream: .standardError,
                data: Data("0.50 speed=1.0x\r".utf8)
            ))
            try Data("encoded fixture".utf8).write(
                to: URL(fileURLWithPath: try XCTUnwrap(request.arguments.last))
            )
            return successfulSubprocessResult()
        }
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { ffmpegPath },
            avmdecPathProvider: { avmdecPath }
        )

        let result = await runConversion(
            ConversionRequest(
                inputURL: inputURL,
                outputURL: outputBaseURL,
                preset: .h264,
                includeDateTag: false,
                sourceMetadata: videoMetadata(timecode: nil, frameRate: 24, duration: 1),
                expectedDuration: 1,
                videoFrameRate: 24
            ),
            using: converter,
            progressUpdate: { progress, _ in
                progressValues.withLock { $0.append(progress) }
            }
        )

        XCTAssertTrue(result.success, result.errorReason ?? "AV2 source decode failed")
        XCTAssertTrue(progressValues.withLock { values in
            values.contains { abs($0 - 0.5) < 0.001 }
        })
        let requests = runner.requests
        XCTAssertEqual(requests.count, 2)
        let decoderRequest = try XCTUnwrap(requests.first { $0.executableURL.path == avmdecPath })
        XCTAssertEqual(decoderRequest.arguments, [inputURL.path, "-o", "-"])
        XCTAssertEqual(decoderRequest.timeout, FFMPEGConverter.av2PipelineTimeout)
        XCTAssertEqual(decoderRequest.standardOutputCaptureLimit, 0)
        XCTAssertEqual(
            decoderRequest.standardErrorCaptureLimit,
            FFMPEGConverter.av2PipelineDiagnosticCaptureLimit
        )
        XCTAssertFalse(decoderRequest.redactedCommandDescription.contains(inputURL.path))
        XCTAssertFalse(decoderRequest.redactedCommandDescription.contains(avmdecPath))

        let ffmpegRequest = try XCTUnwrap(requests.first { $0.executableURL.path == ffmpegPath })
        XCTAssertEqual(ffmpegRequest.timeout, .seconds(7 * 24 * 60 * 60))
        XCTAssertEqual(ffmpegRequest.standardOutputCaptureLimit, 0)
        XCTAssertEqual(ffmpegRequest.standardErrorCaptureLimit, 512 * 1024)
        XCTAssertTrue(ffmpegRequest.arguments.containsAdjacent("-i", "pipe:0"))
        XCTAssertFalse(ffmpegRequest.redactedCommandDescription.contains(inputURL.path))
        XCTAssertFalse(ffmpegRequest.redactedCommandDescription.contains(outputURL.path))
    }

    func testAV2SourceDecoderFailureWinsAndCleansPartialOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AV2DecodePipelineFailure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("secret source.ivf")
        try makeTestIVFData().write(to: inputURL)
        let outputBaseURL = temporaryDirectory.appendingPathComponent("output")
        let outputURL = outputBaseURL.appendingPathExtension("mp4")
        let ffmpegPath = "/private/tools/ffmpeg"
        let avmdecPath = temporaryDirectory.appendingPathComponent("avmdec").path
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: avmdecPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: avmdecPath)
        let runner = SequencedRecordingSubprocessRunner { _, request, _ in
            if request.executableURL.path == avmdecPath {
                return successfulSubprocessResult(
                    standardError: "Could not decode \(inputURL.path)",
                    terminationStatus: 7
                )
            }
            try Data("partial output".utf8).write(
                to: URL(fileURLWithPath: try XCTUnwrap(request.arguments.last))
            )
            return successfulSubprocessResult()
        }
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { ffmpegPath },
            avmdecPathProvider: { avmdecPath }
        )

        let result = await runConversion(
            ConversionRequest(
                inputURL: inputURL,
                outputURL: outputBaseURL,
                preset: .h264,
                includeDateTag: false,
                sourceMetadata: videoMetadata(timecode: nil, frameRate: 24, duration: 1),
                expectedDuration: 1,
                videoFrameRate: 24
            ),
            using: converter
        )

        XCTAssertFalse(result.success)
        let reason = try XCTUnwrap(result.errorReason)
        XCTAssertTrue(reason.contains("AV2 decoder failed"), reason)
        XCTAssertTrue(reason.contains("<redacted>"), reason)
        XCTAssertFalse(reason.contains(inputURL.path), reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testAV2SourceDecoderLaunchFailureIsRedactedAndCleansPartialOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AV2DecodePipelineLaunchFailure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("secret source.ivf")
        try makeTestIVFData().write(to: inputURL)
        let outputBaseURL = temporaryDirectory.appendingPathComponent("output")
        let outputURL = outputBaseURL.appendingPathExtension("mp4")
        let ffmpegPath = "/private/tools/ffmpeg"
        let avmdecPath = temporaryDirectory.appendingPathComponent("avmdec").path
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: avmdecPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: avmdecPath)
        let runner = SequencedRecordingSubprocessRunner { _, request, _ in
            if request.executableURL.path == avmdecPath {
                throw SubprocessRunnerError.failedToStart(
                    command: request.redactedCommandDescription,
                    underlying: "Could not launch \(avmdecPath) for \(inputURL.path)"
                )
            }
            try Data("partial output".utf8).write(
                to: URL(fileURLWithPath: try XCTUnwrap(request.arguments.last))
            )
            return successfulSubprocessResult()
        }
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { ffmpegPath },
            avmdecPathProvider: { avmdecPath }
        )

        let result = await runConversion(
            ConversionRequest(
                inputURL: inputURL,
                outputURL: outputBaseURL,
                preset: .h264,
                includeDateTag: false,
                sourceMetadata: videoMetadata(timecode: nil, frameRate: 24, duration: 1),
                expectedDuration: 1,
                videoFrameRate: 24
            ),
            using: converter
        )

        XCTAssertFalse(result.success)
        let reason = try XCTUnwrap(result.errorReason)
        XCTAssertTrue(reason.contains("Failed to start AV2 decoder"), reason)
        XCTAssertTrue(reason.contains("<redacted>"), reason)
        XCTAssertFalse(reason.contains(avmdecPath), reason)
        XCTAssertFalse(reason.contains(inputURL.path), reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testAV2SourceDecodeCancellationStopsBothPipelineStages() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AV2DecodePipelineCancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("source.ivf")
        try makeTestIVFData().write(to: inputURL)
        let outputBaseURL = temporaryDirectory.appendingPathComponent("output")
        let outputURL = outputBaseURL.appendingPathExtension("mp4")
        let avmdecPath = temporaryDirectory.appendingPathComponent("avmdec").path
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: avmdecPath))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: avmdecPath)
        let runner = TwoStageBlockingPipelineRunner()
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" },
            avmdecPathProvider: { avmdecPath }
        )
        let request = ConversionRequest(
            inputURL: inputURL,
            outputURL: outputBaseURL,
            preset: .h264,
            includeDateTag: false,
            sourceMetadata: videoMetadata(timecode: nil, frameRate: 24, duration: 1),
            expectedDuration: 1,
            videoFrameRate: 24
        )

        let resultTask = Task { await conversionResult(converter: converter, request: request) }
        await runner.waitUntilBothStagesStarted()
        await converter.cancelConversion()
        let result = await resultTask.value

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorReason, "Conversion cancelled")
        let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < cancellationDeadline {
            if await runner.cancelledStageCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let cancelledProducerCount = await runner.cancelledProducerCount
        let cancelledConsumerCount = await runner.cancelledConsumerCount
        XCTAssertEqual(cancelledProducerCount, 1)
        XCTAssertEqual(cancelledConsumerCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testCoreConverterCancellationCancelsSharedRunner() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FFmpegRunnerCancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = CountingBlockingSubprocessRunner()
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/fixture/ffmpeg" }
        )
        let outputBaseURL = temporaryDirectory.appendingPathComponent("output")
        let request = ConversionRequest(
            inputURL: temporaryDirectory.appendingPathComponent("input.mov"),
            outputURL: outputBaseURL,
            preset: .h264,
            includeDateTag: false
        )
        let resultTask = Task {
            await withCheckedContinuation { continuation in
                Task {
                    await converter.convert(
                        request: request,
                        progressUpdate: { _, _ in },
                        completion: { success, errorReason in
                            continuation.resume(returning: (success, errorReason))
                        }
                    )
                }
            }
        }

        await runner.waitUntilStarted(count: 1)
        await converter.cancelConversion()
        let result = await resultTask.value

        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1, "Conversion cancelled")
        XCTAssertEqual(runner.cancelledCount, 1)
        let outputURL = outputBaseURL.appendingPathExtension("mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testCoreConverterCancellationStopsNativeWaveformAnalysis() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveformAnalysisCancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = CountingBlockingSubprocessRunner()
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/fixture/ffmpeg" }
        )
        let outputBaseURL = temporaryDirectory.appendingPathComponent("output")
        let waveformRequest = WaveformVideoRequest(
            width: 640,
            height: 360,
            backgroundHex: "000000",
            foregroundHex: "FFFFFF",
            normalizeAudio: false,
            style: .linear,
            frameRate: 24,
            renderingEngine: .swift,
            swiftStyle: .capsules,
            bandCount: 16,
            frequencyDistribution: .logarithmic,
            foregroundGradientEnabled: false,
            foregroundGradientEndHex: "FFFFFF",
            backgroundGradientEnabled: false,
            backgroundGradientEndHex: "000000",
            waveformOpacity: 1
        )
        let request = ConversionRequest(
            inputURL: temporaryDirectory.appendingPathComponent("input.wav"),
            outputURL: outputBaseURL,
            preset: .h264,
            includeDateTag: false,
            expectedDuration: 1,
            waveformRequest: waveformRequest
        )
        let resultTask = Task {
            await withCheckedContinuation { continuation in
                Task {
                    await converter.convert(
                        request: request,
                        progressUpdate: { _, _ in },
                        completion: { success, errorReason in
                            continuation.resume(returning: (success, errorReason))
                        }
                    )
                }
            }
        }

        await runner.waitUntilStarted(count: 1)
        await converter.cancelConversion()
        let result = await resultTask.value

        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1, "Conversion cancelled")
        XCTAssertEqual(runner.cancelledCount, 1)
        let outputURL = outputBaseURL.appendingPathExtension("mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testNativeWaveformEncoderUsesBoundedStreamingRunnerPolicy() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveformStreamingRunner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = SequencedRecordingSubprocessRunner { index, request, _ in
            guard let outputPath = request.arguments.last else {
                return successfulSubprocessResult(
                    standardError: "missing output path",
                    terminationStatus: 2
                )
            }
            let outputURL = URL(fileURLWithPath: outputPath)
            if index == 0 {
                try Data(count: MemoryLayout<Float>.size).write(to: outputURL)
            } else {
                try Data("encoded".utf8).write(to: outputURL)
            }
            return successfulSubprocessResult()
        }
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" }
        )
        let outputBaseURL = temporaryDirectory.appendingPathComponent("private output")
        let outputURL = outputBaseURL.appendingPathExtension("mp4")
        defer { FileSafetyUtils.unregisterCreatedFile(outputURL) }
        let waveformRequest = WaveformVideoRequest(
            width: 2,
            height: 2,
            backgroundHex: "000000",
            foregroundHex: "FFFFFF",
            normalizeAudio: false,
            style: .linear,
            frameRate: 1,
            renderingEngine: .swift,
            swiftStyle: .capsules,
            bandCount: 1,
            frequencyDistribution: .linear,
            foregroundGradientEnabled: false,
            foregroundGradientEndHex: "FFFFFF",
            backgroundGradientEnabled: false,
            backgroundGradientEndHex: "000000",
            waveformOpacity: 1
        )
        let inputURL = temporaryDirectory.appendingPathComponent("private input.wav")
        let request = ConversionRequest(
            inputURL: inputURL,
            outputURL: outputBaseURL,
            preset: .h264,
            includeDateTag: false,
            expectedDuration: 1,
            waveformRequest: waveformRequest
        )

        let result = await withCheckedContinuation { continuation in
            Task {
                await converter.convert(
                    request: request,
                    progressUpdate: { _, _ in },
                    completion: { success, errorReason in
                        continuation.resume(returning: (success, errorReason))
                    }
                )
            }
        }

        XCTAssertTrue(result.0, result.1 ?? "Native waveform conversion failed")
        let requests = runner.requests
        XCTAssertEqual(requests.count, 2)
        let encodeRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(encodeRequest.executableURL.path, "/private/tools/ffmpeg")
        XCTAssertEqual(encodeRequest.timeout, FFMPEGConverter.nativeWaveformEncodingTimeout)
        XCTAssertEqual(encodeRequest.standardOutputCaptureLimit, 0)
        XCTAssertEqual(
            encodeRequest.standardErrorCaptureLimit,
            FFMPEGConverter.nativeWaveformDiagnosticCaptureLimit
        )
        XCTAssertEqual(encodeRequest.standardInput?.count, 2 * 2 * 4)
        XCTAssertTrue(encodeRequest.sensitiveValues.contains("/private/tools/ffmpeg"))
        XCTAssertTrue(encodeRequest.sensitiveValues.contains(inputURL.path))
        XCTAssertTrue(encodeRequest.sensitiveValues.contains(outputURL.path))
        XCTAssertFalse(encodeRequest.redactedCommandDescription.contains(inputURL.path))
        XCTAssertFalse(encodeRequest.redactedCommandDescription.contains(outputURL.path))
    }

    func testNativeWaveformEncoderMapsTimeoutAndCleansPartialOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveformStreamingTimeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = SequencedRecordingSubprocessRunner { index, request, _ in
            let outputURL = URL(fileURLWithPath: try XCTUnwrap(request.arguments.last))
            if index == 0 {
                try Data(count: MemoryLayout<Float>.size).write(to: outputURL)
                return successfulSubprocessResult()
            }
            try Data("partial".utf8).write(to: outputURL)
            throw SubprocessRunnerError.timedOut(
                command: "<redacted>",
                result: successfulSubprocessResult(
                    standardError: "stalled at \(outputURL.path)",
                    terminationStatus: SIGKILL
                )
            )
        }
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" }
        )
        let outputBaseURL = temporaryDirectory.appendingPathComponent("private output")
        let outputURL = outputBaseURL.appendingPathExtension("mp4")
        let request = makeNativeWaveformConversionRequest(
            inputURL: temporaryDirectory.appendingPathComponent("private input.wav"),
            outputBaseURL: outputBaseURL
        )

        let result = await conversionResult(converter: converter, request: request)

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorReason, "Native waveform encoding timed out")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testNativeWaveformEncoderCancellationReachesStreamingRunner() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveformStreamingCancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let encodeStarted = AsyncTestGate()
        let cancellationCount = LockedInvocationCounter()
        let runner = SequencedRecordingSubprocessRunner { index, request, _ in
            let outputURL = URL(fileURLWithPath: try XCTUnwrap(request.arguments.last))
            if index == 0 {
                try Data(count: MemoryLayout<Float>.size).write(to: outputURL)
                return successfulSubprocessResult()
            }
            encodeStarted.open()
            return try await withTaskCancellationHandler {
                try await Task.sleep(for: .seconds(30))
                return successfulSubprocessResult()
            } onCancel: {
                _ = cancellationCount.incrementAndIsFirst()
            }
        }
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" }
        )
        let outputBaseURL = temporaryDirectory.appendingPathComponent("output")
        let outputURL = outputBaseURL.appendingPathExtension("mp4")
        let request = makeNativeWaveformConversionRequest(
            inputURL: temporaryDirectory.appendingPathComponent("input.wav"),
            outputBaseURL: outputBaseURL
        )
        let resultTask = Task {
            await conversionResult(converter: converter, request: request)
        }

        await encodeStarted.wait()
        await converter.cancelConversion()
        let result = await resultTask.value

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorReason, "Conversion cancelled")
        XCTAssertEqual(cancellationCount.value, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testCoreConverterSupersededRunCannotPublishLateProgressOrClearRetry() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FFmpegRunnerSupersession-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = SupersedingFFMPEGRunner()
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/fixture/ffmpeg" }
        )
        let firstProgress = OSAllocatedUnfairLock<[Double]>(initialState: [])
        let sharedOutputBaseURL = temporaryDirectory.appendingPathComponent("shared-output")
        let firstRequest = ConversionRequest(
            inputURL: temporaryDirectory.appendingPathComponent("first.mov"),
            outputURL: sharedOutputBaseURL,
            preset: .h264,
            includeDateTag: false,
            expectedDuration: 10
        )
        let firstTask = Task {
            await withCheckedContinuation { continuation in
                Task {
                    await converter.convert(
                        request: firstRequest,
                        progressUpdate: { progress, _ in
                            firstProgress.withLock { $0.append(progress) }
                        },
                        completion: { success, errorReason in
                            continuation.resume(returning: (
                                success: success,
                                errorReason: errorReason
                            ))
                        }
                    )
                }
            }
        }
        await runner.waitUntilFirstStarted()

        let secondResult = await runConversion(
            ConversionRequest(
                inputURL: temporaryDirectory.appendingPathComponent("second.mov"),
                outputURL: sharedOutputBaseURL,
                preset: .h264,
                includeDateTag: false,
                expectedDuration: 10
            ),
            using: converter
        )
        runner.releaseCancelledFirst()
        let firstResult = await firstTask.value
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(firstResult.success)
        XCTAssertEqual(firstResult.errorReason, "Conversion cancelled")
        XCTAssertTrue(secondResult.success, secondResult.errorReason ?? "Retry failed without a reason")
        XCTAssertTrue(firstProgress.withLock(\.isEmpty))
        XCTAssertEqual(runner.cancelledCount, 1)
        let cancelledOutputURL = sharedOutputBaseURL.appendingPathExtension("mp4")
        let retryOutputURL = temporaryDirectory.appendingPathComponent("shared-output_1.mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledOutputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(cancelledOutputURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retryOutputURL.path))
        XCTAssertTrue(FileSafetyUtils.isCreatedByApp(retryOutputURL))
    }

    func testGeneratedMultichannelFixtureDownmixesThroughCoreConverter() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterMultichannelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureURL = temporaryDirectory.appendingPathComponent("surround-source.mkv")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=24:duration=1",
            "-f", "lavfi", "-i",
            "aevalsrc=0.1*sin(2*PI*300*t)|0.1*sin(2*PI*400*t)|0.1*sin(2*PI*500*t)|0.1*sin(2*PI*600*t)|0.1*sin(2*PI*700*t)|0.1*sin(2*PI*800*t):s=48000:d=1:c=5.1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le",
            fixtureURL.path
        ])

        let probedFixtureStreams = await FFMPEGProbeService.fetchAudioStreams(for: fixtureURL)
        let fixtureStreams = try XCTUnwrap(probedFixtureStreams)
        XCTAssertEqual(fixtureStreams.count, 1)
        XCTAssertEqual(fixtureStreams.first?.channels, 6)
        XCTAssertEqual(fixtureStreams.first?.channelLayout, "5.1")

        let surroundTrack = AudioTrackInfo(
            streamIndex: 0,
            channels: 6,
            channelLayout: "5.1",
            codec: "pcm_s16le",
            codecLongName: nil,
            sampleRate: 48_000
        )
        var routing = AudioRoutingConfig(inputTracks: [surroundTrack])
        routing.outputTracks = [OutputTrack(streamIndex: 0, downmixToStereo: true)]

        let outputBaseURL = temporaryDirectory.appendingPathComponent("downmixed")
        let result = try await withPresetSettingsAsync([:]) {
            await runConversion(ConversionRequest(
                inputURL: fixtureURL,
                outputURL: outputBaseURL,
                preset: .h264,
                includeDateTag: false,
                expectedDuration: 1,
                audioRoutingConfig: routing
            ))
        }

        XCTAssertTrue(result.success, result.errorReason ?? "Conversion failed without a reason")
        let outputURL = outputBaseURL.appendingPathExtension(ExportPreset.h264.outputExtension(for: fixtureURL))
        let probedStreams = await FFMPEGProbeService.fetchAudioStreams(for: outputURL)
        let streams = try XCTUnwrap(probedStreams)
        XCTAssertEqual(streams.count, 1)
        XCTAssertEqual(streams.first?.channels, 2)
        XCTAssertEqual(streams.first?.channelLayout?.lowercased(), "stereo")
    }

    func testGeneratedSubtitleFixtureIsPreservedThroughCoreConverter() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterSubtitleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let subtitleURL = temporaryDirectory.appendingPathComponent("fixture.srt")
        try Data("1\n00:00:00,100 --> 00:00:00,800\nFixture subtitle\n".utf8).write(to: subtitleURL)

        let fixtureURL = temporaryDirectory.appendingPathComponent("subtitle-source.mkv")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=24:duration=1",
            "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=1",
            "-f", "srt", "-i", subtitleURL.path,
            "-map", "0:v:0", "-map", "1:a:0", "-map", "2:s:0",
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le", "-c:s", "srt",
            "-metadata:s:s:0", "language=nor",
            fixtureURL.path
        ])

        let outputBaseURL = temporaryDirectory.appendingPathComponent("subtitled")
        let result = try await withPresetSettingsAsync([
            AppConstants.keepSubtitlesKey: true
        ]) {
            await runConversion(ConversionRequest(
                inputURL: fixtureURL,
                outputURL: outputBaseURL,
                preset: .h264,
                includeDateTag: false,
                expectedDuration: 1
            ))
        }

        XCTAssertTrue(result.success, result.errorReason ?? "Conversion failed without a reason")
        let outputURL = outputBaseURL.appendingPathExtension(ExportPreset.h264.outputExtension(for: fixtureURL))
        let inspection = try inspectMedia(at: outputURL)
        XCTAssertTrue(inspection.contains("Subtitle: mov_text"), inspection)

        let extractedSubtitleURL = temporaryDirectory.appendingPathComponent("extracted.srt")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y", "-i", outputURL.path,
            "-map", "0:s:0", "-c:s", "srt", extractedSubtitleURL.path
        ])
        let extractedSubtitle = try String(contentsOf: extractedSubtitleURL, encoding: .utf8)
        XCTAssertTrue(extractedSubtitle.contains("Fixture subtitle"), extractedSubtitle)
    }

    func testCoreConverterPreservesExistingOutputAndChoosesUniqueName() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterExistingOutputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureURL = temporaryDirectory.appendingPathComponent("source.mkv")
        try makeVideoFixture(at: fixtureURL)

        let outputBaseURL = temporaryDirectory.appendingPathComponent("converted")
        let existingOutputURL = outputBaseURL.appendingPathExtension("mp4")
        let sentinel = Data("existing output must remain unchanged".utf8)
        try sentinel.write(to: existingOutputURL)

        let result = try await withPresetSettingsAsync([:]) {
            await runConversion(ConversionRequest(
                inputURL: fixtureURL,
                outputURL: outputBaseURL,
                preset: .h264,
                includeDateTag: false,
                expectedDuration: 1
            ))
        }

        XCTAssertTrue(result.success, result.errorReason ?? "Conversion failed without a reason")
        XCTAssertEqual(try Data(contentsOf: existingOutputURL), sentinel)

        let uniqueOutputURL = temporaryDirectory.appendingPathComponent("converted_1.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: uniqueOutputURL.path))
        let probedStreams = await FFMPEGProbeService.verifyOutputStreams(for: uniqueOutputURL)
        let streams = try XCTUnwrap(probedStreams)
        XCTAssertEqual(streams.videoStreamCount, 1)
    }

    func testCoreConverterNeverOverwritesSourceWhenOutputResolvesToSamePath() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterSourceSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureURL = temporaryDirectory.appendingPathComponent("source.mp4")
        try makeVideoFixture(at: fixtureURL)
        let originalSource = try Data(contentsOf: fixtureURL)

        let result = try await withPresetSettingsAsync([:]) {
            await runConversion(ConversionRequest(
                inputURL: fixtureURL,
                outputURL: fixtureURL.deletingPathExtension(),
                preset: .h264,
                includeDateTag: false,
                expectedDuration: 1
            ))
        }

        XCTAssertTrue(result.success, result.errorReason ?? "Conversion failed without a reason")
        XCTAssertEqual(try Data(contentsOf: fixtureURL), originalSource)

        let safeOutputURL = temporaryDirectory.appendingPathComponent("source_encoded.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: safeOutputURL.path))
        let probedStreams = await FFMPEGProbeService.verifyOutputStreams(for: safeOutputURL)
        let streams = try XCTUnwrap(probedStreams)
        XCTAssertEqual(streams.videoStreamCount, 1)
    }

    func testCoreConverterReportsMalformedInputFailureWithoutOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterMalformedInputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureURL = temporaryDirectory.appendingPathComponent("malformed.mov")
        try Data("this is not media".utf8).write(to: fixtureURL)
        let outputBaseURL = temporaryDirectory.appendingPathComponent("converted")

        let result = try await withPresetSettingsAsync([:]) {
            await runConversion(ConversionRequest(
                inputURL: fixtureURL,
                outputURL: outputBaseURL,
                preset: .h264,
                includeDateTag: false
            ))
        }

        XCTAssertFalse(result.success)
        XCTAssertFalse((result.errorReason ?? "").isEmpty)
        let outputURL = outputBaseURL.appendingPathExtension("mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testCoreConverterReportsMissingSelectedFFmpegBeforeCreatingOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterMissingBinaryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputBaseURL = temporaryDirectory.appendingPathComponent("converted")
        let result = try await withPresetSettingsAsync([
            AppConstants.ffmpegBinarySourceKey: BinarySourceSelection.custom.rawValue,
            AppConstants.customFFmpegPathKey: temporaryDirectory.appendingPathComponent("missing-ffmpeg").path
        ]) {
            await runConversion(ConversionRequest(
                inputURL: temporaryDirectory.appendingPathComponent("source.mov"),
                outputURL: outputBaseURL,
                preset: .h264,
                includeDateTag: false
            ))
        }

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorReason, "FFmpeg binary not found")
        let outputURL = outputBaseURL.appendingPathExtension("mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testCoreConverterUnsupportedAV2GeneratedVideoRevokesOutputRegistration() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterAV2RejectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("source.wav")
        let outputBaseURL = temporaryDirectory.appendingPathComponent("converted")
        let result = try await withPresetSettingsAsync([:]) {
            await runConversion(ConversionRequest(
                inputURL: inputURL,
                outputURL: outputBaseURL,
                preset: .av2,
                includeDateTag: false,
                synthesizedVideoRequest: SynthesizedVideoRequest(
                    width: 64,
                    height: 48,
                    backgroundHex: "000000",
                    frameRate: 24,
                    includeAudio: true
                )
            ))
        }

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorReason, "AV2 export does not yet support generated video from audio-only sources")
        let outputURL = outputBaseURL.appendingPathExtension(ExportPreset.av2.outputExtension(for: inputURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testCoreConverterCancellationStopsRunningFFmpeg() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterCancellationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputBaseURL = temporaryDirectory.appendingPathComponent("cancelled")
        let request = ConversionRequest(
            inputURL: temporaryDirectory.appendingPathComponent("virtual-source.mkv"),
            outputURL: outputBaseURL,
            preset: .h264,
            includeDateTag: false,
            expectedDuration: 30,
            customInputArguments: [
                "-re", "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=30:duration=30"
            ]
        )

        let result = try await withPresetSettingsAsync([:]) {
            await runConversion(request, cancellingAfter: 300_000_000)
        }

        XCTAssertFalse(result.success)
        XCTAssertFalse((result.errorReason ?? "").isEmpty)
        let outputURL = outputBaseURL.appendingPathExtension("mp4")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testCustomCommandTokenizationPreservesExplicitlyEmptyQuotedArguments() {
        XCTAssertEqual(
            ExportPreset.parseCustomCommand(#"-vf "" -metadata title='' -c:v libx264"#),
            ["-vf", "", "-metadata", "title=", "-c:v", "libx264"]
        )
    }

    func testCustomCommandTokenizationPreservesQuotedAndEscapedWhitespace() {
        XCTAssertEqual(
            ExportPreset.parseCustomCommand(
                #"-metadata "title=My Clip" -metadata artist=Jane\ Doe -vf 'scale=1280:-2'"#
            ),
            ["-metadata", "title=My Clip", "-metadata", "artist=Jane Doe", "-vf", "scale=1280:-2"]
        )
    }

    func testDefaultFFmpegPresetContainerAndCodecMatrix() throws {
        try withDefaultPresetSettings {
            let sourceURL = URL(fileURLWithPath: "/tmp/source.mov")
            let expectations: [PresetCommandExpectation] = [
                .init(.videoLoop, extension: "mp4", videoCodec: "libx264", audioCodec: nil, media: .videoOnly),
                .init(.videoLoopWithSound, extension: "mp4", videoCodec: "libx264", audioCodec: "aac", media: .videoAndAudio),
                .init(.animatedStill, extension: "avif", videoCodec: "libsvtav1", audioCodec: nil, media: .videoOnly),
                .init(.h264, extension: "mp4", videoCodec: "libx264", audioCodec: "aac", media: .videoAndAudio),
                .init(.h265, extension: "mp4", videoCodec: "libx265", audioCodec: "aac", media: .videoAndAudio),
                .init(.av1, extension: "mp4", videoCodec: "libsvtav1", audioCodec: "aac", media: .videoAndAudio),
                .init(.tvHEVC, extension: "mov", videoCodec: "hevc_videotoolbox", audioCodec: "pcm_s24le", media: .videoAndAudio),
                .init(.tvAVCIntra, extension: "mxf", videoCodec: "libx264", audioCodec: "pcm_s24le", media: .videoAndAudio),
                .init(.prores, extension: "mov", videoCodec: "prores_videotoolbox", audioCodec: "pcm_s24le", media: .videoAndAudio),
                .init(.proxy, extension: "mov", videoCodec: "hevc_videotoolbox", audioCodec: "pcm_s24le", media: .videoAndAudio),
                .init(.streamCopy, extension: "mov", videoCodec: "copy", audioCodec: "copy", media: .streamCopy),
                .init(.audioOnly, extension: "wav", videoCodec: nil, audioCodec: "pcm_s24le", media: .audioOnly),
                .init(.imageSequence, extension: "png", videoCodec: "png", audioCodec: nil, media: .videoOnly),
                .init(.dcp, extension: "mxf", videoCodec: "libopenjpeg", audioCodec: nil, media: .videoOnly),
                .init(.imfJ2K, extension: "mxf", videoCodec: "libopenjpeg", audioCodec: nil, media: .videoOnly),
                .init(.imfProRes, extension: "mxf", videoCodec: "prores_ks", audioCodec: nil, media: .videoOnly)
            ]

            let ffmpegBuiltIns = ExportPreset.allCases.filter { !$0.isCustom && $0 != .av2 }
            XCTAssertEqual(
                Set(expectations.map(\.preset)),
                Set(ffmpegBuiltIns),
                "Update the default command matrix whenever a built-in FFmpeg preset is added or removed."
            )

            for expectation in expectations {
                let arguments = expectation.preset.ffmpegArguments
                let presetName = expectation.preset.rawValue

                XCTAssertEqual(
                    expectation.preset.outputExtension(for: sourceURL),
                    expectation.outputExtension,
                    presetName
                )
                XCTAssertEqual(videoCodec(in: arguments), expectation.videoCodec, presetName)
                XCTAssertEqual(audioCodec(in: arguments), expectation.audioCodec, presetName)

                switch expectation.media {
                case .videoOnly:
                    XCTAssertTrue(arguments.contains("-an"), presetName)
                    XCTAssertFalse(arguments.contains("-vn"), presetName)
                case .audioOnly:
                    XCTAssertTrue(arguments.contains("-vn"), presetName)
                    XCTAssertFalse(arguments.contains("-an"), presetName)
                case .videoAndAudio, .streamCopy:
                    XCTAssertFalse(arguments.contains("-an"), presetName)
                    XCTAssertFalse(arguments.contains("-vn"), presetName)
                }
            }
        }
    }

    func testStreamCopyExcludesSubtitlesButPreservesAudioAndVideoMappings() throws {
        try withDefaultPresetSettings {
            let arguments = ExportPreset.streamCopy.ffmpegArguments

            XCTAssertTrue(arguments.containsAdjacent("-map", "0"))
            XCTAssertTrue(arguments.containsAdjacent("-map", "-0:s?"))
            XCTAssertFalse(arguments.contains("-0:t?"))
            XCTAssertEqual(videoCodec(in: arguments), "copy")
            XCTAssertEqual(audioCodec(in: arguments), "copy")
        }
    }

    func testCodecPresetsRespectContainerAndOpusCompatibility() throws {
        let presets: [(preset: ExportPreset, containerKey: String, audioKey: String)] = [
            (.h264, AppConstants.h264ContainerKey, AppConstants.h264AudioFormatKey),
            (.h265, AppConstants.h265ContainerKey, AppConstants.h265AudioFormatKey),
            (.av1, AppConstants.av1ContainerKey, AppConstants.av1AudioFormatKey)
        ]
        let containers: [(container: CodecContainer, audioCodec: String, usesFastStart: Bool)] = [
            (.mp4, "aac", true),
            (.mov, "aac", true),
            (.mkv, "libopus", false)
        ]

        for preset in presets {
            for expectation in containers {
                try withPresetSettings([
                    preset.containerKey: expectation.container.rawValue,
                    preset.audioKey: CodecAudioFormat.opus.rawValue
                ]) {
                    let arguments = preset.preset.ffmpegArguments
                    let context = "\(preset.preset.rawValue) / \(expectation.container.rawValue)"

                    XCTAssertEqual(
                        preset.preset.outputExtension(for: nil),
                        expectation.container.fileExtension,
                        context
                    )
                    XCTAssertEqual(audioCodec(in: arguments), expectation.audioCodec, context)
                    XCTAssertEqual(
                        arguments.containsAdjacent("-movflags", "+faststart"),
                        expectation.usesFastStart,
                        context
                    )
                }
            }
        }
    }

    func testAV2UsesDedicatedEncoderRouteInsteadOfFFmpegCodecArguments() throws {
        try withDefaultPresetSettings {
            XCTAssertEqual(ExportPreset.av2.outputExtension(for: nil), "ivf")
            XCTAssertEqual(ExportPreset.av2.ffmpegArguments, ["-hide_banner"])
            XCTAssertNil(videoCodec(in: ExportPreset.av2.ffmpegArguments))
            XCTAssertNil(audioCodec(in: ExportPreset.av2.ffmpegArguments))
        }
    }

    func testMetadataStrategyEitherMapsSourceMetadataOrStripsItDeterministically() throws {
        try withPresetSettings([AppConstants.preserveMetadataPreferenceKey: true]) {
            let arguments = ExportPreset.h264.ffmpegArguments

            XCTAssertTrue(arguments.containsAdjacent("-map_metadata", "0"))
            XCTAssertTrue(arguments.containsAdjacent("-map_chapters", "0"))
            XCTAssertFalse(arguments.containsAdjacent("-fflags", "+bitexact"))
            XCTAssertFalse(arguments.containsAdjacent("-metadata:s:v:0", "encoder="))
            XCTAssertFalse(arguments.containsAdjacent("-metadata:s:a:0", "encoder="))
        }

        try withPresetSettings([AppConstants.preserveMetadataPreferenceKey: false]) {
            let arguments = ExportPreset.h264.ffmpegArguments

            XCTAssertTrue(arguments.containsAdjacent("-map_metadata", "-1"))
            XCTAssertTrue(arguments.containsAdjacent("-map_chapters", "-1"))
            XCTAssertTrue(arguments.containsAdjacent("-fflags", "+bitexact"))
            XCTAssertTrue(arguments.containsAdjacent("-metadata:s:v:0", "encoder="))
            XCTAssertTrue(arguments.containsAdjacent("-metadata:s:a:0", "encoder="))
        }
    }

    func testManualTimecodeReplacesPresetTimecodeMetadata() async {
        var arguments = [
            "-metadata", "title=Example",
            "-metadata", "timecode=01:00:00:00",
            "-c:v", "libx264"
        ]

        await FFMPEGCommandBuilder.applyTimecode(
            &arguments,
            timecodeConfig: TimecodeConfig(mode: .manual("10:20:30:12")),
            sourceMetadata: videoMetadata(timecode: "02:00:00:00", frameRate: 24),
            trimStart: nil
        )

        XCTAssertEqual(arguments.adjacentPairCount("-metadata", "timecode=10:20:30:12"), 1)
        XCTAssertEqual(arguments.adjacentPairCount("-metadata:s:v:0", "timecode=10:20:30:12"), 1)
        XCTAssertFalse(arguments.containsAdjacent("-metadata", "timecode=01:00:00:00"))
        XCTAssertTrue(arguments.containsAdjacent("-metadata", "title=Example"))
    }

    func testManualTimecodeDoesNotRequireSourceMetadata() async {
        var arguments: [String] = []

        await FFMPEGCommandBuilder.applyTimecode(
            &arguments,
            timecodeConfig: TimecodeConfig(mode: .manual("10:20:30:12")),
            sourceMetadata: nil,
            trimStart: nil
        )

        XCTAssertTrue(arguments.containsAdjacent("-metadata", "timecode=10:20:30:12"))
    }

    func testDisabledItemTimecodeClearsMappedMetadataWithoutReloadingGlobalDefault() async throws {
        try await withPresetSettingsAsync([
            AppConstants.defaultTimecodeModeKey: "manual",
            AppConstants.defaultTimecodeValueKey: "09:08:07:06"
        ]) {
            var arguments: [String] = []

            await FFMPEGCommandBuilder.applyConfiguredTimecode(
                &arguments,
                preset: .h264,
                inputURL: URL(fileURLWithPath: "/tmp/missing-source.mov"),
                timecodeConfig: nil,
                trimStart: nil
            )

            XCTAssertTrue(arguments.containsAdjacent("-metadata", "timecode="))
            XCTAssertTrue(arguments.containsAdjacent("-metadata:s:v:0", "timecode="))
            XCTAssertFalse(arguments.contains("timecode=09:08:07:06"))
        }
    }

    func testGeneratedStreamCopyMOVPreservesReplacesAndRemovesTimecodeTracks() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterTimecodeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("source.mov")
        let sourceTimecode = "01:02:03:04"
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=red:s=32x32:r=24:d=1",
            "-c:v", "libx264",
            "-metadata", "timecode=\(sourceTimecode)",
            sourceURL.path
        ])

        try await withPresetSettingsAsync([
            AppConstants.preserveMetadataPreferenceKey: true
        ]) {
            let preservedURL = temporaryDirectory.appendingPathComponent("preserved.mov")
            let preservedCommand = await FFMPEGCommandBuilder.buildCommand(
                inputURL: sourceURL,
                outputFileURL: preservedURL,
                preset: .streamCopy,
                comment: "",
                includeDateTag: false,
                trimStart: nil,
                trimEnd: nil,
                timecodeConfig: TimecodeConfig(mode: .preserveSource),
                sourceMetadata: videoMetadata(timecode: sourceTimecode, frameRate: 24)
            )
            try runFFmpeg(preservedCommand.arguments)

            let preservedInspection = try inspectMedia(at: preservedURL)
            XCTAssertTrue(preservedInspection.contains("tmcd"), preservedInspection)
            XCTAssertTrue(preservedInspection.contains(sourceTimecode), preservedInspection)

            let manualURL = temporaryDirectory.appendingPathComponent("manual.mov")
            let manualTimecode = "10:20:30:12"
            let manualCommand = await FFMPEGCommandBuilder.buildCommand(
                inputURL: sourceURL,
                outputFileURL: manualURL,
                preset: .streamCopy,
                comment: "",
                includeDateTag: false,
                trimStart: nil,
                trimEnd: nil,
                timecodeConfig: TimecodeConfig(mode: .manual(manualTimecode))
            )
            try runFFmpeg(manualCommand.arguments)

            let manualInspection = try inspectMedia(at: manualURL)
            XCTAssertTrue(manualInspection.contains("tmcd"), manualInspection)
            XCTAssertTrue(manualInspection.contains(manualTimecode), manualInspection)
            XCTAssertFalse(manualInspection.contains(sourceTimecode), manualInspection)

            let disabledURL = temporaryDirectory.appendingPathComponent("disabled.mov")
            let disabledCommand = await FFMPEGCommandBuilder.buildCommand(
                inputURL: sourceURL,
                outputFileURL: disabledURL,
                preset: .streamCopy,
                comment: "",
                includeDateTag: false,
                trimStart: nil,
                trimEnd: nil,
                timecodeConfig: nil
            )
            try runFFmpeg(disabledCommand.arguments)

            let disabledInspection = try inspectMedia(at: disabledURL)
            XCTAssertFalse(disabledInspection.contains("tmcd"), disabledInspection)
            XCTAssertFalse(disabledInspection.contains(sourceTimecode), disabledInspection)
        }
    }

    func testPreservedTimecodeOffsetsByTrimAtSourceFrameRate() async {
        var arguments: [String] = []

        await FFMPEGCommandBuilder.applyTimecode(
            &arguments,
            timecodeConfig: TimecodeConfig(mode: .preserveSource),
            sourceMetadata: videoMetadata(timecode: "01:02:03:12", frameRate: 24),
            trimStart: 1.5
        )

        XCTAssertTrue(arguments.containsAdjacent("-metadata", "timecode=01:02:05:00"))
    }

    func testPreservedDropFrameTimecodeSkipsInvalidMinuteLabels() async {
        var arguments: [String] = []

        await FFMPEGCommandBuilder.applyTimecode(
            &arguments,
            timecodeConfig: TimecodeConfig(mode: .preserveSource),
            sourceMetadata: videoMetadata(timecode: "00:00:59;29", frameRate: 30_000.0 / 1_001.0),
            trimStart: 1_001.0 / 30_000.0
        )

        XCTAssertTrue(arguments.containsAdjacent("-metadata", "timecode=00:01:00;02"))
    }

    func testPreservedDropFrameTimecodeSupports5994AndTenMinuteBoundary() async {
        var minuteBoundaryArguments: [String] = []
        await FFMPEGCommandBuilder.applyTimecode(
            &minuteBoundaryArguments,
            timecodeConfig: TimecodeConfig(mode: .preserveSource),
            sourceMetadata: videoMetadata(timecode: "00:00:59;59", frameRate: 60_000.0 / 1_001.0),
            trimStart: 1_001.0 / 60_000.0
        )
        XCTAssertTrue(minuteBoundaryArguments.containsAdjacent("-metadata", "timecode=00:01:00;04"))

        var tenMinuteBoundaryArguments: [String] = []
        await FFMPEGCommandBuilder.applyTimecode(
            &tenMinuteBoundaryArguments,
            timecodeConfig: TimecodeConfig(mode: .preserveSource),
            sourceMetadata: videoMetadata(timecode: "00:09:59;29", frameRate: 30_000.0 / 1_001.0),
            trimStart: 1_001.0 / 30_000.0
        )
        XCTAssertTrue(tenMinuteBoundaryArguments.containsAdjacent("-metadata", "timecode=00:10:00;00"))
    }

    func testTimecodeOffsetAtVeryLowFrameRateReturnsOriginalInsteadOfDividingByZero() async {
        var arguments: [String] = []

        await FFMPEGCommandBuilder.applyTimecode(
            &arguments,
            timecodeConfig: TimecodeConfig(mode: .preserveSource),
            sourceMetadata: videoMetadata(timecode: "00:00:00:00", frameRate: 0.25),
            trimStart: 1
        )

        XCTAssertTrue(arguments.containsAdjacent("-metadata", "timecode=00:00:00:00"))
    }

    func testImageSequenceInputArgumentsIncludeFrameRangeAndOptionalAudio() {
        let directory = URL(fileURLWithPath: "/tmp/frames", isDirectory: true)
        let audioURL = URL(fileURLWithPath: "/tmp/guide.wav")
        let config = ImageSequenceConfig(
            pattern: "shot_%04d.exr",
            directory: directory,
            startNumber: 1001,
            endNumber: 1048,
            frameRate: 24,
            imageFormat: .exr,
            associatedAudioURL: audioURL
        )

        XCTAssertEqual(config.frameCount, 48)
        XCTAssertEqual(config.durationSeconds, 2, accuracy: 0.000_001)
        XCTAssertEqual(config.firstFrameURL.path, "/tmp/frames/shot_1001.exr")
        var percentPrefixConfig = config
        percentPrefixConfig.pattern = "shot%done_%04d.exr"
        percentPrefixConfig.startNumber = 7
        XCTAssertEqual(percentPrefixConfig.firstFrameURL.path, "/tmp/frames/shot%done_0007.exr")
        XCTAssertEqual(
            config.ffmpegInputArguments,
            [
                "-framerate", "24.000",
                "-start_number", "1001",
                "-i", "/tmp/frames/shot_%04d.exr",
                "-i", "/tmp/guide.wav"
            ]
        )
    }

    func testImageSequenceJPEGExportAppliesSelectedEncoderAndQuality() throws {
        try withPresetSettings([
            AppConstants.imageSequenceExportFormatKey: ImageSequenceFormat.jpeg.rawValue,
            AppConstants.imageSequenceExportQualityKey: 7
        ]) {
            let arguments = ExportPreset.imageSequence.ffmpegArguments

            XCTAssertEqual(ExportPreset.imageSequence.outputExtension(for: nil), "jpg")
            XCTAssertEqual(videoCodec(in: arguments), "mjpeg")
            XCTAssertTrue(arguments.containsAdjacent("-q:v", "7"))
            XCTAssertTrue(arguments.contains("-an"))
            XCTAssertFalse(arguments.contains("-map_metadata"))
        }
    }

    func testGeneratedImageSequenceExportRetainsEncoderAndAppliesCrop() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterImageSequenceCropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureURL = temporaryDirectory.appendingPathComponent("source.mov")
        let outputPatternURL = temporaryDirectory.appendingPathComponent("frame_%03d.png")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi",
            "-i", "color=c=red:s=64x32:r=1,drawbox=x=32:y=0:w=32:h=32:c=lime:t=fill",
            "-frames:v", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p", fixtureURL.path
        ])

        try await withPresetSettingsAsync([
            AppConstants.imageSequenceExportFormatKey: ImageSequenceFormat.png.rawValue
        ]) {
            let command = await FFMPEGCommandBuilder.buildCommand(
                inputURL: fixtureURL,
                outputFileURL: outputPatternURL,
                preset: .imageSequence,
                comment: "",
                includeDateTag: false,
                trimStart: nil,
                trimEnd: nil,
                cropConfig: CropConfig(
                    normalizedRect: CropRect(x: 0.5, y: 0, width: 0.5, height: 1)
                )
            )

            XCTAssertTrue(command.arguments.containsAdjacent("-c:v", "png"))
            XCTAssertEqual(try videoFilter(in: command.arguments), "crop=32:32:32:0")
            try runFFmpeg(command.arguments)
        }

        let outputURL = temporaryDirectory.appendingPathComponent("frame_001.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let rawURL = temporaryDirectory.appendingPathComponent("cropped.rgb")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y", "-i", outputURL.path,
            "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", rawURL.path
        ])

        let pixels = try Data(contentsOf: rawURL)
        XCTAssertEqual(pixels.count, 32 * 32 * 3)
        let centerPixelOffset = ((16 * 32) + 16) * 3
        XCTAssertLessThan(pixels[centerPixelOffset], 30)
        XCTAssertGreaterThan(pixels[centerPixelOffset + 1], 140)
        XCTAssertLessThan(pixels[centerPixelOffset + 2], 30)
    }

    func testGeneratedImageSequenceInputUsesFirstFrameGeometryForCrop() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterImageSequenceInputCropTests-\(UUID().uuidString)", isDirectory: true)
        let inputDirectory = temporaryDirectory.appendingPathComponent("input", isDirectory: true)
        let outputDirectory = temporaryDirectory.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputPatternURL = inputDirectory.appendingPathComponent("source_%04d.png")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi",
            "-i", "color=c=red:s=64x32:r=1:d=2,drawbox=x=32:y=0:w=32:h=32:c=lime:t=fill",
            "-frames:v", "2", "-start_number", "1001", inputPatternURL.path
        ])

        let config = ImageSequenceConfig(
            pattern: "source_%04d.png",
            directory: inputDirectory,
            startNumber: 1001,
            endNumber: 1002,
            frameRate: 1,
            imageFormat: .png
        )
        let outputPatternURL = outputDirectory.appendingPathComponent("cropped_%03d.png")

        try await withPresetSettingsAsync([
            AppConstants.imageSequenceExportFormatKey: ImageSequenceFormat.png.rawValue
        ]) {
            let command = await FFMPEGCommandBuilder.buildCommand(
                inputURL: inputDirectory,
                outputFileURL: outputPatternURL,
                preset: .imageSequence,
                comment: "",
                includeDateTag: false,
                trimStart: nil,
                trimEnd: nil,
                cropConfig: CropConfig(
                    normalizedRect: CropRect(x: 0.5, y: 0, width: 0.5, height: 1)
                ),
                visualSourceURL: config.firstFrameURL,
                customInputArguments: config.ffmpegInputArguments,
                additionalOutputArguments: ["-frames:v", "1"]
            )

            XCTAssertEqual(try videoFilter(in: command.arguments), "crop=32:32:32:0")
            try runFFmpeg(command.arguments)
        }

        let outputURL = outputDirectory.appendingPathComponent("cropped_001.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let rawURL = temporaryDirectory.appendingPathComponent("cropped.rgb")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y", "-i", outputURL.path,
            "-frames:v", "1", "-pix_fmt", "rgb24", "-f", "rawvideo", rawURL.path
        ])

        let pixels = try Data(contentsOf: rawURL)
        XCTAssertEqual(pixels.count, 32 * 32 * 3)
        let centerPixelOffset = ((16 * 32) + 16) * 3
        XCTAssertLessThan(pixels[centerPixelOffset], 30)
        XCTAssertGreaterThan(pixels[centerPixelOffset + 1], 140)
        XCTAssertLessThan(pixels[centerPixelOffset + 2], 30)
    }

    func testDCPCommandUsesSelectedCinemaProfileRateAndFitGeometry() throws {
        try withPresetSettings([
            AppConstants.dcpResolutionKey: DCPResolution.fourKFull.rawValue,
            AppConstants.dcpFrameRateKey: DCPFrameRate.fps24.rawValue,
            AppConstants.dcpBitrateKey: DCPBitrate.max.rawValue,
            AppConstants.dcpScalingModeKey: DCPScalingMode.fit.rawValue
        ]) {
            let arguments = ExportPreset.dcp.ffmpegArguments

            XCTAssertTrue(arguments.containsAdjacent("-profile", "cinema4k"))
            XCTAssertTrue(arguments.containsAdjacent("-cinema_mode", "4k_24"))
            XCTAssertTrue(arguments.containsAdjacent("-pix_fmt", "xyz12le"))
            XCTAssertTrue(arguments.containsAdjacent("-b:v", "250M"))
            XCTAssertTrue(arguments.containsAdjacent("-r", "24"))
            XCTAssertTrue(arguments.containsAdjacent(
                "-vf",
                "scale=iw*sar:ih,setsar=1,scale=4096:2160:force_original_aspect_ratio=decrease,pad=4096:2160:-1:-1:color=black"
            ))
        }
    }

    func testPackageAudioExtractionUsesEntireConcatSource() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterConcatAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let firstAudioURL = temporaryDirectory.appendingPathComponent("first.wav")
        let secondAudioURL = temporaryDirectory.appendingPathComponent("second.wav")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.5",
            "-c:a", "pcm_s16le", firstAudioURL.path
        ])
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000:duration=0.5",
            "-c:a", "pcm_s16le", secondAudioURL.path
        ])

        let listURL = temporaryDirectory.appendingPathComponent("inputs.ffconcat")
        let list = "file '\(firstAudioURL.path)'\nfile '\(secondAudioURL.path)'\n"
        try Data(list.utf8).write(to: listURL)

        let result = await FFMPEGConverter.extractAudioAsPCMWAV(
            inputURL: firstAudioURL,
            customInputArguments: ["-f", "concat", "-safe", "0", "-i", listURL.path],
            outputFolder: temporaryDirectory,
            ffmpegPath: ffmpegExecutableURL.path,
            trimStart: nil,
            trimEnd: nil
        )

        let outputURL: URL
        switch result {
        case .extracted(let url):
            outputURL = url
        case .noAudioInSource:
            return XCTFail("Concat source was incorrectly treated as silent")
        case .failed(let reason):
            return XCTFail("Concat audio extraction failed: \(reason)")
        }

        let duration = try XCTUnwrap(ParsingUtils.parseDuration(from: inspectMedia(at: outputURL)))
        XCTAssertEqual(duration, 1.0, accuracy: 0.02)
    }

    func testPackageAudioExtractionUsesImageSequenceCompanionAudio() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterSequenceAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let audioURL = temporaryDirectory.appendingPathComponent("sequence.wav")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000:duration=0.75",
            "-c:a", "pcm_s24le", audioURL.path
        ])

        let config = ImageSequenceConfig(
            pattern: "frame_%04d.png",
            directory: temporaryDirectory,
            startNumber: 1,
            endNumber: 18,
            frameRate: 24,
            imageFormat: .png,
            associatedAudioURL: audioURL
        )
        let result = await FFMPEGConverter.extractAudioAsPCMWAV(
            inputURL: temporaryDirectory,
            customInputArguments: config.ffmpegInputArguments,
            outputFolder: temporaryDirectory,
            ffmpegPath: ffmpegExecutableURL.path,
            trimStart: nil,
            trimEnd: nil
        )

        let outputURL: URL
        switch result {
        case .extracted(let url):
            outputURL = url
        case .noAudioInSource:
            return XCTFail("Image-sequence companion audio was incorrectly treated as missing")
        case .failed(let reason):
            return XCTFail("Image-sequence audio extraction failed: \(reason)")
        }

        let duration = try XCTUnwrap(ParsingUtils.parseDuration(from: inspectMedia(at: outputURL)))
        XCTAssertEqual(duration, 0.75, accuracy: 0.02)
    }

    func testPackageAudioExtractionTreatsEmptyRoutingAsIntentionalSilence() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterSilentPackageAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let audioURL = temporaryDirectory.appendingPathComponent("source.wav")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.1",
            "-c:a", "pcm_s16le", audioURL.path
        ])

        let routing = AudioRoutingConfig(
            inputTracks: [audioTrack(index: 0, channels: 1)],
            outputTracks: []
        )
        let result = await FFMPEGConverter.extractAudioAsPCMWAV(
            inputURL: audioURL,
            outputFolder: temporaryDirectory,
            ffmpegPath: "/path/that/must/not/be/launched",
            trimStart: nil,
            trimEnd: nil,
            audioRoutingConfig: routing
        )

        guard case .noAudioInSource = result else {
            return XCTFail("Removing every routed track should produce a silent package")
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("audio_temp_") },
            []
        )
    }

    func testImageSequenceAudioExtractionUsesBoundedRedactedRunnerAndValidatesOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("private image sequence audio \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("private source.mov")
        let outputURL = temporaryDirectory.appendingPathComponent("frames.wav")
        try Data("older valid sidecar".utf8).write(to: outputURL)
        let privateFFmpegPath = "/private/tools/ffmpeg"
        let runner = RecordingSubprocessRunner { request, _ in
            let stagedURL = URL(fileURLWithPath: try XCTUnwrap(request.arguments.last))
            try Data("pcm fixture".utf8).write(to: stagedURL)
            return successfulSubprocessResult()
        }

        let result = await FFMPEGConverter.extractAudioAsWAV(
            inputURL: inputURL,
            outputFolder: temporaryDirectory,
            baseName: "frames",
            ffmpegPath: privateFFmpegPath,
            trimStart: 1.25,
            trimEnd: 2.5,
            subprocessRunner: runner,
            audioStreamProvider: { _ in
                [FFMPEGProbeService.AudioStreamInfo(
                    index: 1,
                    channels: 2,
                    channelLayout: "stereo",
                    codecName: "aac"
                )]
            }
        )

        guard case .extracted(let producedURL) = result else {
            return XCTFail("Expected the fake runner output to be accepted")
        }
        XCTAssertEqual(producedURL, outputURL)
        XCTAssertEqual(try Data(contentsOf: producedURL), Data("pcm fixture".utf8))

        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.executableURL.path, privateFFmpegPath)
        XCTAssertEqual(request.timeout, FFMPEGConverter.imageSequenceAudioExtractionTimeout)
        XCTAssertEqual(request.standardOutputCaptureLimit, 0)
        XCTAssertEqual(
            request.standardErrorCaptureLimit,
            FFMPEGConverter.imageSequenceAudioDiagnosticCaptureLimit
        )
        XCTAssertTrue(request.arguments.containsAdjacent("-ss", "1.250"))
        XCTAssertTrue(request.arguments.containsAdjacent("-t", "1.250"))
        XCTAssertTrue(request.arguments.containsAdjacent("-c:a", "pcm_s24le"))
        XCTAssertTrue(request.arguments.containsAdjacent("-rf64", "auto"))
        let stagedPath = try XCTUnwrap(request.arguments.last)
        XCTAssertNotEqual(stagedPath, outputURL.path)
        XCTAssertEqual(URL(fileURLWithPath: stagedPath).pathExtension, "wav")
        XCTAssertFalse(request.redactedCommandDescription.contains(privateFFmpegPath))
        XCTAssertFalse(request.redactedCommandDescription.contains(inputURL.path))
        XCTAssertFalse(request.redactedCommandDescription.contains(outputURL.path))
    }

    func testImageSequenceAudioExtractionRedactsFailureAndRemovesPartialOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed image sequence audio \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("private source.mov")
        let outputURL = temporaryDirectory.appendingPathComponent("frames.wav")
        try Data("older valid sidecar".utf8).write(to: outputURL)
        let runner = RecordingSubprocessRunner { request, _ in
            let stagedURL = URL(fileURLWithPath: try XCTUnwrap(request.arguments.last))
            try Data("partial".utf8).write(to: stagedURL)
            return successfulSubprocessResult(
                standardError: "cannot read \(inputURL.path) or write \(stagedURL.path)",
                terminationStatus: 7
            )
        }

        let result = await FFMPEGConverter.extractAudioAsWAV(
            inputURL: inputURL,
            outputFolder: temporaryDirectory,
            baseName: "frames",
            ffmpegPath: "/private/tools/ffmpeg",
            trimStart: nil,
            trimEnd: nil,
            subprocessRunner: runner,
            audioStreamProvider: { _ in
                [FFMPEGProbeService.AudioStreamInfo(index: 1, channels: 2, channelLayout: "stereo", codecName: "aac")]
            }
        )

        guard case .failed(let reason) = result else {
            return XCTFail("Expected nonzero FFmpeg exit to fail")
        }
        XCTAssertTrue(reason.contains("status 7"))
        XCTAssertTrue(reason.contains("<redacted>"))
        XCTAssertFalse(reason.contains(inputURL.path))
        XCTAssertFalse(reason.contains(outputURL.path))
        XCTAssertEqual(try Data(contentsOf: outputURL), Data("older valid sidecar".utf8))
    }

    func testImageSequenceAudioExtractionMapsTimeoutAndInvalidOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("image sequence audio failures \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("source.mov")
        let outputURL = temporaryDirectory.appendingPathComponent("frames.wav")
        let hasAudio: @Sendable (URL) async -> [FFMPEGProbeService.AudioStreamInfo]? = { _ in
            [FFMPEGProbeService.AudioStreamInfo(index: 1, channels: 2, channelLayout: "stereo", codecName: "aac")]
        }
        let timeoutRunner = RecordingSubprocessRunner { request, _ in
            let stagedURL = URL(fileURLWithPath: try XCTUnwrap(request.arguments.last))
            try Data("partial".utf8).write(to: stagedURL)
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: successfulSubprocessResult(
                    standardError: "stalled at \(stagedURL.path)",
                    terminationStatus: SIGKILL
                )
            )
        }
        let timeoutResult = await FFMPEGConverter.extractAudioAsWAV(
            inputURL: inputURL,
            outputFolder: temporaryDirectory,
            baseName: "frames",
            ffmpegPath: "/private/tools/ffmpeg",
            trimStart: nil,
            trimEnd: nil,
            subprocessRunner: timeoutRunner,
            audioStreamProvider: hasAudio
        )
        guard case .failed(let timeoutReason) = timeoutResult else {
            return XCTFail("Expected timeout to fail")
        }
        XCTAssertTrue(timeoutReason.contains("timed out after 12 hours"))
        XCTAssertTrue(timeoutReason.contains("<redacted>"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))

        let missingOutputResult = await FFMPEGConverter.extractAudioAsWAV(
            inputURL: inputURL,
            outputFolder: temporaryDirectory,
            baseName: "frames",
            ffmpegPath: "/private/tools/ffmpeg",
            trimStart: nil,
            trimEnd: nil,
            subprocessRunner: RecordingSubprocessRunner { _, _ in successfulSubprocessResult() },
            audioStreamProvider: hasAudio
        )
        guard case .failed(let missingReason) = missingOutputResult else {
            return XCTFail("Expected missing output to fail validation")
        }
        XCTAssertEqual(missingReason, "Output file was not created")

        let emptyOutputResult = await FFMPEGConverter.extractAudioAsWAV(
            inputURL: inputURL,
            outputFolder: temporaryDirectory,
            baseName: "frames",
            ffmpegPath: "/private/tools/ffmpeg",
            trimStart: nil,
            trimEnd: nil,
            subprocessRunner: RecordingSubprocessRunner { request, _ in
                let stagedURL = URL(fileURLWithPath: try XCTUnwrap(request.arguments.last))
                try Data().write(to: stagedURL)
                return successfulSubprocessResult()
            },
            audioStreamProvider: hasAudio
        )
        guard case .failed(let emptyReason) = emptyOutputResult else {
            return XCTFail("Expected empty output to fail validation")
        }
        XCTAssertEqual(emptyReason, "Output file is empty (0 bytes)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testImageSequenceAudioExtractionCancellationAndNoAudioSkipRunner() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancelled image sequence audio \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("source.mov")
        let outputURL = temporaryDirectory.appendingPathComponent("frames.wav")
        try Data("partial".utf8).write(to: outputURL)
        let runner = CountingBlockingSubprocessRunner()
        let task = Task {
            await FFMPEGConverter.extractAudioAsWAV(
                inputURL: inputURL,
                outputFolder: temporaryDirectory,
                baseName: "frames",
                ffmpegPath: "/private/tools/ffmpeg",
                trimStart: nil,
                trimEnd: nil,
                subprocessRunner: runner,
                audioStreamProvider: { _ in
                    [FFMPEGProbeService.AudioStreamInfo(index: 1, channels: 2, channelLayout: "stereo", codecName: "aac")]
                }
            )
        }

        await runner.waitUntilStarted(count: 1)
        task.cancel()
        guard case .cancelled = await task.value else {
            return XCTFail("Expected image-sequence audio cancellation")
        }
        XCTAssertEqual(runner.cancelledCount, 1)
        XCTAssertEqual(try Data(contentsOf: outputURL), Data("partial".utf8))

        let lateRunner = DeferredSuccessfulFileRunner(outputData: Data("late replacement".utf8))
        let lateTask = Task {
            await FFMPEGConverter.extractAudioAsWAV(
                inputURL: inputURL,
                outputFolder: temporaryDirectory,
                baseName: "frames",
                ffmpegPath: "/private/tools/ffmpeg",
                trimStart: nil,
                trimEnd: nil,
                subprocessRunner: lateRunner,
                audioStreamProvider: { _ in
                    [FFMPEGProbeService.AudioStreamInfo(index: 1, channels: 2, channelLayout: "stereo", codecName: "aac")]
                }
            )
        }
        await lateRunner.waitUntilStarted()
        lateTask.cancel()
        lateRunner.release()
        guard case .cancelled = await lateTask.value else {
            return XCTFail("A late non-cooperative success must not publish after cancellation")
        }
        XCTAssertEqual(try Data(contentsOf: outputURL), Data("partial".utf8))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil)
                .contains { $0.lastPathComponent.hasPrefix(".frames-") }
        )

        let skipRunner = RecordingSubprocessRunner { _, _ in
            XCTFail("No-audio input must not launch FFmpeg")
            return successfulSubprocessResult()
        }
        let noAudioResult = await FFMPEGConverter.extractAudioAsWAV(
            inputURL: inputURL,
            outputFolder: temporaryDirectory,
            baseName: "frames",
            ffmpegPath: "/private/tools/ffmpeg",
            trimStart: nil,
            trimEnd: nil,
            subprocessRunner: skipRunner,
            audioStreamProvider: { _ in [] }
        )
        guard case .noAudioInSource = noAudioResult else {
            return XCTFail("Expected an audio-free source to skip extraction")
        }
        XCTAssertNil(skipRunner.lastRequest)
    }

    func testGeneratedImageSequenceAudioExtractionPublishesWAV() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("generated image sequence audio \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("source.mkv")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=blue:s=64x32:r=24:d=0.5",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=0.5",
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "ffv1", "-c:a", "pcm_s16le", "-shortest", inputURL.path,
        ])

        let result = await FFMPEGConverter.extractAudioAsWAV(
            inputURL: inputURL,
            outputFolder: temporaryDirectory,
            baseName: "frames",
            ffmpegPath: ffmpegExecutableURL.path,
            trimStart: 0.1,
            trimEnd: 0.4
        )

        guard case .extracted(let outputURL) = result else {
            return XCTFail("Expected generated source audio to be extracted")
        }
        XCTAssertEqual(outputURL, temporaryDirectory.appendingPathComponent("frames.wav"))
        let duration = try XCTUnwrap(ParsingUtils.parseDuration(from: inspectMedia(at: outputURL)))
        XCTAssertEqual(duration, 0.3, accuracy: 0.02)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil)
                .contains { $0.lastPathComponent.hasPrefix(".frames-") }
        )
    }

    func testAVCIntraAudioPreprocessingUsesBoundedRedactedRunnerAndValidatesOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("private AVC-Intra preprocessing \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("private source.wav")
        let outputURL = temporaryDirectory.appendingPathComponent("private channels.mka")
        let executablePath = "/private/tools/ffmpeg"
        let arguments = ["-y", "-nostdin", "-i", inputURL.path, "-c:a", "pcm_s24le", outputURL.path]
        let runner = RecordingSubprocessRunner { _, _ in
            try Data("preprocessed audio".utf8).write(to: outputURL)
            return successfulSubprocessResult()
        }

        let result = await FFMPEGConverter.runAVCIntraAudioPreprocessing(
            executablePath: executablePath,
            arguments: arguments,
            outputURL: outputURL,
            subprocessRunner: runner
        )

        guard case .success(let producedURL) = result else {
            return XCTFail("Expected fake preprocessing output to be accepted")
        }
        XCTAssertEqual(producedURL, outputURL)
        XCTAssertEqual(try Data(contentsOf: producedURL), Data("preprocessed audio".utf8))

        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.executableURL.path, executablePath)
        XCTAssertEqual(request.arguments, arguments)
        XCTAssertEqual(request.timeout, FFMPEGConverter.avcIntraAudioPreprocessingTimeout)
        XCTAssertEqual(request.standardOutputCaptureLimit, 0)
        XCTAssertEqual(
            request.standardErrorCaptureLimit,
            FFMPEGConverter.avcIntraAudioPreprocessingDiagnosticCaptureLimit
        )
        XCTAssertFalse(request.redactedCommandDescription.contains(executablePath))
        XCTAssertFalse(request.redactedCommandDescription.contains(inputURL.path))
        XCTAssertFalse(request.redactedCommandDescription.contains(outputURL.path))
    }

    func testAVCIntraAudioPreprocessingRedactsFailureAndRemovesPartialOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed AVC-Intra preprocessing \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("private source.wav")
        let outputURL = temporaryDirectory.appendingPathComponent("partial.mka")
        let runner = RecordingSubprocessRunner { _, _ in
            try Data("partial".utf8).write(to: outputURL)
            return successfulSubprocessResult(
                standardError: "cannot read \(inputURL.path) or write \(outputURL.path)",
                terminationStatus: 7
            )
        }

        let result = await FFMPEGConverter.runAVCIntraAudioPreprocessing(
            executablePath: "/private/tools/ffmpeg",
            arguments: ["-i", inputURL.path, outputURL.path],
            outputURL: outputURL,
            subprocessRunner: runner
        )

        guard case .failed(let reason) = result else {
            return XCTFail("Expected nonzero FFmpeg exit to fail")
        }
        XCTAssertTrue(reason.contains("status 7"))
        XCTAssertTrue(reason.contains("<redacted>"))
        XCTAssertFalse(reason.contains(inputURL.path))
        XCTAssertFalse(reason.contains(outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testAVCIntraAudioPreprocessingMapsTimeoutAndInvalidOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AVC-Intra preprocessing failures \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputURL = temporaryDirectory.appendingPathComponent("channels.mka")
        let timeoutRunner = RecordingSubprocessRunner { request, _ in
            try Data("partial".utf8).write(to: outputURL)
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: successfulSubprocessResult(
                    standardError: "stalled at \(outputURL.path)",
                    terminationStatus: SIGKILL
                )
            )
        }
        let timeoutResult = await FFMPEGConverter.runAVCIntraAudioPreprocessing(
            executablePath: "/private/tools/ffmpeg",
            arguments: [outputURL.path],
            outputURL: outputURL,
            subprocessRunner: timeoutRunner
        )
        guard case .failed(let timeoutReason) = timeoutResult else {
            return XCTFail("Expected timeout to fail")
        }
        XCTAssertTrue(timeoutReason.contains("timed out after 12 hours"))
        XCTAssertTrue(timeoutReason.contains("<redacted>"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))

        let missingOutputResult = await FFMPEGConverter.runAVCIntraAudioPreprocessing(
            executablePath: "/private/tools/ffmpeg",
            arguments: [outputURL.path],
            outputURL: outputURL,
            subprocessRunner: RecordingSubprocessRunner { _, _ in successfulSubprocessResult() }
        )
        guard case .failed(let missingReason) = missingOutputResult else {
            return XCTFail("Expected missing output to fail validation")
        }
        XCTAssertEqual(missingReason, "Output file was not created")

        try Data().write(to: outputURL)
        let emptyOutputResult = await FFMPEGConverter.runAVCIntraAudioPreprocessing(
            executablePath: "/private/tools/ffmpeg",
            arguments: [outputURL.path],
            outputURL: outputURL,
            subprocessRunner: RecordingSubprocessRunner { _, _ in successfulSubprocessResult() }
        )
        guard case .failed(let emptyReason) = emptyOutputResult else {
            return XCTFail("Expected empty output to fail validation")
        }
        XCTAssertEqual(emptyReason, "Output file is empty (0 bytes)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))

        let launchFailureResult = await FFMPEGConverter.runAVCIntraAudioPreprocessing(
            executablePath: "/private/tools/ffmpeg",
            arguments: [outputURL.path],
            outputURL: outputURL,
            subprocessRunner: RecordingSubprocessRunner { request, _ in
                throw SubprocessRunnerError.failedToStart(
                    command: request.redactedCommandDescription,
                    underlying: "cannot launch for \(outputURL.path)"
                )
            }
        )
        guard case .failed(let launchReason) = launchFailureResult else {
            return XCTFail("Expected launch failure to fail preprocessing")
        }
        XCTAssertTrue(launchReason.contains("Failed to start"))
        XCTAssertTrue(launchReason.contains("<redacted>"))
        XCTAssertFalse(launchReason.contains(outputURL.path))
    }

    func testAVCIntraAudioPreprocessingCancellationCancelsRunnerAndRemovesPartialOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancelled AVC-Intra preprocessing \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputURL = temporaryDirectory.appendingPathComponent("partial.mka")
        try Data("partial".utf8).write(to: outputURL)
        let runner = CountingBlockingSubprocessRunner()
        let task = Task {
            await FFMPEGConverter.runAVCIntraAudioPreprocessing(
                executablePath: "/private/tools/ffmpeg",
                arguments: [outputURL.path],
                outputURL: outputURL,
                subprocessRunner: runner
            )
        }

        await runner.waitUntilStarted(count: 1)
        task.cancel()
        guard case .cancelled = await task.value else {
            return XCTFail("Expected preprocessing cancellation")
        }
        XCTAssertEqual(runner.cancelledCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testPackageAudioExtractionUsesBoundedRunnerAndValidatesOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("private package audio \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("private source.wav")
        let privateFFmpegPath = "/private/tools/ffmpeg"
        let runner = RecordingSubprocessRunner { request, _ in
            let outputURL = URL(fileURLWithPath: try XCTUnwrap(request.arguments.last))
            try Data("pcm fixture".utf8).write(to: outputURL)
            return successfulSubprocessResult()
        }

        let result = await FFMPEGConverter.extractAudioAsPCMWAV(
            inputURL: inputURL,
            outputFolder: temporaryDirectory,
            ffmpegPath: privateFFmpegPath,
            trimStart: 1.25,
            trimEnd: 2.5,
            subprocessRunner: runner
        )

        guard case .extracted(let outputURL) = result else {
            return XCTFail("Expected the fake runner output to be accepted")
        }
        XCTAssertEqual(try Data(contentsOf: outputURL), Data("pcm fixture".utf8))

        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.executableURL.path, privateFFmpegPath)
        XCTAssertEqual(request.timeout, FFMPEGConverter.packageAudioExtractionTimeout)
        XCTAssertEqual(request.standardOutputCaptureLimit, 0)
        XCTAssertEqual(
            request.standardErrorCaptureLimit,
            FFMPEGConverter.packageAudioDiagnosticCaptureLimit
        )
        XCTAssertTrue(request.arguments.containsAdjacent("-ss", "1.250"))
        XCTAssertTrue(request.arguments.containsAdjacent("-t", "1.250"))
        XCTAssertTrue(request.arguments.containsAdjacent("-map", "0:a:0"))
        XCTAssertTrue(request.arguments.containsAdjacent("-c:a", "pcm_s24le"))
        XCTAssertTrue(request.arguments.containsAdjacent("-ar", "48000"))
        XCTAssertFalse(request.redactedCommandDescription.contains(privateFFmpegPath))
        XCTAssertFalse(request.redactedCommandDescription.contains(inputURL.path))
        XCTAssertFalse(request.redactedCommandDescription.contains(outputURL.path))
    }

    func testPackageAudioExtractionRedactsFailureAndRemovesPartialOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("private failed package audio \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("private source.wav")
        let runner = RecordingSubprocessRunner { request, _ in
            let outputURL = URL(fileURLWithPath: try XCTUnwrap(request.arguments.last))
            try Data("partial".utf8).write(to: outputURL)
            return successfulSubprocessResult(
                standardError: "cannot read \(inputURL.path) or write \(outputURL.path)",
                terminationStatus: 7
            )
        }

        let result = await FFMPEGConverter.extractAudioAsPCMWAV(
            inputURL: inputURL,
            outputFolder: temporaryDirectory,
            ffmpegPath: "/private/tools/ffmpeg",
            trimStart: nil,
            trimEnd: nil,
            subprocessRunner: runner
        )

        guard case .failed(let reason) = result else {
            return XCTFail("Expected nonzero FFmpeg exit to fail")
        }
        XCTAssertTrue(reason.contains("ffmpeg exit 7"))
        XCTAssertTrue(reason.contains("<redacted>"))
        XCTAssertFalse(reason.contains(inputURL.path))
        XCTAssertEqual(try packageAudioTemporaryFiles(in: temporaryDirectory), [])
    }

    func testPackageAudioExtractionMapsTimeoutCancellationAndInvalidOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("package audio failures \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let inputURL = temporaryDirectory.appendingPathComponent("source.wav")

        let timeoutRunner = RecordingSubprocessRunner { request, _ in
            let outputURL = URL(fileURLWithPath: try XCTUnwrap(request.arguments.last))
            try Data("partial".utf8).write(to: outputURL)
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: successfulSubprocessResult(terminationStatus: SIGKILL)
            )
        }
        let timeoutResult = await FFMPEGConverter.extractAudioAsPCMWAV(
            inputURL: inputURL,
            outputFolder: temporaryDirectory,
            ffmpegPath: "/private/tools/ffmpeg",
            trimStart: nil,
            trimEnd: nil,
            subprocessRunner: timeoutRunner
        )
        guard case .failed(let timeoutReason) = timeoutResult else {
            return XCTFail("Expected timeout to fail")
        }
        XCTAssertEqual(timeoutReason, "FFmpeg audio extraction timed out after 12 hours")
        XCTAssertEqual(try packageAudioTemporaryFiles(in: temporaryDirectory), [])

        let missingOutputRunner = RecordingSubprocessRunner { _, _ in
            successfulSubprocessResult()
        }
        let missingOutputResult = await FFMPEGConverter.extractAudioAsPCMWAV(
            inputURL: inputURL,
            outputFolder: temporaryDirectory,
            ffmpegPath: "/private/tools/ffmpeg",
            trimStart: nil,
            trimEnd: nil,
            subprocessRunner: missingOutputRunner
        )
        guard case .failed(let missingOutputReason) = missingOutputResult else {
            return XCTFail("Expected a missing output to fail validation")
        }
        XCTAssertEqual(missingOutputReason, "Output file was not created")

        let cancellationRunner = RecordingSubprocessRunner { _, _ in
            try await Task.sleep(for: .seconds(30))
            return successfulSubprocessResult()
        }
        let extractionTask = Task {
            await FFMPEGConverter.extractAudioAsPCMWAV(
                inputURL: inputURL,
                outputFolder: temporaryDirectory,
                ffmpegPath: "/private/tools/ffmpeg",
                trimStart: nil,
                trimEnd: nil,
                subprocessRunner: cancellationRunner
            )
        }
        while cancellationRunner.lastRequest == nil {
            await Task.yield()
        }
        extractionTask.cancel()
        guard case .failed(let cancellationReason) = await extractionTask.value else {
            return XCTFail("Expected parent-task cancellation to fail extraction")
        }
        XCTAssertEqual(cancellationReason, "Conversion cancelled")
        XCTAssertEqual(try packageAudioTemporaryFiles(in: temporaryDirectory), [])
    }

    func testPackageWrapperUsesBoundedRedactedRunnerAndValidatesOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("private package wrapper \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("private input.j2c")
        let outputURL = temporaryDirectory.appendingPathComponent("private output.mxf")
        let executablePath = "/private/tools/asdcp-wrap"
        let arguments = ["-v", inputURL.path, outputURL.path]
        let runner = RecordingSubprocessRunner { _, _ in
            try Data("wrapped essence".utf8).write(to: outputURL)
            return successfulSubprocessResult(
                standardOutput: "wrapper stdout",
                standardError: "wrapper stderr"
            )
        }

        let result = await FFMPEGConverter.runPackageWrapper(
            executablePath: executablePath,
            arguments: arguments,
            outputURL: outputURL,
            subprocessRunner: runner
        )

        guard case .success(let diagnostic) = result else {
            return XCTFail("Expected package wrapper success")
        }
        XCTAssertTrue(diagnostic.contains("wrapper stdout"))
        XCTAssertTrue(diagnostic.contains("wrapper stderr"))
        XCTAssertEqual(try Data(contentsOf: outputURL), Data("wrapped essence".utf8))

        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.executableURL.path, executablePath)
        XCTAssertEqual(request.arguments, arguments)
        XCTAssertEqual(request.timeout, FFMPEGConverter.packageWrapperTimeout)
        XCTAssertEqual(
            request.standardOutputCaptureLimit,
            FFMPEGConverter.packageWrapperDiagnosticCaptureLimit
        )
        XCTAssertEqual(
            request.standardErrorCaptureLimit,
            FFMPEGConverter.packageWrapperDiagnosticCaptureLimit
        )
        XCTAssertFalse(request.redactedCommandDescription.contains(executablePath))
        XCTAssertFalse(request.redactedCommandDescription.contains(inputURL.path))
        XCTAssertFalse(request.redactedCommandDescription.contains(outputURL.path))
    }

    func testPackageWrapperMapsFailureTimeoutAndInvalidOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("package wrapper failures \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("private input.wav")
        let outputURL = temporaryDirectory.appendingPathComponent("private output.mxf")
        let executablePath = "/private/tools/asdcp-wrap"
        let arguments = [inputURL.path, outputURL.path]
        let failureRunner = RecordingSubprocessRunner { _, _ in
            try Data("partial".utf8).write(to: outputURL)
            return successfulSubprocessResult(
                standardError: "cannot read \(inputURL.path) or write \(outputURL.path)",
                terminationStatus: 7
            )
        }
        let failure = await FFMPEGConverter.runPackageWrapper(
            executablePath: executablePath,
            arguments: arguments,
            outputURL: outputURL,
            subprocessRunner: failureRunner
        )
        guard case .failed(let status, let reason, let diagnostic) = failure else {
            return XCTFail("Expected nonzero package wrapper failure")
        }
        XCTAssertEqual(status, 7)
        XCTAssertEqual(reason, "tool exited with status 7")
        XCTAssertTrue(diagnostic.contains("<redacted>"))
        XCTAssertFalse(diagnostic.contains(inputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))

        let timeoutRunner = RecordingSubprocessRunner { request, _ in
            try Data("partial".utf8).write(to: outputURL)
            throw SubprocessRunnerError.timedOut(
                command: request.redactedCommandDescription,
                result: successfulSubprocessResult(
                    standardError: "stalled at \(outputURL.path)",
                    terminationStatus: SIGKILL
                )
            )
        }
        let timeout = await FFMPEGConverter.runPackageWrapper(
            executablePath: executablePath,
            arguments: arguments,
            outputURL: outputURL,
            subprocessRunner: timeoutRunner
        )
        guard case .failed(_, let timeoutReason, let timeoutDiagnostic) = timeout else {
            return XCTFail("Expected package wrapper timeout")
        }
        XCTAssertEqual(timeoutReason, "tool timed out after 12 hours")
        XCTAssertTrue(timeoutDiagnostic.contains("<redacted>"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))

        let missingOutput = await FFMPEGConverter.runPackageWrapper(
            executablePath: executablePath,
            arguments: arguments,
            outputURL: outputURL,
            subprocessRunner: RecordingSubprocessRunner { _, _ in successfulSubprocessResult() }
        )
        guard case .failed(_, let missingReason, _) = missingOutput else {
            return XCTFail("Expected missing package wrapper output to fail")
        }
        XCTAssertEqual(missingReason, "Output file was not created")

        try Data().write(to: outputURL)
        let emptyOutput = await FFMPEGConverter.runPackageWrapper(
            executablePath: executablePath,
            arguments: arguments,
            outputURL: outputURL,
            subprocessRunner: RecordingSubprocessRunner { _, _ in successfulSubprocessResult() }
        )
        guard case .failed(_, let emptyReason, _) = emptyOutput else {
            return XCTFail("Expected empty package wrapper output to fail")
        }
        XCTAssertEqual(emptyReason, "Output file is empty (0 bytes)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testPackageWrapperCancellationCancelsRunnerAndRemovesPartialOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cancelled package wrapper \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputURL = temporaryDirectory.appendingPathComponent("partial.mxf")
        try Data("partial".utf8).write(to: outputURL)
        let runner = CountingBlockingSubprocessRunner()
        let task = Task {
            await FFMPEGConverter.runPackageWrapper(
                executablePath: "/private/tools/raw2bmx",
                arguments: ["-o", outputURL.path],
                outputURL: outputURL,
                subprocessRunner: runner
            )
        }

        await runner.waitUntilStarted(count: 1)
        task.cancel()
        guard case .cancelled = await task.value else {
            return XCTFail("Expected package wrapper cancellation")
        }
        XCTAssertEqual(runner.cancelledCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testPackageCodestreamPreparationChecksCancellationAfterFinalFrame() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0xFF, 0x4F, 1]).write(to: root.appendingPathComponent("frame.jp2"))
        let task = Task.detached {
            try FFMPEGConverter.preparePackageCodestreams(
                sourceDirectory: root,
                frameNames: ["frame.jp2"],
                destinationDirectory: root.appendingPathComponent("output")
            ) { _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation during the final frame must not report successful preparation")
        } catch is CancellationError {
            // Expected even when there is no next frame to check cancellation.
        }
    }

    func testIMFQueueCancellationStopsFramePreparationBeforeWrapper() async throws {
        guard BinaryPathResolver.raw2bmxPath != nil else {
            throw XCTSkip("Bundled raw2bmx is required to enter IMF frame preparation")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = SequencedRecordingSubprocessRunner { index, request, _ in
            XCTAssertEqual(index, 0, "Cancellation must prevent launching the package wrapper")
            let pattern = try XCTUnwrap(request.arguments.last)
            for frame in 1...2 {
                let path = pattern.replacingOccurrences(of: "%06d", with: String(format: "%06d", frame))
                try Data([0xFF, 0x4F, 1]).write(to: URL(fileURLWithPath: path))
            }
            return successfulSubprocessResult()
        }
        let converter = FFMPEGConverter(subprocessRunner: runner, ffmpegPathProvider: { "/fixture/ffmpeg" })
        let preparedStatuses = OSAllocatedUnfairLock(initialState: [String]())
        let result = await runConversion(
            ConversionRequest(
                inputURL: root.appendingPathComponent("input.mov"),
                outputURL: root.appendingPathComponent("output"),
                preset: .imfJ2K,
                includeDateTag: false,
                sourceMetadata: videoMetadata(timecode: nil, frameRate: 24, duration: 1),
                expectedDuration: 1,
                videoFrameRate: 24
            ),
            using: converter
        ) { _, status in
            guard let status, status.hasPrefix("Preparing J2C frames") else { return }
            preparedStatuses.withLock { $0.append(status) }
            let cancelled = DispatchSemaphore(value: 0)
            Task {
                await converter.cancelConversion()
                cancelled.signal()
            }
            XCTAssertEqual(cancelled.wait(timeout: .now() + 5), .success,
                           "Frame preparation must leave the converter actor available for cancellation")
        }
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorReason, "Conversion cancelled")
        XCTAssertEqual(preparedStatuses.withLock { $0 }, ["Preparing J2C frames 1/2"])
        XCTAssertEqual(runner.requests.count, 1)
    }

    func testPackageCodestreamPreparationRequiresEveryFrameAndCountsWrittenBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let frames = ["frame_000001.jp2", "frame_000002.jp2"]
        let codestreams = [Data([0xFF, 0x4F, 1, 2, 0xFF, 0xD9]), Data([0xFF, 0x4F, 3, 0xFF, 0xD9])]
        for (frame, codestream) in zip(frames, codestreams) {
            try (Data([0, 0, 0, 12]) + codestream).write(to: root.appendingPathComponent(frame))
        }
        let destination = root.appendingPathComponent("codestreams")
        var completedFrames: [Int] = []
        let bytes = try FFMPEGConverter.preparePackageCodestreams(
            sourceDirectory: root, frameNames: frames, destinationDirectory: destination
        ) { completed, total in
            XCTAssertEqual(total, 2)
            completedFrames.append(completed)
        }
        XCTAssertEqual(bytes, Int64(codestreams.reduce(0) { $0 + $1.count }))
        XCTAssertEqual(completedFrames, [1, 2])
        for (frame, expected) in zip(frames, codestreams) {
            let output = destination.appendingPathComponent(frame).deletingPathExtension().appendingPathExtension("j2c")
            XCTAssertEqual(try Data(contentsOf: output), expected)
        }
    }

    func testPackageCodestreamPreparationRejectsMissingAndMalformedFrames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([0xFF, 0x4F, 1]).write(to: root.appendingPathComponent("valid.jp2"))
        try Data("invalid frame".utf8).write(to: root.appendingPathComponent("invalid.jp2"))
        for badFrame in ["missing.jp2", "invalid.jp2"] {
            let destination = root.appendingPathComponent(UUID().uuidString)
            var completedFrames: [Int] = []
            XCTAssertThrowsError(try FFMPEGConverter.preparePackageCodestreams(
                sourceDirectory: root, frameNames: ["valid.jp2", badFrame], destinationDirectory: destination
            ) { completed, _ in completedFrames.append(completed) })
            XCTAssertEqual(completedFrames, [1], "A failed frame must never be counted as prepared")
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(badFrame).deletingPathExtension().appendingPathExtension("j2c").path))
        }
    }

    func testPackageCodestreamPreparationReportsDirectoryAndWriteFailures() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("frame.jp2")
        try Data([0xFF, 0x4F, 1]).write(to: source)
        XCTAssertThrowsError(try FFMPEGConverter.preparePackageCodestreams(
            sourceDirectory: root, frameNames: ["frame.jp2"], destinationDirectory: source
        ))
        let destination = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("frame.j2c"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try FFMPEGConverter.preparePackageCodestreams(
            sourceDirectory: root, frameNames: ["frame.jp2"], destinationDirectory: destination
        ))
        XCTAssertEqual(try Data(contentsOf: source), Data([0xFF, 0x4F, 1]))
    }

    func testDCPManifestAssemblyMovesDummyEssencesAndBuildsConsistentAssets() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterDCPManifestTests-\(UUID().uuidString)", isDirectory: true)
        let packageDirectory = temporaryDirectory.appendingPathComponent("Package & Delivery", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let videoSource = temporaryDirectory.appendingPathComponent("picture.mxf")
        let audioSource = temporaryDirectory.appendingPathComponent("sound.mxf")
        let videoData = Data("dummy DCP picture essence".utf8)
        let audioData = Data("dummy DCP sound essence".utf8)
        try videoData.write(to: videoSource)
        try audioData.write(to: audioSource)

        let assembled = await DCPService.shared.assembleDCP(
            videoMXFURL: videoSource,
            audioMXFURL: audioSource,
            outputDirectoryURL: packageDirectory,
            title: "Feature & <Trailer>",
            resolution: .twoKFlat,
            frameRate: .fps24,
            frameCount: 48,
            itemMetadata: DCPItemMetadata(
                contentKind: .trailer,
                annotationText: "QC & mastering <approved>",
                ratingLabel: "PG & 12",
                audioLanguage: "nb"
            ),
            progress: { _ in }
        )

        XCTAssertTrue(assembled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: videoSource.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioSource.path))

        let files = try FileManager.default.contentsOfDirectory(
            at: packageDirectory,
            includingPropertiesForKeys: nil
        )
        let videoURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("j2c_") })
        let audioURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("pcm_") })
        let cplURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("cpl_") })
        let pklURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("pkl_") })
        let assetMapURL = packageDirectory.appendingPathComponent("ASSETMAP.xml")

        XCTAssertEqual(try Data(contentsOf: videoURL), videoData)
        XCTAssertEqual(try Data(contentsOf: audioURL), audioData)
        try assertPackingList(
            at: pklURL,
            describes: [cplURL, videoURL, audioURL]
        )
        try assertAssetMap(
            at: assetMapURL,
            describes: [pklURL, cplURL, videoURL, audioURL]
        )

        XCTAssertEqual(try xmlTexts(named: "ContentTitleText", at: cplURL), ["Feature & <Trailer>"])
        XCTAssertEqual(try xmlTexts(named: "AnnotationText", at: cplURL).first, "QC & mastering <approved>")
        XCTAssertEqual(try xmlTexts(named: "ContentKind", at: cplURL), [DCPContentKind.trailer.rawValue])
        XCTAssertEqual(try xmlTexts(named: "Language", at: cplURL), ["nb"])
        XCTAssertEqual(try xmlTexts(named: "IntrinsicDuration", at: cplURL), ["48", "48", "48"])
        XCTAssertTrue(try xmlTexts(named: "EditRate", at: cplURL).allSatisfy { $0 == "24 1" })
        XCTAssertEqual(try xmlTexts(named: "AnnotationText", at: pklURL).first, "QC & mastering <approved>")
    }

    func testIMFManifestAssemblyMovesDummyEssencesAndRoundTripsPackage() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterIMFManifestTests-\(UUID().uuidString)", isDirectory: true)
        let packageDirectory = temporaryDirectory.appendingPathComponent("IMP Package", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let videoSource = temporaryDirectory.appendingPathComponent("picture.mxf")
        let audioSource = temporaryDirectory.appendingPathComponent("sound.mxf")
        let videoData = Data("dummy IMF picture essence".utf8)
        let audioData = Data("dummy IMF sound essence".utf8)
        try videoData.write(to: videoSource)
        try audioData.write(to: audioSource)

        let assembled = await IMFManifestWriter.shared.assembleIMP(
            videoMXFURL: videoSource,
            audioMXFURL: audioSource,
            outputDirectoryURL: packageDirectory,
            title: "Episode & <Special>",
            application: .app2e,
            editRateNumerator: 30_000,
            editRateDenominator: 1_001,
            frameCount: 90,
            itemMetadata: IMFItemMetadata(
                contentKind: .episode,
                annotationText: "Archive & delivery <master>",
                audioLanguage: "nb"
            ),
            progress: { _ in }
        )

        XCTAssertTrue(assembled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: videoSource.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioSource.path))

        let files = try FileManager.default.contentsOfDirectory(
            at: packageDirectory,
            includingPropertiesForKeys: nil
        )
        let videoURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("video_") })
        let audioURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("audio_") })
        let cplURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("CPL_") })
        let pklURL = try XCTUnwrap(files.first { $0.lastPathComponent.hasPrefix("PKL_") })
        let assetMapURL = packageDirectory.appendingPathComponent("ASSETMAP.xml")

        XCTAssertEqual(try Data(contentsOf: videoURL), videoData)
        XCTAssertEqual(try Data(contentsOf: audioURL), audioData)
        try assertPackingList(
            at: pklURL,
            describes: [cplURL, videoURL, audioURL]
        )
        try assertAssetMap(
            at: assetMapURL,
            describes: [pklURL, cplURL, videoURL, audioURL]
        )

        let parsed = try IMFPackageParser.parsePackage(folder: packageDirectory)
        XCTAssertEqual(parsed.contentTitle, "Episode & <Special>")
        XCTAssertEqual(parsed.essences.map(\.kind), [.mainImage, .mainAudio])
        XCTAssertEqual(
            parsed.essences.map { $0.mxfURL.resolvingSymlinksInPath().path },
            [videoURL, audioURL].map { $0.resolvingSymlinksInPath().path }
        )
        XCTAssertEqual(try Data(contentsOf: parsed.essences[0].mxfURL), videoData)
        XCTAssertEqual(try Data(contentsOf: parsed.essences[1].mxfURL), audioData)

        XCTAssertEqual(try xmlTexts(named: "AnnotationText", at: cplURL).first, "Archive & delivery <master>")
        XCTAssertEqual(try xmlTexts(named: "ContentKind", at: cplURL), [IMFContentKind.episode.rawValue])
        XCTAssertEqual(try xmlTexts(named: "EditRate", at: cplURL), ["30000 1001"])
        XCTAssertEqual(try xmlTexts(named: "IntrinsicDuration", at: cplURL), ["90", "90"])
        XCTAssertEqual(try xmlTexts(named: "SourceDuration", at: cplURL), ["90", "90"])
    }

    func testPackageManifestAssemblyOmitsAudioAssetsWhenSourceHasNoAudio() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterSilentPackageTests-\(UUID().uuidString)", isDirectory: true)
        let dcpDirectory = temporaryDirectory.appendingPathComponent("DCP", isDirectory: true)
        let imfDirectory = temporaryDirectory.appendingPathComponent("IMF", isDirectory: true)
        try FileManager.default.createDirectory(at: dcpDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: imfDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let dcpVideoSource = temporaryDirectory.appendingPathComponent("dcp-picture.mxf")
        let imfVideoSource = temporaryDirectory.appendingPathComponent("imf-picture.mxf")
        try Data("silent DCP picture essence".utf8).write(to: dcpVideoSource)
        try Data("silent IMF picture essence".utf8).write(to: imfVideoSource)

        let dcpAssembled = await DCPService.shared.assembleDCP(
            videoMXFURL: dcpVideoSource,
            audioMXFURL: nil,
            outputDirectoryURL: dcpDirectory,
            title: "Silent DCP",
            resolution: .twoKFlat,
            frameRate: .fps24,
            frameCount: 24,
            progress: { _ in }
        )
        let imfAssembled = await IMFManifestWriter.shared.assembleIMP(
            videoMXFURL: imfVideoSource,
            audioMXFURL: nil,
            outputDirectoryURL: imfDirectory,
            title: "Silent IMF",
            application: .app5,
            editRateNumerator: 24,
            editRateDenominator: 1,
            frameCount: 24,
            progress: { _ in }
        )
        XCTAssertTrue(dcpAssembled)
        XCTAssertTrue(imfAssembled)

        let dcpFiles = try FileManager.default.contentsOfDirectory(at: dcpDirectory, includingPropertiesForKeys: nil)
        let dcpVideoURL = try XCTUnwrap(dcpFiles.first { $0.lastPathComponent.hasPrefix("j2c_") })
        let dcpCPLURL = try XCTUnwrap(dcpFiles.first { $0.lastPathComponent.hasPrefix("cpl_") })
        let dcpPKLURL = try XCTUnwrap(dcpFiles.first { $0.lastPathComponent.hasPrefix("pkl_") })
        XCTAssertFalse(dcpFiles.contains { $0.lastPathComponent.hasPrefix("pcm_") })
        XCTAssertTrue(try xmlTexts(named: "MainSound", at: dcpCPLURL).isEmpty)
        try assertPackingList(at: dcpPKLURL, describes: [dcpCPLURL, dcpVideoURL])
        try assertAssetMap(
            at: dcpDirectory.appendingPathComponent("ASSETMAP.xml"),
            describes: [dcpPKLURL, dcpCPLURL, dcpVideoURL]
        )

        let imfFiles = try FileManager.default.contentsOfDirectory(at: imfDirectory, includingPropertiesForKeys: nil)
        let imfVideoURL = try XCTUnwrap(imfFiles.first { $0.lastPathComponent.hasPrefix("video_") })
        let imfCPLURL = try XCTUnwrap(imfFiles.first { $0.lastPathComponent.hasPrefix("CPL_") })
        let imfPKLURL = try XCTUnwrap(imfFiles.first { $0.lastPathComponent.hasPrefix("PKL_") })
        XCTAssertFalse(imfFiles.contains { $0.lastPathComponent.hasPrefix("audio_") })
        XCTAssertTrue(try xmlTexts(named: "MainAudioSequence", at: imfCPLURL).isEmpty)
        try assertPackingList(at: imfPKLURL, describes: [imfCPLURL, imfVideoURL])
        try assertAssetMap(
            at: imfDirectory.appendingPathComponent("ASSETMAP.xml"),
            describes: [imfPKLURL, imfCPLURL, imfVideoURL]
        )
        XCTAssertEqual(try IMFPackageParser.parsePackage(folder: imfDirectory).essences.map(\.kind), [.mainImage])
    }

    func testIMFJ2KCommandUsesRationalRateHDRTagsAndFillGeometry() throws {
        try withPresetSettings([
            AppConstants.imfResolutionKey: IMFResolution.uhd2160.rawValue,
            AppConstants.imfFrameRateKey: IMFFrameRate.fps29_97.rawValue,
            AppConstants.imfScalingModeKey: IMFScalingMode.fill.rawValue,
            AppConstants.imfJ2KColorEncodingKey: IMFColorEncoding.rec2020PQ.rawValue,
            AppConstants.imfJ2KBitrateKey: DCPBitrate.high.rawValue
        ]) {
            let arguments = ExportPreset.imfJ2K.ffmpegArguments

            XCTAssertTrue(arguments.containsAdjacent("-pix_fmt", "yuv422p10le"))
            XCTAssertTrue(arguments.containsAdjacent("-color_primaries", "bt2020"))
            XCTAssertTrue(arguments.containsAdjacent("-color_trc", "smpte2084"))
            XCTAssertTrue(arguments.containsAdjacent("-colorspace", "bt2020nc"))
            XCTAssertTrue(arguments.containsAdjacent("-r", "30000/1001"))
            XCTAssertTrue(arguments.containsAdjacent(
                "-vf",
                "scale=iw*sar:ih,setsar=1,scale=3840:2160:force_original_aspect_ratio=increase,crop=3840:2160"
            ))
            XCTAssertFalse(arguments.contains("-cinema_mode"))
        }
    }

    func testIMFPictureFrameCountPrefersProducedFramesAndFallsBackToDuration() {
        XCTAssertEqual(
            FFMPEGConverter.resolvedIMFPictureFrameCount(
                exactFrameCount: 48,
                duration: 1.1,
                editRateNumerator: 24,
                editRateDenominator: 1
            ),
            48
        )
        XCTAssertEqual(
            FFMPEGConverter.resolvedIMFPictureFrameCount(
                exactFrameCount: nil,
                duration: 10,
                editRateNumerator: 30_000,
                editRateDenominator: 1_001
            ),
            300
        )
        XCTAssertEqual(
            FFMPEGConverter.resolvedIMFPictureFrameCount(
                exactFrameCount: nil,
                duration: nil,
                editRateNumerator: 24,
                editRateDenominator: 1
            ),
            0
        )
    }

    func testIMFProResCommandUsesSelectedProfileAndHLGTags() throws {
        try withPresetSettings([
            AppConstants.imfResolutionKey: IMFResolution.uhd2160.rawValue,
            AppConstants.imfFrameRateKey: IMFFrameRate.fps59_94.rawValue,
            AppConstants.imfScalingModeKey: IMFScalingMode.fit.rawValue,
            AppConstants.imfJ2KColorEncodingKey: IMFColorEncoding.rec2020HLG.rawValue,
            AppConstants.imfProResProfileKey: IMFProResProfile.proRes4444XQ.rawValue
        ]) {
            let arguments = ExportPreset.imfProRes.ffmpegArguments

            XCTAssertTrue(arguments.containsAdjacent("-profile:v", "5"))
            XCTAssertTrue(arguments.containsAdjacent("-pix_fmt", "yuva444p10le"))
            XCTAssertTrue(arguments.containsAdjacent("-color_primaries", "bt2020"))
            XCTAssertTrue(arguments.containsAdjacent("-color_trc", "arib-std-b67"))
            XCTAssertTrue(arguments.containsAdjacent("-colorspace", "bt2020nc"))
            XCTAssertTrue(arguments.containsAdjacent("-r", "60000/1001"))
        }
    }

    func testAV2ChunkPlanningRespectsRateControlAndMinimumChunkSize() {
        XCTAssertEqual(
            AV2CommandBuilder.resolvedChunkCount(totalFrames: 240, hint: 8, rateMode: .targetBitrate),
            1
        )
        XCTAssertEqual(
            AV2CommandBuilder.resolvedChunkCount(totalFrames: 47, hint: 8, rateMode: .constantQuality),
            1
        )
        XCTAssertEqual(
            AV2CommandBuilder.resolvedChunkCount(totalFrames: 48, hint: 8, rateMode: .constantQuality),
            2
        )
        XCTAssertEqual(
            AV2CommandBuilder.resolvedChunkCount(totalFrames: 240, hint: 8, rateMode: .constantQuality),
            8
        )
    }

    func testAV2EffectiveDurationHandlesEveryTrimShape() {
        XCTAssertEqual(
            AV2CommandBuilder.resolvedEffectiveDuration(
                sourceDuration: 10,
                trimStart: nil,
                trimEnd: nil
            ),
            10
        )
        XCTAssertEqual(
            AV2CommandBuilder.resolvedEffectiveDuration(
                sourceDuration: 10,
                trimStart: 2.5,
                trimEnd: nil
            ),
            7.5
        )
        XCTAssertEqual(
            AV2CommandBuilder.resolvedEffectiveDuration(
                sourceDuration: 10,
                trimStart: nil,
                trimEnd: 4
            ),
            4
        )
        XCTAssertEqual(
            AV2CommandBuilder.resolvedEffectiveDuration(
                sourceDuration: 10,
                trimStart: 2,
                trimEnd: 6
            ),
            4
        )
        XCTAssertEqual(
            AV2CommandBuilder.resolvedEffectiveDuration(
                sourceDuration: 10,
                trimStart: 8,
                trimEnd: 20
            ),
            2
        )
        XCTAssertEqual(
            AV2CommandBuilder.resolvedEffectiveDuration(
                sourceDuration: 10,
                trimStart: 12,
                trimEnd: nil
            ),
            0
        )
    }

    func testSingleAV2EncodeUsesBoundedRedactedPipelineAndSplitPOCProgress() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AV2PipelinePolicy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let y4mData = Data("YUV4MPEG2 W2 H2 F24:1 Ip A1:1 C420\nFRAME\nfixture".utf8)
        let progressValues = OSAllocatedUnfairLock<[Double]>(initialState: [])
        let runner = SequencedRecordingSubprocessRunner { index, request, outputHandler in
            if index == 0 {
                outputHandler?(SubprocessOutputChunk(stream: .standardOutput, data: y4mData))
                outputHandler?(
                    SubprocessOutputChunk(
                        stream: .standardError,
                        data: Data("out_time=00:00:00.500000\r".utf8)
                    )
                )
                return successfulSubprocessResult()
            }

            XCTAssertEqual(request.standardInput, y4mData)
            outputHandler?(
                SubprocessOutputChunk(stream: .standardOutput, data: Data("frame PO".utf8))
            )
            outputHandler?(
                SubprocessOutputChunk(stream: .standardOutput, data: Data("C: 0\n".utf8))
            )
            let outputIndex = try XCTUnwrap(request.arguments.firstIndex(of: "-o"))
            let outputPath = try XCTUnwrap(
                request.arguments.indices.contains(outputIndex + 1)
                    ? request.arguments[outputIndex + 1]
                    : nil
            )
            try Data("encoded AV2".utf8).write(to: URL(fileURLWithPath: outputPath))
            return successfulSubprocessResult()
        }
        let ffmpegPath = "/private/tools/ffmpeg"
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { ffmpegPath }
        )
        let inputURL = temporaryDirectory.appendingPathComponent("private input.mov")
        let outputBaseURL = temporaryDirectory.appendingPathComponent("private output")
        let outputURL = outputBaseURL.appendingPathExtension("ivf")
        defer { FileSafetyUtils.unregisterCreatedFile(outputURL) }

        let result = try await withPresetSettingsAsync([
            AppConstants.av2ParallelChunksKey: 1,
            AppConstants.av2ContainerKey: AV2Container.ivf.rawValue
        ]) {
            await runConversion(
                ConversionRequest(
                    inputURL: inputURL,
                    outputURL: outputBaseURL,
                    preset: .av2,
                    includeDateTag: false,
                    sourceMetadata: videoMetadata(
                        timecode: nil,
                        frameRate: 24,
                        duration: 1
                    ),
                    expectedDuration: 1,
                    videoFrameRate: 24
                ),
                using: converter,
                progressUpdate: { progress, _ in
                    progressValues.withLock { $0.append(progress) }
                }
            )
        }

        XCTAssertTrue(result.success, result.errorReason ?? "AV2 pipeline failed without a reason")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(progressValues.withLock { values in
            values.contains { abs($0 - (1.0 / 24.0)) < 0.001 }
        })

        let requests = runner.requests
        XCTAssertEqual(requests.count, 2)
        let producer = requests[0]
        let consumer = requests[1]
        XCTAssertEqual(producer.executableURL.path, ffmpegPath)
        XCTAssertEqual(producer.timeout, FFMPEGConverter.av2PipelineTimeout)
        XCTAssertEqual(producer.standardOutputCaptureLimit, 0)
        XCTAssertEqual(
            producer.standardErrorCaptureLimit,
            FFMPEGConverter.av2PipelineDiagnosticCaptureLimit
        )
        XCTAssertEqual(consumer.timeout, FFMPEGConverter.av2PipelineTimeout)
        XCTAssertEqual(consumer.standardOutputCaptureLimit, 0)
        XCTAssertEqual(
            consumer.standardErrorCaptureLimit,
            FFMPEGConverter.av2PipelineDiagnosticCaptureLimit
        )
        XCTAssertTrue(consumer.arguments.containsAdjacent("-o", outputURL.path))
        XCTAssertFalse(producer.redactedCommandDescription.contains(inputURL.path))
        XCTAssertFalse(consumer.redactedCommandDescription.contains(outputURL.path))
        XCTAssertFalse(producer.redactedCommandDescription.contains(ffmpegPath))
    }

    func testSingleAV2PipelineFailureRedactsDiagnosticsAndCleansPartialOutput() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AV2PipelineFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("secret input.mov")
        let outputBaseURL = temporaryDirectory.appendingPathComponent("private output")
        let outputURL = outputBaseURL.appendingPathExtension("ivf")
        let runner = SequencedRecordingSubprocessRunner { index, request, _ in
            if index == 0 {
                return successfulSubprocessResult(
                    standardError: "Could not read \(inputURL.path)",
                    terminationStatus: 7
                )
            }
            let outputIndex = try XCTUnwrap(request.arguments.firstIndex(of: "-o"))
            let outputPath = request.arguments[outputIndex + 1]
            try Data("partial AV2".utf8).write(to: URL(fileURLWithPath: outputPath))
            return successfulSubprocessResult(
                standardError: "avmenc rejected truncated Y4M",
                terminationStatus: 9
            )
        }
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" }
        )

        let result = try await withPresetSettingsAsync([
            AppConstants.av2ParallelChunksKey: 1,
            AppConstants.av2ContainerKey: AV2Container.ivf.rawValue
        ]) {
            await runConversion(
                ConversionRequest(
                    inputURL: inputURL,
                    outputURL: outputBaseURL,
                    preset: .av2,
                    includeDateTag: false,
                    sourceMetadata: videoMetadata(
                        timecode: nil,
                        frameRate: 24,
                        duration: 1
                    ),
                    expectedDuration: 1,
                    videoFrameRate: 24
                ),
                using: converter
            )
        }

        XCTAssertFalse(result.success)
        let reason = try XCTUnwrap(result.errorReason)
        XCTAssertTrue(reason.contains("<redacted>"), reason)
        XCTAssertFalse(reason.contains(inputURL.path), reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testSingleAV2ProducerLaunchFailureWinsOverDownstreamEncoderError() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AV2PipelineLaunchFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let privateFFmpegPath = "/private/tools/missing-ffmpeg"
        let runner = SequencedRecordingSubprocessRunner { index, request, _ in
            if index == 0 {
                throw SubprocessRunnerError.failedToStart(
                    command: request.redactedCommandDescription,
                    underlying: "Could not launch \(privateFFmpegPath)"
                )
            }
            return successfulSubprocessResult(
                standardError: "avmenc could not read an empty input",
                terminationStatus: 9
            )
        }
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { privateFFmpegPath }
        )
        let outputBaseURL = temporaryDirectory.appendingPathComponent("output")
        let outputURL = outputBaseURL.appendingPathExtension("ivf")

        let result = try await withPresetSettingsAsync([
            AppConstants.av2ParallelChunksKey: 1,
            AppConstants.av2ContainerKey: AV2Container.ivf.rawValue
        ]) {
            await runConversion(
                ConversionRequest(
                    inputURL: temporaryDirectory.appendingPathComponent("input.mov"),
                    outputURL: outputBaseURL,
                    preset: .av2,
                    includeDateTag: false,
                    sourceMetadata: videoMetadata(timecode: nil, frameRate: 24, duration: 1),
                    expectedDuration: 1,
                    videoFrameRate: 24
                ),
                using: converter
            )
        }

        XCTAssertFalse(result.success)
        let reason = try XCTUnwrap(result.errorReason)
        XCTAssertTrue(reason.contains("Failed to start FFmpeg"), reason)
        XCTAssertTrue(reason.contains("<redacted>"), reason)
        XCTAssertFalse(reason.contains(privateFFmpegPath), reason)
        XCTAssertFalse(reason.contains("empty input"), reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testSingleAV2CompletedPipelineCannotPublishAfterCancellationWinsOwnership() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AV2PipelineLateCancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = CancellingCompletedPipelineRunner()
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" }
        )
        await runner.setBeforeConsumerReturns {
            await converter.cancelConversion()
        }
        let outputBaseURL = temporaryDirectory.appendingPathComponent("output")
        let outputURL = outputBaseURL.appendingPathExtension("ivf")

        let result = try await withPresetSettingsAsync([
            AppConstants.av2ParallelChunksKey: 1,
            AppConstants.av2ContainerKey: AV2Container.ivf.rawValue
        ]) {
            await runConversion(
                ConversionRequest(
                    inputURL: temporaryDirectory.appendingPathComponent("input.mov"),
                    outputURL: outputBaseURL,
                    preset: .av2,
                    includeDateTag: false,
                    sourceMetadata: videoMetadata(timecode: nil, frameRate: 24, duration: 1),
                    expectedDuration: 1,
                    videoFrameRate: 24
                ),
                using: converter
            )
        }

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorReason, "Conversion cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testSingleAV2PipelineCancellationStopsTrackedProducer() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AV2PipelineCancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = TwoStageBlockingPipelineRunner()
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" }
        )
        let outputBaseURL = temporaryDirectory.appendingPathComponent("output")
        let outputURL = outputBaseURL.appendingPathExtension("ivf")
        let request = ConversionRequest(
            inputURL: temporaryDirectory.appendingPathComponent("input.mov"),
            outputURL: outputBaseURL,
            preset: .av2,
            includeDateTag: false,
            sourceMetadata: videoMetadata(timecode: nil, frameRate: 24, duration: 1),
            expectedDuration: 1,
            videoFrameRate: 24
        )

        let result = try await withPresetSettingsAsync([
            AppConstants.av2ParallelChunksKey: 1,
            AppConstants.av2ContainerKey: AV2Container.ivf.rawValue
        ]) {
            let resultTask = Task {
                await conversionResult(converter: converter, request: request)
            }
            await runner.waitUntilBothStagesStarted()
            await converter.cancelConversion()
            return await resultTask.value
        }

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorReason, "Conversion cancelled")
        let cancellationDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < cancellationDeadline {
            if await runner.cancelledStageCount >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let cancelledProducerCount = await runner.cancelledProducerCount
        let cancelledConsumerCount = await runner.cancelledConsumerCount
        XCTAssertEqual(cancelledProducerCount, 1)
        XCTAssertEqual(cancelledConsumerCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testChunkedAV2UsesBoundedRedactedPipelinesAndSplitPOCProgress() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AV2ChunkPipelinePolicy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let ffmpegPath = "/private/tools/ffmpeg"
        let progressValues = OSAllocatedUnfairLock<[Double]>(initialState: [])
        let runner = SequencedRecordingSubprocessRunner { _, request, outputHandler in
            if request.executableURL.path == ffmpegPath {
                outputHandler?(
                    SubprocessOutputChunk(
                        stream: .standardOutput,
                        data: Data("YUV4MPEG2 W1920 H1080 F24:1 Ip A1:1 C420\nFRAME\nfixture".utf8)
                    )
                )
                return successfulSubprocessResult()
            }

            XCTAssertNotNil(request.standardInput)
            outputHandler?(SubprocessOutputChunk(stream: .standardOutput, data: Data("encoded PO".utf8)))
            outputHandler?(SubprocessOutputChunk(stream: .standardOutput, data: Data("C: 0\n".utf8)))
            let outputIndex = try XCTUnwrap(request.arguments.firstIndex(of: "-o"))
            let outputPath = request.arguments[outputIndex + 1]
            try makeTestIVFData().write(to: URL(fileURLWithPath: outputPath))
            return successfulSubprocessResult()
        }
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { ffmpegPath }
        )
        let inputURL = temporaryDirectory.appendingPathComponent("private source.mov")
        let outputBaseURL = temporaryDirectory.appendingPathComponent("private output")
        let outputURL = outputBaseURL.appendingPathExtension("ivf")
        defer { FileSafetyUtils.unregisterCreatedFile(outputURL) }

        let result = try await withPresetSettingsAsync([
            AppConstants.av2ParallelChunksKey: 2,
            AppConstants.av2RateControlModeKey: AV2RateControlMode.constantQuality.rawValue,
            AppConstants.av2ContainerKey: AV2Container.ivf.rawValue
        ]) {
            await runConversion(
                ConversionRequest(
                    inputURL: inputURL,
                    outputURL: outputBaseURL,
                    preset: .av2,
                    includeDateTag: false,
                    sourceMetadata: videoMetadata(timecode: nil, frameRate: 24, duration: 2),
                    expectedDuration: 2,
                    videoFrameRate: 24
                ),
                using: converter,
                progressUpdate: { progress, _ in
                    progressValues.withLock { $0.append(progress) }
                }
            )
        }

        XCTAssertTrue(result.success, result.errorReason ?? "Chunked AV2 pipeline failed")
        XCTAssertNotNil(IVFHeaderParser.parse(url: outputURL))
        XCTAssertTrue(progressValues.withLock { values in
            values.contains { abs($0 - (1.0 / 48.0)) < 0.001 }
        })

        let requests = runner.requests
        let producers = requests.filter { $0.executableURL.path == ffmpegPath }
        let consumers = requests.filter { $0.executableURL.path != ffmpegPath }
        XCTAssertEqual(producers.count, 2)
        XCTAssertEqual(consumers.count, 2)
        for request in requests {
            XCTAssertEqual(request.timeout, FFMPEGConverter.av2PipelineTimeout)
            XCTAssertEqual(request.standardOutputCaptureLimit, 0)
            XCTAssertEqual(
                request.standardErrorCaptureLimit,
                FFMPEGConverter.av2PipelineDiagnosticCaptureLimit
            )
            XCTAssertFalse(request.redactedCommandDescription.contains(inputURL.path))
            XCTAssertFalse(request.redactedCommandDescription.contains(ffmpegPath))
        }
        for consumer in consumers {
            let outputIndex = try XCTUnwrap(consumer.arguments.firstIndex(of: "-o"))
            let segmentPath = consumer.arguments[outputIndex + 1]
            XCTAssertFalse(consumer.redactedCommandDescription.contains(segmentPath))
        }
    }

    func testChunkedAV2ProducerFailureWinsAndRedactsDiagnostics() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AV2ChunkPipelineFailure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let ffmpegPath = "/private/tools/ffmpeg"
        let inputURL = temporaryDirectory.appendingPathComponent("private source.mov")
        let segmentDirectories = OSAllocatedUnfairLock<Set<URL>>(initialState: [])
        let runner = SequencedRecordingSubprocessRunner { _, request, _ in
            if request.executableURL.path == ffmpegPath {
                return successfulSubprocessResult(
                    standardError: "Could not read \(inputURL.path)",
                    terminationStatus: 7
                )
            }
            let outputIndex = try XCTUnwrap(request.arguments.firstIndex(of: "-o"))
            let outputURL = URL(fileURLWithPath: request.arguments[outputIndex + 1])
            _ = segmentDirectories.withLock { $0.insert(outputURL.deletingLastPathComponent()) }
            try Data("partial AV2".utf8).write(to: outputURL)
            return successfulSubprocessResult(
                standardError: "avmenc rejected empty input",
                terminationStatus: 9
            )
        }
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { ffmpegPath }
        )
        let outputBaseURL = temporaryDirectory.appendingPathComponent("output")
        let outputURL = outputBaseURL.appendingPathExtension("ivf")

        let result = try await withPresetSettingsAsync([
            AppConstants.av2ParallelChunksKey: 2,
            AppConstants.av2RateControlModeKey: AV2RateControlMode.constantQuality.rawValue,
            AppConstants.av2ContainerKey: AV2Container.ivf.rawValue
        ]) {
            await runConversion(
                ConversionRequest(
                    inputURL: inputURL,
                    outputURL: outputBaseURL,
                    preset: .av2,
                    includeDateTag: false,
                    sourceMetadata: videoMetadata(timecode: nil, frameRate: 24, duration: 2),
                    expectedDuration: 2,
                    videoFrameRate: 24
                ),
                using: converter
            )
        }

        XCTAssertFalse(result.success)
        let reason = try XCTUnwrap(result.errorReason)
        XCTAssertTrue(reason.contains("Could not read <redacted>"), reason)
        XCTAssertFalse(reason.contains(inputURL.path), reason)
        XCTAssertFalse(reason.contains("empty input"), reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
        for directory in segmentDirectories.withLock({ $0 }) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testChunkedAV2CancellationStopsEveryTrackedPipelineStage() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AV2ChunkPipelineCancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let runner = TwoStageBlockingPipelineRunner()
        let converter = FFMPEGConverter(
            subprocessRunner: runner,
            ffmpegPathProvider: { "/private/tools/ffmpeg" }
        )
        let outputBaseURL = temporaryDirectory.appendingPathComponent("output")
        let outputURL = outputBaseURL.appendingPathExtension("ivf")
        let request = ConversionRequest(
            inputURL: temporaryDirectory.appendingPathComponent("input.mov"),
            outputURL: outputBaseURL,
            preset: .av2,
            includeDateTag: false,
            sourceMetadata: videoMetadata(timecode: nil, frameRate: 24, duration: 2),
            expectedDuration: 2,
            videoFrameRate: 24
        )

        let result = try await withPresetSettingsAsync([
            AppConstants.av2ParallelChunksKey: 2,
            AppConstants.av2RateControlModeKey: AV2RateControlMode.constantQuality.rawValue,
            AppConstants.av2ContainerKey: AV2Container.ivf.rawValue
        ]) {
            let resultTask = Task {
                await conversionResult(converter: converter, request: request)
            }
            await runner.waitUntilStagesStarted(count: 2)
            await converter.cancelConversion()
            return await resultTask.value
        }

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorReason, "Conversion cancelled")
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await runner.cancelledStageCount >= 4 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let cancelledProducerCount = await runner.cancelledProducerCount
        let cancelledConsumerCount = await runner.cancelledConsumerCount
        XCTAssertEqual(cancelledProducerCount, 2)
        XCTAssertEqual(cancelledConsumerCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileSafetyUtils.isCreatedByApp(outputURL))
    }

    func testGeneratedAV2StartOnlyTrimPlansOnlyRemainingFrames() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterAV2TrimTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureURL = temporaryDirectory.appendingPathComponent("source.mov")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=32x32:rate=24:duration=4",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            fixtureURL.path
        ])

        try await withPresetSettingsAsync([
            AppConstants.av2ParallelChunksKey: 2,
            AppConstants.av2RateControlModeKey: AV2RateControlMode.constantQuality.rawValue
        ]) {
            let builtPlan = await AV2CommandBuilder.buildSegments(
                inputURL: fixtureURL,
                trimStart: 1.5,
                trimEnd: nil,
                cropConfig: nil
            )
            let plan = try XCTUnwrap(builtPlan)
            defer { try? FileManager.default.removeItem(at: plan.segmentDirectory) }

            XCTAssertEqual(plan.effectiveDuration ?? -1, 2.5, accuracy: 0.02)
            XCTAssertEqual(plan.frameRate ?? -1, 24, accuracy: 0.01)
            XCTAssertEqual(plan.totalFrames, 60)
            XCTAssertEqual(plan.segments.map(\.frameCount).reduce(0, +), plan.totalFrames)
            XCTAssertEqual(plan.segments.count, 2)
            XCTAssertTrue(plan.segments[0].ffmpegArguments.containsAdjacent("-ss", "1.500000"))
            XCTAssertTrue(plan.segments[1].ffmpegArguments.containsAdjacent("-ss", "2.750000"))
            XCTAssertEqual(plan.segments.last?.frameCount, 30)
        }
    }

    func testAV2PlanningReusesOneKnownMetadataResultAcrossEveryStage() async throws {
        let inputURL = URL(fileURLWithPath: "/private/nonexistent-av2-source.mov")
        let outputURL = URL(fileURLWithPath: "/private/nonexistent-av2-output.ivf")
        let metadata = videoMetadata(timecode: "01:02:03:12", frameRate: 24)

        try await withPresetSettingsAsync([
            AppConstants.av2ParallelChunksKey: 2,
            AppConstants.av2RateControlModeKey: AV2RateControlMode.constantQuality.rawValue,
            AppConstants.av2BitDepthKey: AV2BitDepthOption.auto.rawValue
        ]) {
            let command = await AV2CommandBuilder.build(
                inputURL: inputURL,
                outputURL: outputURL,
                trimStart: nil,
                trimEnd: nil,
                cropConfig: nil,
                metadataSource: .resolved(metadata)
            )
            XCTAssertEqual(command?.outputWidth, 1920)
            XCTAssertEqual(command?.outputHeight, 1080)
            XCTAssertEqual(command?.frameRate ?? -1, 24, accuracy: 0.001)

            let plan = await AV2CommandBuilder.buildSegments(
                inputURL: inputURL,
                trimStart: nil,
                trimEnd: nil,
                cropConfig: nil,
                metadataSource: .resolved(metadata)
            )
            let unwrappedPlan = try XCTUnwrap(plan)
            defer { try? FileManager.default.removeItem(at: unwrappedPlan.segmentDirectory) }
            XCTAssertEqual(unwrappedPlan.segments.count, 2)
            XCTAssertEqual(unwrappedPlan.totalFrames, 1_440)
            XCTAssertEqual(unwrappedPlan.bitDepth, 8)

            let bitDepth = await AV2CommandBuilder.resolvedBitDepth(
                inputURL: inputURL,
                trimStart: nil,
                trimEnd: nil,
                cropConfig: nil,
                metadataSource: .resolved(metadata)
            )
            XCTAssertEqual(bitDepth, 8)
        }
    }

    func testAV2BuildUsesConcatInputAndKnownVirtualSourceDuration() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterAV2ConcatTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureURL = temporaryDirectory.appendingPathComponent("source.mov")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=32x32:rate=24:duration=1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            fixtureURL.path
        ])
        let listURL = temporaryDirectory.appendingPathComponent("inputs.ffconcat")
        try "file '\(fixtureURL.path)'\nfile '\(fixtureURL.path)'\n".write(
            to: listURL,
            atomically: true,
            encoding: .utf8
        )
        let customInputs = ["-f", "concat", "-safe", "0", "-i", listURL.path]

        try await withPresetSettingsAsync([AppConstants.av2ParallelChunksKey: 2]) {
            let outputURL = temporaryDirectory.appendingPathComponent("output.ivf")
            let builtCommand = await AV2CommandBuilder.build(
                inputURL: fixtureURL,
                outputURL: outputURL,
                trimStart: nil,
                trimEnd: nil,
                cropConfig: nil,
                customInputArguments: customInputs,
                expectedDuration: 2,
                videoFrameRate: 24
            )
            let command = try XCTUnwrap(builtCommand)

            XCTAssertEqual(command.effectiveDuration ?? -1, 2, accuracy: 0.001)
            XCTAssertEqual(command.frameRate ?? -1, 24, accuracy: 0.001)
            XCTAssertTrue(command.ffmpegArguments.containsAdjacent("-i", listURL.path))
            XCTAssertTrue(command.ffmpegArguments.containsAdjacent("-f", "concat"))
            XCTAssertFalse(command.ffmpegArguments.containsAdjacent("-i", fixtureURL.path))

            let chunkPlan = await AV2CommandBuilder.buildSegments(
                inputURL: fixtureURL,
                trimStart: nil,
                trimEnd: nil,
                cropConfig: nil,
                customInputArguments: customInputs,
                expectedDuration: 2,
                videoFrameRate: 24
            )
            XCTAssertNil(chunkPlan, "Virtual inputs must use the validated single-process path")
        }
    }

    func testAV2BuildUsesImageSequenceInputAndConcreteVisualSource() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterAV2ImageSequenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let firstFrameURL = temporaryDirectory.appendingPathComponent("frame_0001.png")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=red:size=40x24",
            "-frames:v", "1",
            firstFrameURL.path
        ])
        let patternURL = temporaryDirectory.appendingPathComponent("frame_%04d.png")
        let customInputs = [
            "-framerate", "12.000",
            "-start_number", "1",
            "-i", patternURL.path
        ]
        let outputURL = temporaryDirectory.appendingPathComponent("output.ivf")

        let builtCommand = await AV2CommandBuilder.build(
            inputURL: temporaryDirectory,
            outputURL: outputURL,
            trimStart: nil,
            trimEnd: nil,
            cropConfig: nil,
            visualSourceURL: firstFrameURL,
            customInputArguments: customInputs,
            expectedDuration: 1
        )
        let command = try XCTUnwrap(builtCommand)

        XCTAssertEqual(command.outputWidth, 40)
        XCTAssertEqual(command.outputHeight, 24)
        XCTAssertEqual(command.effectiveDuration ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(command.frameRate ?? -1, 12, accuracy: 0.001)
        XCTAssertTrue(command.ffmpegArguments.containsAdjacent("-i", patternURL.path))
        XCTAssertFalse(command.ffmpegArguments.containsAdjacent("-i", temporaryDirectory.path))
        XCTAssertTrue(command.avmencArguments.contains("--fps=12000/1000"))
    }

    func testAV2MatroskaAudioUsesVirtualSourceAndHonorsMute() {
        let primaryURL = URL(fileURLWithPath: "/tmp/primary.mov")
        let concatURL = URL(fileURLWithPath: "/tmp/inputs.ffconcat")
        let concatArguments = ["-f", "concat", "-safe", "0", "-i", concatURL.path]

        XCTAssertEqual(
            FFMPEGConverter.av2MuxAudioInput(
                inputURL: primaryURL,
                customInputArguments: concatArguments,
                isMuted: false
            ),
            FFMPEGConverter.PackageAudioInput(
                arguments: concatArguments,
                probeURL: primaryURL,
                ffmpegInputIndex: 0,
                assumesSingleAudioStreamIfProbeUnavailable: false
            )
        )

        let companionAudioURL = URL(fileURLWithPath: "/tmp/sequence.wav")
        let imageSequenceArguments = [
            "-framerate", "24",
            "-i", "/tmp/frame_%04d.png",
            "-i", companionAudioURL.path
        ]
        XCTAssertEqual(
            FFMPEGConverter.av2MuxAudioInput(
                inputURL: URL(fileURLWithPath: "/tmp/sequence"),
                customInputArguments: imageSequenceArguments,
                isMuted: false
            ),
            FFMPEGConverter.PackageAudioInput(
                arguments: ["-i", companionAudioURL.path],
                probeURL: companionAudioURL,
                ffmpegInputIndex: 0,
                assumesSingleAudioStreamIfProbeUnavailable: true
            )
        )

        XCTAssertNil(
            FFMPEGConverter.av2MuxAudioInput(
                inputURL: primaryURL,
                customInputArguments: concatArguments,
                isMuted: true
            )
        )
    }

    func testAV2MatroskaCapabilitiesFollowSelectedContainer() throws {
        try withPresetSettings([AppConstants.av2ContainerKey: AV2Container.ivf.rawValue]) {
            XCTAssertFalse(ExportPreset.av2.outputsAudioTrack)
            XCTAssertFalse(ExportPreset.av2.appliesAudioRouting)
        }
        try withPresetSettings([AppConstants.av2ContainerKey: AV2Container.mkv.rawValue]) {
            XCTAssertTrue(ExportPreset.av2.outputsAudioTrack)
            XCTAssertTrue(ExportPreset.av2.appliesAudioRouting)
        }
    }

    func testAV2AudioRoutingArgumentsPreserveOrderDuplicatesAndFilters() {
        let tracks = [audioTrack(index: 0, channels: 2), audioTrack(index: 1, channels: 6)]
        let config = AudioRoutingConfig(
            inputTracks: tracks,
            outputTracks: [
                OutputTrack(streamIndex: 1, downmixToStereo: true),
                OutputTrack(streamIndex: 0),
                OutputTrack(streamIndex: 1)
            ]
        )

        XCTAssertEqual(
            FFMPEGConverter.av2MuxAudioRoutingArguments(
                inputIndex: 2,
                audioRoutingConfig: config,
                defaultAudioStreamIndices: [99]
            ),
            [
                "-filter_complex",
                "[2:a:1]aresample=ochl=stereo[aout0];[2:a:0]anull[aout1];[2:a:1]anull[aout2]",
                "-map", "[aout0]",
                "-map", "[aout1]",
                "-map", "[aout2]"
            ]
        )
        XCTAssertEqual(
            FFMPEGConverter.av2MuxAudioRoutingArguments(
                inputIndex: 1,
                audioRoutingConfig: nil,
                defaultAudioStreamIndices: [0, 2]
            ),
            ["-map", "1:a:0", "-map", "1:a:2"]
        )
        XCTAssertEqual(
            FFMPEGConverter.av2MuxAudioRoutingArguments(
                inputIndex: 0,
                audioRoutingConfig: AudioRoutingConfig(inputTracks: tracks, outputTracks: []),
                defaultAudioStreamIndices: [0, 1]
            ),
            []
        )
        XCTAssertEqual(
            FFMPEGConverter.av2MuxAudioRoutingArguments(
                inputIndex: 10,
                audioRoutingConfig: config,
                defaultAudioStreamIndices: []
            ),
            [
                "-filter_complex",
                "[10:a:1]aresample=ochl=stereo[aout0];[10:a:0]anull[aout1];[10:a:1]anull[aout2]",
                "-map", "[aout0]",
                "-map", "[aout1]",
                "-map", "[aout2]"
            ]
        )
    }

    func testAV2OneShotHelperUsesBoundedRedactedRunnerPolicy() async throws {
        let executablePath = "/private/tools/ffmpeg"
        let inputPath = "/private/media/source.mov"
        let outputPath = "/private/media/output.mkv"
        let runner = RecordingSubprocessRunner { _, _ in
            successfulSubprocessResult()
        }

        let result = await FFMPEGConverter.runAV2Helper(
            executablePath: executablePath,
            arguments: ["-i", inputPath, "-y", outputPath],
            timeout: FFMPEGConverter.av2AudioHelperTimeout,
            subprocessRunner: runner
        )

        XCTAssertEqual(result, .success)
        let request = try XCTUnwrap(runner.lastRequest)
        XCTAssertEqual(request.executableURL.path, executablePath)
        XCTAssertEqual(request.arguments, ["-i", inputPath, "-y", outputPath])
        XCTAssertEqual(request.timeout, FFMPEGConverter.av2AudioHelperTimeout)
        XCTAssertEqual(request.standardOutputCaptureLimit, 0)
        XCTAssertEqual(
            request.standardErrorCaptureLimit,
            FFMPEGConverter.av2HelperDiagnosticCaptureLimit
        )
        XCTAssertNil(request.standardInput)
        XCTAssertTrue(request.sensitiveValues.contains(executablePath))
        XCTAssertTrue(request.sensitiveValues.contains(inputPath))
        XCTAssertTrue(request.sensitiveValues.contains(outputPath))
        XCTAssertFalse(request.redactedCommandDescription.contains(executablePath))
        XCTAssertFalse(request.redactedCommandDescription.contains(inputPath))
        XCTAssertFalse(request.redactedCommandDescription.contains(outputPath))
    }

    func testAV2OneShotHelperReturnsBoundedRedactedFailures() async {
        let privatePath = "/private/media/secret.mov"
        let nonzeroRunner = RecordingSubprocessRunner { _, _ in
            successfulSubprocessResult(
                standardError: "cannot read \(privatePath)",
                terminationStatus: 7
            )
        }
        let nonzero = await FFMPEGConverter.runAV2Helper(
            executablePath: "/private/tools/ffmpeg",
            arguments: ["-i", privatePath],
            timeout: .seconds(5),
            subprocessRunner: nonzeroRunner
        )
        guard case .failed(let nonzeroReason) = nonzero else {
            return XCTFail("Expected a nonzero helper result")
        }
        XCTAssertTrue(nonzeroReason.contains("status 7"))
        XCTAssertFalse(nonzeroReason.contains(privatePath))
        XCTAssertTrue(nonzeroReason.contains("<redacted>"))

        let timeoutRunner = RecordingSubprocessRunner { _, _ in
            throw SubprocessRunnerError.timedOut(
                command: "<redacted>",
                result: successfulSubprocessResult(
                    standardError: "stalled while reading \(privatePath)",
                    terminationStatus: SIGKILL
                )
            )
        }
        let timedOut = await FFMPEGConverter.runAV2Helper(
            executablePath: "/private/tools/ffmpeg",
            arguments: ["-i", privatePath],
            timeout: .seconds(5),
            subprocessRunner: timeoutRunner
        )
        guard case .failed(let timeoutReason) = timedOut else {
            return XCTFail("Expected a timed-out helper result")
        }
        XCTAssertTrue(timeoutReason.contains("timed out"))
        XCTAssertFalse(timeoutReason.contains(privatePath))

        let launchFailureRunner = RecordingSubprocessRunner { _, _ in
            throw NSError(
                domain: "AV2HelperTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "missing file at \(privatePath)"]
            )
        }
        let launchFailure = await FFMPEGConverter.runAV2Helper(
            executablePath: "/private/tools/ffmpeg",
            arguments: ["-i", privatePath],
            timeout: .seconds(5),
            subprocessRunner: launchFailureRunner
        )
        guard case .failed(let launchReason) = launchFailure else {
            return XCTFail("Expected a helper launch failure")
        }
        XCTAssertTrue(launchReason.contains("failed to start"))
        XCTAssertFalse(launchReason.contains(privatePath))
    }

    func testAV2OneShotHelperPropagatesTaskCancellation() async {
        let runner = CountingBlockingSubprocessRunner()
        let task = Task {
            await FFMPEGConverter.runAV2Helper(
                executablePath: "/private/tools/ffmpeg",
                arguments: ["-version"],
                timeout: .seconds(30),
                subprocessRunner: runner
            )
        }

        await runner.waitUntilStarted(count: 1)
        task.cancel()

        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(runner.cancelledCount, 1)
    }

    func testAV2AudioHelperCancellationIsIsolatedAcrossReplacement() async {
        let runner = CountingBlockingSubprocessRunner()
        let converter = FFMPEGConverter(subprocessRunner: runner)
        let source = FFMPEGConverter.PackageAudioInput(
            arguments: ["-i", "/private/media/source.mov"],
            probeURL: nil,
            ffmpegInputIndex: 0,
            assumesSingleAudioStreamIfProbeUnavailable: false
        )
        let routing = AudioRoutingConfig(
            inputTracks: [audioTrack(index: 0, channels: 2)],
            outputTracks: [OutputTrack(streamIndex: 0)]
        )

        let first = Task {
            await converter.extractAudioTracksForAV2Mux(
                source: source,
                audioRoutingConfig: routing,
                trimStart: nil,
                trimEnd: nil,
                ffmpegPath: "/private/tools/ffmpeg"
            )
        }
        await runner.waitUntilStarted(count: 1)

        let replacement = Task {
            await converter.extractAudioTracksForAV2Mux(
                source: source,
                audioRoutingConfig: routing,
                trimStart: nil,
                trimEnd: nil,
                ffmpegPath: "/private/tools/ffmpeg"
            )
        }
        await runner.waitUntilStarted(count: 2)

        guard case .cancelled = await first.value else {
            return XCTFail("Superseded AV2 helper did not report cancellation")
        }
        await converter.cancelConversion()
        guard case .cancelled = await replacement.value else {
            return XCTFail("Active AV2 helper did not report cancellation")
        }
        XCTAssertEqual(runner.cancelledCount, 2)
    }

    func testAV2AudioMuxDoesNotLaunchHelperAfterCancellationDuringProbes() async throws {
        let sourceURL = URL(fileURLWithPath: "/private/media/source.mov")
        let source = FFMPEGConverter.PackageAudioInput(
            arguments: ["-i", sourceURL.path],
            probeURL: sourceURL,
            ffmpegInputIndex: 0,
            assumesSingleAudioStreamIfProbeUnavailable: false
        )

        do {
            let provider = BlockingAudioStreamProvider()
            let runner = RecordingSubprocessRunner { _, _ in
                XCTFail("A helper launched after cancellation during the source probe")
                return successfulSubprocessResult()
            }
            let converter = FFMPEGConverter(subprocessRunner: runner)
            let task = Task {
                await converter.extractAudioTracksForAV2Mux(
                    source: source,
                    audioRoutingConfig: nil,
                    trimStart: nil,
                    trimEnd: nil,
                    ffmpegPath: "/private/tools/ffmpeg",
                    audioStreamProvider: { await provider.fetch(for: $0) }
                )
            }

            await provider.waitUntilStarted()
            task.cancel()
            await provider.resume(with: [])

            guard case .cancelled = await task.value else {
                return XCTFail("Cancellation during the source probe was ignored")
            }
            XCTAssertNil(runner.lastRequest)
        }

        do {
            let provider = BlockingAudioStreamProvider()
            let runner = SequencedRecordingSubprocessRunner { index, request, _ in
                XCTAssertEqual(index, 0, "A packet-extraction helper launched after cancellation")
                if let outputPath = request.arguments.last {
                    try Data("routed audio".utf8).write(to: URL(fileURLWithPath: outputPath))
                }
                return successfulSubprocessResult()
            }
            let converter = FFMPEGConverter(subprocessRunner: runner)
            let routing = AudioRoutingConfig(
                inputTracks: [audioTrack(index: 0, channels: 2)],
                outputTracks: [OutputTrack(streamIndex: 0)]
            )
            let task = Task {
                await converter.extractAudioTracksForAV2Mux(
                    source: source,
                    audioRoutingConfig: routing,
                    trimStart: nil,
                    trimEnd: nil,
                    ffmpegPath: "/private/tools/ffmpeg",
                    audioStreamProvider: { await provider.fetch(for: $0) }
                )
            }

            await provider.waitUntilStarted()
            task.cancel()
            await provider.resume(with: [
                FFMPEGProbeService.AudioStreamInfo(
                    index: 0,
                    channels: 2,
                    channelLayout: "stereo",
                    codecName: "aac"
                )
            ])

            guard case .cancelled = await task.value else {
                return XCTFail("Cancellation during the routed-output probe was ignored")
            }
            XCTAssertEqual(runner.requests.count, 1)
        }
    }

    func testAV2ConcatHelperRedactsIndirectSourcePaths() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AV2ConcatRedaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let indirectSourcePath = "/private/media/second secret clip.mov"
        let concatURL = directory.appendingPathComponent("inputs.ffconcat")
        try "file '\(indirectSourcePath)'".write(to: concatURL, atomically: true, encoding: .utf8)
        let source = FFMPEGConverter.PackageAudioInput(
            arguments: ["-f", "concat", "-safe", "0", "-i", concatURL.path],
            probeURL: URL(fileURLWithPath: "/private/media/first.mov"),
            ffmpegInputIndex: 0,
            assumesSingleAudioStreamIfProbeUnavailable: false
        )
        let routing = AudioRoutingConfig(
            inputTracks: [audioTrack(index: 0, channels: 2)],
            outputTracks: [OutputTrack(streamIndex: 0)]
        )
        let runner = RecordingSubprocessRunner { _, _ in
            successfulSubprocessResult(
                standardError: "could not open \(indirectSourcePath)",
                terminationStatus: 2
            )
        }

        let result = await FFMPEGConverter(subprocessRunner: runner).extractAudioTracksForAV2Mux(
            source: source,
            audioRoutingConfig: routing,
            trimStart: nil,
            trimEnd: nil,
            ffmpegPath: "/private/tools/ffmpeg"
        )

        guard case .failed(let reason) = result else {
            return XCTFail("Expected the routed concat helper to fail")
        }
        XCTAssertFalse(reason.contains(indirectSourcePath))
        XCTAssertTrue(reason.contains("<redacted>"))
        XCTAssertTrue(try XCTUnwrap(runner.lastRequest).sensitiveValues.contains(indirectSourcePath))
    }

    func testADTSChannelConfigurationMappingRejectsUnsupportedLayouts() {
        XCTAssertNil(FFMPEGConverter.adtsChannelCount(forConfiguration: 0))
        XCTAssertEqual(FFMPEGConverter.adtsChannelCount(forConfiguration: 1), 1)
        XCTAssertEqual(FFMPEGConverter.adtsChannelCount(forConfiguration: 2), 2)
        XCTAssertEqual(FFMPEGConverter.adtsChannelCount(forConfiguration: 6), 6)
        XCTAssertEqual(FFMPEGConverter.adtsChannelCount(forConfiguration: 7), 8)
        XCTAssertNil(FFMPEGConverter.adtsChannelCount(forConfiguration: 8))
    }

    func testGeneratedAV2AudioRoutingProducesOrderedTracksForAACAndOpus() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterAV2AudioRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("source.mkv")
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "color=c=black:s=16x16:r=24:d=0.25",
            "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo:d=0.25",
            "-f", "lavfi", "-i", "anullsrc=r=48000:cl=5.1:d=0.25",
            "-map", "0:v:0", "-map", "1:a:0", "-map", "2:a:0",
            "-c:v", "ffv1", "-c:a", "pcm_s16le", sourceURL.path
        ])

        let tracks = [audioTrack(index: 0, channels: 2), audioTrack(index: 1, channels: 6)]
        let routing = AudioRoutingConfig(
            inputTracks: tracks,
            outputTracks: [
                OutputTrack(streamIndex: 1, downmixToStereo: true),
                OutputTrack(streamIndex: 0),
                OutputTrack(streamIndex: 1)
            ]
        )
        let source = FFMPEGConverter.PackageAudioInput(
            arguments: ["-i", sourceURL.path],
            probeURL: sourceURL,
            ffmpegInputIndex: 0,
            assumesSingleAudioStreamIfProbeUnavailable: false
        )

        for codec in [AV2AudioCodec.aac, .opus] {
            let result = try await withPresetSettingsAsync([
                AppConstants.av2AudioCodecKey: codec.rawValue,
                AppConstants.av2AudioBitrateKey: AppConstants.defaultAV2AudioBitrate
            ]) {
                await FFMPEGConverter().extractAudioTracksForAV2Mux(
                    source: source,
                    audioRoutingConfig: routing,
                    trimStart: nil,
                    trimEnd: nil,
                    ffmpegPath: ffmpegExecutableURL.path
                )
            }

            guard case .tracks(let extractedTracks) = result else {
                XCTFail("AV2 \(codec.rawValue) routing did not produce audio tracks")
                continue
            }
            XCTAssertEqual(extractedTracks.count, 3, codec.rawValue)
            XCTAssertEqual(extractedTracks.map(\.info.channels), [2, 2, 6], codec.rawValue)
            XCTAssertEqual(extractedTracks.map(\.info.codecID), Array(repeating: codec.matroskaCodecID, count: 3))
            XCTAssertTrue(extractedTracks.allSatisfy { !$0.frames.isEmpty }, codec.rawValue)
        }

        let defaultResult = try await withPresetSettingsAsync([
            AppConstants.av2AudioCodecKey: AV2AudioCodec.aac.rawValue
        ]) {
            await FFMPEGConverter().extractAudioTracksForAV2Mux(
                source: source,
                audioRoutingConfig: nil,
                trimStart: nil,
                trimEnd: nil,
                ffmpegPath: ffmpegExecutableURL.path
            )
        }
        guard case .tracks(let defaultTracks) = defaultResult else {
            return XCTFail("Default AV2 routing did not preserve every decodable audio track")
        }
        XCTAssertEqual(defaultTracks.map(\.info.channels), [2, 6])

        var splitRouting = AudioRoutingConfig(inputTracks: tracks)
        splitRouting.setChannelOperation(.splitToMono(trackIndex: 0))
        let splitResult = try await withPresetSettingsAsync([
            AppConstants.av2AudioCodecKey: AV2AudioCodec.aac.rawValue
        ]) {
            await FFMPEGConverter().extractAudioTracksForAV2Mux(
                source: source,
                audioRoutingConfig: splitRouting,
                trimStart: nil,
                trimEnd: nil,
                ffmpegPath: ffmpegExecutableURL.path
            )
        }
        guard case .tracks(let splitTracks) = splitResult else {
            return XCTFail("AV2 split-to-mono routing did not survive audio staging")
        }
        XCTAssertEqual(splitTracks.map(\.info.channels), [1, 1])

        var extractRouting = AudioRoutingConfig(inputTracks: tracks)
        extractRouting.setChannelOperation(.extractChannel(trackIndex: 1, channelIndex: 4, channelName: "Ls"))
        let extractResult = try await withPresetSettingsAsync([
            AppConstants.av2AudioCodecKey: AV2AudioCodec.aac.rawValue
        ]) {
            await FFMPEGConverter().extractAudioTracksForAV2Mux(
                source: source,
                audioRoutingConfig: extractRouting,
                trimStart: nil,
                trimEnd: nil,
                ffmpegPath: ffmpegExecutableURL.path
            )
        }
        guard case .tracks(let extractTracks) = extractResult else {
            return XCTFail("AV2 extract-channel routing did not survive audio staging")
        }
        XCTAssertEqual(extractTracks.map(\.info.channels), [1])

        let invalidRouting = AudioRoutingConfig(
            inputTracks: tracks,
            outputTracks: [OutputTrack(streamIndex: 99)]
        )
        let invalidResult = try await withPresetSettingsAsync([
            AppConstants.av2AudioCodecKey: AV2AudioCodec.aac.rawValue
        ]) {
            await FFMPEGConverter().extractAudioTracksForAV2Mux(
                source: source,
                audioRoutingConfig: invalidRouting,
                trimStart: nil,
                trimEnd: nil,
                ffmpegPath: ffmpegExecutableURL.path
            )
        }
        guard case .failed(let reason) = invalidResult else {
            return XCTFail("Invalid selected AV2 audio was silently discarded")
        }
        XCTAssertFalse(reason.isEmpty)

        let unreadableURL = temporaryDirectory.appendingPathComponent("unreadable.mkv")
        try Data("not a Matroska file".utf8).write(to: unreadableURL)
        let unreadableSource = FFMPEGConverter.PackageAudioInput(
            arguments: ["-i", unreadableURL.path],
            probeURL: unreadableURL,
            ffmpegInputIndex: 0,
            assumesSingleAudioStreamIfProbeUnavailable: false
        )
        let unreadableResult = await FFMPEGConverter().extractAudioTracksForAV2Mux(
            source: unreadableSource,
            audioRoutingConfig: nil,
            trimStart: nil,
            trimEnd: nil,
            ffmpegPath: ffmpegExecutableURL.path
        )
        guard case .failed(let probeReason) = unreadableResult else {
            return XCTFail("Unreadable default AV2 audio was treated as a silent source")
        }
        XCTAssertTrue(probeReason.contains("inspect"))
    }

    func testAV2MatroskaMetadataUsesSharedCommentAndTimecodePolicy() throws {
        try withPresetSettings([
            AppConstants.commentPrefixKey: "Prefix",
            AppConstants.commentSuffixKey: "Suffix",
            AppConstants.commentSeparatorKey: " | ",
            AppConstants.commentDateFormatKey: "yyyy-MM-dd",
            AppConstants.dateTagPrefixKey: "Date"
        ]) {
            let comment = try XCTUnwrap(FFMPEGCommandBuilder.commentMetadataValue(
                comment: "Hei fra AV2 🎬",
                includeDateTag: true,
                date: Date(timeIntervalSince1970: 0)
            ))
            XCTAssertEqual(comment, "Date: 1970-01-01 | Prefix | Hei fra AV2 🎬 | Suffix")

            let timecode = try XCTUnwrap(FFMPEGCommandBuilder.resolvedTimecode(
                timecodeConfig: TimecodeConfig(mode: .preserveSource),
                sourceMetadata: videoMetadata(timecode: "01:02:03:12", frameRate: 24),
                trimStart: 2
            ))
            XCTAssertEqual(timecode, "01:02:05:12")

            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("AagedalMediaConverterMatroskaMetadataTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

            let outputURL = temporaryDirectory.appendingPathComponent("metadata.mkv")
            try MatroskaMuxer.write(
                to: outputURL,
                video: MatroskaMuxer.VideoTrackInfo(
                    codecPrivate: nil,
                    width: 16,
                    height: 16,
                    fpsNumerator: 24,
                    fpsDenominator: 1
                ),
                videoFrames: [MatroskaMuxer.VideoFrame(data: Data([0x12, 0x34]), isKeyframe: true)],
                audio: nil,
                audioFrames: [],
                metadata: MatroskaMuxer.Metadata(comment: comment, timecode: timecode)
            )

            let data = try Data(contentsOf: outputURL)
            XCTAssertNotNil(data.range(of: Data("COMMENT".utf8)))
            XCTAssertNotNil(data.range(of: Data(comment.utf8)))
            XCTAssertNotNil(data.range(of: Data(timecode.utf8)))
            let firstTimecodeTag = try XCTUnwrap(data.range(of: Data("TIMECODE".utf8)))
            XCTAssertNotNil(data[firstTimecodeTag.upperBound...].range(of: Data("TIMECODE".utf8)))
            XCTAssertNotNil(data.range(of: Data([0x63, 0xC0, 0x80])))
            XCTAssertNotNil(data.range(of: Data([0x63, 0xC5, 0x81, 0x01])))
        }
    }

    func testMatroskaMuxerWritesOrderedMultipleAudioTracksAndBlocks() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterMatroskaAudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let outputURL = temporaryDirectory.appendingPathComponent("multi-audio.mkv")
        let audioTracks = [
            MatroskaMuxer.AudioTrack(
                info: MatroskaMuxer.AudioTrackInfo(
                    codecID: "A_AAC", codecPrivate: Data([0x12, 0x10]), sampleRate: 48_000, channels: 2
                ),
                frames: [MatroskaMuxer.AudioFrame(data: Data([0xA1]), durationSamples: 1_024)]
            ),
            MatroskaMuxer.AudioTrack(
                info: MatroskaMuxer.AudioTrackInfo(
                    codecID: "A_OPUS", codecPrivate: Data("OpusHead".utf8), sampleRate: 48_000, channels: 1
                ),
                frames: [MatroskaMuxer.AudioFrame(data: Data([0xB2]), durationSamples: 960)]
            )
        ]
        try MatroskaMuxer.write(
            to: outputURL,
            video: MatroskaMuxer.VideoTrackInfo(
                codecPrivate: nil,
                width: 16,
                height: 16,
                fpsNumerator: 24,
                fpsDenominator: 1
            ),
            videoFrames: [MatroskaMuxer.VideoFrame(data: Data([0x12, 0x34]), isKeyframe: true)],
            audioTracks: audioTracks
        )

        let data = try Data(contentsOf: outputURL)
        let aacCodec = try XCTUnwrap(data.range(of: Data("A_AAC".utf8)))
        let opusCodec = try XCTUnwrap(data.range(of: Data("A_OPUS".utf8)))
        XCTAssertLessThan(aacCodec.lowerBound, opusCodec.lowerBound)
        XCTAssertNotNil(data.range(of: Data([0xD7, 0x81, 0x02])))
        XCTAssertNotNil(data.range(of: Data([0xD7, 0x81, 0x03])))
        XCTAssertNotNil(data.range(of: Data([0x88, 0x81, 0x01])))
        XCTAssertNotNil(data.range(of: Data([0x88, 0x81, 0x00])))
        XCTAssertNotNil(data.range(of: Data([0x82, 0x00, 0x00, 0x80, 0xA1])))
        XCTAssertNotNil(data.range(of: Data([0x83, 0x00, 0x00, 0x80, 0xB2])))
    }

    func testAV2RejectsAdditionalFFmpegOutputArgumentsInsteadOfIgnoringThem() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AagedalMediaConverterAV2ArgumentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let inputURL = temporaryDirectory.appendingPathComponent("source.mov")
        try Data([0]).write(to: inputURL)
        let result = await runConversion(ConversionRequest(
            inputURL: inputURL,
            outputURL: temporaryDirectory.appendingPathComponent("output"),
            preset: .av2,
            additionalOutputArguments: ["-metadata", "title=Must not be ignored"]
        ))

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorReason, "AV2 export does not support additional FFmpeg output arguments")
    }

    func testAudioRoutingPreservesSelectionOrderAndDuplicateTracks() {
        let tracks = [audioTrack(index: 0, channels: 2), audioTrack(index: 1, channels: 1)]
        let config = AudioRoutingConfig(
            inputTracks: tracks,
            outputTracks: [
                OutputTrack(streamIndex: 1),
                OutputTrack(streamIndex: 0),
                OutputTrack(streamIndex: 1)
            ]
        )

        XCTAssertEqual(
            AudioRoutingService.buildFFmpegMapArguments(config: config),
            ["-map", "0:a:1", "-map", "0:a:0", "-map", "0:a:1"]
        )
    }

    func testAudioRoutingSupportsRemovingAllTracks() {
        let config = AudioRoutingConfig(
            inputTracks: [audioTrack(index: 0, channels: 2)],
            outputTracks: []
        )

        XCTAssertEqual(AudioRoutingService.buildFFmpegMapArguments(config: config), [])
    }

    func testAudioRoutingBuildsMixedDownmixAndPassThroughFilters() {
        let tracks = [audioTrack(index: 0, channels: 6), audioTrack(index: 1, channels: 2)]
        let config = AudioRoutingConfig(
            inputTracks: tracks,
            outputTracks: [
                OutputTrack(streamIndex: 0, downmixToStereo: true),
                OutputTrack(streamIndex: 1)
            ]
        )

        XCTAssertEqual(
            AudioRoutingService.buildFFmpegMapArguments(config: config),
            [
                "-filter_complex",
                "[0:a:0]aresample=ochl=stereo[aout0];[0:a:1]anull[aout1]",
                "-map", "[aout0]",
                "-map", "[aout1]"
            ]
        )
    }

    func testAudioRoutingBuildsChannelOperationMatrix() {
        let tracks = [
            audioTrack(index: 0, channels: 1, layout: "mono"),
            audioTrack(index: 1, channels: 1, layout: "mono"),
            audioTrack(index: 2, channels: 2, layout: "stereo"),
            audioTrack(index: 3, channels: 6, layout: "5.1")
        ]
        var config = AudioRoutingConfig(inputTracks: tracks)

        config.setChannelOperation(.mergeToStereo(trackIndices: [0, 1]))
        XCTAssertEqual(
            AudioRoutingService.buildFFmpegMapArguments(config: config),
            ["-filter_complex", "[0:a:0][0:a:1]amerge=inputs=2,pan=stereo|c0<c0+c2|c1<c1+c3[aout]", "-map", "[aout]"]
        )

        config.setChannelOperation(.splitToMono(trackIndex: 2))
        XCTAssertEqual(
            AudioRoutingService.buildFFmpegMapArguments(config: config),
            [
                "-filter_complex",
                "[0:a:2]channelsplit=channel_layout=stereo[splitL][splitR];[splitL]aformat=channel_layouts=mono[L];[splitR]aformat=channel_layouts=mono[R]",
                "-map", "[L]", "-map", "[R]"
            ]
        )

        config.setChannelOperation(.swapChannels(trackIndex: 2))
        XCTAssertEqual(
            AudioRoutingService.buildFFmpegMapArguments(config: config),
            ["-filter_complex", "[0:a:2]pan=stereo|c0=c1|c1=c0[aout]", "-map", "[aout]"]
        )

        config.setChannelOperation(.extractChannel(trackIndex: 3, channelIndex: 4, channelName: "Ls"))
        XCTAssertEqual(
            AudioRoutingService.buildFFmpegMapArguments(config: config),
            ["-filter_complex", "[0:a:3]pan=mono|c0=c4[aout]", "-map", "[aout]"]
        )
    }

    func testInvalidChannelOperationFallsBackToSelectedTracks() {
        let tracks = [audioTrack(index: 0, channels: 1), audioTrack(index: 1, channels: 2)]
        var config = AudioRoutingConfig(
            inputTracks: tracks,
            outputTracks: [OutputTrack(streamIndex: 1)]
        )
        config.setChannelOperation(.splitToMono(trackIndex: 0))

        XCTAssertEqual(
            AudioRoutingService.buildFFmpegMapArguments(config: config),
            ["-map", "0:a:1"]
        )
    }

    func testApplyingAudioRoutingReusesVideoMapWhenAudioMapComesFirst() {
        var arguments = [
            "-map", "0:a",
            "-map", "0:v:0",
            "-c:v", "libx264",
            "-c:a", "aac"
        ]
        let config = AudioRoutingConfig(
            inputTracks: [audioTrack(index: 0, channels: 2), audioTrack(index: 1, channels: 1)],
            outputTracks: [OutputTrack(streamIndex: 1)]
        )

        FFMPEGCommandBuilder.applyAudioRouting(config: config, to: &arguments)

        XCTAssertEqual(arguments.adjacentPairCount("-map", "0:v:0"), 1)
        XCTAssertEqual(arguments.adjacentPairCount("-map", "0:a:1"), 1)
        XCTAssertFalse(arguments.containsAdjacent("-map", "0:a"))
    }

    func testSubtitleMappingOnlyTargetsSupportedContainers() {
        XCTAssertEqual(
            FFMPEGCommandBuilder.subtitleArguments(keepSubtitles: true, outputExtension: "MKV"),
            ["-map", "0:s?", "-c:s", "copy"]
        )
        for outputExtension in ["mp4", "mov"] {
            XCTAssertEqual(
                FFMPEGCommandBuilder.subtitleArguments(keepSubtitles: true, outputExtension: outputExtension),
                ["-map", "0:s?", "-c:s", "mov_text"],
                outputExtension
            )
        }
        for outputExtension in ["png", "avif", "mxf", "ivf", "wav"] {
            XCTAssertTrue(
                FFMPEGCommandBuilder.subtitleArguments(keepSubtitles: true, outputExtension: outputExtension).isEmpty,
                outputExtension
            )
        }
        XCTAssertTrue(
            FFMPEGCommandBuilder.subtitleArguments(keepSubtitles: false, outputExtension: "mkv").isEmpty
        )
    }

    func testAVCIntraMCALabelOverrideLabelsSourceChannelsButNotPadding() throws {
        try withDefaultPresetSettings {
            let content = try XCTUnwrap(MCALabelsBuilder.buildAVCIntraLabelsFile(
                inputStreams: [
                    .init(audioRelativeIndex: 0, channelCount: 2, channelLayout: "stereo", sampleRate: 48_000)
                ],
                inputMCALabels: [],
                overrides: [
                    0: MCALabelOverride(soundfield: .stereo, audioElement: .mainProgram)
                ],
                outputTrackCount: 4
            ))

            XCTAssertTrue(content.contains("0\nchL\nsgST, id=sg1\nggMPg, id=gosg1"), content)
            XCTAssertTrue(content.contains("1\nchR\nsgST, id=sg1, repeat=false\nggMPg, id=gosg1, repeat=false"), content)
            XCTAssertFalse(content.contains("\n2\n"), content)
        }
    }

    func testAVCIntraMCALabelsPreserveMatchingInputDualMonoLayout() throws {
        try withDefaultPresetSettings {
            let content = try XCTUnwrap(MCALabelsBuilder.buildAVCIntraLabelsFile(
                inputStreams: [
                    .init(audioRelativeIndex: 0, channelCount: 2, channelLayout: "stereo", sampleRate: 48_000)
                ],
                inputMCALabels: [
                    AudioTrackMCALabels(
                        trackNumber: 1,
                        channelCount: 2,
                        sampleRate: 48_000,
                        soundfieldGroup: "Dual Mono",
                        audioElement: nil,
                        channelLabels: ["M1", "M2"]
                    )
                ],
                outputTrackCount: 2
            ))

            XCTAssertTrue(content.contains("chM1"), content)
            XCTAssertTrue(content.contains("chM2"), content)
            XCTAssertTrue(content.contains("sgDM"), content)
            XCTAssertFalse(content.contains("gg"), content)
        }
    }

    func testAVCIntraMCALabelsOmitUnknownLayouts() throws {
        try withDefaultPresetSettings {
            XCTAssertNil(MCALabelsBuilder.buildAVCIntraLabelsFile(
                inputStreams: [
                    .init(audioRelativeIndex: 0, channelCount: 3, channelLayout: "3.0", sampleRate: 48_000)
                ],
                inputMCALabels: [],
                outputTrackCount: 4
            ))
        }
    }

    private func presetVideoArguments() -> [String] {
        [
            "-vf",
            "scale='trunc(ih*dar/2)*2:trunc(ih/2)*2',setsar=1/1,scale=w='if(lte(iw,ih),1080,-2)':h='if(lte(iw,ih),-2,1080)'"
        ]
    }

    private func centeredSquareCropForAnamorphicHD() -> CropConfig {
        let cropWidth = 1080.0 / 1920.0
        return CropConfig(
            normalizedRect: CropRect(x: (1 - cropWidth) / 2, y: 0, width: cropWidth, height: 1)
        )
    }

    private func videoFilter(in args: [String]) throws -> String {
        let index = try XCTUnwrap(args.firstIndex(of: "-vf"))
        return try XCTUnwrap(args.indices.contains(index + 1) ? args[index + 1] : nil)
    }

    private func audioTrack(index: Int, channels: Int, layout: String? = nil) -> AudioTrackInfo {
        AudioTrackInfo(
            streamIndex: index,
            channels: channels,
            channelLayout: layout,
            codec: "pcm_s24le",
            codecLongName: nil,
            sampleRate: 48_000
        )
    }

    private func videoMetadata(
        timecode: String?,
        frameRate: Double,
        duration: Double? = 60
    ) -> VideoMetadata {
        VideoMetadata(
            duration: duration,
            formatName: "mov",
            containerLongName: "QuickTime / MOV",
            sizeBytes: nil,
            bitRate: nil,
            comment: nil,
            timecode: timecode,
            timecodes: [],
            frameCount: nil,
            containerCreationDate: nil,
            containerModificationDate: nil,
            title: nil,
            artist: nil,
            gpsLatitude: nil,
            gpsLongitude: nil,
            gpsAltitude: nil,
            warnings: [],
            videoStreams: [
                VideoMetadata.VideoStream(
                    codec: "h264",
                    codecLongName: nil,
                    profile: nil,
                    width: 1920,
                    height: 1080,
                    pixelFormat: "yuv420p",
                    hasAlpha: false,
                    pixelAspectRatio: VideoMetadata.Ratio(numerator: 1, denominator: 1),
                    displayAspectRatio: VideoMetadata.Ratio(numerator: 16, denominator: 9),
                    frameRate: VideoMetadata.FrameRate(double: frameRate),
                    bitDepth: 8,
                    bitRate: nil,
                    duration: 60,
                    chromaSubsampling: "4:2:0",
                    colorPrimaries: nil,
                    colorTransfer: nil,
                    colorSpace: nil,
                    colorRange: nil,
                    chromaLocation: nil,
                    fieldOrder: nil,
                    isInterlaced: false,
                    title: nil,
                    isDefault: true,
                    isForced: false
                )
            ],
            audioStreams: [],
            subtitleStreams: []
        )
    }

    private func videoCodec(in arguments: [String]) -> String? {
        optionValue(in: arguments, options: ["-c:v", "-vcodec", "-c"])
    }

    private func audioCodec(in arguments: [String]) -> String? {
        optionValue(in: arguments, options: ["-c:a", "-acodec", "-c"])
    }

    private func optionValue(in arguments: [String], options: [String]) -> String? {
        for option in options {
            guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
                continue
            }
            return arguments[index + 1]
        }
        return nil
    }

    private func withDefaultPresetSettings(_ body: () throws -> Void) throws {
        try withPresetSettings([:], body)
    }

    private func withPresetSettings(_ overrides: [String: Any], _ body: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let argumentDomain = "NSArgumentDomain"
        let originalArguments = defaults.volatileDomain(forName: argumentDomain)
        var testArguments = originalArguments
        testArguments.merge(defaultPresetSettings) { _, testValue in testValue }
        testArguments.merge(overrides) { _, testValue in testValue }

        defaults.removeVolatileDomain(forName: argumentDomain)
        defaults.setVolatileDomain(testArguments, forName: argumentDomain)
        defer {
            defaults.removeVolatileDomain(forName: argumentDomain)
            defaults.setVolatileDomain(originalArguments, forName: argumentDomain)
        }

        try body()
    }

    private func withPresetSettingsAsync<Result>(
        _ overrides: [String: Any],
        _ body: () async throws -> Result
    ) async throws -> Result {
        let defaults = UserDefaults.standard
        let argumentDomain = "NSArgumentDomain"
        let originalArguments = defaults.volatileDomain(forName: argumentDomain)
        var testArguments = originalArguments
        testArguments.merge(defaultPresetSettings) { _, testValue in testValue }
        testArguments.merge(overrides) { _, testValue in testValue }

        defaults.removeVolatileDomain(forName: argumentDomain)
        defaults.setVolatileDomain(testArguments, forName: argumentDomain)
        defer {
            defaults.removeVolatileDomain(forName: argumentDomain)
            defaults.setVolatileDomain(originalArguments, forName: argumentDomain)
        }

        return try await body()
    }

    private var defaultPresetSettings: [String: Any] {
        [
            AppConstants.preserveMetadataPreferenceKey: false,
            AppConstants.animatedStillFormatKey: AppConstants.defaultAnimatedStillFormat,
            AppConstants.h264EncoderKey: AppConstants.defaultH264Encoder,
            AppConstants.h264ContainerKey: AppConstants.defaultH264Container,
            AppConstants.h264AudioFormatKey: AppConstants.defaultH264AudioFormat,
            AppConstants.h265EncoderKey: AppConstants.defaultH265Encoder,
            AppConstants.h265ContainerKey: AppConstants.defaultH265Container,
            AppConstants.h265AudioFormatKey: AppConstants.defaultH265AudioFormat,
            AppConstants.av1ContainerKey: AppConstants.defaultAV1Container,
            AppConstants.av1AudioFormatKey: AppConstants.defaultAV1AudioFormat,
            AppConstants.tvFramerateModeKey: AppConstants.defaultTVFramerateMode,
            AppConstants.tvResolutionLimitKey: AppConstants.defaultTVResolutionLimit,
            AppConstants.avcIntraClassKey: AppConstants.defaultAVCIntraClass,
            AppConstants.avcIntraAudioChannelsKey: AppConstants.defaultAVCIntraAudioChannels,
            AppConstants.avcIntraDefaultMCASoundfield1ChKey: "",
            AppConstants.avcIntraDefaultMCASoundfield2ChKey: "",
            AppConstants.avcIntraDefaultMCASoundfield6ChKey: "",
            AppConstants.avcIntraDefaultMCASoundfield8ChKey: "",
            AppConstants.proResProfileKey: ProResProfile.standard.rawValue,
            AppConstants.proxyCodecKey: AppConstants.defaultProxyCodec,
            AppConstants.proxyResolutionLimitKey: AppConstants.defaultProxyResolutionLimit,
            AppConstants.streamCopyContainerKey: AppConstants.defaultStreamCopyContainer,
            AppConstants.audioOnlyFormatKey: AppConstants.defaultAudioOnlyFormat,
            AppConstants.audioOnlyBitDepthKey: AppConstants.defaultAudioOnlyBitDepth,
            AppConstants.imageSequenceExportFormatKey: AppConstants.defaultImageSequenceExportFormat,
            AppConstants.dcpResolutionKey: AppConstants.defaultDCPResolution,
            AppConstants.dcpFrameRateKey: AppConstants.defaultDCPFrameRate,
            AppConstants.dcpBitrateKey: AppConstants.defaultDCPBitrate,
            AppConstants.dcpScalingModeKey: AppConstants.defaultDCPScalingMode,
            AppConstants.imfResolutionKey: AppConstants.defaultIMFResolution,
            AppConstants.imfFrameRateKey: AppConstants.defaultIMFFrameRate,
            AppConstants.imfScalingModeKey: AppConstants.defaultIMFScalingMode,
            AppConstants.imfJ2KColorEncodingKey: AppConstants.defaultIMFJ2KColorEncoding,
            AppConstants.imfJ2KBitrateKey: AppConstants.defaultIMFJ2KBitrate,
            AppConstants.imfProResProfileKey: AppConstants.defaultIMFProResProfile,
            AppConstants.av2ContainerKey: AppConstants.defaultAV2Container
        ]
    }

    @discardableResult
    private func runFFmpeg(_ arguments: [String]) throws -> String {
        let executableURL = ffmpegExecutableURL

        let process = Process()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError

        try process.run()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let log = String(decoding: errorData, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, log)
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "AagedalMediaConverterTests.FFmpeg",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: log]
            )
        }
        return log
    }

    private func makeVideoFixture(at url: URL) throws {
        try runFFmpeg([
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=64x48:rate=24:duration=1",
            "-c:v", "libx264", "-pix_fmt", "yuv420p",
            url.path
        ])
    }

    private func runConversion(
        _ request: ConversionRequest
    ) async -> (success: Bool, errorReason: String?) {
        let converter = FFMPEGConverter()
        return await runConversion(request, using: converter)
    }

    private func runConversion(
        _ request: ConversionRequest,
        using converter: FFMPEGConverter,
        progressUpdate: @escaping @Sendable (Double, String?) -> Void = { _, _ in }
    ) async -> (success: Bool, errorReason: String?) {
        return await withCheckedContinuation { continuation in
            Task {
                await converter.convert(
                    request: request,
                    progressUpdate: progressUpdate,
                    completion: { success, errorReason in
                        continuation.resume(returning: (success, errorReason))
                    }
                )
            }
        }
    }

    private func runConversion(
        _ request: ConversionRequest,
        cancellingAfter delayNanoseconds: UInt64
    ) async -> (success: Bool, errorReason: String?) {
        let converter = FFMPEGConverter()
        return await withCheckedContinuation { continuation in
            Task {
                await converter.convert(
                    request: request,
                    progressUpdate: { _, _ in },
                    completion: { success, errorReason in
                        continuation.resume(returning: (success, errorReason))
                    }
                )
                try? await Task.sleep(nanoseconds: delayNanoseconds)
                await converter.cancelConversion()
            }
        }
    }

    private var ffmpegExecutableURL: URL {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceBinary = sourceRoot
            .appendingPathComponent("Aagedal Media Converter", isDirectory: true)
            .appendingPathComponent("Binaries", isDirectory: true)
            .appendingPathComponent("ffmpeg")
        return Bundle.main.url(forResource: "ffmpeg", withExtension: nil) ?? sourceBinary
    }

    private func inspectMedia(at url: URL) throws -> String {
        try runFFmpeg([
            "-hide_banner", "-i", url.path,
            "-map", "0", "-c", "copy",
            "-f", "null", "-"
        ])
    }

    private func assertPackingList(
        at packingListURL: URL,
        describes expectedFiles: [URL],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let assets = try xmlAssets(at: packingListURL)
        XCTAssertEqual(assets.count, expectedFiles.count, file: file, line: line)
        XCTAssertEqual(Set(assets.compactMap(\.id)).count, expectedFiles.count, file: file, line: line)

        for expectedFile in expectedFiles {
            let asset = try XCTUnwrap(
                assets.first { $0.originalFileName == expectedFile.lastPathComponent },
                "Missing PKL asset for \(expectedFile.lastPathComponent)",
                file: file,
                line: line
            )
            XCTAssertEqual(asset.size, SMPTEPackageUtils.fileSize(at: expectedFile), file: file, line: line)
            let expectedHash = try XCTUnwrap(
                SMPTEPackageUtils.computeSHA1(for: expectedFile),
                file: file,
                line: line
            )
            XCTAssertEqual(
                asset.hash,
                SMPTEPackageUtils.base64SHA1(hex: expectedHash),
                file: file,
                line: line
            )
        }
    }

    private func assertAssetMap(
        at assetMapURL: URL,
        describes expectedFiles: [URL],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let assets = try xmlAssets(at: assetMapURL)
        XCTAssertEqual(assets.count, expectedFiles.count, file: file, line: line)
        XCTAssertEqual(Set(assets.compactMap(\.id)).count, expectedFiles.count, file: file, line: line)

        for expectedFile in expectedFiles {
            let asset = try XCTUnwrap(
                assets.first { $0.path == expectedFile.lastPathComponent },
                "Missing ASSETMAP asset for \(expectedFile.lastPathComponent)",
                file: file,
                line: line
            )
            XCTAssertEqual(asset.size, SMPTEPackageUtils.fileSize(at: expectedFile), file: file, line: line)
        }

        XCTAssertEqual(
            assets.filter(\.isPackingList).map(\.path),
            [expectedFiles[0].lastPathComponent],
            file: file,
            line: line
        )

        let packingListAssets = try xmlAssets(at: expectedFiles[0])
        for expectedFile in expectedFiles.dropFirst() {
            let packingListID = packingListAssets.first {
                $0.originalFileName == expectedFile.lastPathComponent
            }?.id
            let assetMapID = assets.first { $0.path == expectedFile.lastPathComponent }?.id
            XCTAssertNotNil(packingListID, file: file, line: line)
            XCTAssertEqual(assetMapID, packingListID, file: file, line: line)
        }
    }

    private func xmlAssets(at url: URL) throws -> [ManifestAsset] {
        let document = try XMLDocument(contentsOf: url, options: [])
        return try document.nodes(forXPath: "//*[local-name()='Asset']").map { node in
            let sizeText = xmlText(named: "Size", below: node) ?? xmlText(named: "Length", below: node)
            return ManifestAsset(
                id: xmlText(named: "Id", below: node),
                hash: xmlText(named: "Hash", below: node),
                size: sizeText.flatMap(Int64.init),
                originalFileName: xmlText(named: "OriginalFileName", below: node),
                path: xmlText(named: "Path", below: node),
                isPackingList: xmlText(named: "PackingList", below: node) == "true"
            )
        }
    }

    private func xmlTexts(named name: String, at url: URL) throws -> [String] {
        let document = try XMLDocument(contentsOf: url, options: [])
        return try document.nodes(forXPath: "//*[local-name()='\(name)']")
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func xmlText(named name: String, below node: XMLNode) -> String? {
        guard let element = node as? XMLElement,
              let match = (try? element.nodes(forXPath: ".//*[local-name()='\(name)']"))?.first else {
            return nil
        }
        return match.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

private func whisperDestinationURL(in request: SubprocessRequest) -> URL? {
    guard let filterIndex = request.arguments.firstIndex(of: "-af"),
          request.arguments.indices.contains(filterIndex + 1) else {
        return nil
    }
    let filter = request.arguments[filterIndex + 1]
    guard let start = filter.range(of: "destination=")?.upperBound,
          let end = filter.range(of: ":use_gpu=true", range: start..<filter.endIndex)?.lowerBound else {
        return nil
    }
    let escapedPath = String(filter[start..<end])
    return URL(fileURLWithPath: escapedPath
        .replacingOccurrences(of: "\\:", with: ":")
        .replacingOccurrences(of: "\\'", with: "'")
        .replacingOccurrences(of: "\\\\", with: "\\"))
}

private func fixtureParakeetService(runner: any SubprocessRunning) -> ParakeetService {
    ParakeetService(
        subprocessRunner: runner,
        parakeetPathProvider: { "/fixture/parakeet-mlx" },
        ffmpegPathProvider: { "/fixture/ffmpeg" },
        chunkDurationProvider: { AppConstants.defaultParakeetChunkDuration },
        overlapDurationProvider: { AppConstants.defaultParakeetOverlapDuration }
    )
}

private func parakeetDestinationURL(in request: SubprocessRequest) -> URL? {
    guard let outputDirectoryIndex = request.arguments.firstIndex(of: "--output-dir"),
          request.arguments.indices.contains(outputDirectoryIndex + 1) else {
        return nil
    }
    return URL(fileURLWithPath: request.arguments[outputDirectoryIndex + 1])
        .appendingPathComponent("input.srt")
}

private extension Array where Element == String {
    func containsAdjacent(_ first: String, _ second: String) -> Bool {
        adjacentPairCount(first, second) > 0
    }

    func adjacentPairCount(_ first: String, _ second: String) -> Int {
        indices.reduce(into: 0) { count, index in
            if self[index] == first,
               indices.contains(index + 1),
               self[index + 1] == second {
                count += 1
            }
        }
    }
}

private func makeAnalyticsFixtureFiles() throws -> (directory: URL, source: URL, encoded: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("analytics fixture \(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
        let source = directory.appendingPathComponent("private source.mov")
        let encoded = directory.appendingPathComponent("private encoded.mov")
        try Data("source".utf8).write(to: source)
        try Data("encoded".utf8).write(to: encoded)
        return (directory, source, encoded)
    } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

private func makeBMXFixture() throws -> (directory: URL, input: URL, output: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BMX fixture \(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
        let input = directory.appendingPathComponent("private source.mxf")
        let output = directory.appendingPathComponent("private output.mxf")
        try Data("fixture".utf8).write(to: input)
        return (directory, input, output)
    } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

private func bmxOutputURL(in request: SubprocessRequest) -> URL? {
    guard let outputIndex = request.arguments.firstIndex(of: "-o"),
          request.arguments.indices.contains(outputIndex + 1) else { return nil }
    return URL(fileURLWithPath: request.arguments[outputIndex + 1])
}

private func successfulSubprocessResult(
    standardOutput: String = "",
    standardError: String = "",
    terminationStatus: Int32 = 0
) -> SubprocessResult {
    SubprocessResult(
        terminationStatus: terminationStatus,
        termination: .exited,
        standardOutput: Data(standardOutput.utf8),
        standardError: Data(standardError.utf8),
        discardedStandardOutputBytes: 0,
        discardedStandardErrorBytes: 0,
        duration: .milliseconds(10)
    )
}

private func makeTestIVFData(
    width: Int = 1_920,
    height: Int = 1_080,
    fpsNumerator: Int = 24,
    fpsDenominator: Int = 1,
    payload: Data = Data([0x01])
) -> Data {
    func appendUInt16(_ value: Int, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
    }
    func appendUInt32(_ value: Int, to bytes: inout [UInt8]) {
        for shift in stride(from: 0, through: 24, by: 8) {
            bytes.append(UInt8((value >> shift) & 0xFF))
        }
    }

    var bytes = Array("DKIF".utf8)
    appendUInt16(0, to: &bytes)
    appendUInt16(32, to: &bytes)
    bytes.append(contentsOf: Array("AV02".utf8))
    appendUInt16(width, to: &bytes)
    appendUInt16(height, to: &bytes)
    appendUInt32(fpsNumerator, to: &bytes)
    appendUInt32(fpsDenominator, to: &bytes)
    appendUInt32(1, to: &bytes)
    appendUInt32(0, to: &bytes)
    appendUInt32(payload.count, to: &bytes)
    bytes.append(contentsOf: [UInt8](repeating: 0, count: 8))
    bytes.append(contentsOf: payload)
    return Data(bytes)
}

private func makeNativeWaveformConversionRequest(
    inputURL: URL,
    outputBaseURL: URL
) -> ConversionRequest {
    ConversionRequest(
        inputURL: inputURL,
        outputURL: outputBaseURL,
        preset: .h264,
        includeDateTag: false,
        expectedDuration: 1,
        waveformRequest: WaveformVideoRequest(
            width: 2,
            height: 2,
            backgroundHex: "000000",
            foregroundHex: "FFFFFF",
            normalizeAudio: false,
            style: .linear,
            frameRate: 1,
            renderingEngine: .swift,
            swiftStyle: .capsules,
            bandCount: 1,
            frequencyDistribution: .linear,
            foregroundGradientEnabled: false,
            foregroundGradientEndHex: "FFFFFF",
            backgroundGradientEnabled: false,
            backgroundGradientEndHex: "000000",
            waveformOpacity: 1
        )
    )
}

private func conversionResult(
    converter: FFMPEGConverter,
    request: ConversionRequest
) async -> (success: Bool, errorReason: String?) {
    await withCheckedContinuation { continuation in
        Task {
            await converter.convert(
                request: request,
                progressUpdate: { _, _ in },
                completion: { success, errorReason in
                    continuation.resume(returning: (success, errorReason))
                }
            )
        }
    }
}

private func packageAudioTemporaryFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("audio_temp_") }
}

private struct StubAnalyticsMediaInfoProvider: AnalyticsMediaInfoProviding {
    let duration: Double?
    let resolution: (width: Int, height: Int)?

    func duration(for file: URL) async -> Double? {
        duration
    }

    func resolution(for file: URL) async -> (width: Int, height: Int)? {
        resolution
    }
}

private struct ClosureAnalyticsMediaInfoProvider: AnalyticsMediaInfoProviding {
    let durationHandler: @Sendable (URL) async -> Double?
    let resolutionHandler: @Sendable (URL) async -> (width: Int, height: Int)?

    init(
        duration: @escaping @Sendable (URL) async -> Double?,
        resolution: @escaping @Sendable (URL) async -> (width: Int, height: Int)?
    ) {
        self.durationHandler = duration
        self.resolutionHandler = resolution
    }

    func duration(for file: URL) async -> Double? {
        await durationHandler(file)
    }

    func resolution(for file: URL) async -> (width: Int, height: Int)? {
        await resolutionHandler(file)
    }
}

private struct PresetCommandExpectation {
    enum Media {
        case videoOnly
        case audioOnly
        case videoAndAudio
        case streamCopy
    }

    let preset: ExportPreset
    let outputExtension: String
    let videoCodec: String?
    let audioCodec: String?
    let media: Media

    init(
        _ preset: ExportPreset,
        extension outputExtension: String,
        videoCodec: String?,
        audioCodec: String?,
        media: Media
    ) {
        self.preset = preset
        self.outputExtension = outputExtension
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.media = media
    }
}

private struct ManifestAsset {
    let id: String?
    let hash: String?
    let size: Int64?
    let originalFileName: String?
    let path: String?
    let isPackingList: Bool
}

private struct StubYTDLPUpdateService: YTDLPUpdating {
    let path: String?

    func resolveYTDLPPath() async -> String? {
        path
    }

    func ensureDenoInstalled() async -> String? {
        nil
    }
}

private struct StubRcloneUpdateService: RcloneUpdating {
    let path: String?

    func resolveRclonePath() async -> String? {
        path
    }
}

private struct StubWhisperModelProvider: WhisperModelProviding {
    let path: URL

    func modelPath(for model: WhisperModel) -> URL {
        path
    }

    func isModelDownloaded(_ model: WhisperModel) -> Bool {
        true
    }
}

private final class LockedInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func incrementAndIsFirst() -> Bool {
        lock.withLock {
            count += 1
            return count == 1
        }
    }

    var value: Int {
        lock.withLock { count }
    }
}

private final class AsyncTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard !isOpen else { return [] }
            isOpen = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending {
            waiter.resume()
        }
    }
}

private final class RecordingSubprocessRunner: SubprocessRunning, @unchecked Sendable {
    typealias Operation = @Sendable (
        SubprocessRequest,
        (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult

    private let lock = NSLock()
    private let operation: Operation
    private var recordedRequest: SubprocessRequest?

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    var lastRequest: SubprocessRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequest
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        lock.withLock {
            recordedRequest = request
        }
        return try await operation(request, outputHandler)
    }
}

private final class SequencedRecordingSubprocessRunner: SubprocessRunning, @unchecked Sendable {
    typealias Operation = @Sendable (
        Int,
        SubprocessRequest,
        (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult

    private let lock = NSLock()
    private let operation: Operation
    private var recordedRequests: [SubprocessRequest] = []

    init(operation: @escaping Operation) {
        self.operation = operation
    }

    var requests: [SubprocessRequest] {
        lock.withLock { recordedRequests }
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        let index = lock.withLock { () -> Int in
            let index = recordedRequests.count
            recordedRequests.append(request)
            return index
        }
        return try await operation(index, request, outputHandler)
    }
}

private actor SupersedingSubtitleSubprocessRunner: SubprocessRunning {
    private var startedCount = 0
    private var firstReleaseContinuation: CheckedContinuation<Void, Never>?
    private var firstReleaseRequested = false

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        startedCount += 1
        let invocation = startedCount
        if invocation == 1 {
            await withCheckedContinuation { continuation in
                if firstReleaseRequested {
                    firstReleaseRequested = false
                    continuation.resume()
                } else {
                    firstReleaseContinuation = continuation
                }
            }
        }

        guard let outputPath = request.arguments.last else {
            throw CocoaError(.fileNoSuchFile)
        }
        try Data("embedded-\(invocation)".utf8).write(
            to: URL(fileURLWithPath: outputPath)
        )
        return successfulSubprocessResult()
    }

    func waitUntilStarted(count: Int) async {
        while startedCount < count {
            await Task.yield()
        }
    }

    func releaseFirst() {
        if let continuation = firstReleaseContinuation {
            firstReleaseContinuation = nil
            continuation.resume()
        } else {
            firstReleaseRequested = true
        }
    }
}

private final class ControllableBMXSubprocessRunner: SubprocessRunning, @unchecked Sendable {
    let firstOperationID = UUID()
    let secondOperationID = UUID()

    private let lock = NSLock()
    private var recordedStartedCount = 0
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var firstReleaseRequested = false
    private var firstReleaseContinuation: CheckedContinuation<Void, Never>?

    var startedCount: Int {
        lock.withLock { recordedStartedCount }
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        let invocation = signalStarted()
        if invocation == 1 {
            await waitForFirstRelease()
        }
        let outputURL = try XCTUnwrap(bmxOutputURL(in: request))
        try Data("rewrapped-\(invocation)".utf8).write(to: outputURL)
        return successfulSubprocessResult()
    }

    func waitUntilStarted(count: Int) async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard recordedStartedCount < count else { return true }
                startWaiters.append((count, continuation))
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func releaseFirst() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if let continuation = firstReleaseContinuation {
                firstReleaseContinuation = nil
                return continuation
            }
            firstReleaseRequested = true
            return nil
        }
        continuation?.resume()
    }

    private func signalStarted() -> Int {
        let state = lock.withLock { () -> (Int, [CheckedContinuation<Void, Never>]) in
            recordedStartedCount += 1
            let invocation = recordedStartedCount
            let ready = startWaiters
                .filter { invocation >= $0.0 }
                .map(\.1)
            startWaiters.removeAll { invocation >= $0.0 }
            return (invocation, ready)
        }
        state.1.forEach { $0.resume() }
        return state.0
    }

    private func waitForFirstRelease() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                if firstReleaseRequested {
                    firstReleaseRequested = false
                    return true
                }
                firstReleaseContinuation = continuation
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }
}

private final class BlockingSubprocessRunner: SubprocessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }

        try await Task.sleep(for: .seconds(30))
        return SubprocessResult(
            terminationStatus: 0,
            termination: .exited,
            standardOutput: Data(),
            standardError: Data(),
            discardedStandardOutputBytes: 0,
            discardedStandardErrorBytes: 0,
            duration: .seconds(30)
        )
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if started {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

private actor BlockingAudioStreamProvider {
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation: CheckedContinuation<[FFMPEGProbeService.AudioStreamInfo]?, Never>?
    private var pendingResult: [FFMPEGProbeService.AudioStreamInfo]??

    func fetch(for _: URL) async -> [FFMPEGProbeService.AudioStreamInfo]? {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        if let pendingResult {
            self.pendingResult = nil
            return pendingResult
        }
        return await withCheckedContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func resume(with result: [FFMPEGProbeService.AudioStreamInfo]?) {
        if let resultContinuation {
            self.resultContinuation = nil
            resultContinuation.resume(returning: result)
        } else {
            pendingResult = .some(result)
        }
    }
}

private final class CountingBlockingSubprocessRunner: SubprocessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var startedCount = 0
    private var recordedCancelledCount = 0
    private var startWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []

    var cancelledCount: Int {
        lock.withLock { recordedCancelledCount }
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        signalStarted()
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            lock.withLock {
                recordedCancelledCount += 1
            }
            throw error
        }
        return SubprocessResult(
            terminationStatus: 0,
            termination: .exited,
            standardOutput: Data(),
            standardError: Data(),
            discardedStandardOutputBytes: 0,
            discardedStandardErrorBytes: 0,
            duration: .seconds(30)
        )
    }

    func waitUntilStarted(count: Int) async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard startedCount < count else { return true }
                startWaiters.append((count, continuation))
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    private func signalStarted() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            startedCount += 1
            let ready = startWaiters
                .filter { startedCount >= $0.count }
                .map(\.continuation)
            startWaiters.removeAll { startedCount >= $0.count }
            return ready
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor TwoStageBlockingPipelineRunner: SubprocessRunning {
    private var producerStartedCount = 0
    private var consumerStartedCount = 0
    private(set) var cancelledProducerCount = 0
    private(set) var cancelledConsumerCount = 0

    var cancelledStageCount: Int {
        cancelledProducerCount + cancelledConsumerCount
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        producerStartedCount += 1
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            cancelledProducerCount += 1
            throw error
        }
        return successfulSubprocessResult()
    }

    func runWithStreamingStandardInput(
        _ request: SubprocessRequest,
        inputProducer: @escaping SubprocessStandardInputProducer,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        consumerStartedCount += 1
        let writer = SubprocessStandardInputWriter(write: { _ in }, finish: {})
        let inputTask = Task { await inputProducer(writer) }
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            inputTask.cancel()
            cancelledConsumerCount += 1
            throw error
        }
        inputTask.cancel()
        return successfulSubprocessResult()
    }

    func waitUntilBothStagesStarted(file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntilStagesStarted(count: 1, file: file, line: line)
    }

    func waitUntilStagesStarted(count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while producerStartedCount < count || consumerStartedCount < count {
            guard ContinuousClock.now < deadline, !Task.isCancelled else {
                XCTFail(
                    "Pipeline did not start \(count) producer/consumer stages within five seconds "
                        + "(started \(producerStartedCount)/\(consumerStartedCount))",
                    file: file, line: line
                )
                // Return to the caller so its converter cancellation still cleans up any
                // partially started stages after reporting the missing-start regression.
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor CancellingCompletedPipelineRunner: SubprocessRunning {
    private var beforeConsumerReturns: (@Sendable () async -> Void)?

    func setBeforeConsumerReturns(_ operation: @escaping @Sendable () async -> Void) {
        beforeConsumerReturns = operation
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        successfulSubprocessResult()
    }

    func runWithStreamingStandardInput(
        _ request: SubprocessRequest,
        inputProducer: @escaping SubprocessStandardInputProducer,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        let writer = SubprocessStandardInputWriter(write: { _ in }, finish: {})
        await inputProducer(writer)
        if let outputIndex = request.arguments.firstIndex(of: "-o"),
           request.arguments.indices.contains(outputIndex + 1) {
            try Data("encoded AV2".utf8).write(
                to: URL(fileURLWithPath: request.arguments[outputIndex + 1])
            )
        }
        let operation = beforeConsumerReturns
        beforeConsumerReturns = nil
        await operation?()
        return successfulSubprocessResult()
    }
}

private final class SupersedingFFMPEGRunner: SubprocessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var invocationCount = 0
    private var firstStarted = false
    private var firstStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCancellationReleaseRequested = false
    private var firstCancellationContinuation: CheckedContinuation<Void, Never>?
    private var recordedCancelledCount = 0

    var cancelledCount: Int {
        lock.withLock { recordedCancelledCount }
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        let invocation = lock.withLock { () -> Int in
            invocationCount += 1
            return invocationCount
        }

        if invocation == 1 {
            signalFirstStarted()
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                // Simulate a final pipe callback racing cancellation. The converter's
                // per-attempt gate must suppress this 90% update.
                outputHandler?(SubprocessOutputChunk(
                    stream: .standardError,
                    data: Data("frame=270 time=00:00:09.00 speed=1.0x\r".utf8)
                ))
                lock.withLock { recordedCancelledCount += 1 }
                await waitForFirstCancellationRelease()
                throw CancellationError()
            }
        }

        let outputPath = try XCTUnwrap(request.arguments.last)
        try Data("retry output".utf8).write(to: URL(fileURLWithPath: outputPath))
        return SubprocessResult(
            terminationStatus: 0,
            termination: .exited,
            standardOutput: Data(),
            standardError: Data(),
            discardedStandardOutputBytes: 0,
            discardedStandardErrorBytes: 0,
            duration: .milliseconds(10)
        )
    }

    func waitUntilFirstStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard !firstStarted else { return true }
                firstStartWaiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func releaseCancelledFirst() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            firstCancellationReleaseRequested = true
            let continuation = firstCancellationContinuation
            firstCancellationContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    private func waitForFirstCancellationRelease() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard !firstCancellationReleaseRequested else { return true }
                firstCancellationContinuation = continuation
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    private func signalFirstStarted() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            firstStarted = true
            let waiters = firstStartWaiters
            firstStartWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

private final class DeferredSuccessfulWhisperRunner: SubprocessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        await withCheckedContinuation { continuation in
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                releaseContinuation = continuation
                started = true
                let waiters = startWaiters
                startWaiters.removeAll()
                return waiters
            }
            for waiter in waiters { waiter.resume() }
        }
        let stagedURL = try XCTUnwrap(whisperDestinationURL(in: request))
        try "1\n00:00:00,000 --> 00:00:01,000\nLate output\n".write(
            to: stagedURL,
            atomically: true,
            encoding: .utf8
        )
        return SubprocessResult(
            terminationStatus: 0,
            termination: .exited,
            standardOutput: Data(),
            standardError: Data(),
            discardedStandardOutputBytes: 0,
            discardedStandardErrorBytes: 0,
            duration: .milliseconds(10)
        )
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard !started else { return true }
                startWaiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { releaseContinuation = nil }
            return releaseContinuation
        }
        continuation?.resume()
    }
}

private final class DeferredSuccessfulFileRunner: SubprocessRunning, @unchecked Sendable {
    private let outputData: Data
    private let lock = NSLock()
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseRequested = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(outputData: Data) {
        self.outputData = outputData
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        await withCheckedContinuation { continuation in
            let state = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
                started = true
                let waiters = startWaiters
                startWaiters.removeAll()
                if releaseRequested {
                    releaseRequested = false
                    return (true, waiters)
                }
                releaseContinuation = continuation
                return (false, waiters)
            }
            state.1.forEach { $0.resume() }
            if state.0 { continuation.resume() }
        }

        let outputPath = try XCTUnwrap(request.arguments.last)
        try outputData.write(to: URL(fileURLWithPath: outputPath))
        return successfulSubprocessResult()
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard !started else { return true }
                startWaiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if let continuation = releaseContinuation {
                releaseContinuation = nil
                return continuation
            }
            releaseRequested = true
            return nil
        }
        continuation?.resume()
    }
}

private final class CoordinatedWhisperOutputRunner: SubprocessRunning, @unchecked Sendable {
    private let expectedCount: Int
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        await withCheckedContinuation { continuation in
            let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                waiting.append(continuation)
                guard waiting.count == expectedCount else { return [] }
                let continuations = waiting
                waiting.removeAll()
                return continuations
            }
            for continuation in continuations { continuation.resume() }
        }

        let stagedURL = try XCTUnwrap(whisperDestinationURL(in: request))
        let inputName: String = {
            guard let inputIndex = request.arguments.firstIndex(of: "-i"),
                  request.arguments.indices.contains(inputIndex + 1) else {
                return "unknown"
            }
            return URL(fileURLWithPath: request.arguments[inputIndex + 1]).lastPathComponent
        }()
        try "1\n00:00:00,000 --> 00:00:01,000\n\(inputName)\n".write(
            to: stagedURL,
            atomically: true,
            encoding: .utf8
        )
        return SubprocessResult(
            terminationStatus: 0,
            termination: .exited,
            standardOutput: Data(),
            standardError: Data(),
            discardedStandardOutputBytes: 0,
            discardedStandardErrorBytes: 0,
            duration: .milliseconds(10)
        )
    }
}

private final class CoordinatedParakeetOutputRunner: SubprocessRunning, @unchecked Sendable {
    private let expectedCount: Int
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        await withCheckedContinuation { continuation in
            let continuations = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                waiting.append(continuation)
                guard waiting.count == expectedCount else { return [] }
                let continuations = waiting
                waiting.removeAll()
                return continuations
            }
            for continuation in continuations { continuation.resume() }
        }

        let stagedURL = try XCTUnwrap(parakeetDestinationURL(in: request))
        let inputName = URL(fileURLWithPath: request.arguments.first ?? "unknown").pathExtension
        try "1\n00:00:00,000 --> 00:00:01,000\n\(inputName)\n".write(
            to: stagedURL,
            atomically: true,
            encoding: .utf8
        )
        return SubprocessResult(
            terminationStatus: 0,
            termination: .exited,
            standardOutput: Data(),
            standardError: Data(),
            discardedStandardOutputBytes: 0,
            discardedStandardErrorBytes: 0,
            duration: .milliseconds(10)
        )
    }
}

private final class DeferredSuccessfulParakeetRunner: SubprocessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        await withCheckedContinuation { continuation in
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                releaseContinuation = continuation
                started = true
                let waiters = startWaiters
                startWaiters.removeAll()
                return waiters
            }
            for waiter in waiters { waiter.resume() }
        }
        let stagedURL = try XCTUnwrap(parakeetDestinationURL(in: request))
        try "1\n00:00:00,000 --> 00:00:01,000\nLate output\n".write(
            to: stagedURL,
            atomically: true,
            encoding: .utf8
        )
        return SubprocessResult(
            terminationStatus: 0,
            termination: .exited,
            standardOutput: Data(),
            standardError: Data(),
            discardedStandardOutputBytes: 0,
            discardedStandardErrorBytes: 0,
            duration: .milliseconds(10)
        )
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard !started else { return true }
                startWaiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { releaseContinuation = nil }
            return releaseContinuation
        }
        continuation?.resume()
    }
}

private final class SelectiveRcloneRunner: SubprocessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var startedCount = 0
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var recordedCancelledPaths: [String] = []

    var cancelledPaths: [String] {
        lock.withLock { recordedCancelledPaths }
    }

    func run(
        _ request: SubprocessRequest,
        outputHandler: (@Sendable (SubprocessOutputChunk) -> Void)?
    ) async throws -> SubprocessResult {
        let localPath = request.arguments.count > 1 ? request.arguments[1] : ""
        signalStarted()

        if localPath.contains("cancel") {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                lock.withLock {
                    recordedCancelledPaths.append(localPath)
                }
                throw error
            }
        }

        return SubprocessResult(
            terminationStatus: 0,
            termination: .exited,
            standardOutput: Data(),
            standardError: Data(),
            discardedStandardOutputBytes: 0,
            discardedStandardErrorBytes: 0,
            duration: .seconds(1)
        )
    }

    func waitUntilStarted(count: Int) async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                if startedCount >= count {
                    return true
                }
                startWaiters.append((count, continuation))
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    private func signalStarted() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            startedCount += 1
            let ready = startWaiters.filter { startedCount >= $0.count }
            startWaiters.removeAll { startedCount >= $0.count }
            return ready.map(\.continuation)
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private final class RcloneCallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [Double] = []
    private var recordedSpeeds: [String?] = []

    var values: [Double] {
        lock.withLock { recordedValues }
    }

    func record(value: Double, speed: String?) {
        lock.withLock {
            recordedValues.append(value)
            recordedSpeeds.append(speed)
        }
    }
}

private func makeParakeetMetadata(fileName: String) -> ParakeetModelMetadata {
    ParakeetModelMetadata(
        sha: "testcommit",
        siblings: [
            ParakeetModelMetadata.File(
                rfilename: fileName,
                size: nil,
                lfs: nil
            )
        ]
    )
}

private final class ImmediateParakeetMetadataOperation: ParakeetModelMetadataOperation,
    @unchecked Sendable
{
    private let metadata: ParakeetModelMetadata

    init(metadata: ParakeetModelMetadata) {
        self.metadata = metadata
    }

    func run() async throws -> ParakeetModelMetadata {
        metadata
    }

    func cancel() {}
}

private final class ControlledParakeetMetadataOperation: ParakeetModelMetadataOperation,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let honorsCancellation: Bool
    private var result: Result<ParakeetModelMetadata, Error>?
    private var continuation: CheckedContinuation<ParakeetModelMetadata, Error>?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var recordedCancellationCount = 0

    init(honorsCancellation: Bool = true) {
        self.honorsCancellation = honorsCancellation
    }

    var cancellationCount: Int {
        lock.withLock { recordedCancellationCount }
    }

    func run() async throws -> ParakeetModelMetadata {
        try await withCheckedThrowingContinuation { continuation in
            let state = lock.withLock { () -> (
                Result<ParakeetModelMetadata, Error>?,
                [CheckedContinuation<Void, Never>]
            ) in
                let currentResult = result
                if currentResult == nil {
                    self.continuation = continuation
                }
                started = true
                let waiters = startWaiters
                startWaiters.removeAll()
                return (currentResult, waiters)
            }
            state.1.forEach { $0.resume() }
            if let result = state.0 {
                continuation.resume(with: result)
            }
        }
    }

    func cancel() {
        let shouldResolve = lock.withLock { () -> Bool in
            recordedCancellationCount += 1
            return honorsCancellation
        }
        if shouldResolve {
            resolve(.failure(CancellationError()))
        }
    }

    func succeed(with metadata: ParakeetModelMetadata) {
        resolve(.success(metadata))
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard !started else { return true }
                startWaiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    private func resolve(_ newResult: Result<ParakeetModelMetadata, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<ParakeetModelMetadata, Error>? in
            guard result == nil else { return nil }
            result = newResult
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(with: newResult)
    }
}

private final class ControlledParakeetFileDownloadOperation: ParakeetFileDownloadOperation,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let honorsCancellation: Bool
    private var result: Result<ParakeetFileDownloadResult, Error>?
    private var continuation: CheckedContinuation<ParakeetFileDownloadResult, Error>?
    private var progressHandler: (@Sendable (Int64, Int64) -> Void)?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var recordedCancellationCount = 0

    init(honorsCancellation: Bool = true) {
        self.honorsCancellation = honorsCancellation
    }

    var cancellationCount: Int {
        lock.withLock { recordedCancellationCount }
    }

    func run(
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> ParakeetFileDownloadResult {
        try await withCheckedThrowingContinuation { continuation in
            let state = lock.withLock { () -> (
                Result<ParakeetFileDownloadResult, Error>?,
                [CheckedContinuation<Void, Never>]
            ) in
                let currentResult = result
                if currentResult == nil {
                    self.continuation = continuation
                    progressHandler = progress
                }
                started = true
                let waiters = startWaiters
                startWaiters.removeAll()
                return (currentResult, waiters)
            }
            state.1.forEach { $0.resume() }
            if let result = state.0 {
                continuation.resume(with: result)
            }
        }
    }

    func cancel() {
        let shouldResolve = lock.withLock { () -> Bool in
            recordedCancellationCount += 1
            return honorsCancellation
        }
        if shouldResolve {
            resolve(.failure(CancellationError()))
        }
    }

    func emitProgress(bytesWritten: Int64, totalExpected: Int64) {
        let handler = lock.withLock { result == nil ? progressHandler : nil }
        handler?(bytesWritten, totalExpected)
    }

    func succeed(
        temporaryURL: URL,
        expectedContentLength: Int64,
        eTag: String?,
        statusCode: Int = 200
    ) {
        resolve(
            .success(
                ParakeetFileDownloadResult(
                    temporaryURL: temporaryURL,
                    statusCode: statusCode,
                    expectedContentLength: expectedContentLength,
                    eTag: eTag
                )
            )
        )
    }

    func fail(with error: Error) {
        resolve(.failure(error))
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard !started else { return true }
                startWaiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    private func resolve(_ newResult: Result<ParakeetFileDownloadResult, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<ParakeetFileDownloadResult, Error>? in
            guard result == nil else { return nil }
            result = newResult
            let pending = continuation
            continuation = nil
            progressHandler = nil
            return pending
        }
        pending?.resume(with: newResult)
    }
}

private final class ParakeetFileDownloadOperationQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [any ParakeetFileDownloadOperation]

    init(_ operations: [any ParakeetFileDownloadOperation]) {
        self.operations = operations
    }

    func next() -> any ParakeetFileDownloadOperation {
        lock.withLock {
            precondition(!operations.isEmpty, "No configured Parakeet download operation remains")
            return operations.removeFirst()
        }
    }
}

private final class ParakeetModelProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedFractions: [Double] = []

    var fractions: [Double] {
        lock.withLock { recordedFractions }
    }

    func record(_ progress: ModelDownloadProgress) {
        lock.withLock { recordedFractions.append(progress.overallFraction) }
    }

    func waitUntilCompleted() async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while fractions.last != 1, ContinuousClock.now < deadline {
            await Task.yield()
        }
    }
}

private final class ControlledWhisperModelDownloadOperation: WhisperModelDownloadOperation,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let honorsCancellation: Bool
    private var result: Result<URL, Error>?
    private var continuation: CheckedContinuation<URL, Error>?
    private var progressHandler: (@Sendable (Double) -> Void)?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var recordedCancellationCount = 0

    init(honorsCancellation: Bool = true) {
        self.honorsCancellation = honorsCancellation
    }

    var cancellationCount: Int {
        lock.withLock { recordedCancellationCount }
    }

    func run(progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let state = lock.withLock { () -> (
                Result<URL, Error>?,
                [CheckedContinuation<Void, Never>]
            ) in
                let currentResult = result
                if currentResult == nil {
                    self.continuation = continuation
                    progressHandler = progress
                }
                started = true
                let waiters = startWaiters
                startWaiters.removeAll()
                return (currentResult, waiters)
            }
            for waiter in state.1 {
                waiter.resume()
            }
            if let result = state.0 {
                continuation.resume(with: result)
            }
        }
    }

    func cancel() {
        let shouldResolve = lock.withLock { () -> Bool in
            recordedCancellationCount += 1
            return honorsCancellation
        }
        if shouldResolve {
            resolve(.failure(CancellationError()))
        }
    }

    func emitProgress(_ value: Double) {
        let handler = lock.withLock { result == nil ? progressHandler : nil }
        handler?(value)
    }

    func succeed(with url: URL) {
        resolve(.success(url))
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard !started else { return true }
                startWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    private func resolve(_ newResult: Result<URL, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            guard result == nil else { return nil }
            result = newResult
            let pending = continuation
            continuation = nil
            progressHandler = nil
            return pending
        }
        pending?.resume(with: newResult)
    }
}

private final class WhisperModelDownloadOperationQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [any WhisperModelDownloadOperation]

    init(_ operations: [any WhisperModelDownloadOperation]) {
        self.operations = operations
    }

    func next() -> any WhisperModelDownloadOperation {
        lock.withLock {
            precondition(!operations.isEmpty, "No configured Whisper download operation remains")
            return operations.removeFirst()
        }
    }
}

private final class WhisperProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [Double] = []

    var values: [Double] {
        lock.withLock { recordedValues }
    }

    func record(_ value: Double) {
        lock.withLock { recordedValues.append(value) }
    }

    func waitUntilContains(_ expectedValue: Double) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !values.contains(expectedValue), ContinuousClock.now < deadline {
            await Task.yield()
        }
    }
}

private final class YTDLPCallbackRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedProgressValues: [Double] = []
    private var recordedTitles: [String] = []

    var progressValues: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return recordedProgressValues
    }

    var titles: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTitles
    }

    func recordProgress(_ value: Double) {
        lock.lock()
        recordedProgressValues.append(value)
        lock.unlock()
    }

    func recordTitle(_ title: String) {
        lock.lock()
        recordedTitles.append(title)
        lock.unlock()
    }
}

private final class SubprocessChunkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()

    var standardOutput: Data {
        lock.lock()
        defer { lock.unlock() }
        return output
    }

    var standardError: Data {
        lock.lock()
        defer { lock.unlock() }
        return error
    }

    func append(_ chunk: SubprocessOutputChunk) {
        lock.lock()
        switch chunk.stream {
        case .standardOutput:
            output.append(chunk.data)
        case .standardError:
            error.append(chunk.data)
        }
        lock.unlock()
    }
}

private final class SecurityScopeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [URL] = []
    private var stops: [URL] = []

    var startedURLs: [URL] {
        lock.withLock { starts }
    }

    var stoppedURLs: [URL] {
        lock.withLock { stops }
    }

    func start(_ url: URL) -> Bool {
        lock.withLock { starts.append(url) }
        return true
    }

    func stop(_ url: URL) {
        lock.withLock { stops.append(url) }
    }
}

private final class DeferredTerminationCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    var startedCount: Int {
        lock.withLock { didStart ? 1 : 0 }
    }

    func run() async {
        await withCheckedContinuation { continuation in
            let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                releaseContinuation = continuation
                didStart = true
                let waiters = startWaiters
                startWaiters.removeAll()
                return waiters
            }
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard !didStart else { return true }
                startWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { releaseContinuation = nil }
            return releaseContinuation
        }
        continuation?.resume()
    }
}


final class SwiftExifDurationDeadlineTests: XCTestCase {
    func testDurationReturnsSuccessfulProbeValue() async {
        let result = await SwiftExifMediaProbe.duration(
            for: URL(fileURLWithPath: "/tmp/duration.mov"),
            timeout: .seconds(1)
        ) { _ in 12.5 }
        XCTAssertEqual(result, 12.5)
    }

    func testDurationReturnsNilWithoutJoiningStalledProbe() async {
        let stalled = DeferredTerminationCleanup()
        defer { stalled.release() }
        let started = ContinuousClock.now
        let task = Task {
            await SwiftExifMediaProbe.duration(
                for: URL(fileURLWithPath: "/tmp/duration.mov"),
                timeout: .milliseconds(100)
            ) { _ in
                await stalled.run()
                return 12.5
            }
        }
        await stalled.waitUntilStarted()

        let result = await task.value
        XCTAssertNil(result)
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        // The suspended operation is released only after its caller has returned.
        stalled.release()
    }

    func testDurationCancellationReturnsNilWithoutJoiningProbe() async {
        let stalled = DeferredTerminationCleanup()
        defer { stalled.release() }
        let task = Task {
            await SwiftExifMediaProbe.duration(
                for: URL(fileURLWithPath: "/tmp/duration.mov"),
                timeout: .seconds(30)
            ) { _ in
                await stalled.run()
                return 12.5
            }
        }
        await stalled.waitUntilStarted()
        let started = ContinuousClock.now
        task.cancel()

        let result = await task.value
        XCTAssertNil(result)
        XCTAssertLessThan(started.duration(to: .now), .seconds(2))
        stalled.release()
    }
}


extension SwiftExifDurationDeadlineTests {
    func testDurationTimeoutRetainsSecurityAccessUntilLateProbeReturns() async {
        let stalled = DeferredTerminationCleanup()
        let scopes = SecurityScopeRecorder()
        let stopped = expectation(description: "Late probe releases its own scope")
        defer { stalled.release() }
        let url = URL(fileURLWithPath: "/tmp/scoped-duration.mov")
        let task = Task {
            await SwiftExifMediaProbe.duration(
                for: url,
                timeout: .milliseconds(100),
                startAccess: { url in
                    _ = scopes.start(url)
                    return .direct(url)
                },
                stopAccess: { access in
                    if case .direct(let url) = access { scopes.stop(url) }
                    stopped.fulfill()
                }
            ) { _ in
                await stalled.run()
                return 12.5
            }
        }
        await stalled.waitUntilStarted()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(scopes.startedURLs, [url])
        XCTAssertTrue(scopes.stoppedURLs.isEmpty)

        stalled.release()
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(scopes.stoppedURLs, [url])
    }
}

extension Aagedal_Media_Converter_Tests {
    func testNativePreviewDeadlinePublishesOnlyReturnedFrameIndices() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destinations = (0..<3).map { directory.appendingPathComponent("thumb_\($0).png") }
        let image = Data("generated image".utf8)
        let generator = PreviewAssetGenerator(thumbnailRenderer: { _, requests in
            XCTAssertEqual(requests.map(\.index), [0, 2])
            return [2: image]
        })
        let result = try await generator.generateNativeThumbnails(
            url: directory.appendingPathComponent("source.mov"),
            requests: [0, 2].map { PreviewThumbnailRequest(index: $0, position: 0, width: 320, tolerance: 1) },
            destinations: destinations
        )
        XCTAssertEqual(result, [2: image])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinations[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinations[1].path))
        XCTAssertEqual(try Data(contentsOf: destinations[2]), image)
    }

    func testNativePreviewDeadlineDoesNotPublishLateFramesOverFallback() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destinations = (0..<2).map { directory.appendingPathComponent("thumb_\($0).png") }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let generator = PreviewAssetGenerator(
            thumbnailTimeout: .milliseconds(50),
            thumbnailRenderer: { _, _ in
                await withCheckedContinuation { continuation in
                    started.signal()
                    DispatchQueue.global().async {
                        release.wait()
                        continuation.resume(returning: [0: Data("late".utf8), 1: Data("late".utf8)])
                        finished.signal()
                    }
                }
            }
        )
        let start = ContinuousClock.now
        do {
            _ = try await generator.generateNativeThumbnails(
                url: directory.appendingPathComponent("source.mov"),
                requests: [0, 1].map { PreviewThumbnailRequest(index: $0, position: 0, width: 320, tolerance: 1) },
                destinations: destinations
            )
            XCTFail("Expected timeout")
        } catch NonJoiningTaskDeadlineError.timedOut {
            // Expected even though the renderer has not completed.
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let fallback = Data("fallback".utf8)
        try fallback.write(to: destinations[0])
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(try Data(contentsOf: destinations[0]), fallback)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinations[1].path))
    }

    func testNativePreviewCancellationReturnsWithoutPublishingLateRowThumbnail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("row_thumb.png")
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let generator = PreviewAssetGenerator(
            thumbnailTimeout: .seconds(10),
            thumbnailRenderer: { _, _ in
                await withCheckedContinuation { continuation in
                    started.signal()
                    DispatchQueue.global().async {
                        release.wait()
                        continuation.resume(returning: [0: Data("late".utf8)])
                        finished.signal()
                    }
                }
            }
        )
        let task = Task {
            try await generator.generateNativeThumbnails(
                url: directory.appendingPathComponent("source.mov"),
                requests: [PreviewThumbnailRequest(index: 0, position: 1, width: 640, tolerance: 2)],
                destinations: [destination]
            )
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
