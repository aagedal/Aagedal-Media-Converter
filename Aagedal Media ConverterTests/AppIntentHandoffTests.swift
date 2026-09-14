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
        XCTAssertEqual(request.sourceSettings?.map(\.sourceURL), [second, first])
        XCTAssertNil(request.idempotencyKey)
        XCTAssertEqual(request.capturedAt, capturedAt)

        defaults.set(CodecContainer.mp4.rawValue, forKey: AppConstants.h264ContainerKey)
        let summary = request.acceptedSettingsSummary
        XCTAssertTrue(summary.contains("Container: MOV"))
        XCTAssertTrue(summary.contains("Timecode: 01:02:03:04"))
        XCTAssertTrue(summary.contains("Destination: /outputs"))
    }

    func testManualBridgeCapturesPerSourceAdjustments() throws {
        let defaults = try makeIsolatedDefaults()
        var firstItem = makeItem(url: first)
        firstItem.comment = "First shot"
        firstItem.trimStart = 1
        firstItem.trimEnd = 4
        firstItem.cropConfig = CropConfig(
            normalizedRect: CropRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6)
        )
        firstItem.isMuted = true
        firstItem.audioRoutingConfig = AudioRoutingConfig(
            inputTracks: [AudioTrackInfo(
                streamIndex: 0, channels: 6, channelLayout: "5.1", codec: "aac",
                codecLongName: nil, sampleRate: 48_000
            )],
            outputTracks: [OutputTrack(streamIndex: 0, downmixToStereo: true)]
        )
        firstItem.outputFileNameOverride = "first-custom"

        var secondItem = makeItem(url: second)
        secondItem.includeDateTag.toggle()
        secondItem.timecodeConfig = TimecodeConfig(mode: .manual("02:03:04:05"))

        let request = try XCTUnwrap(ManualApplicationJobBridge.makeRequest(
            items: [firstItem, secondItem], destinationFolderURL: folder, preset: .h264,
            mergeClipsEnabled: false, defaults: defaults
        ))

        let sourceSettings = try XCTUnwrap(request.sourceSettings)
        XCTAssertEqual(sourceSettings.count, 2)
        XCTAssertEqual(sourceSettings[0].comment, "First shot")
        XCTAssertEqual(sourceSettings[0].trimStart, 1)
        XCTAssertEqual(sourceSettings[0].trimEnd, 4)
        XCTAssertEqual(sourceSettings[0].cropConfig, firstItem.cropConfig)
        XCTAssertTrue(sourceSettings[0].isMuted)
        XCTAssertEqual(sourceSettings[0].audioRoutingConfig, firstItem.audioRoutingConfig)
        XCTAssertEqual(sourceSettings[0].outputBaseNameOverride, "first-custom")
        XCTAssertEqual(sourceSettings[1].includeDateTag, secondItem.includeDateTag)
        XCTAssertEqual(sourceSettings[1].timecodeMode, .manual)
        XCTAssertEqual(sourceSettings[1].manualTimecode, "02:03:04:05")

        let summary = request.acceptedSettingsSummary(sourceIndex: 0)
        XCTAssertTrue(summary.contains("Comment: First shot"))
        XCTAssertTrue(summary.contains("Trim start: 1 s"))
        XCTAssertTrue(summary.contains("Trim end: 4 s"))
        XCTAssertTrue(summary.contains("Crop: On"))
        XCTAssertTrue(summary.contains("Audio: Muted"))
        XCTAssertTrue(summary.contains("Output name: first-custom"))
    }

    func testManualBridgeCapturesSaveNextToOriginalDestinations() throws {
        let defaults = try makeIsolatedDefaults()
        defaults.set(true, forKey: AppConstants.saveNextToOriginalKey)
        defaults.set(true, forKey: AppConstants.saveNextToOriginalSubfolderKey)
        defaults.set("custom", forKey: AppConstants.saveNextToOriginalSubfolderModeKey)
        defaults.set("Converted", forKey: AppConstants.saveNextToOriginalSubfolderNameKey)
        let firstItem = makeItem(url: URL(fileURLWithPath: "/sources/one/first.mov"))
        let secondItem = makeItem(url: URL(fileURLWithPath: "/sources/two/second.mov"))

        let request = try XCTUnwrap(ManualApplicationJobBridge.makeRequest(
            items: [firstItem, secondItem],
            destinationFolderURL: folder,
            preset: .h264,
            mergeClipsEnabled: false,
            defaults: defaults
        ))

        XCTAssertEqual(request.sourceSettings?.map(\.destinationFolderURL), [
            URL(fileURLWithPath: "/sources/one/Converted", isDirectory: true),
            URL(fileURLWithPath: "/sources/two/Converted", isDirectory: true)
        ])
        XCTAssertTrue(
            request.acceptedSettingsSummary(sourceIndex: 1)
                .contains("Destination: /sources/two/Converted")
        )
        XCTAssertTrue(request.acceptedSettingsSummary.contains("Destination: Per source"))
        XCTAssertFalse(request.acceptedSettingsSummary.contains("Destination: /outputs"))
    }

    func testAcceptedSettingsSummaryHasNorwegianCatalogCoverageAndFormatting() throws {
        let defaults = try makeIsolatedDefaults()
        var item = makeItem(url: first)
        item.comment = "Første opptak"
        item.trimStart = 1.5
        item.cropConfig = CropConfig(
            normalizedRect: CropRect(x: 0, y: 0, width: 0.5, height: 1)
        )
        item.isMuted = true
        item.outputFileNameOverride = "scene-one"

        let request = try XCTUnwrap(ManualApplicationJobBridge.makeRequest(
            items: [item], destinationFolderURL: folder, preset: .h264,
            mergeClipsEnabled: false,
            capturedAt: Date(timeIntervalSince1970: 1_789_300_800),
            defaults: defaults
        ))
        let summary = request.acceptedSettingsSummary(
            sourceIndex: 0,
            locale: Locale(identifier: "nb")
        )
        XCTAssertTrue(summary.contains("Trim start: 1,5 s"), summary)
        XCTAssertTrue(summary.contains("13. sep."), summary)

        let norwegianPath = try XCTUnwrap(
            Bundle.main.path(forResource: "nb", ofType: "lproj")
        )
        let norwegianBundle = try XCTUnwrap(Bundle(path: norwegianPath))
        let expectedTranslations = [
            "Audio routing: %@": "Lydruting: %@",
            "Audio: %@": "Lyd: %@",
            "Audio: Muted": "Lyd: Dempet",
            "Captured: %@": "Innstillinger hentet: %@",
            "Comment: %@": "Kommentar: %@",
            "Container: %@": "Konteiner: %@",
            "Crop: %@": "Beskjæring: %@",
            "Custom tracks": "Egendefinerte spor",
            "Date tag: %@": "Datomerking: %@",
            "Destination: %@": "Målmappe: %@",
            "Destination: Per source": "Målmappe: Per kilde",
            "Encoding speed: %@": "Kodehastighet: %@",
            "Extract %@": "Trekk ut %@",
            "Filename processing: %@": "Filnavnbehandling: %@",
            "Filename template: %@": "Filnavnmal: %@",
            "Keep subtitles: %@": "Behold undertekster: %@",
            "Maximum height: %@p": "Maksimal høyde: %@p",
            "Merge to Stereo": "Slå sammen til stereo",
            "Output name: %@": "Utdatanavn: %@",
            "Per-file adjustments: %@": "Justeringer per fil: %@",
            "Preset: %@": "Forhåndsinnstilling: %@",
            "Preserve metadata: %@": "Ta vare på metadata: %@",
            "Preserve source": "Behold fra kilde",
            "Quality: %@": "Kvalitet: %@",
            "Split to Mono": "Del til mono",
            "Swap L/R": "Bytt V/H",
            "Timecode: %@": "Tidskode: %@",
            "Trim end: %@ s": "Sluttpunkt: %@ s",
            "Trim start: %@ s": "Startpunkt: %@ s",
            "Video bitrate: %@": "Videobitrate: %@",
            "Video encoder: %@": "Videokoder: %@",
            "Video profile: %@": "Videoprofil: %@"
        ]
        for (key, expected) in expectedTranslations {
            XCTAssertEqual(
                norwegianBundle.localizedString(forKey: key, value: nil, table: "Localizable"),
                expected,
                key
            )
        }
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

        var unsupportedRouting = ordinary
        unsupportedRouting.audioRoutingConfig = AudioRoutingConfig(inputTracks: [])
        XCTAssertNil(ManualApplicationJobBridge.makeRequest(
            items: [unsupportedRouting], destinationFolderURL: folder, preset: .streamCopy,
            mergeClipsEnabled: false, defaults: defaults
        ))

        var unsafeName = ordinary
        unsafeName.outputFileNameOverride = "../outside"
        XCTAssertNil(ManualApplicationJobBridge.makeRequest(
            items: [unsafeName], destinationFolderURL: folder, preset: .h264,
            mergeClipsEnabled: false, defaults: defaults
        ))

        var streamCopyCrop = ordinary
        streamCopyCrop.cropConfig = CropConfig(
            normalizedRect: CropRect(x: 0, y: 0, width: 0.5, height: 1)
        )
        XCTAssertNil(ManualApplicationJobBridge.makeRequest(
            items: [streamCopyCrop], destinationFolderURL: folder,
            preset: .streamCopy, mergeClipsEnabled: false, defaults: defaults
        ))

        var audioWaveform = ordinary
        audioWaveform.hasVideoStream = false
        audioWaveform.waveformVideoEnabled = true
        XCTAssertNil(ManualApplicationJobBridge.makeRequest(
            items: [audioWaveform], destinationFolderURL: folder,
            preset: .h264, mergeClipsEnabled: false, defaults: defaults
        ))
    }

    func testManualBridgeIgnoresDormantWaveformPreferenceForVideoSources() throws {
        let defaults = try makeIsolatedDefaults()
        var video = makeItem(url: first)
        video.hasVideoStream = true
        video.waveformVideoEnabled = true

        XCTAssertNotNil(ManualApplicationJobBridge.makeRequest(
            items: [video], destinationFolderURL: folder,
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

    @MainActor
    func testManualBridgePersistsEveryPerSourceDestinationGrant() throws {
        let defaults = try makeIsolatedDefaults()
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let firstDestination = temporaryRoot.appendingPathComponent("first", isDirectory: true)
        let secondDestination = temporaryRoot.appendingPathComponent("second", isDirectory: true)
        let unusedDestination = temporaryRoot.appendingPathComponent("unused", isDirectory: true)
        let request = ApplicationConversionRequest(
            origin: .manual,
            requesterID: ManualApplicationJobBridge.requesterID,
            sourceURLs: [first, second],
            destinationFolderURL: unusedDestination,
            presetID: .h264,
            sourceSettings: [
                ApplicationSourceExecutionSettings(
                    sourceURL: first,
                    destinationFolderURL: firstDestination,
                    includeDateTag: false,
                    timecodeConfig: nil
                ),
                ApplicationSourceExecutionSettings(
                    sourceURL: second,
                    destinationFolderURL: secondDestination,
                    includeDateTag: false,
                    timecodeConfig: nil
                )
            ],
            defaults: defaults
        )
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

        ManualApplicationJobBridge.persistFileAccess(for: request, bookmarks: bookmarks)

        for destination in [firstDestination, secondDestination] {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: destination.path,
                isDirectory: &isDirectory
            ))
            XCTAssertTrue(isDirectory.boolValue)
            guard case .bookmark = bookmarks.startAccessingStoredBookmark(
                containing: destination.appendingPathComponent("output.mov"),
                requiresWriteAccess: true
            ) else { return XCTFail("Expected a writable grant for \(destination.path)") }
        }
        guard case .none = bookmarks.startAccessingStoredBookmark(
            containing: unusedDestination.appendingPathComponent("output.mov"),
            requiresWriteAccess: true
        ) else { return XCTFail("The unused batch destination should not be persisted") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: unusedDestination.path))
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
