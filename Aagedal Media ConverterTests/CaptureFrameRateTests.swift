import AVFoundation
import XCTest
import ScreenCaptureKit
import os
@testable import Aagedal_Media_Converter

final class CaptureFrameRateTests: XCTestCase {
    func testPreviewConfigurationReplacesEveryChangedCaptureOption() {
        let original = CaptureSettings()
        let configuration = CapturePreviewConfiguration(settings: original, maxWidth: 1280)
        let changes: [(inout CaptureSettings) -> Void] = [
            { $0.frameRate = .fps25 },
            { $0.includeSystemAudio = false },
            { $0.includeMicrophone = true },
            { $0.microphoneDeviceID = "replacement-microphone" },
            { $0.hideCursor = true },
            { $0.excludeCurrentApp = true },
            { $0.excludedAppBundleIDs = ["com.example.excluded"] },
            { $0.regionRect = CGRect(x: 10, y: 20, width: 640, height: 480) }
        ]
        for (index, change) in changes.enumerated() {
            var requested = original
            change(&requested)
            XCTAssertTrue(configuration.requiresReplacement(
                settings: requested, maxWidth: 1280, isRecording: false
            ), "Changed option \(index) must reach the live preview")
            XCTAssertFalse(configuration.requiresReplacement(
                settings: requested, maxWidth: 1280, isRecording: true
            ), "Changed option \(index) must preserve the active recording")
        }
    }

    func testPreviewConfigurationPreservesUnchangedTileAndRebuildsForWidth() {
        let settings = CaptureSettings()
        let configuration = CapturePreviewConfiguration(settings: settings, maxWidth: 1280)
        XCTAssertFalse(configuration.requiresReplacement(settings: settings, maxWidth: 1280, isRecording: false))
        XCTAssertTrue(configuration.requiresReplacement(settings: settings, maxWidth: 640, isRecording: false))
        XCTAssertFalse(configuration.requiresReplacement(settings: settings, maxWidth: 640, isRecording: true))
    }

    @MainActor
    func testPreviewSelectionRetiresPendingDeliveryAndRejectsLateAdoption() throws {
        let operations = CapturePreviewOperations()
        let selection = operations.invalidateAll()
        let old = try XCTUnwrap(operations.beginStart(displayID: 1))
        let delivery = CaptureSampleDelivery()
        operations.registerDelivery(delivery, for: old)
        XCTAssertNil(operations.beginStart(displayID: 1))
        XCTAssertNotEqual(operations.invalidateAll(), selection)
        XCTAssertFalse(delivery.isActive)
        XCTAssertFalse(operations.isCurrent(old))
        let replacement = try XCTUnwrap(operations.beginStart(displayID: 1))
        operations.finish(old)
        XCTAssertTrue(operations.isCurrent(replacement))
    }

    @MainActor
    func testRecordingReplacementRetiresOnlyItsPendingPreview() throws {
        let operations = CapturePreviewOperations()
        let first = try XCTUnwrap(operations.beginStart(displayID: 1))
        let second = try XCTUnwrap(operations.beginStart(displayID: 2))
        let delivery = CaptureSampleDelivery()
        operations.registerDelivery(delivery, for: first)
        operations.invalidate(displayID: 1)
        XCTAssertFalse(delivery.isActive)
        XCTAssertFalse(operations.isCurrent(first))
        XCTAssertTrue(operations.isCurrent(second))
        let lateDelivery = CaptureSampleDelivery()
        operations.registerDelivery(lateDelivery, for: first)
        XCTAssertFalse(lateDelivery.isActive)
    }

    @MainActor
    func testAdoptedPreviewDeliverySurvivesPendingSelectionInvalidation() throws {
        let operations = CapturePreviewOperations()
        let operation = try XCTUnwrap(operations.beginStart(displayID: 1))
        let delivery = CaptureSampleDelivery()
        operations.registerDelivery(delivery, for: operation)
        operations.finish(operation)
        operations.invalidateAll()
        XCTAssertTrue(delivery.isActive)
    }

    @MainActor
    func testStopRetiresSuspendedRecordingStartAndKeepsItsScopeClaim() throws {
        let operations = CaptureRecordingOperations()
        let start = try XCTUnwrap(operations.beginStart(displayID: 1))
        let delivery = CaptureSampleDelivery()
        operations.registerDelivery(delivery, for: start)
        XCTAssertTrue(operations.isCurrent(start))

        let stop = operations.beginStop()
        XCTAssertFalse(operations.isCurrent(start))
        XCTAssertFalse(delivery.isActive)
        operations.finishStop(stop)

        // A start still suspended in ScreenCaptureKit retains the folder claim
        // after Stop returns and cannot admit another recording session.
        XCTAssertTrue(operations.hasPendingOperations)
        XCTAssertTrue(operations.hasPendingCleanup)
        XCTAssertNil(operations.beginStart(displayID: 2))
        operations.finishStart(start)
        XCTAssertFalse(operations.hasPendingOperations)
        XCTAssertFalse(operations.hasPendingCleanup)
        XCTAssertNotNil(operations.beginStart(displayID: 2))
    }

    @MainActor
    func testOverlappingRecordingFinalizersKeepScopeUntilBothFinish() {
        let operations = CaptureRecordingOperations()
        let first = operations.beginStop()
        let second = operations.beginStop()
        operations.finishStop(second)
        XCTAssertTrue(operations.hasPendingOperations)
        XCTAssertTrue(operations.hasPendingCleanup)
        XCTAssertNil(operations.beginStart(displayID: 1))
        operations.finishStop(first)
        XCTAssertFalse(operations.hasPendingOperations)
        XCTAssertFalse(operations.hasPendingCleanup)
        XCTAssertNotNil(operations.beginStart(displayID: 1))
    }

    @MainActor
    func testDuplicateRecordingStartIsReservedAcrossSuspension() throws {
        let operations = CaptureRecordingOperations()
        let first = try XCTUnwrap(operations.beginStart(displayID: 1))
        XCTAssertNil(operations.beginStart(displayID: 1))
        let other = try XCTUnwrap(operations.beginStart(displayID: 2))
        operations.finishStart(first)
        XCTAssertTrue(operations.isCurrent(other))
        XCTAssertTrue(operations.hasPendingOperations)
        operations.finishStart(other)
        XCTAssertFalse(operations.hasPendingOperations)
    }

    @MainActor
    func testLateRecordingCompletionCannotRetireReplacementReservation() throws {
        let operations = CaptureRecordingOperations()
        let first = try XCTUnwrap(operations.beginStart(displayID: 1))
        let stop = operations.beginStop()
        operations.finishStart(first)
        operations.finishStop(stop)
        let replacement = try XCTUnwrap(operations.beginStart(displayID: 1))
        operations.finishStart(first)
        XCTAssertFalse(operations.isCurrent(first))
        XCTAssertTrue(operations.isCurrent(replacement))
        XCTAssertTrue(operations.hasPendingOperations)
    }

    @MainActor
    func testDeselectionRetiresPendingRecordingAndLateDeliveryRegistration() throws {
        let operations = CaptureRecordingOperations()
        let start = try XCTUnwrap(operations.beginStart(displayID: 1))
        operations.retireStarts(outside: [2])
        let delivery = CaptureSampleDelivery()
        operations.registerDelivery(delivery, for: start)
        XCTAssertFalse(operations.isCurrent(start))
        XCTAssertFalse(delivery.isActive)
        XCTAssertTrue(operations.hasPendingCleanup)
        operations.finishStart(start)
        XCTAssertFalse(operations.hasPendingOperations)
    }

    func testRetiredCaptureDeliveryRejectsLateSamplesWithoutRetiringReplacement() {
        let retired = CaptureSampleDelivery()
        let replacement = CaptureSampleDelivery()
        var samples = 0
        retired.ifActive { samples += 1 }
        retired.invalidate()
        retired.invalidate()
        retired.ifActive { samples += 100 }
        replacement.ifActive { samples += 1 }
        XCTAssertEqual(samples, 2)
        XCTAssertFalse(retired.isActive)
        XCTAssertTrue(replacement.isActive)
    }

    func testCaptureStreamStartupAdoptsSuccessfulStream() async throws {
        try await CaptureStreamStartup.start(
            operation: {},
            retire: { XCTFail("Successful start must retain delivery") },
            cleanup: { XCTFail("Adopted stream belongs to its tile") }
        )
    }

    func testCaptureStreamStartupRetiresFrameworkFailureWithoutStopping() async {
        enum StartFailure: Error { case rejected }
        let delivery = CaptureSampleDelivery()
        do {
            try await CaptureStreamStartup.start(
                operation: { throw StartFailure.rejected },
                retire: { delivery.invalidate() },
                cleanup: { XCTFail("Failed stream did not start") }
            )
            XCTFail("Expected framework failure")
        } catch StartFailure.rejected {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(delivery.isActive)
    }

    func testCaptureStreamStartupStopsLateSuccessAfterTimeout() async {
        await assertAbandonedCaptureStartIsCleanedUp(cancel: false)
    }

    func testCaptureStreamStartupStopsLateSuccessAfterCancellation() async {
        await assertAbandonedCaptureStartIsCleanedUp(cancel: true)
    }

    func testCaptureStreamStartupIgnoresLateFrameworkFailure() async {
        enum StartFailure: Error { case rejected }
        let registered = expectation(description: "Start registered")
        let failed = expectation(description: "Late failure delivered")
        let callback = OSAllocatedUnfairLock<CheckedContinuation<Void, Error>?>(initialState: nil)
        let task = Task {
            do {
                try await CaptureStreamStartup.start(
                    timeout: .milliseconds(50),
                    operation: {
                        defer { failed.fulfill() }
                        try await withCheckedThrowingContinuation { continuation in
                            callback.withLock { $0 = continuation }
                            registered.fulfill()
                        }
                    },
                    retire: {},
                    cleanup: { XCTFail("A late failure must not stop an unstarted stream") }
                )
                XCTFail("Expected timeout")
            } catch CaptureStreamStartupError.timedOut {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        await fulfillment(of: [registered], timeout: 2)
        await task.value
        callback.withLock { $0?.resume(throwing: StartFailure.rejected); $0 = nil }
        await fulfillment(of: [failed], timeout: 2)
    }

    private func assertAbandonedCaptureStartIsCleanedUp(cancel: Bool) async {
        let registered = expectation(description: "Start callback registered")
        let returned = expectation(description: "Caller returned before callback")
        let cleaned = expectation(description: "Late successful stream stopped once")
        cleaned.assertForOverFulfill = true
        let callback = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
        let delivery = CaptureSampleDelivery()
        let cleanupCount = OSAllocatedUnfairLock(initialState: 0)
        let task = Task {
            do {
                try await CaptureStreamStartup.start(
                    timeout: cancel ? .seconds(30) : .milliseconds(50),
                    operation: {
                        await withCheckedContinuation { continuation in
                            callback.withLock { $0 = continuation }
                            registered.fulfill()
                        }
                    },
                    retire: { delivery.invalidate() },
                    cleanup: {
                        XCTAssertFalse(delivery.isActive)
                        XCTAssertFalse(Task.isCancelled)
                        cleanupCount.withLock { $0 += 1 }
                        cleaned.fulfill()
                    }
                )
                XCTFail("Expected abandoned startup")
            } catch is CancellationError {
                XCTAssertTrue(cancel)
            } catch CaptureStreamStartupError.timedOut {
                XCTAssertFalse(cancel)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertFalse(delivery.isActive)
            returned.fulfill()
        }
        await fulfillment(of: [registered], timeout: 2)
        if cancel { task.cancel() }
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(cleanupCount.withLock { $0 }, 0)
        callback.withLock { $0?.resume(); $0 = nil }
        await fulfillment(of: [cleaned], timeout: 2)
        await task.value
        XCTAssertEqual(cleanupCount.withLock { $0 }, 1)
    }

    func testCaptureStreamShutdownReturnsBeforeLateCallback() async {
        let registered = expectation(description: "Stop registered")
        let deadlineReturned = expectation(description: "Stop deadline returned")
        let lateOperationReturned = expectation(description: "Late operation returned")
        let callback = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
        let delivery = CaptureSampleDelivery()
        delivery.invalidate()
        let stop = Task {
            do {
                try await CaptureStreamShutdown.stop(timeout: .milliseconds(50)) {
                    await withCheckedContinuation { continuation in
                        callback.withLock { $0 = continuation }
                        registered.fulfill()
                    }
                    XCTAssertFalse(delivery.isActive)
                    lateOperationReturned.fulfill()
                }
                XCTFail("Expected stream stop timeout")
            } catch CaptureStreamShutdownError.timedOut {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            deadlineReturned.fulfill()
        }
        await fulfillment(of: [registered, deadlineReturned], timeout: 2)
        callback.withLock { value in
            value?.resume()
            value = nil
        }
        await fulfillment(of: [lateOperationReturned], timeout: 2)
        await stop.value
    }

    func testCaptureStreamShutdownStillRunsWhenCallerIsCancelled() async {
        let callerReady = expectation(description: "Caller ready")
        let cleanupRan = expectation(description: "Cleanup ran")
        let resumeCaller = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
        let task = Task {
            await withCheckedContinuation { continuation in
                resumeCaller.withLock { $0 = continuation }
                callerReady.fulfill()
            }
            do {
                try await CaptureStreamShutdown.stop(timeout: .seconds(1)) {
                    XCTAssertFalse(Task.isCancelled)
                    cleanupRan.fulfill()
                }
            } catch {
                XCTFail("Cleanup should complete despite caller cancellation: \(error)")
            }
        }
        await fulfillment(of: [callerReady], timeout: 2)
        task.cancel()
        resumeCaller.withLock { $0?.resume(); $0 = nil }
        await fulfillment(of: [cleanupRan], timeout: 2)
        await task.value
    }

    func testCaptureStreamShutdownPreservesFrameworkError() async {
        enum StopFailure: Error { case rejected }
        do {
            try await CaptureStreamShutdown.stop { throw StopFailure.rejected }
            XCTFail("Expected framework failure")
        } catch StopFailure.rejected {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testMicrophonePermissionReturnsActualGrantAndDenial() async throws {
        let request = CaptureMicrophonePermissionRequest()
        let granted = try await request.request { $0(true) }
        XCTAssertTrue(granted)
        let denied = try await request.request { $0(false) }
        XCTAssertFalse(denied)
    }

    @MainActor
    func testMicrophonePermissionTimeoutDoesNotWaitForLateResponse() async {
        let request = CaptureMicrophonePermissionRequest()
        let registered = expectation(description: "Permission requested")
        let finished = expectation(description: "Permission deadline returned")
        let callback = OSAllocatedUnfairLock<(@Sendable (Bool) -> Void)?>(initialState: nil)
        let task = Task {
            do {
                _ = try await request.request(timeout: .milliseconds(50)) { completion in
                    callback.withLock { $0 = completion }
                    registered.fulfill()
                }
                XCTFail("Expected timeout")
            } catch NonJoiningTaskDeadlineError.timedOut {
                // Expected even while the system prompt is unanswered.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            finished.fulfill()
        }
        await fulfillment(of: [registered, finished], timeout: 2)
        callback.withLock { $0 }?(true)
        await task.value
    }

    @MainActor
    func testMicrophonePermissionSupersessionRejectsLateGrant() async throws {
        let request = CaptureMicrophonePermissionRequest()
        let registered = expectation(description: "First permission requested")
        let finished = expectation(description: "Superseded request cancelled")
        let callback = OSAllocatedUnfairLock<(@Sendable (Bool) -> Void)?>(initialState: nil)
        let first = Task {
            do {
                _ = try await request.request { completion in
                    callback.withLock { $0 = completion }
                    registered.fulfill()
                }
                XCTFail("Expected supersession cancellation")
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            finished.fulfill()
        }
        await fulfillment(of: [registered], timeout: 2)
        let denied = try await request.request { $0(false) }
        XCTAssertFalse(denied)
        await fulfillment(of: [finished], timeout: 2)
        callback.withLock { $0 }?(true)
        await first.value
    }

    @MainActor
    func testMicrophonePermissionParentCancellationReturnsBeforeCallback() async {
        let request = CaptureMicrophonePermissionRequest()
        let registered = expectation(description: "Permission requested")
        let finished = expectation(description: "Cancelled request returned")
        let callback = OSAllocatedUnfairLock<(@Sendable (Bool) -> Void)?>(initialState: nil)
        let task = Task {
            do {
                _ = try await request.request { completion in
                    callback.withLock { $0 = completion }
                    registered.fulfill()
                }
                XCTFail("Expected parent cancellation")
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            finished.fulfill()
        }
        await fulfillment(of: [registered], timeout: 2)
        task.cancel()
        await fulfillment(of: [finished], timeout: 2)
        callback.withLock { $0 }?(true)
        await task.value
    }

    @MainActor
    func testMicrophonePermissionExplicitStopReturnsBeforeCallback() async {
        let request = CaptureMicrophonePermissionRequest()
        let registered = expectation(description: "Permission requested")
        let finished = expectation(description: "Cancelled request returned")
        let callback = OSAllocatedUnfairLock<(@Sendable (Bool) -> Void)?>(initialState: nil)
        let task = Task {
            do {
                _ = try await request.request { completion in
                    callback.withLock { $0 = completion }
                    registered.fulfill()
                }
                XCTFail("Expected stop cancellation")
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            finished.fulfill()
        }
        await fulfillment(of: [registered], timeout: 2)
        request.cancel()
        await fulfillment(of: [finished], timeout: 2)
        callback.withLock { $0 }?(true)
        await task.value
    }

    func testScreenCaptureDiscoveryReturnsSnapshot() async throws {
        let snapshot = try await ScreenCaptureContentDiscovery.discover {
            ["display", "window"]
        }
        XCTAssertEqual(snapshot, ["display", "window"])
    }

    func testScreenCaptureDiscoveryTimesOutWithoutJoiningLateCallback() async {
        let registered = expectation(description: "Discovery started")
        let completed = expectation(description: "Discovery returned on deadline")
        let callback = OSAllocatedUnfairLock<CheckedContinuation<String, Never>?>(initialState: nil)
        let task = Task {
            do {
                _ = try await ScreenCaptureContentDiscovery.discover(timeout: .milliseconds(50)) {
                    await withCheckedContinuation { continuation in
                        callback.withLock { $0 = continuation }
                        registered.fulfill()
                    }
                }
                XCTFail("Expected discovery timeout")
            } catch ScreenCaptureContentDiscoveryError.timedOut {
                // Expected; the framework operation remains suspended.
            } catch {
                XCTFail("Unexpected discovery failure: \(error)")
            }
            completed.fulfill()
        }
        await fulfillment(of: [registered, completed], timeout: 2)
        let lateCallback = callback.withLock { value in
            defer { value = nil }
            return value
        }
        lateCallback?.resume(returning: "late display")
        await task.value
    }

    func testScreenCaptureDiscoveryCancellationDoesNotWaitForFramework() async {
        let registered = expectation(description: "Discovery started")
        let completed = expectation(description: "Discovery returned on cancellation")
        let callback = OSAllocatedUnfairLock<CheckedContinuation<String, Never>?>(initialState: nil)
        let task = Task {
            do {
                _ = try await ScreenCaptureContentDiscovery.discover(timeout: .seconds(30)) {
                    await withCheckedContinuation { continuation in
                        callback.withLock { $0 = continuation }
                        registered.fulfill()
                    }
                }
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                // Cancellation remains distinct from a capture-service timeout.
            } catch {
                XCTFail("Unexpected discovery failure: \(error)")
            }
            completed.fulfill()
        }
        await fulfillment(of: [registered], timeout: 2)
        task.cancel()
        await fulfillment(of: [completed], timeout: 2)
        let lateCallback = callback.withLock { value in
            defer { value = nil }
            return value
        }
        lateCallback?.resume(returning: "late display")
        await task.value
    }

    func testPersistedOptionsKeepExistingValuesAndExposeExactRates() {
        XCTAssertNil(CaptureFrameRateOption.auto.fixedValue)
        XCTAssertEqual(CaptureFrameRateOption(rawValue: "fps50")?.fixedValue, CaptureFrameRate(50))
        XCTAssertEqual(CaptureFrameRateOption(rawValue: "fps60")?.fixedValue, CaptureFrameRate(60))
        XCTAssertEqual(CaptureFrameRateOption.fps25.fixedValue, CaptureFrameRate(25))
        XCTAssertEqual(CaptureFrameRateOption.fps2997.fixedValue, CaptureFrameRate(30000, denominator: 1001))
        XCTAssertEqual(CaptureFrameRateOption.fps5994.fixedValue, CaptureFrameRate(60000, denominator: 1001))
    }

    func testRationalCadenceDoesNotAccumulateTimestampRounding() {
        for rate in [CaptureFrameRate(30000, denominator: 1001), CaptureFrameRate(60000, denominator: 1001)] {
            let index = 10_000_000
            let start = rate.presentationOffset(frameIndex: index)
            let next = rate.presentationOffset(frameIndex: index + 1)
            XCTAssertEqual(CMTimeCompare(CMTimeSubtract(next, start), rate.frameDuration), 0)
            XCTAssertEqual(start.value, Int64(index) * 1001)
            XCTAssertEqual(start.timescale, rate.numerator)
        }
    }

    func testDropFrameMinuteAndTenMinuteBoundaries() {
        for rate in [CaptureFrameRate(30000, denominator: 1001), CaptureFrameRate(60000, denominator: 1001)] {
            let multiplier = rate.nominalRate / 30
            XCTAssertEqual(rate.timecodeFrame(hour: 0, minute: 1, second: 0), 1800 * multiplier)
            XCTAssertEqual(rate.timecodeFrame(hour: 0, minute: 10, second: 0), 17982 * multiplier)
            XCTAssertEqual(rate.timecodeFrame(hour: 1, minute: 0, second: 0), 107892 * multiplier)
            XCTAssertNotEqual(rate.timecodeFlags & kCMTimeCodeFlag_DropFrame, 0)
        }
    }

    func testMidnightWrapsForDropFrameAndIntegerRates() {
        for rate in CaptureFrameRateOption.allCases.compactMap(\.fixedValue) {
            let last = rate.timecodeFrame(hour: 23, minute: 59, second: 59, nanosecond: 999_999_999)
            XCTAssertEqual(last, rate.framesPerTimecodeDay - 1)
            XCTAssertEqual(rate.wrappedTimecodeFrame(start: last, frameIndex: 1), 0)
            XCTAssertEqual(rate.wrappedTimecodeFrame(start: last, frameIndex: 2), 1)
            XCTAssertNotEqual(rate.timecodeFlags & kCMTimeCodeFlag_24HourMax, 0)
            if rate.denominator == 1 {
                XCTAssertEqual(rate.timecodeFlags & kCMTimeCodeFlag_DropFrame, 0)
            }
        }
    }

    func testGeneratedGrowingRecordingPersistsRationalCadenceAndTimecode() async throws {
        let rates = CaptureFrameRateOption.allCases.compactMap(\.fixedValue)
        let scenarios = rates.map { ($0, Duration.milliseconds(350)) } + rates.map { ($0, Duration.zero) }
        for (rate, captureDuration) in scenarios {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            defer { try? FileManager.default.removeItem(at: url) }
            let sourceTime = CMClockGetTime(CMClockGetHostTimeClock())
            let writer = try ScreenCaptureWriter(
                outputURL: url, fileType: .mov,
                videoSettings: CapturePreset.avcGrowing.videoSettings(width: 64, height: 64, frameRate: rate),
                audioSettings: CapturePreset.avcGrowing.audioSettings,
                dynamicRange: .sdr, includeMicrophone: false, isGrowing: true, frameRate: rate,
                currentTime: {
                    captureDuration == .zero ? sourceTime : CMClockGetTime(CMClockGetHostTimeClock())
                }
            )
            var pixelBuffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                                              [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(pixelBuffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)), 0, CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            var format: CMVideoFormatDescription?
            XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &format), noErr)
            var timing = CMSampleTimingInfo(duration: rate.frameDuration,
                                            presentationTimeStamp: sourceTime, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                                   formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
            writer.append(sampleBuffer: try XCTUnwrap(sample), type: .screen)
            // A single static screen frame must produce a CFR sequence via the real pump.
            // Immediate stop must flush the captured frame even before the first
            // timer tick; longer recordings exercise duplicate-frame pumping.
            if captureDuration > .zero { try await Task.sleep(for: captureDuration) }
            try await writer.finish()
            let asset = AVURLAsset(url: url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let video = try XCTUnwrap(videoTracks.first)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var timestamps: [CMTime] = []
            var durations: [CMTime] = []
            while let sample = output.copyNextSampleBuffer() {
                // AssetReader also returns zero-sample boundary/empty-edit markers.
                // Only encoded video samples describe the persisted frame cadence.
                guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 1)
                XCTAssertGreaterThan(CMSampleBufferGetTotalSampleSize(sample), 0)
                XCTAssertTrue(CMSampleBufferGetPresentationTimeStamp(sample).isNumeric)
                timestamps.append(CMSampleBufferGetPresentationTimeStamp(sample))
                durations.append(CMSampleBufferGetDuration(sample))
            }
            if captureDuration > .zero {
                XCTAssertGreaterThan(timestamps.count, 2)
            } else {
                XCTAssertEqual(timestamps.count, 1, "A frozen stop clock must produce exactly one frame at \(rate)")
            }
            for (previous, next) in zip(timestamps, timestamps.dropFirst()) {
                XCTAssertEqual(CMTimeCompare(CMTimeSubtract(next, previous), rate.frameDuration), 0, "Rate \(rate), previous \(previous), next \(next), delta \(CMTimeSubtract(next, previous))")
            }
            XCTAssertEqual(CMTimeCompare(try XCTUnwrap(durations.last), rate.frameDuration), 0, "Last frame duration at \(rate): \(durations)")
            let videoRange = try await video.load(.timeRange)
            XCTAssertEqual(CMTimeCompare(videoRange.duration, rate.presentationOffset(frameIndex: timestamps.count)), 0, "Video duration at \(rate): \(videoRange), frame count \(timestamps.count)")
            let timecodeTracks = try await asset.loadTracks(withMediaType: .timecode)
            let timecode = try XCTUnwrap(timecodeTracks.first)
            let timecodeReader = try AVAssetReader(asset: asset)
            let timecodeOutput = AVAssetReaderTrackOutput(track: timecode, outputSettings: nil)
            timecodeReader.add(timecodeOutput)
            XCTAssertTrue(timecodeReader.startReading())
            var timecodeTimestamps: [CMTime] = []
            while let sample = timecodeOutput.copyNextSampleBuffer() {
                guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                timecodeTimestamps.append(CMSampleBufferGetPresentationTimeStamp(sample))
            }
            XCTAssertEqual(timecodeTimestamps.count, timestamps.count)
            for (videoPTS, timecodePTS) in zip(timestamps, timecodeTimestamps) {
                XCTAssertEqual(CMTimeCompare(videoPTS, timecodePTS), 0)
            }
            let descriptions = try await timecode.load(.formatDescriptions)
            let timecodeFormat = try XCTUnwrap(descriptions.first)
            XCTAssertEqual(CMTimeCompare(CMTimeCodeFormatDescriptionGetFrameDuration(timecodeFormat), rate.frameDuration), 0)
            XCTAssertEqual(CMTimeCodeFormatDescriptionGetFrameQuanta(timecodeFormat), UInt32(rate.nominalRate))
            XCTAssertEqual(CMTimeCodeFormatDescriptionGetTimeCodeFlags(timecodeFormat), rate.timecodeFlags)
        }
    }

    func testAutoRateFollowsFractionalRefreshRates() {
        XCTAssertEqual(CaptureFrameRate.display(refreshRate: 59.94006, maximumFramesPerSecond: 60, fallback: 60), CaptureFrameRate(60000, denominator: 1001))
        XCTAssertEqual(CaptureFrameRate.display(refreshRate: 59.94, maximumFramesPerSecond: 59, fallback: 60), CaptureFrameRate(60000, denominator: 1001))
        XCTAssertEqual(CaptureFrameRate.display(refreshRate: 23.976, maximumFramesPerSecond: 24, fallback: 60), CaptureFrameRate(24000, denominator: 1001))
        XCTAssertEqual(CaptureFrameRate.display(refreshRate: 29.97, maximumFramesPerSecond: 0, fallback: 60), CaptureFrameRate(30000, denominator: 1001))
        XCTAssertEqual(CaptureFrameRate.display(refreshRate: 60, maximumFramesPerSecond: 60, fallback: 30), CaptureFrameRate(60))
        // Built-in panels report no mode refresh rate.
        XCTAssertEqual(CaptureFrameRate.display(refreshRate: 0, maximumFramesPerSecond: 120, fallback: 60), CaptureFrameRate(120))
        // A variable-refresh display that can run faster keeps its maximum.
        XCTAssertEqual(CaptureFrameRate.display(refreshRate: 59.94, maximumFramesPerSecond: 120, fallback: 60), CaptureFrameRate(120))
        // Rates that are not 1000/1001 of an integer stay integral.
        XCTAssertEqual(CaptureFrameRate.display(refreshRate: 74.97, maximumFramesPerSecond: 75, fallback: 60), CaptureFrameRate(75))
        XCTAssertEqual(CaptureFrameRate.display(refreshRate: 0, maximumFramesPerSecond: 0, fallback: 30), CaptureFrameRate(30))
    }

    /// ScreenCaptureKit runs faster than the target; the schedule must pick the ideal
    /// mix of whole-refresh gaps and hold the exact long-run rate.
    func testScheduleKeepsExactRateFromRefreshAlignedFrames() {
        var seed: UInt64 = 42
        func jitter() -> Double {   // ±0.05 ms of timestamp noise
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Double(seed >> 11) / Double(1 << 53) - 0.5) * 0.0001
        }
        let cases: [(refresh: Double, rate: CaptureFrameRate)] = [
            (60, CaptureFrameRate(25)), (60, CaptureFrameRate(30000, denominator: 1001)),
            (60, CaptureFrameRate(50)), (60, CaptureFrameRate(60000, denominator: 1001)), (60, CaptureFrameRate(60)),
            (60, CaptureFrameRate(24000, denominator: 1001)), (60, CaptureFrameRate(120)),
            (120, CaptureFrameRate(25)), (120, CaptureFrameRate(30000, denominator: 1001)), (120, CaptureFrameRate(50)),
            (120, CaptureFrameRate(60)), (48, CaptureFrameRate(25)), (50, CaptureFrameRate(25))
        ]
        for (refresh, rate) in cases {
            var schedule = CaptureFrameSchedule(frameRate: rate)
            let seconds = 120.0
            var kept: [Int] = []
            for index in 0..<Int(seconds * refresh) {
                let time = 1000 + Double(index) / refresh + jitter()
                if schedule.keeps(CMTime(seconds: time, preferredTimescale: 1_000_000_000)) { kept.append(index) }
            }
            let expected = min(rate.framesPerSecond, refresh)
            XCTAssertEqual(Double(kept.count) / seconds, expected, accuracy: expected * 0.002, "\(rate) at \(refresh) Hz")
            let ideal = refresh / rate.framesPerSecond
            let allowed: Set<Int> = [max(1, Int(ideal.rounded(.down))), max(1, Int(ideal.rounded(.up)))]
            let gaps = Set(zip(kept, kept.dropFirst()).map { $1 - $0 })
            XCTAssertTrue(gaps.isSubset(of: allowed), "\(rate) at \(refresh) Hz: gaps \(gaps), allowed \(allowed)")
        }
    }

    func testScheduleRestartsAfterStaticScreenWithoutBursting() {
        var schedule = CaptureFrameSchedule(frameRate: CaptureFrameRate(25))
        let at = { (seconds: Double) in CMTime(seconds: seconds, preferredTimescale: 1_000_000_000) }
        XCTAssertTrue(schedule.keeps(at(0)))
        XCTAssertTrue(schedule.keeps(at(2)))             // first change after two static seconds
        XCTAssertFalse(schedule.keeps(at(2 + 1.0 / 60)))
        XCTAssertTrue(schedule.keeps(at(2 + 2.0 / 60)))
    }

    /// Growing presets: the pump fills slots from `sessionStartPTS`, whatever its phase
    /// against the display refresh. Each slot must get its own kept frame.
    func testAnchoredScheduleFillsEveryPumpSlotOnce() {
        var seed: UInt64 = 7
        func jitter() -> Double {   // ±0.05 ms of timestamp noise
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Double(seed >> 11) / Double(1 << 53) - 0.5) * 0.0001
        }
        let rates = [
            CaptureFrameRate(24), CaptureFrameRate(24000, denominator: 1001), CaptureFrameRate(25),
            CaptureFrameRate(30000, denominator: 1001), CaptureFrameRate(50)
        ]
        let at = { (seconds: Double) in CMTime(seconds: seconds, preferredTimescale: 1_000_000_000) }
        for refresh in [60.0, 60000.0 / 1001] {
            for rate in rates {
                let interval = 1 / rate.framesPerSecond
                let pumpDelay = interval / 2 + 0.04
                let capacity = Int((pumpDelay * rate.framesPerSecond).rounded(.up)) + 2
                for step in 0..<40 {
                    let firstFrame = 1000.0
                    let start = firstFrame - interval * (Double(step) + 0.5) / 40
                    var schedule = CaptureFrameSchedule(frameRate: rate)
                    schedule.anchor(toSlotsFrom: at(start))
                    var queue = CaptureFrameQueue<Int>(capacity: capacity)
                    var kept: [Int] = []
                    var emitted: [Int] = []
                    // The first slot whose window holds the first frame; earlier ones can only repeat it.
                    let firstSlot = step < 20 ? 0 : 1
                    var slot = 0
                    for index in 0..<Int(20 * refresh) {
                        let time = firstFrame + Double(index) / refresh + (index == 0 ? 0 : jitter())
                        while start + Double(slot) * interval <= time - pumpDelay {
                            let frame = queue.frame(forSlotAt: at(start + Double(slot) * interval), halfInterval: at(interval / 2))
                            if slot >= firstSlot, let frame { emitted.append(frame) }
                            slot += 1
                        }
                        if schedule.keeps(at(time)) {
                            kept.append(index)
                            queue.append(index, at: at(time))
                        }
                    }
                    let context = "\(rate.framesPerSecond) fps at \(refresh) Hz, first frame \(step).5/40 of an interval after the first slot"
                    XCTAssertEqual(Set(emitted).count, emitted.count, "Repeated frames: \(context)")
                    XCTAssertEqual(Array(kept.prefix(emitted.count)), emitted, "Dropped frames: \(context)")
                    XCTAssertGreaterThan(emitted.count, Int(19 * rate.framesPerSecond), context)
                }
            }
        }
    }

    func testFrameQueueFillsSlotsByCaptureTime() {
        let ms = { (value: Int64) in CMTime(value: value, timescale: 1000) }
        var queue = CaptureFrameQueue<Int>(capacity: 8)
        // 25 fps kept from a 60 Hz display: 2- and 3-refresh gaps around 40 ms slots.
        for (index, time) in [Int64(0), 33, 83, 117, 167].enumerated() { queue.append(index, at: ms(time)) }
        let slots = [Int64(0), 40, 80, 120, 160, 200].map { queue.frame(forSlotAt: ms($0), halfInterval: ms(20)) }
        XCTAssertEqual(slots, [0, 1, 2, 3, 4, 4], "Every captured frame fills a slot; a static screen repeats the last")
        // A retry after encoder backpressure gets the same frame.
        XCTAssertEqual(queue.frame(forSlotAt: ms(200), halfInterval: ms(20)), 4)
        XCTAssertEqual(queue.frames.count, 1)

        var bounded = CaptureFrameQueue<Int>(capacity: 2)
        for index in 0..<5 { bounded.append(index, at: ms(Int64(index) * 10)) }
        XCTAssertEqual(bounded.frames.map(\.frame), [3, 4])
    }

    func testCadenceStatsBucketsIntervalsAndStaticGaps() {
        var stats = CaptureCadenceStats()
        var time = CMTime(value: 0, timescale: 600)
        for _ in 0..<4 {
            stats.record(presentationTime: time)
            time = CMTimeAdd(time, CMTime(value: 30, timescale: 600))   // 50 ms
        }
        time = CMTimeAdd(time, CMTime(value: 3, timescale: 1))
        stats.record(presentationTime: time)
        XCTAssertEqual(stats.frameCount, 5)
        XCTAssertEqual(stats.intervalCounts, [50: 3, CaptureCadenceStats.staticGapMilliseconds: 1])
        XCTAssertEqual(stats.summary, "50 ms ×3, ≥250 ms ×1")
        XCTAssertEqual(CaptureCadenceStats().summary, "none")
    }

    /// Finalizing another display's file can take seconds; the pump must not keep
    /// adding frames after delivery stopped, or video runs past the audio.
    func testFrozenEndpointEndsGrowingRecordingAtDeliveryCutoff() async throws {
        for rate in [CaptureFrameRate(25), CaptureFrameRate(30000, denominator: 1001)] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            defer { try? FileManager.default.removeItem(at: url) }
            let clock = OSAllocatedUnfairLock(initialState: CMTime.zero)
            let writer = try ScreenCaptureWriter(
                outputURL: url, fileType: .mov,
                videoSettings: CapturePreset.avcGrowing.videoSettings(width: 64, height: 64, frameRate: rate),
                audioSettings: CapturePreset.avcGrowing.audioSettings,
                dynamicRange: .sdr, includeMicrophone: false, isGrowing: true, frameRate: rate,
                currentTime: { clock.withLock { $0 } }
            )
            writer.append(sampleBuffer: try makeScreenSample(at: .zero, rate: rate), type: .screen)
            // 5.25 frame durations in: frames 0...5 are due when delivery stops.
            clock.withLock { $0 = CMTimeMultiplyByFloat64(rate.frameDuration, multiplier: 5.25) }
            writer.freezeEndpoint()
            clock.withLock { $0 = CMTime(value: 3, timescale: 1) }
            try await Task.sleep(for: .milliseconds(150))   // several pump ticks
            try await writer.finish()

            let tracks = try await AVURLAsset(url: url).loadTracks(withMediaType: .video)
            let video = try XCTUnwrap(tracks.first)
            let range = try await video.load(.timeRange)
            XCTAssertEqual(CMTimeCompare(range.duration, rate.presentationOffset(frameIndex: 6)), 0, "Video duration at \(rate): \(range.duration)")
        }
    }

    private func makeScreenSample(at time: CMTime, rate: CaptureFrameRate) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                                          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)), 0, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: rate.frameDuration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                               formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    func testContinuouslyReadyBacklogYieldsBetweenBoundedPasses() throws {
        var emitted = 0
        let drained = try CaptureFrameEmission.drain(
            remainingFrameCount: 1_000_000, checkDeadline: {},
            emit: { emitted += 1; return true }
        )
        XCTAssertFalse(drained)
        XCTAssertEqual(emitted, 32)
    }

    func testDeadlineInterruptsAReadyBacklogInsideTheEmissionPass() {
        enum Failure: Error { case deadline }
        var emitted = 0
        XCTAssertThrowsError(try CaptureFrameEmission.drain(
            remainingFrameCount: 1_000_000,
            checkDeadline: { if emitted == 3 { throw Failure.deadline } },
            emit: { emitted += 1; return true }
        )) { XCTAssertEqual($0 as? Failure, .deadline) }
        XCTAssertEqual(emitted, 3)
    }

    func testTimecodeBackpressureDefersBothTracksUntilRetry() throws {
        var videoFrames = 0
        var timecodeFrames = 0
        for ready in [false, false, true] {
            let emitted = try CaptureFrameEmission.append(
                videoReady: true, timecodeReady: ready,
                appendVideo: { videoFrames += 1 },
                appendTimecode: { timecodeFrames += 1 }
            )
            XCTAssertEqual(emitted, ready)
            XCTAssertEqual(videoFrames, ready ? 1 : 0)
            XCTAssertEqual(timecodeFrames, videoFrames)
        }
    }

    func testVideoBackpressureDoesNotAdvanceTimecode() throws {
        let emitted = try CaptureFrameEmission.append(
            videoReady: false, timecodeReady: true,
            appendVideo: { XCTFail("Blocked video must not be appended") },
            appendTimecode: { XCTFail("Timecode must wait for video") }
        )
        XCTAssertFalse(emitted)
    }

    func testTrackAppendErrorsPropagateInsteadOfReportingACompletedFrame() {
        enum Failure: Error { case video, timecode }
        XCTAssertThrowsError(try CaptureFrameEmission.append(
            videoReady: true, timecodeReady: true,
            appendVideo: { throw Failure.video },
            appendTimecode: { XCTFail("Timecode must not advance after failed video") }
        )) { XCTAssertEqual($0 as? Failure, .video) }
        var videoAppended = false
        XCTAssertThrowsError(try CaptureFrameEmission.append(
            videoReady: true, timecodeReady: true,
            appendVideo: { videoAppended = true },
            appendTimecode: { throw Failure.timecode }
        )) { XCTAssertEqual($0 as? Failure, .timecode) }
        XCTAssertTrue(videoAppended)
    }

    func testCoreMediaTimecodeDescriptionRetainsExactDurationAndFlags() throws {
        for rate in CaptureFrameRateOption.allCases.compactMap(\.fixedValue) {
            var format: CMTimeCodeFormatDescription?
            let status = CMTimeCodeFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
                frameDuration: rate.frameDuration, frameQuanta: UInt32(rate.nominalRate),
                flags: rate.timecodeFlags, extensions: nil, formatDescriptionOut: &format
            )
            XCTAssertEqual(status, noErr)
            let description = try XCTUnwrap(format)
            XCTAssertEqual(CMTimeCompare(CMTimeCodeFormatDescriptionGetFrameDuration(description), rate.frameDuration), 0)
            XCTAssertEqual(CMTimeCodeFormatDescriptionGetFrameQuanta(description), UInt32(rate.nominalRate))
            XCTAssertEqual(CMTimeCodeFormatDescriptionGetTimeCodeFlags(description), rate.timecodeFlags)
        }
    }
}

@MainActor
private final class MeterSessionStub: AudioMeterCaptureSession {
    var startGate: CheckedContinuation<Void, Never>?
    var stopGate: CheckedContinuation<Void, Never>?
    var stallsStart = false
    var stallsStop = false
    var starts = 0
    var stops = 0
    var levels: (@MainActor (UniversalAudioMeterService.AudioLevels) -> Void)?

    func configure(
        levels: @escaping @MainActor (UniversalAudioMeterService.AudioLevels) -> Void,
        bands: @escaping @MainActor ([Float]) -> Void
    ) { self.levels = levels }
    func reloadFrequencySettings() {}
    func start() async throws {
        starts += 1
        if stallsStart { await withCheckedContinuation { startGate = $0 } }
    }
    func stop() async throws {
        stops += 1
        if stallsStop { await withCheckedContinuation { stopGate = $0 } }
    }
}

extension CaptureFrameRateTests {
    @MainActor
    func testAudioMeterStopBoundsStalledCallbackAndRejectsLateSamples() async throws {
        let session = MeterSessionStub()
        let meter = UniversalAudioMeterService(timeout: .milliseconds(30)) { session }
        await meter.startMonitoring()
        XCTAssertTrue(meter.isMonitoring)
        session.levels?(.init(leftChannel: -4, rightChannel: -4, peak: -4))
        XCTAssertEqual(meter.currentLevels.peak, -4)
        session.stallsStop = true
        let before = ContinuousClock.now
        await meter.stopMonitoring()
        XCTAssertLessThan(before.duration(to: .now), .seconds(1))
        XCTAssertFalse(meter.isMonitoring)
        session.levels?(.init(leftChannel: -2, rightChannel: -2, peak: -2))
        XCTAssertEqual(meter.currentLevels.peak, -60)
        session.stopGate?.resume()
        session.stopGate = nil
    }

    @MainActor
    func testAudioMeterStartTimeoutCleansUpLateStartWithoutReplacingRetry() async throws {
        let old = MeterSessionStub()
        old.stallsStart = true
        let fresh = MeterSessionStub()
        var count = 0
        let meter = UniversalAudioMeterService(timeout: .milliseconds(30)) {
            count += 1
            return count == 1 ? old : fresh
        }
        let before = ContinuousClock.now
        await meter.startMonitoring()
        XCTAssertLessThan(before.duration(to: .now), .seconds(1))
        XCTAssertFalse(meter.isMonitoring)
        XCTAssertEqual(old.stops, 1)
        await meter.startMonitoring()
        XCTAssertTrue(meter.isMonitoring)
        old.startGate?.resume()
        old.startGate = nil
        try await waitForAudioMeterState("late start cleanup") { old.stops >= 2 }
        XCTAssertEqual(old.stops, 2)
        XCTAssertTrue(meter.isMonitoring)
        old.levels?(.init(leftChannel: -2, rightChannel: -2, peak: -2))
        XCTAssertEqual(meter.currentLevels.peak, -60)
        await meter.stopMonitoring()
    }

    @MainActor
    func testAudioMeterStopDuringDiscoveryPreventsStreamStart() async throws {
        let session = MeterSessionStub()
        var gate: CheckedContinuation<Void, Never>?
        let meter = UniversalAudioMeterService(timeout: .seconds(5)) {
            await withCheckedContinuation { gate = $0 }
            return session
        }
        let start = Task { await meter.startMonitoring() }
        try await waitForAudioMeterState("discovery started") { gate != nil }
        await meter.stopMonitoring()
        await start.value
        gate?.resume()
        gate = nil
        try await waitForAudioMeterState("cancelled discovery cleanup") { session.stops > 0 }
        XCTAssertEqual(session.starts, 0)
        XCTAssertEqual(session.stops, 1)
        XCTAssertFalse(meter.isMonitoring)
    }

    @MainActor
    func testAudioMeterParentCancellationStopsPendingStartPromptly() async throws {
        let session = MeterSessionStub()
        session.stallsStart = true
        let meter = UniversalAudioMeterService(timeout: .seconds(5)) { session }
        let start = Task { await meter.startMonitoring() }
        try await waitForAudioMeterState("stream start pending") { session.startGate != nil }
        let before = ContinuousClock.now
        start.cancel()
        await start.value
        XCTAssertLessThan(before.duration(to: .now), .seconds(1))
        XCTAssertFalse(meter.isMonitoring)
        XCTAssertEqual(session.stops, 1)
        session.startGate?.resume()
        session.startGate = nil
        try await waitForAudioMeterState("late cancelled start cleanup") { session.stops >= 2 }
        XCTAssertEqual(session.stops, 2)
    }
}

/// A broken lifecycle must fail the test rather than leave its readiness wait suspended.
@MainActor
private func waitForAudioMeterState(
    _ description: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    predicate: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !predicate() {
        guard ContinuousClock.now < deadline else {
            XCTFail("Timed out waiting for \(description)", file: file, line: line)
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}
