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

    @MainActor
    func testBufferedRequestsReplayInSubmissionOrderOnlyOnce() {
        var received: [Int] = []
        let requests = PendingAppIntentRequests { received.append($0.object as! Int) }
        for index in 0..<20 {
            requests.submit(name: .enqueueFileURL, object: index,
                            userInfo: [PendingAppIntentRequests.requestIDKey: UUID()])
        }
        received.removeAll()
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
}
