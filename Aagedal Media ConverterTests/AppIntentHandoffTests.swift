import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class AppIntentHandoffTests: XCTestCase {
    private let first = URL(fileURLWithPath: "/fixtures/first.mov")
    private let second = URL(fileURLWithPath: "/fixtures/second.mov")
    private let folder = URL(fileURLWithPath: "/outputs")

    func testEnqueueAcceptsSingleAndOrderedMultipleURLs() {
        for (object, expected) in [(first as Any, [first]), ([second, first] as Any, [second, first])] {
            guard case let .enqueue(urls) = AppIntentHandoff(
                notification: Notification(name: .enqueueFileURL, object: object), selectedPreset: .videoLoop
            ) else { return XCTFail("Expected enqueue") }
            XCTAssertEqual(urls, expected)
        }
    }

    func testConversionUsesRequestedPresetAndLegacySingleFile() {
        guard case let .convert(files, output, preset) = AppIntentHandoff(
            notification: Notification(name: .convertImmediately, userInfo: [
                "fileURL": first, "outputFolderURL": folder, "presetRawValue": ExportPreset.audioOnly.rawValue
            ]), selectedPreset: .videoLoop
        ) else { return XCTFail("Expected conversion") }
        XCTAssertEqual(files, [first])
        XCTAssertEqual(output, folder)
        XCTAssertEqual(preset, .audioOnly)
    }

    func testConversionPreservesFileOrderAndFallsBackFromUnknownPreset() {
        guard case let .convert(files, _, preset) = AppIntentHandoff(
            notification: Notification(name: .convertImmediately, userInfo: [
                "fileURLs": [second, first], "outputFolderURL": folder, "presetRawValue": "unknown"
            ]), selectedPreset: .videoLoop
        ) else { return XCTFail("Expected conversion") }
        XCTAssertEqual(files, [second, first])
        XCTAssertEqual(preset, .videoLoop)
    }

    func testPickerDefaultsToConvertButSupportsEnqueueOnly() {
        for shouldConvert in [true, false] {
            let info: [AnyHashable: Any] = shouldConvert ? [:] : ["startConversion": false]
            guard case let .pickFiles(preset, start) = AppIntentHandoff(
                notification: Notification(name: .convertPickFiles, userInfo: info), selectedPreset: .videoLoop
            ) else { return XCTFail("Expected picker") }
            XCTAssertEqual(start, shouldConvert)
            XCTAssertEqual(preset, .videoLoop)
        }
    }

    func testMalformedAndUnrelatedNotificationsAreRejected() {
        let notifications = [
            Notification(name: .enqueueFileURL, object: "not a URL"),
            Notification(name: .convertImmediately, userInfo: ["fileURL": first]),
            Notification(name: .convertImmediately, userInfo: ["outputFolderURL": folder]),
            Notification(name: Notification.Name("unrelated"))
        ]
        for notification in notifications {
            XCTAssertNil(AppIntentHandoff(notification: notification, selectedPreset: .videoLoop))
        }
    }

    func testSharedBridgeMapsOnlyInitialSupportedPresets() {
        let expected: [(ExportPreset, ApplicationPresetID)] = [
            (.h264, .h264), (.h265, .hevc), (.prores, .proRes),
            (.proxy, .proxy), (.audioOnly, .audioOnly), (.streamCopy, .streamCopy)
        ]
        for (preset, applicationID) in expected {
            XCTAssertEqual(ApplicationPresetID(exportPreset: preset), applicationID)
            XCTAssertEqual(applicationID.exportPreset, preset)
        }
        XCTAssertNil(ApplicationPresetID(exportPreset: .videoLoop))
        XCTAssertNil(ApplicationPresetID(exportPreset: .av1))
        XCTAssertNil(ApplicationPresetID(exportPreset: .dcp))
        XCTAssertNil(ApplicationPresetID(exportPreset: .custom1))
    }

    func testSharedBridgeCapturesAppIntentIdentitySettingsAndOrderedUniqueSources() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(CodecContainer.mov.rawValue, forKey: AppConstants.h264ContainerKey)
        defaults.set(true, forKey: AppConstants.includeDateTagPreferenceKey)
        defaults.set("manual", forKey: AppConstants.defaultTimecodeModeKey)
        defaults.set("01:02:03:04", forKey: AppConstants.defaultTimecodeValueKey)
        defaults.set("Shot", forKey: AppConstants.commentPrefixKey)
        let requestID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let capturedAt = Date(timeIntervalSince1970: 1234)

        let request = try XCTUnwrap(AppIntentApplicationJobBridge.makeRequest(
            sourceURLs: [second, first, second],
            destinationFolderURL: folder,
            preset: .h264,
            requestID: requestID,
            capturedAt: capturedAt,
            defaults: defaults
        ))

        XCTAssertEqual(request.requestID, requestID)
        XCTAssertEqual(request.origin, .appIntent)
        XCTAssertEqual(request.requesterID, AppIntentApplicationJobBridge.requesterID)
        XCTAssertEqual(request.sourceURLs, [second, first])
        XCTAssertEqual(request.destinationFolderURL, folder)
        XCTAssertEqual(request.presetID, .h264)
        XCTAssertEqual(request.presetSettings.containerID, .mov)
        XCTAssertEqual(request.executionSettings?.includeDateTag, true)
        XCTAssertEqual(request.executionSettings?.timecodeMode, .manual)
        XCTAssertEqual(request.executionSettings?.manualTimecode, "01:02:03:04")
        XCTAssertEqual(request.executionSettings?.comment.prefix, "Shot")
        XCTAssertEqual(request.idempotencyKey, requestID.uuidString.lowercased())
        XCTAssertEqual(request.capturedAt, capturedAt)
    }

    func testSharedBridgeRejectsUnsupportedOrEmptySubmissions() throws {
        let defaults = try makeIsolatedDefaults()
        XCTAssertNil(AppIntentApplicationJobBridge.makeRequest(
            sourceURLs: [first], destinationFolderURL: folder,
            preset: .videoLoop, requestID: UUID(), defaults: defaults
        ))
        XCTAssertNil(AppIntentApplicationJobBridge.makeRequest(
            sourceURLs: [], destinationFolderURL: folder,
            preset: .h264, requestID: UUID(), defaults: defaults
        ))

        defaults.set(true, forKey: AppConstants.saveNextToOriginalKey)
        XCTAssertNil(AppIntentApplicationJobBridge.makeRequest(
            sourceURLs: [first], destinationFolderURL: folder,
            preset: .h264, requestID: UUID(), defaults: defaults
        ))
    }

    func testManualBridgeCapturesOrderedRowsAndTheirExecutionSettings() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(CodecContainer.mov.rawValue, forKey: AppConstants.h264ContainerKey)
        var firstItem = makeItem(url: second)
        firstItem.includeDateTag = false
        firstItem.timecodeConfig = TimecodeConfig(mode: .manual("01:02:03:04"))
        var secondItem = makeItem(url: first)
        secondItem.includeDateTag = false
        secondItem.timecodeConfig = firstItem.timecodeConfig
        let capturedAt = Date(timeIntervalSince1970: 5678)

        let request = try XCTUnwrap(ManualApplicationJobBridge.makeRequest(
            items: [firstItem, secondItem],
            destinationFolderURL: folder,
            preset: .h264,
            mergeClipsEnabled: false,
            capturedAt: capturedAt,
            defaults: defaults
        ))

        XCTAssertEqual(request.origin, .manual)
        XCTAssertEqual(request.requesterID, ManualApplicationJobBridge.requesterID)
        XCTAssertEqual(request.sourceURLs, [second, first])
        XCTAssertEqual(request.destinationFolderURL, folder)
        XCTAssertEqual(request.presetID, .h264)
        XCTAssertEqual(request.presetSettings.containerID, .mov)
        XCTAssertEqual(request.executionSettings?.includeDateTag, false)
        XCTAssertEqual(request.executionSettings?.timecodeMode, .manual)
        XCTAssertEqual(request.executionSettings?.manualTimecode, "01:02:03:04")
        XCTAssertNil(request.idempotencyKey)
        XCTAssertEqual(request.capturedAt, capturedAt)

        defaults.set(CodecContainer.mp4.rawValue, forKey: AppConstants.h264ContainerKey)
        let summary = request.acceptedSettingsSummary
        XCTAssertTrue(summary.contains("Container: MOV"))
        XCTAssertTrue(summary.contains("Timecode: 01:02:03:04"))
        XCTAssertTrue(summary.contains("Destination: /outputs"))
    }

    func testManualBridgeFallsBackWhenBehaviorCannotBeRepresented() throws {
        let defaults = try makeIsolatedDefaults()
        let ordinary = makeItem(url: first)

        XCTAssertNil(ManualApplicationJobBridge.makeRequest(
            items: [ordinary], destinationFolderURL: folder, preset: .videoLoop,
            mergeClipsEnabled: false, defaults: defaults
        ))
        XCTAssertNil(ManualApplicationJobBridge.makeRequest(
            items: [ordinary], destinationFolderURL: folder, preset: .h264,
            mergeClipsEnabled: true, defaults: defaults
        ))

        var customized = ordinary
        customized.trimStart = 1
        XCTAssertNil(ManualApplicationJobBridge.makeRequest(
            items: [customized], destinationFolderURL: folder, preset: .h264,
            mergeClipsEnabled: false, defaults: defaults
        ))

        var differentExecutionSettings = makeItem(url: second)
        differentExecutionSettings.includeDateTag.toggle()
        XCTAssertNil(ManualApplicationJobBridge.makeRequest(
            items: [ordinary, differentExecutionSettings], destinationFolderURL: folder,
            preset: .h264, mergeClipsEnabled: false, defaults: defaults
        ))
    }

    @MainActor
    func testSharedBridgePersistsReadAndWritableIntentGrants() throws {
        let defaults = try makeIsolatedDefaults()
        let bookmarks = SecurityScopedBookmarkManager(
            defaults: defaults,
            createBookmark: { url, _ in Data(url.absoluteString.utf8) },
            resolveData: { data in
                let value = String(decoding: data, as: UTF8.self)
                return (try XCTUnwrap(URL(string: value)), false)
            },
            startScope: { _ in true },
            stopScope: { _ in }
        )

        AppIntentApplicationJobBridge.persistFileAccess(
            sourceURLs: [first, second, first],
            destinationFolderURL: folder,
            bookmarks: bookmarks
        )

        guard case .bookmark = bookmarks.startAccessingStoredBookmark(
            containing: first,
            requiresWriteAccess: false
        ) else { return XCTFail("Expected the source read grant") }
        guard case .bookmark = bookmarks.startAccessingStoredBookmark(
            containing: folder.appendingPathComponent("output.mov"),
            requiresWriteAccess: true
        ) else { return XCTFail("Expected the destination write grant") }
    }

    private func makeItem(url: URL) -> VideoItem {
        VideoItem(
            url: url,
            name: url.lastPathComponent,
            size: 1,
            duration: "00:00:01",
            status: .waiting,
            progress: 0,
            eta: nil
        )
    }

    @MainActor
    func testBufferedRequestsReplayInSubmissionOrderOnlyOnce() {
        var received: [Int] = []
        var receiverReady = false
        var requests: PendingAppIntentRequests!
        requests = PendingAppIntentRequests { notification in
            guard receiverReady, requests.claim(notification) else { return }
            received.append(notification.object as! Int)
        }
        for index in 0..<20 {
            requests.submit(name: .enqueueFileURL, object: index,
                            userInfo: [PendingAppIntentRequests.requestIDKey: UUID()])
        }
        receiverReady = true
        requests.drain()
        XCTAssertEqual(received, Array(0..<20))
        requests.drain()
        XCTAssertEqual(received, Array(0..<20))
    }

    @MainActor
    func testConsumedAndUnbufferedRequestsAreNotReplayed() {
        var received: [Int] = []
        let requests = PendingAppIntentRequests { received.append($0.object as! Int) }
        let id = UUID()
        requests.submit(name: .enqueueFileURL, object: 1, userInfo: [PendingAppIntentRequests.requestIDKey: id])
        requests.consume(id: id)
        requests.submit(name: .enqueueFileURL, object: 2, userInfo: [:])
        requests.drain()
        XCTAssertEqual(received, [1, 2])
    }

    @MainActor
    func testRepeatedPendingIDRetainsPositionAndLatestPayload() {
        var received: [Int] = []
        let requests = PendingAppIntentRequests { received.append($0.object as! Int) }
        let id = UUID()
        requests.submit(name: .enqueueFileURL, object: 1, userInfo: [PendingAppIntentRequests.requestIDKey: id])
        requests.submit(name: .enqueueFileURL, object: 2, userInfo: [PendingAppIntentRequests.requestIDKey: UUID()])
        requests.submit(name: .enqueueFileURL, object: 3, userInfo: [PendingAppIntentRequests.requestIDKey: id])
        received.removeAll()
        requests.drain()
        XCTAssertEqual(received, [3, 2])
    }
    @MainActor
    func testDrainBeforeReceiversAreReadyRetainsRequests() {
        var receiverReady = false
        var received: [Int] = []
        var requests: PendingAppIntentRequests!
        requests = PendingAppIntentRequests { notification in
            guard receiverReady, requests.claim(notification) else { return }
            received.append(notification.object as! Int)
        }
        requests.submit(name: .enqueueFileURL, object: 1,
                        userInfo: [PendingAppIntentRequests.requestIDKey: UUID()])
        requests.drain()
        requests.drain()
        XCTAssertTrue(received.isEmpty)
        receiverReady = true
        requests.drain()
        requests.drain()
        XCTAssertEqual(received, [1])
    }

    @MainActor
    func testMultipleWindowReceiversOnlyClaimRequestOnce() {
        var accepted = 0
        var requests: PendingAppIntentRequests!
        requests = PendingAppIntentRequests { notification in
            for _ in 0..<3 {
                if requests.claim(notification) { accepted += 1 }
            }
        }
        requests.submit(name: .convertImmediately, object: nil,
                        userInfo: [PendingAppIntentRequests.requestIDKey: UUID()])
        requests.drain()
        XCTAssertEqual(accepted, 1)
    }

    @MainActor
    func testReplaySkipsRequestsConsumedDuringEarlierDelivery() {
        var receiverReady = false
        var received: [Int] = []
        let laterID = UUID()
        var requests: PendingAppIntentRequests!
        requests = PendingAppIntentRequests { notification in
            guard receiverReady, requests.claim(notification) else { return }
            received.append(notification.object as! Int)
            requests.consume(id: laterID)
            requests.drain() // Reentrant replay must not recurse or double-deliver.
        }
        requests.submit(name: .enqueueFileURL, object: 1,
                        userInfo: [PendingAppIntentRequests.requestIDKey: UUID()])
        requests.submit(name: .enqueueFileURL, object: 2,
                        userInfo: [PendingAppIntentRequests.requestIDKey: laterID])
        receiverReady = true
        requests.drain()
        XCTAssertEqual(received, [1])
    }

    @MainActor
    func testClaimedConversionsKeepFIFOSettingsAcrossImportAndConversionSuspension() async {
        let queue = AppIntentOperationQueue()
        let importStarted = expectation(description: "first import suspended")
        let conversionStarted = expectation(description: "first conversion suspended")
        let allFinished = expectation(description: "queued handoffs finished")
        var finishImport: CheckedContinuation<Void, Never>?
        var finishConversion: CheckedContinuation<Void, Never>?
        var events: [String] = []
        var sharedPreset = "initial"
        var sharedOutput = "/initial"

        queue.enqueue {
            events.append("first import")
            await withCheckedContinuation { continuation in
                finishImport = continuation
                importStarted.fulfill()
            }
            sharedPreset = "audio"
            sharedOutput = "/audio"
            events.append("first conversion")
            await withCheckedContinuation { continuation in
                finishConversion = continuation
                conversionStarted.fulfill()
            }
            XCTAssertEqual(sharedPreset, "audio")
            XCTAssertEqual(sharedOutput, "/audio")
            events.append("first complete")
        }
        queue.enqueue {
            events.append("second import")
            sharedPreset = "video"
            sharedOutput = "/video"
            events.append("second complete")
        }
        await fulfillment(of: [importStarted], timeout: 2)
        XCTAssertEqual(events, ["first import"])
        XCTAssertEqual(sharedPreset, "initial")
        finishImport?.resume()
        await fulfillment(of: [conversionStarted], timeout: 2)
        XCTAssertEqual(events, ["first import", "first conversion"])
        // A picker/enqueue arriving during conversion must not mutate its state.
        queue.enqueue {
            events.append("picker")
            XCTAssertEqual(sharedPreset, "video")
            XCTAssertEqual(sharedOutput, "/video")
            allFinished.fulfill()
        }
        finishConversion?.resume()
        await fulfillment(of: [allFinished], timeout: 2)
        XCTAssertEqual(events, ["first import", "first conversion", "first complete",
                                "second import", "second complete", "picker"])
    }

    @MainActor
    func testOperationQueueAcceptsNewWorkAfterBecomingIdle() async {
        let queue = AppIntentOperationQueue()
        let firstFinished = expectation(description: "first work finished")
        let secondFinished = expectation(description: "later work finished")
        var events: [Int] = []
        queue.enqueue { events.append(1); firstFinished.fulfill() }
        await fulfillment(of: [firstFinished], timeout: 2)
        queue.enqueue { events.append(2); secondFinished.fulfill() }
        await fulfillment(of: [secondFinished], timeout: 2)
        XCTAssertEqual(events, [1, 2])
    }

    private func makeIsolatedDefaults() throws -> UserDefaults {
        let suite = "AppIntentHandoffTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

}
