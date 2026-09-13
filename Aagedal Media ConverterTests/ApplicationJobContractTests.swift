// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
@testable import Aagedal_Media_Converter

final class ApplicationJobContractTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/fixtures/input.mov")
    private let destination = URL(fileURLWithPath: "/outputs", isDirectory: true)

    func testSupportedPresetIDsAreStableAndMapToInitialPresetSubset() {
        XCTAssertEqual(ApplicationPresetID.allCases.map(\.rawValue), [
            "h264", "hevc", "prores", "proxy", "audio_only", "stream_copy"
        ])
        XCTAssertEqual(ApplicationPresetID.allCases.map(\.exportPreset), [
            .h264, .h265, .prores, .proxy, .audioOnly, .streamCopy
        ])
    }

    func testRequestAndJobIDRoundTripThroughJSON() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let request = makeRequest(capturedAt: date)
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ApplicationConversionRequest.self, from: encoded)
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.schemaVersion, 1)

        let id = ApplicationJobID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        let idData = try JSONEncoder().encode(id)
        XCTAssertEqual(String(decoding: idData, as: UTF8.self), "\"11111111-2222-3333-4444-555555555555\"")
        XCTAssertEqual(try JSONDecoder().decode(ApplicationJobID.self, from: idData), id)
    }

    func testRequestCapturesResolvedPresetAndNamingSettings() throws {
        let defaults = try makeDefaults()
        defaults.set(H264Encoder.software.rawValue, forKey: AppConstants.h264EncoderKey)
        defaults.set(CodecContainer.mkv.rawValue, forKey: AppConstants.h264ContainerKey)
        defaults.set(CodecQualityLevel.high.rawValue, forKey: AppConstants.h264QualityKey)
        defaults.set(EncodingSpeed.slow.rawValue, forKey: AppConstants.h264SpeedKey)
        defaults.set(CodecResolutionLimit.r720.rawValue, forKey: AppConstants.h264ResolutionLimitKey)
        defaults.set(CodecAudioFormat.opus.rawValue, forKey: AppConstants.h264AudioFormatKey)
        defaults.set(AudioBitrate.k256.rawValue, forKey: AppConstants.h264AudioBitrateKey)
        defaults.set(true, forKey: AppConstants.preserveMetadataPreferenceKey)
        defaults.set(true, forKey: AppConstants.keepSubtitlesKey)
        defaults.set(false, forKey: AppConstants.fileNameReplaceSpacesKey)

        let request = makeRequest(defaults: defaults)
        XCTAssertEqual(request.presetSettings.containerID, .mkv)
        XCTAssertEqual(request.presetSettings.video?.encoderID, .libx264)
        XCTAssertEqual(request.presetSettings.video?.quality, 18)
        XCTAssertEqual(request.presetSettings.video?.speed, "slow")
        XCTAssertEqual(request.presetSettings.video?.maximumHeight, 720)
        XCTAssertEqual(request.presetSettings.audio, ApplicationAudioSettings(codecID: .opus, bitrate: "256k"))
        XCTAssertTrue(request.presetSettings.preserveMetadata)
        XCTAssertTrue(request.presetSettings.keepSubtitles)
        XCTAssertFalse(request.presetSettings.fileName.replaceSpaces)

        defaults.set(CodecQualityLevel.veryLow.rawValue, forKey: AppConstants.h264QualityKey)
        defaults.set(CodecAudioFormat.aac.rawValue, forKey: AppConstants.h264AudioFormatKey)
        XCTAssertEqual(request.presetSettings.video?.quality, 18)
        XCTAssertEqual(request.presetSettings.audio?.codecID, .opus)

        let roundTrip = try JSONDecoder().decode(
            ApplicationConversionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(roundTrip, request)
    }

    func testRequestDecodesSnapshotsCreatedBeforeCounterCapture() throws {
        let encoded = try JSONEncoder().encode(makeRequest())
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        root.removeValue(forKey: "executionSettings")
        var presetSettings = try XCTUnwrap(root["presetSettings"] as? [String: Any])
        var fileName = try XCTUnwrap(presetSettings["fileName"] as? [String: Any])
        fileName.removeValue(forKey: "counterStart")
        presetSettings["fileName"] = fileName
        root["presetSettings"] = presetSettings

        let legacyData = try JSONSerialization.data(withJSONObject: root)
        let decoded = try JSONDecoder().decode(ApplicationConversionRequest.self, from: legacyData)
        XCTAssertEqual(
            decoded.presetSettings.fileName.counterStart,
            AppConstants.defaultCustomFileNameCounterValue
        )
        XCTAssertNil(decoded.executionSettings)
    }

    func testSupportedPresetSnapshotsUseStableResolvedValues() throws {
        let defaults = try makeDefaults()
        defaults.set(ProResProfile.hq.rawValue, forKey: AppConstants.proResProfileKey)
        defaults.set(ProxyCodec.dnxhd.rawValue, forKey: AppConstants.proxyCodecKey)
        defaults.set(ProxyResolutionLimit.r480.rawValue, forKey: AppConstants.proxyResolutionLimitKey)
        defaults.set(AudioOnlyFormat.flac.rawValue, forKey: AppConstants.audioOnlyFormatKey)
        defaults.set(StreamCopyContainer.keepCurrent.rawValue, forKey: AppConstants.streamCopyContainerKey)

        let proRes = ApplicationPresetSettings(presetID: .proRes, defaults: defaults)
        XCTAssertEqual(proRes.containerID, .mov)
        XCTAssertEqual(proRes.video?.profileID, .proResHQ)
        XCTAssertEqual(proRes.audio?.codecID, .pcm24)

        let proxy = ApplicationPresetSettings(presetID: .proxy, defaults: defaults)
        XCTAssertEqual(proxy.containerID, .mxf)
        XCTAssertEqual(proxy.video?.encoderID, .dnxhd)
        XCTAssertEqual(proxy.video?.profileID, .dnxhrLB)
        XCTAssertEqual(proxy.video?.maximumHeight, 480)

        let audioOnly = ApplicationPresetSettings(presetID: .audioOnly, defaults: defaults)
        XCTAssertNil(audioOnly.video)
        XCTAssertEqual(audioOnly.containerID, .flac)
        XCTAssertEqual(audioOnly.audio?.codecID, .flac)

        let streamCopy = ApplicationPresetSettings(presetID: .streamCopy, defaults: defaults)
        XCTAssertEqual(streamCopy.containerID, .source)
        XCTAssertEqual(streamCopy.video?.encoderID, .streamCopy)
        XCTAssertEqual(streamCopy.audio?.codecID, .streamCopy)
        XCTAssertFalse(streamCopy.keepSubtitles)
    }

    func testMalformedH265QualityUsesTheExecutionFallback() throws {
        let defaults = try makeDefaults()
        defaults.set("not-a-quality", forKey: AppConstants.h265QualityKey)

        let settings = ApplicationPresetSettings(presetID: .hevc, defaults: defaults)

        XCTAssertEqual(settings.video?.quality, CodecQualityLevel.balanced.crfValue)
    }

    func testPlanningCapturesDeterministicOutputsAndCollisionWarnings() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let firstSource = directory.appendingPathComponent("First Clip.mov")
        let secondSource = directory.appendingPathComponent("Second Clip.mov")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)

        let defaults = try makeDefaults()
        defaults.set(true, forKey: AppConstants.enableCustomFileNameTemplateKey)
        defaults.set("{sourceName}_{counter}{presetSuffix}", forKey: AppConstants.customFileNameTemplateKey)
        defaults.set(3, forKey: AppConstants.customFileNameCounterPaddingKey)
        defaults.set(7, forKey: AppConstants.customFileNameCounterValueKey)
        defaults.set(true, forKey: AppConstants.fileNameIncludePresetSuffixKey)
        defaults.set(CodecContainer.mkv.rawValue, forKey: AppConstants.h264ContainerKey)
        let request = makeRequest(
            sourceURLs: [firstSource, secondSource],
            destinationFolderURL: outputDirectory,
            defaults: defaults
        )
        defaults.set(CodecContainer.mov.rawValue, forKey: AppConstants.h264ContainerKey)
        let existingOutput = outputDirectory.appendingPathComponent("First_Clip_007_h264.mkv")
        try Data().write(to: existingOutput)

        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted)
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        let plan = try await service.plan(request, now: now)

        XCTAssertEqual(plan.createdAt, now)
        XCTAssertEqual(plan.expiresAt, now.addingTimeInterval(15 * 60))
        XCTAssertEqual(plan.sources.map(\.fileSize), [5, 6])
        XCTAssertEqual(plan.outputs.map { $0.outputURL.lastPathComponent }, [
            "First_Clip_007_h264.mkv", "Second_Clip_008_h264.mkv"
        ])
        XCTAssertEqual(plan.warnings, [
            ApplicationPlanWarning(code: .outputAlreadyExists, url: existingOutput)
        ])
        let roundTrip = try JSONDecoder().decode(
            ApplicationConversionPlan.self,
            from: JSONEncoder().encode(plan)
        )
        XCTAssertEqual(roundTrip, plan)
    }

    func testPlanAndSubmitUsesTheSharedPlanningAndAcceptanceBoundary() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("input.mov")
        try Data("source".utf8).write(to: sourceURL)
        let defaults = try makeDefaults()
        let request = makeRequest(
            origin: .appIntent,
            requesterID: AppIntentApplicationJobBridge.requesterID,
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory,
            executionSettings: ApplicationRequestExecutionSettings(appIntentDefaults: defaults),
            idempotencyKey: "shortcut-request",
            defaults: defaults
        )
        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted)
        let now = Date(timeIntervalSince1970: 1_800_000_200)

        let acceptance = try await service.planAndSubmit(request, now: now)

        XCTAssertFalse(acceptance.wasAlreadyAccepted)
        XCTAssertEqual(acceptance.record.request.origin, .appIntent)
        XCTAssertEqual(acceptance.record.state, .queued)
        let outputURLs = try await service.plannedOutputURLs(
            for: acceptance.record.id,
            now: now
        )
        XCTAssertEqual(
            outputURLs,
            [outputDirectory.appendingPathComponent("input_h264.mp4")]
        )
    }

    func testVisibleQueueUpdatesPublishAcceptedAndCancelledJobsWithPlannedOutputs() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("input.mov")
        try Data("source".utf8).write(to: sourceURL)

        let service = ApplicationJobService(
            planLifetime: 1,
            fileAccessAuthorizer: .unrestricted
        )
        let updates = await service.recordUpdates()
        var iterator = updates.makeAsyncIterator()
        let initialRecords = await iterator.next()
        XCTAssertEqual(initialRecords, [])

        let request = makeRequest(
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory
        )
        let acceptedAt = Date(timeIntervalSince1970: 10_000)
        let plan = try await service.plan(request, now: acceptedAt)
        let acceptance = try await service.submit(planID: plan.id, now: acceptedAt)

        let nextAcceptedRecords = await iterator.next()
        let acceptedRecords = try XCTUnwrap(nextAcceptedRecords)
        XCTAssertEqual(acceptedRecords.map(\.id), [acceptance.record.id])
        XCTAssertEqual(acceptedRecords.first?.state, .queued)
        let outputURLs = try await service.plannedOutputURLs(for: acceptance.record.id)
        XCTAssertEqual(outputURLs, plan.outputs.map(\.outputURL))

        // A submitted plan can age out while a long job is still visible. Its
        // immutable accepted request must continue to resolve the same output.
        _ = try await service.plan(request, now: acceptedAt.addingTimeInterval(2))
        let reconstructedOutputURLs = try await service.plannedOutputURLs(for: acceptance.record.id)
        XCTAssertEqual(reconstructedOutputURLs, plan.outputs.map(\.outputURL))

        _ = try await service.requestCancellation(acceptance.record.id)
        let nextCancelledRecords = await iterator.next()
        let cancelledRecords = try XCTUnwrap(nextCancelledRecords)
        XCTAssertEqual(cancelledRecords.first?.state, .cancelled)
    }

    func testPlanningRequiresApprovedReadAndWriteScopes() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceURL)
        let request = makeRequest(
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory
        )

        let sourceDenied = ApplicationJobService(fileAccessAuthorizer: ApplicationFileAccessAuthorizer {
            url, mode in
            guard mode == .write, url == outputDirectory else { return nil }
            return ApplicationFileAccessLease {}
        })
        do {
            _ = try await sourceDenied.plan(request)
            XCTFail("Expected missing source approval to be rejected")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .sourceAccessDenied(sourceURL))
        }

        let destinationDenied = ApplicationJobService(fileAccessAuthorizer: ApplicationFileAccessAuthorizer {
            url, mode in
            guard mode == .read, url == sourceURL else { return nil }
            return ApplicationFileAccessLease {}
        })
        do {
            _ = try await destinationDenied.plan(request)
            XCTFail("Expected missing writable destination approval to be rejected")
        } catch {
            XCTAssertEqual(
                error as? ApplicationJobError,
                .destinationAccessDenied(outputDirectory)
            )
        }
    }

    func testSubmissionRechecksRevokedFolderAccess() async throws {
        final class GrantState: @unchecked Sendable {
            private let lock = NSLock()
            private var enabled = true

            func revoke() {
                lock.withLock { enabled = false }
            }

            func acquire() -> ApplicationFileAccessLease? {
                lock.withLock { enabled ? ApplicationFileAccessLease {} : nil }
            }
        }

        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceURL)
        let grants = GrantState()
        let service = ApplicationJobService(fileAccessAuthorizer: ApplicationFileAccessAuthorizer {
            _, _ in grants.acquire()
        })
        let plan = try await service.plan(makeRequest(
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory
        ))

        grants.revoke()
        do {
            _ = try await service.submit(planID: plan.id)
            XCTFail("Expected revoked access to be rejected at submission")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .sourceAccessDenied(sourceURL))
        }
        let records = try await service.allRecords()
        XCTAssertTrue(records.isEmpty)
    }

    func testSubmitRejectsExpiredPlansAndChangedSources() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        try Data("before".utf8).write(to: sourceURL)
        let request = makeRequest(
            sourceURLs: [sourceURL],
            destinationFolderURL: directory,
            idempotencyKey: nil
        )
        let now = Date(timeIntervalSince1970: 1_800_000_200)

        let expiringService = ApplicationJobService(
            planLifetime: 10,
            fileAccessAuthorizer: .unrestricted
        )
        let expiredPlan = try await expiringService.plan(request, now: now)
        do {
            _ = try await expiringService.submit(planID: expiredPlan.id, now: now.addingTimeInterval(11))
            XCTFail("Expected an expired plan to be rejected")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .expiredPlan(expiredPlan.id))
        }

        let changedSourceService = ApplicationJobService(fileAccessAuthorizer: .unrestricted)
        let changedPlan = try await changedSourceService.plan(request, now: now)
        try Data("after-change".utf8).write(to: sourceURL)
        do {
            _ = try await changedSourceService.submit(planID: changedPlan.id, now: now)
            XCTFail("Expected a changed source to be rejected")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .sourceChanged(sourceURL))
        }
    }

    func testSubmissionReservesOutputsAndPlanRetryReturnsOriginalJob() async throws {
        let directory = try makeTemporaryDirectory()
        let firstDirectory = directory.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = directory.appendingPathComponent("second", isDirectory: true)
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        for folder in [firstDirectory, secondDirectory, outputDirectory] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let firstSource = firstDirectory.appendingPathComponent("clip.mov")
        let secondSource = secondDirectory.appendingPathComponent("clip.mov")
        try Data("one".utf8).write(to: firstSource)
        try Data("two".utf8).write(to: secondSource)

        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted)
        let firstPlan = try await service.plan(makeRequest(
            sourceURLs: [firstSource], destinationFolderURL: outputDirectory, idempotencyKey: nil
        ))
        let secondPlan = try await service.plan(makeRequest(
            sourceURLs: [secondSource], destinationFolderURL: outputDirectory, idempotencyKey: nil
        ))
        let firstAcceptance = try await service.submit(planID: firstPlan.id)
        let retry = try await service.submit(planID: firstPlan.id)
        XCTAssertEqual(retry.record.id, firstAcceptance.record.id)
        XCTAssertTrue(retry.wasAlreadyAccepted)

        do {
            _ = try await service.submit(planID: secondPlan.id)
            XCTFail("Expected the accepted output reservation to reject a competing plan")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .outputCollision(secondPlan.outputs[0].outputURL))
        }

        _ = try await service.transition(firstAcceptance.record.id, to: .running)
        _ = try await service.transition(firstAcceptance.record.id, to: .succeeded)
        let secondAcceptance = try await service.submit(planID: secondPlan.id)
        XCTAssertNotEqual(secondAcceptance.record.id, firstAcceptance.record.id)
    }

    func testIdempotentRetryThroughANewPlanReturnsOriginalReservedJob() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceURL)
        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted)
        let firstRequest = makeRequest(
            requestID: UUID(),
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory,
            idempotencyKey: "network-retry"
        )
        let retryRequest = makeRequest(
            requestID: UUID(),
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory,
            idempotencyKey: "network-retry"
        )

        let firstPlan = try await service.plan(firstRequest)
        let firstAcceptance = try await service.submit(planID: firstPlan.id)
        let retryPlan = try await service.plan(retryRequest)
        let retryAcceptance = try await service.submit(planID: retryPlan.id)

        XCTAssertEqual(retryAcceptance.record.id, firstAcceptance.record.id)
        XCTAssertTrue(retryAcceptance.wasAlreadyAccepted)
        let records = try await service.allRecords()
        XCTAssertEqual(records.count, 1)
    }

    func testSubmitRejectsAnOutputCreatedAfterPlanning() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        try Data("source".utf8).write(to: sourceURL)
        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted)
        let plan = try await service.plan(makeRequest(
            sourceURLs: [sourceURL], destinationFolderURL: directory, idempotencyKey: nil
        ))
        let outputURL = try XCTUnwrap(plan.outputs.first?.outputURL)
        try Data("occupied".utf8).write(to: outputURL)

        do {
            _ = try await service.submit(planID: plan.id)
            XCTFail("Expected a submit-time output collision")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .outputCollision(outputURL))
        }
    }

    func testPlanningRejectsTwoSourcesThatResolveToTheSameOutput() async throws {
        let directory = try makeTemporaryDirectory()
        let firstDirectory = directory.appendingPathComponent("first", isDirectory: true)
        let secondDirectory = directory.appendingPathComponent("second", isDirectory: true)
        for folder in [firstDirectory, secondDirectory] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let firstSource = firstDirectory.appendingPathComponent("same.mov")
        let secondSource = secondDirectory.appendingPathComponent("same.mov")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)
        let request = makeRequest(
            sourceURLs: [firstSource, secondSource],
            destinationFolderURL: directory,
            idempotencyKey: nil
        )

        do {
            _ = try await ApplicationJobService(fileAccessAuthorizer: .unrestricted).plan(request)
            XCTFail("Expected duplicate proposed output names to be rejected")
        } catch {
            let expected = directory.appendingPathComponent("same_h264.mp4")
            XCTAssertEqual(error as? ApplicationJobError, .duplicateOutput(expected))
        }
    }

    func testAcceptanceCreatesStableQueuedRecordAndPreservesOrder() async throws {
        let registry = ApplicationJobRegistry()
        let first = try await registry.accept(makeRequest(idempotencyKey: nil))
        let second = try await registry.accept(makeRequest(
            sourceURLs: [URL(fileURLWithPath: "/fixtures/second.mov")],
            idempotencyKey: nil
        ))
        XCTAssertFalse(first.wasAlreadyAccepted)
        XCTAssertEqual(first.record.state, .queued)
        let records = await registry.allRecords()
        XCTAssertEqual(records.map(\.id), [first.record.id, second.record.id])
    }

    func testConcurrentRetriesWithSameIdempotencyKeyCreateOneJob() async throws {
        let registry = ApplicationJobRegistry()
        let firstRequest = makeRequest(requestID: UUID(), idempotencyKey: "retry-42")
        let retryRequest = makeRequest(requestID: UUID(), idempotencyKey: "retry-42")

        async let first = registry.accept(firstRequest)
        async let retry = registry.accept(retryRequest)
        let results = try await [first, retry]

        XCTAssertEqual(Set(results.map(\.record.id)).count, 1)
        XCTAssertEqual(results.filter(\.wasAlreadyAccepted).count, 1)
        let records = await registry.allRecords()
        XCTAssertEqual(records.count, 1)
    }

    func testIdempotencyIsScopedByRequesterAndRejectsChangedPayload() async throws {
        let registry = ApplicationJobRegistry()
        _ = try await registry.accept(makeRequest(requesterID: "client-a", idempotencyKey: "same-key"))
        let otherClient = try await registry.accept(makeRequest(requesterID: "client-b", idempotencyKey: "same-key"))
        XCTAssertFalse(otherClient.wasAlreadyAccepted)

        do {
            _ = try await registry.accept(makeRequest(
                requesterID: "client-a",
                sourceURLs: [URL(fileURLWithPath: "/fixtures/different.mov")],
                idempotencyKey: "same-key"
            ))
            XCTFail("Expected a changed payload to conflict with the accepted key")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .idempotencyConflict)
        }
    }

    func testIdempotencyRejectsAChangedCapturedPresetSnapshot() async throws {
        let defaults = try makeDefaults()
        defaults.set(CodecQualityLevel.good.rawValue, forKey: AppConstants.h264QualityKey)
        let first = makeRequest(idempotencyKey: "same-settings-key", defaults: defaults)

        defaults.set(CodecQualityLevel.low.rawValue, forKey: AppConstants.h264QualityKey)
        let changed = makeRequest(idempotencyKey: "same-settings-key", defaults: defaults)
        let registry = ApplicationJobRegistry()
        _ = try await registry.accept(first)

        do {
            _ = try await registry.accept(changed)
            XCTFail("Expected changed captured settings to conflict")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .idempotencyConflict)
        }
    }

    func testValidationRejectsUnsupportedOrUnsafeBoundaryValues() async {
        let cases: [(ApplicationConversionRequest, ApplicationJobError)] = [
            (makeRequest(schemaVersion: 2), .unsupportedSchema(2)),
            (makeRequest(requesterID: " client "), .invalidRequesterID),
            (makeRequest(sourceURLs: []), .noSources),
            (makeRequest(sourceURLs: [source, source]), .duplicateSource(source)),
            (makeRequest(sourceURLs: [URL(string: "https://example.com/input.mov")!]),
             .nonFileURL(URL(string: "https://example.com/input.mov")!)),
            (makeRequest(destinationFolderURL: URL(string: "https://example.com/output")!),
             .nonFileURL(URL(string: "https://example.com/output")!)),
            (makeRequest(idempotencyKey: " bad-key "), .invalidIdempotencyKey),
            (makeRequest(
                presetID: .h264,
                presetSettings: ApplicationPresetSettings(presetID: .hevc)
            ), .presetSettingsMismatch)
        ]

        for (request, expectedError) in cases {
            let registry = ApplicationJobRegistry()
            do {
                _ = try await registry.accept(request)
                XCTFail("Expected \(expectedError)")
            } catch {
                XCTAssertEqual(error as? ApplicationJobError, expectedError)
            }
        }
    }

    func testErrorsExposeStableWireCodes() {
        XCTAssertEqual(ApplicationJobError.unsupportedSchema(99).code.rawValue, "unsupported_schema")
        XCTAssertEqual(ApplicationJobError.idempotencyConflict.code.rawValue, "idempotency_conflict")
        XCTAssertEqual(ApplicationJobError.presetSettingsMismatch.code.rawValue, "preset_settings_mismatch")
        XCTAssertEqual(ApplicationJobError.outputCollision(destination).code.rawValue, "output_collision")
        XCTAssertEqual(ApplicationJobError.sourceChanged(source).code.rawValue, "source_changed")
        XCTAssertEqual(ApplicationJobError.sourceAccessDenied(source).code.rawValue, "source_access_denied")
        XCTAssertEqual(
            ApplicationJobError.destinationAccessDenied(destination).code.rawValue,
            "destination_access_denied"
        )
        XCTAssertEqual(
            ApplicationJobError.invalidTransition(from: .queued, to: .succeeded).code.rawValue,
            "invalid_transition"
        )
    }

    func testCancellationWaitsForRunningOwnerButQueuedCancellationIsTerminal() async throws {
        let registry = ApplicationJobRegistry()
        let queued = try await registry.accept(makeRequest(idempotencyKey: nil)).record
        let cancelledBeforeStart = try await registry.requestCancellation(queued.id)
        XCTAssertEqual(cancelledBeforeStart.state, .cancelled)

        let running = try await registry.accept(makeRequest(
            sourceURLs: [URL(fileURLWithPath: "/fixtures/running.mov")],
            idempotencyKey: nil
        )).record
        _ = try await registry.transition(running.id, to: .running)
        let cancelling = try await registry.requestCancellation(running.id)
        XCTAssertEqual(cancelling.state, .cancelling)
        let repeatedCancellation = try await registry.requestCancellation(running.id)
        XCTAssertEqual(repeatedCancellation.state, .cancelling)
        let cancelledAfterDrain = try await registry.transition(running.id, to: .cancelled)
        XCTAssertEqual(cancelledAfterDrain.state, .cancelled)
    }

    func testTerminalJobsCannotBeRevivedAndProgressRequiresAnActiveOwner() async throws {
        let registry = ApplicationJobRegistry()
        let record = try await registry.accept(makeRequest()).record
        _ = try await registry.transition(record.id, to: .running)
        let progress = try await registry.updateProgress(record.id, progress: 0.5, stage: "Encoding")
        XCTAssertEqual(progress.progress, 0.5)
        XCTAssertEqual(progress.stage, "Encoding")
        _ = try await registry.transition(
            record.id,
            to: .succeeded,
            outputURLs: [destination.appendingPathComponent("output.mp4")]
        )

        do {
            _ = try await registry.transition(record.id, to: .running)
            XCTFail("Expected a terminal-state transition to fail")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .invalidTransition(from: .succeeded, to: .running))
        }
        do {
            _ = try await registry.updateProgress(record.id, progress: 1.1, stage: nil)
            XCTFail("Expected invalid progress to fail")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .invalidProgress(1.1))
        }
    }

    func testRestartInterruptsOnlyIncompleteJobs() async throws {
        let registry = ApplicationJobRegistry()
        let queued = try await registry.accept(makeRequest(idempotencyKey: "queued")).record
        let running = try await registry.accept(makeRequest(idempotencyKey: "running")).record
        let finished = try await registry.accept(makeRequest(idempotencyKey: "finished")).record
        _ = try await registry.transition(running.id, to: .running)
        _ = try await registry.transition(finished.id, to: .running)
        _ = try await registry.transition(finished.id, to: .succeeded)

        let interrupted = await registry.interruptInFlightJobs(diagnostic: "Application restarted")
        XCTAssertEqual(Set(interrupted.map(\.id)), [queued.id, running.id])
        XCTAssertTrue(interrupted.allSatisfy { $0.state == .interrupted })
        let retainedFinished = await registry.record(for: finished.id)
        XCTAssertEqual(retainedFinished?.state, .succeeded)
    }

    func testPersistedPlansAndJobsRestoreIdempotencyAndInterruptIncompleteWork() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceURL)
        let store = ApplicationJobStore(fileURL: directory.appendingPathComponent("jobs.json"))
        let request = makeRequest(
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory,
            idempotencyKey: "persisted-request"
        )
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)

        let firstService = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
        let plan = try await firstService.plan(request, now: createdAt)
        let accepted = try await firstService.submit(planID: plan.id, now: createdAt)
        _ = try await firstService.transition(accepted.record.id, to: .running, now: createdAt)

        let restoredService = ApplicationJobService(store: store, fileAccessAuthorizer: .unrestricted)
        let restartDate = createdAt.addingTimeInterval(60)
        let interrupted = try await restoredService.restorePersistedState(
            now: restartDate,
            interruptionDiagnostic: "Restarted"
        )
        XCTAssertEqual(interrupted.map(\.id), [accepted.record.id])
        XCTAssertEqual(interrupted.first?.state, .interrupted)
        XCTAssertEqual(interrupted.first?.diagnostic, "Restarted")

        let retryPlan = try await restoredService.plan(request, now: restartDate)
        let retry = try await restoredService.submit(planID: retryPlan.id, now: restartDate)
        XCTAssertEqual(retry.record.id, accepted.record.id)
        XCTAssertEqual(retry.record.state, .interrupted)
        XCTAssertTrue(retry.wasAlreadyAccepted)

        let secondRestore = try await restoredService.restorePersistedState(now: restartDate)
        XCTAssertTrue(secondRestore.isEmpty)
    }

    func testPersistenceRetentionRemovesExpiredPlansAndOldTerminalIdempotencyKeys() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceURL)
        let store = ApplicationJobStore(fileURL: directory.appendingPathComponent("jobs.json"))
        let service = ApplicationJobService(
            planLifetime: 10,
            recordRetentionLifetime: 20,
            store: store,
            fileAccessAuthorizer: .unrestricted
        )
        let request = makeRequest(
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory,
            idempotencyKey: "retained-request"
        )
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        let plan = try await service.plan(request, now: createdAt)
        let accepted = try await service.submit(planID: plan.id, now: createdAt)
        _ = try await service.transition(accepted.record.id, to: .running, now: createdAt)
        _ = try await service.transition(accepted.record.id, to: .succeeded, now: createdAt)

        let retryDate = createdAt.addingTimeInterval(21)
        let newPlan = try await service.plan(request, now: retryDate)
        let removedPlan = try await service.plan(for: plan.id)
        let removedRecord = try await service.record(for: accepted.record.id)
        XCTAssertNil(removedPlan)
        XCTAssertNil(removedRecord)

        let newAcceptance = try await service.submit(planID: newPlan.id, now: retryDate)
        XCTAssertNotEqual(newAcceptance.record.id, accepted.record.id)
        XCTAssertFalse(newAcceptance.wasAlreadyAccepted)
    }

    func testDamagedPersistenceBlocksMutationAndIsNotOverwritten() async throws {
        let directory = try makeTemporaryDirectory()
        let stateURL = directory.appendingPathComponent("jobs.json")
        let damagedData = Data("{not valid json".utf8)
        try damagedData.write(to: stateURL)
        let service = ApplicationJobService(
            store: ApplicationJobStore(fileURL: stateURL),
            fileAccessAuthorizer: .unrestricted
        )

        do {
            _ = try await service.plan(makeRequest())
            XCTFail("Expected damaged persisted state to block a new plan")
        } catch {
            XCTAssertTrue(error is DecodingError)
        }
        XCTAssertEqual(try Data(contentsOf: stateURL), damagedData)
    }

    func testSubmittedJobsExecuteSeriallyAndPublishProgressAndOutputs() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let firstSource = directory.appendingPathComponent("first.mov")
        let secondSource = directory.appendingPathComponent("second.mov")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)

        let harness = ApplicationJobExecutorHarness(blocksFirstExecution: true)
        let service = makeExecutingService(harness: harness)
        let firstPlan = try await service.plan(makeRequest(
            origin: .manual,
            requesterID: "main-window",
            sourceURLs: [firstSource],
            destinationFolderURL: outputDirectory,
            idempotencyKey: "manual-1"
        ))
        let secondPlan = try await service.plan(makeRequest(
            origin: .localAgent,
            requesterID: "codex",
            sourceURLs: [secondSource],
            destinationFolderURL: outputDirectory,
            idempotencyKey: "agent-1"
        ))
        let first = try await service.submit(planID: firstPlan.id)
        let second = try await service.submit(planID: secondPlan.id)

        _ = try await waitForRecord(service: service, jobID: first.record.id, state: .running)
        let queuedSecond = try await service.record(for: second.record.id)
        XCTAssertEqual(queuedSecond?.state, .queued)
        let blockedSnapshot = await harness.snapshot()
        XCTAssertEqual(blockedSnapshot.startedIDs, [first.record.id])
        XCTAssertEqual(blockedSnapshot.maximumConcurrentExecutions, 1)

        await harness.releaseFirstExecution()
        let completedFirst = try await waitForRecord(
            service: service, jobID: first.record.id, state: .succeeded
        )
        let completedSecond = try await waitForRecord(
            service: service, jobID: second.record.id, state: .succeeded
        )

        XCTAssertEqual(completedFirst.progress, 1)
        XCTAssertEqual(completedFirst.stage, "Encoding")
        XCTAssertEqual(completedFirst.outputURLs, firstPlan.outputs.map(\.outputURL))
        XCTAssertEqual(completedSecond.outputURLs, secondPlan.outputs.map(\.outputURL))
        XCTAssertEqual(completedFirst.request.origin, .manual)
        XCTAssertEqual(completedSecond.request.origin, .localAgent)
        let completedSnapshot = await harness.snapshot()
        XCTAssertEqual(completedSnapshot.startedIDs, [first.record.id, second.record.id])
        XCTAssertEqual(completedSnapshot.maximumConcurrentExecutions, 1)
    }

    func testCancellationSkipsQueuedJobAndSignalsRunningExecutor() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let firstSource = directory.appendingPathComponent("first.mov")
        let secondSource = directory.appendingPathComponent("second.mov")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)

        let harness = ApplicationJobExecutorHarness(blocksFirstExecution: true)
        let service = makeExecutingService(harness: harness)
        let firstPlan = try await service.plan(makeRequest(
            sourceURLs: [firstSource], destinationFolderURL: outputDirectory, idempotencyKey: "first"
        ))
        let secondPlan = try await service.plan(makeRequest(
            sourceURLs: [secondSource], destinationFolderURL: outputDirectory, idempotencyKey: "second"
        ))
        let first = try await service.submit(planID: firstPlan.id)
        let second = try await service.submit(planID: secondPlan.id)
        _ = try await waitForRecord(service: service, jobID: first.record.id, state: .running)

        let queuedCancellation = try await service.requestCancellation(second.record.id)
        XCTAssertEqual(queuedCancellation.state, .cancelled)
        let runningCancellation = try await service.requestCancellation(first.record.id)
        XCTAssertEqual(runningCancellation.state, .cancelling)

        _ = try await waitForRecord(service: service, jobID: first.record.id, state: .cancelled)
        let snapshot = await harness.snapshot()
        XCTAssertEqual(snapshot.startedIDs, [first.record.id])
        XCTAssertEqual(snapshot.cancelledIDs, [first.record.id])
        XCTAssertFalse(snapshot.startedIDs.contains(second.record.id))
    }

    func testExecutionRechecksSourceIdentityAfterWaitingInQueue() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let firstSource = directory.appendingPathComponent("first.mov")
        let secondSource = directory.appendingPathComponent("second.mov")
        try Data("first".utf8).write(to: firstSource)
        try Data("second".utf8).write(to: secondSource)

        let harness = ApplicationJobExecutorHarness(blocksFirstExecution: true)
        let service = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: ApplicationJobExecutor(
                execute: { jobID, plan, progress in
                    await harness.execute(jobID: jobID, plan: plan, progress: progress)
                },
                cancel: { jobID in
                    await harness.cancel(jobID: jobID)
                }
            ),
            sourceIdentityProvider: { url in
                ApplicationSourceIdentity(
                    url: url.standardizedFileURL,
                    fileSize: Int64(try Data(contentsOf: url).count),
                    modificationDate: nil,
                    fileIdentifier: nil
                )
            }
        )
        let firstPlan = try await service.plan(makeRequest(
            sourceURLs: [firstSource], destinationFolderURL: outputDirectory, idempotencyKey: "first"
        ))
        let secondPlan = try await service.plan(makeRequest(
            sourceURLs: [secondSource], destinationFolderURL: outputDirectory, idempotencyKey: "second"
        ))
        let first = try await service.submit(planID: firstPlan.id)
        let second = try await service.submit(planID: secondPlan.id)
        _ = try await waitForRecord(service: service, jobID: first.record.id, state: .running)

        try Data("changed while queued".utf8).write(to: secondSource)
        await harness.releaseFirstExecution()
        _ = try await waitForRecord(service: service, jobID: first.record.id, state: .succeeded)
        let failed = try await waitForRecord(
            service: service, jobID: second.record.id, state: .failed
        )

        XCTAssertEqual(failed.diagnostic, ApplicationJobErrorCode.sourceChanged.rawValue)
        let snapshot = await harness.snapshot()
        XCTAssertEqual(snapshot.startedIDs, [first.record.id])
    }

    func testExecutorFailureAndOutputMismatchBecomeTerminalFailures() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let failedSource = directory.appendingPathComponent("failed.mov")
        let mismatchedSource = directory.appendingPathComponent("mismatched.mov")
        try Data("failed".utf8).write(to: failedSource)
        try Data("mismatched".utf8).write(to: mismatchedSource)

        let failedExecutor = ApplicationJobExecutor(
            execute: { _, _, _ in .failed(diagnostic: "Encoder unavailable") },
            cancel: { _ in }
        )
        let failedService = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: failedExecutor
        )
        let failedPlan = try await failedService.plan(makeRequest(
            sourceURLs: [failedSource], destinationFolderURL: outputDirectory, idempotencyKey: nil
        ))
        let failed = try await failedService.submit(planID: failedPlan.id)
        let failedRecord = try await waitForRecord(
            service: failedService, jobID: failed.record.id, state: .failed
        )
        XCTAssertEqual(failedRecord.diagnostic, "Encoder unavailable")

        let mismatchExecutor = ApplicationJobExecutor(
            execute: { _, _, _ in
                .succeeded(outputURLs: [outputDirectory.appendingPathComponent("unexpected.mp4")])
            },
            cancel: { _ in }
        )
        let mismatchService = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: mismatchExecutor
        )
        let mismatchPlan = try await mismatchService.plan(makeRequest(
            sourceURLs: [mismatchedSource], destinationFolderURL: outputDirectory, idempotencyKey: nil
        ))
        let mismatch = try await mismatchService.submit(planID: mismatchPlan.id)
        let mismatchRecord = try await waitForRecord(
            service: mismatchService, jobID: mismatch.record.id, state: .failed
        )
        XCTAssertEqual(
            mismatchRecord.diagnostic,
            "Executor outputs did not match the accepted conversion plan."
        )
    }

    func testExecutionRetainsAllAccessLeasesUntilExecutorCompletes() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("input.mov")
        try Data("source".utf8).write(to: sourceURL)

        let leaseState = ApplicationJobLeaseState()
        let executor = ApplicationJobExecutor(
            execute: { _, plan, progress in
                XCTAssertEqual(leaseState.activeCount, 2)
                await progress.report(ApplicationJobProgressUpdate(progress: 0.5, stage: "Encoding"))
                XCTAssertEqual(leaseState.activeCount, 2)
                return .succeeded(outputURLs: plan.outputs.map(\.outputURL))
            },
            cancel: { _ in }
        )
        let service = ApplicationJobService(
            fileAccessAuthorizer: ApplicationFileAccessAuthorizer { _, _ in
                leaseState.acquire()
            },
            executor: executor
        )
        let plan = try await service.plan(makeRequest(
            sourceURLs: [sourceURL], destinationFolderURL: outputDirectory, idempotencyKey: nil
        ))
        XCTAssertEqual(leaseState.activeCount, 0)
        let accepted = try await service.submit(planID: plan.id)
        let record = try await waitForRecord(
            service: service, jobID: accepted.record.id, state: .succeeded
        )
        XCTAssertEqual(record.outputURLs, plan.outputs.map(\.outputURL))
        XCTAssertEqual(leaseState.activeCount, 0)
    }

    func testFFmpegAdapterBuildsExecutableSettingsForAllSupportedPresets() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let defaults = try makeDefaults()
        defaults.set(true, forKey: AppConstants.keepSubtitlesKey)

        let harness = ApplicationFFmpegRunnerHarness()
        let adapter = ApplicationFFmpegJobExecutor(runner: ApplicationFFmpegRunner(
            run: { conversion, progress in
                await harness.run(conversion: conversion, progress: progress)
            },
            cancel: { await harness.cancel() }
        ))
        let service = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: adapter.jobExecutor
        )

        for presetID in ApplicationPresetID.allCases {
            let sourceURL = directory.appendingPathComponent("\(presetID.rawValue).mov")
            try Data(presetID.rawValue.utf8).write(to: sourceURL)
            let request = makeRequest(
                sourceURLs: [sourceURL],
                destinationFolderURL: outputDirectory,
                presetID: presetID,
                idempotencyKey: presetID.rawValue,
                defaults: defaults
            )
            let plan = try await service.plan(request)
            let accepted = try await service.submit(planID: plan.id)
            _ = try await waitForRecord(
                service: service,
                jobID: accepted.record.id,
                state: .succeeded
            )
        }

        let snapshots = await harness.snapshots()
        XCTAssertEqual(snapshots.map(\.preset), [.h264, .h265, .prores, .proxy, .audioOnly, .streamCopy])
        XCTAssertEqual(Set(snapshots.map(\.outputURL)).count, ApplicationPresetID.allCases.count)
        XCTAssertTrue(snapshots[0].ffmpegArguments.contains("libx264"))
        XCTAssertTrue(snapshots[1].ffmpegArguments.contains("libx265"))
        XCTAssertTrue(snapshots[2].ffmpegArguments.contains("prores_videotoolbox"))
        XCTAssertTrue(snapshots[3].ffmpegArguments.contains("hevc_videotoolbox"))
        XCTAssertEqual(snapshots[4].audioOnlyFormat, .wav)
        XCTAssertTrue(snapshots[4].ffmpegArguments.contains("pcm_s24le"))
        XCTAssertTrue(snapshots[5].ffmpegArguments.contains("copy"))
        XCTAssertEqual(snapshots[0].keepsSubtitles, true)
        XCTAssertEqual(snapshots[4].keepsSubtitles, false)
    }

    func testFFmpegAdapterExecutesCapturedSettingsAfterDefaultsChange() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("captured.mov")
        try Data("source".utf8).write(to: sourceURL)
        let defaults = try makeDefaults()
        defaults.set(H264Encoder.software.rawValue, forKey: AppConstants.h264EncoderKey)
        defaults.set(CodecQualityLevel.high.rawValue, forKey: AppConstants.h264QualityKey)
        defaults.set(EncodingSpeed.slow.rawValue, forKey: AppConstants.h264SpeedKey)
        defaults.set(CodecContainer.mov.rawValue, forKey: AppConstants.h264ContainerKey)
        defaults.set(CodecResolutionLimit.r720.rawValue, forKey: AppConstants.h264ResolutionLimitKey)
        defaults.set(CodecAudioFormat.pcm24.rawValue, forKey: AppConstants.h264AudioFormatKey)
        defaults.set(true, forKey: AppConstants.includeDateTagPreferenceKey)
        defaults.set("manual", forKey: AppConstants.defaultTimecodeModeKey)
        defaults.set("10:11:12:13", forKey: AppConstants.defaultTimecodeValueKey)
        defaults.set("Original", forKey: AppConstants.commentPrefixKey)
        let executionSettings = ApplicationRequestExecutionSettings(appIntentDefaults: defaults)

        let harness = ApplicationFFmpegRunnerHarness()
        let adapter = ApplicationFFmpegJobExecutor(runner: ApplicationFFmpegRunner(
            run: { conversion, progress in
                await harness.run(conversion: conversion, progress: progress)
            },
            cancel: { await harness.cancel() }
        ))
        let service = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: adapter.jobExecutor
        )
        let plan = try await service.plan(makeRequest(
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory,
            presetID: .h264,
            executionSettings: executionSettings,
            idempotencyKey: nil,
            defaults: defaults
        ))

        defaults.set(H264Encoder.hardware.rawValue, forKey: AppConstants.h264EncoderKey)
        defaults.set("50M", forKey: AppConstants.h264BitrateKey)
        defaults.set(CodecContainer.mkv.rawValue, forKey: AppConstants.h264ContainerKey)
        defaults.set(false, forKey: AppConstants.includeDateTagPreferenceKey)
        defaults.set("disabled", forKey: AppConstants.defaultTimecodeModeKey)
        defaults.set("Changed", forKey: AppConstants.commentPrefixKey)
        let accepted = try await service.submit(planID: plan.id)
        _ = try await waitForRecord(service: service, jobID: accepted.record.id, state: .succeeded)

        let capturedSnapshots = await harness.snapshots()
        let snapshot = try XCTUnwrap(capturedSnapshots.first)
        XCTAssertEqual(snapshot.outputURL.pathExtension, "mov")
        XCTAssertTrue(snapshot.ffmpegArguments.contains("libx264"))
        XCTAssertTrue(snapshot.ffmpegArguments.contains("18"))
        XCTAssertTrue(snapshot.ffmpegArguments.contains("slow"))
        XCTAssertTrue(snapshot.ffmpegArguments.contains("pcm_s24le"))
        XCTAssertFalse(snapshot.ffmpegArguments.contains("h264_videotoolbox"))
        XCTAssertFalse(snapshot.ffmpegArguments.contains("50M"))
        XCTAssertTrue(snapshot.includeDateTag)
        XCTAssertEqual(snapshot.manualTimecode, "10:11:12:13")
        XCTAssertEqual(snapshot.commentPrefix, "Original")
    }

    func testFFmpegAdapterCancellationSignalsOnlyItsActiveRunner() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("cancel.mov")
        try Data("source".utf8).write(to: sourceURL)

        let harness = ApplicationFFmpegRunnerHarness(blocksFirstRun: true)
        let adapter = ApplicationFFmpegJobExecutor(runner: ApplicationFFmpegRunner(
            run: { conversion, progress in
                await harness.run(conversion: conversion, progress: progress)
            },
            cancel: { await harness.cancel() }
        ))
        let service = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: adapter.jobExecutor
        )
        let plan = try await service.plan(makeRequest(
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory,
            idempotencyKey: nil
        ))
        let accepted = try await service.submit(planID: plan.id)
        _ = try await waitForRecord(service: service, jobID: accepted.record.id, state: .running)

        _ = try await service.requestCancellation(accepted.record.id)
        let cancelled = try await waitForRecord(
            service: service,
            jobID: accepted.record.id,
            state: .cancelled
        )

        XCTAssertEqual(cancelled.diagnostic, "Conversion cancelled.")
        let cancelCount = await harness.cancelCount()
        let runCount = await harness.runCount()
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(runCount, 1)
    }

    func testFFmpegAdapterRejectsUnrepresentableCapturedSettingsBeforeLaunching() async throws {
        let directory = try makeTemporaryDirectory()
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent("invalid.mov")
        try Data("source".utf8).write(to: sourceURL)
        let defaults = try makeDefaults()
        let captured = ApplicationPresetSettings(presetID: .h264, defaults: defaults)
        let invalid = ApplicationPresetSettings(
            presetID: .h264,
            containerID: .mp4,
            video: ApplicationVideoSettings(
                encoderID: .libx264,
                profileID: .hevcMain10,
                quality: 23,
                bitrate: nil,
                speed: "medium",
                maximumHeight: nil
            ),
            audio: captured.audio,
            preserveMetadata: captured.preserveMetadata,
            keepSubtitles: captured.keepSubtitles,
            fileName: captured.fileName
        )

        let harness = ApplicationFFmpegRunnerHarness()
        let adapter = ApplicationFFmpegJobExecutor(runner: ApplicationFFmpegRunner(
            run: { conversion, progress in
                await harness.run(conversion: conversion, progress: progress)
            },
            cancel: { await harness.cancel() }
        ))
        let service = ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: adapter.jobExecutor
        )
        let plan = try await service.plan(makeRequest(
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory,
            presetID: .h264,
            presetSettings: invalid,
            idempotencyKey: nil
        ))
        let accepted = try await service.submit(planID: plan.id)
        let failed = try await waitForRecord(
            service: service,
            jobID: accepted.record.id,
            state: .failed
        )

        XCTAssertEqual(
            failed.diagnostic,
            "The accepted preset settings cannot be represented by the conversion engine."
        )
        let runCount = await harness.runCount()
        XCTAssertEqual(runCount, 0)
    }

    func testAgentToolsAdvertiseOnlySupportedPresetsWithCapturedSettings() throws {
        let defaults = try makeDefaults()
        defaults.set(CodecContainer.mkv.rawValue, forKey: AppConstants.h264ContainerKey)
        defaults.set(AudioOnlyFormat.flac.rawValue, forKey: AppConstants.audioOnlyFormatKey)
        let defaultsFixture = ApplicationAgentDefaultsFixture(defaults)
        let tools = ApplicationAgentTools(
            jobService: ApplicationJobService(fileAccessAuthorizer: .unrestricted),
            fileAccessAuthorizer: .unrestricted,
            presetSettingsProvider: {
                ApplicationPresetSettings(presetID: $0, defaults: defaultsFixture.value)
            }
        )

        let presets = tools.listPresets()

        XCTAssertEqual(presets.map(\.id), ApplicationPresetID.allCases)
        XCTAssertEqual(presets.map(\.displayName), [
            "H.264 / AVC", "H.265 / HEVC", "ProRes", "Proxy", "Audio Only", "Stream Copy"
        ])
        XCTAssertTrue(presets.allSatisfy { $0.supportedOverrides.isEmpty })
        XCTAssertEqual(presets.first { $0.id == .h264 }?.settings.containerID, .mkv)
        XCTAssertEqual(presets.first { $0.id == .audioOnly }?.settings.containerID, .flac)
        XCTAssertNoThrow(try JSONDecoder().decode(
            [ApplicationPresetDescriptor].self,
            from: JSONEncoder().encode(presets)
        ))
    }

    func testAgentToolsInspectionRetainsAccessAndReturnsCodableMetadata() async throws {
        let sourceURL = URL(fileURLWithPath: "/approved/clip.mov")
        let leaseState = ApplicationJobLeaseState()
        let expected = ApplicationMediaInspection(
            sourceURL: sourceURL,
            durationSeconds: 12.5,
            formatName: "mov",
            containerName: "QuickTime",
            sizeBytes: 4_096,
            bitRate: 2_000_000,
            timecode: "01:00:00:00",
            timecodes: [],
            frameCount: 300,
            warnings: ["fixture warning"],
            videoStreams: [ApplicationMediaVideoStream(
                index: 0,
                codec: "h264",
                profile: "High",
                width: 1920,
                height: 1080,
                pixelFormat: "yuv420p",
                hasAlpha: false,
                pixelAspectRatio: nil,
                displayAspectRatio: nil,
                frameRate: ApplicationMediaRational(numerator: 24_000, denominator: 1_001, value: 23.976),
                bitDepth: 8,
                bitRate: 1_800_000,
                durationSeconds: 12.5,
                chromaSubsampling: "4:2:0",
                colorPrimaries: "bt709",
                colorTransfer: "bt709",
                colorSpace: "bt709",
                colorRange: "tv",
                fieldOrder: "progressive",
                isInterlaced: false,
                title: nil,
                isDefault: true,
                isForced: false
            )],
            audioStreams: [],
            subtitleStreams: []
        )
        let tools = ApplicationAgentTools(
            jobService: ApplicationJobService(fileAccessAuthorizer: .unrestricted),
            fileAccessAuthorizer: ApplicationFileAccessAuthorizer { url, mode in
                guard url == sourceURL, mode == .read else { return nil }
                return leaseState.acquire()
            },
            mediaInspector: ApplicationMediaInspector { url in
                XCTAssertEqual(url, sourceURL)
                XCTAssertEqual(leaseState.activeCount, 1)
                return expected
            }
        )

        let inspection = try await tools.inspectMedia(at: sourceURL)

        XCTAssertEqual(inspection, expected)
        XCTAssertEqual(leaseState.activeCount, 0)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ApplicationMediaInspection.self,
                from: JSONEncoder().encode(inspection)
            ),
            expected
        )
    }

    func testMediaInspectionMapsProbeStreamsAndExactFrameRate() throws {
        let sourceURL = URL(fileURLWithPath: "/approved/clip.mov")
        let metadata = VideoMetadata(
            duration: 10,
            formatName: "mov",
            containerLongName: "QuickTime",
            sizeBytes: 1_024,
            bitRate: 900_000,
            comment: nil,
            timecode: "10:00:00:00",
            timecodes: [TimecodeEntry(value: "10:00:00:00", source: .tmcdTrack, frameRate: 23.976)],
            frameCount: 240,
            containerCreationDate: nil,
            containerModificationDate: nil,
            title: nil,
            artist: nil,
            gpsLatitude: nil,
            gpsLongitude: nil,
            gpsAltitude: nil,
            warnings: [],
            videoStreams: [VideoMetadata.VideoStream(
                codec: "h264",
                codecLongName: "H.264",
                profile: "High",
                width: 1920,
                height: 1080,
                pixelFormat: "yuv420p",
                hasAlpha: false,
                pixelAspectRatio: VideoMetadata.Ratio(numerator: 1, denominator: 1),
                displayAspectRatio: VideoMetadata.Ratio(numerator: 16, denominator: 9),
                frameRate: VideoMetadata.FrameRate(frameRateString: "24000/1001"),
                bitDepth: 8,
                bitRate: 800_000,
                duration: 10,
                chromaSubsampling: "4:2:0",
                colorPrimaries: "bt709",
                colorTransfer: "bt709",
                colorSpace: "bt709",
                colorRange: "tv",
                chromaLocation: "left",
                fieldOrder: "progressive",
                isInterlaced: false,
                title: "Picture",
                isDefault: true,
                isForced: false
            )],
            audioStreams: [VideoMetadata.AudioStream(
                index: 1,
                languageCode: "eng",
                title: "Main",
                codec: "aac",
                codecLongName: "AAC",
                profile: "LC",
                sampleRate: 48_000,
                channels: 2,
                channelLayout: "stereo",
                bitDepth: nil,
                bitRate: 96_000,
                isDefault: true
            )],
            subtitleStreams: [VideoMetadata.SubtitleStream(
                index: 2,
                languageCode: "nor",
                title: "Norsk",
                codec: "mov_text",
                codecLongName: "MOV text",
                isDefault: false,
                isForced: true,
                isHearingImpaired: false,
                duration: 9.5
            )]
        )

        let inspection = ApplicationMediaInspection(sourceURL: sourceURL, metadata: metadata)

        XCTAssertEqual(inspection.videoStreams[0].frameRate?.numerator, 24_000)
        XCTAssertEqual(inspection.videoStreams[0].frameRate?.denominator, 1_001)
        XCTAssertEqual(inspection.videoStreams[0].displayAspectRatio?.value, 16.0 / 9.0)
        XCTAssertEqual(inspection.videoStreams[0].width, 1920)
        XCTAssertEqual(inspection.audioStreams[0].channelLayout, "stereo")
        XCTAssertEqual(inspection.subtitleStreams[0].languageCode, "nor")
        XCTAssertEqual(inspection.timecodes, metadata.timecodes)
    }

    func testAgentToolsInspectionRejectsMissingApprovalAndMapsFailures() async throws {
        let sourceURL = URL(fileURLWithPath: "/not-approved/clip.mov")
        let unknownJob = ApplicationJobID(
            UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )
        let tools = ApplicationAgentTools(
            jobService: ApplicationJobService(fileAccessAuthorizer: .unrestricted),
            fileAccessAuthorizer: ApplicationFileAccessAuthorizer { _, _ in nil },
            mediaInspector: ApplicationMediaInspector { _ in
                XCTFail("Inspection must not run without an approved bookmark")
                throw CancellationError()
            }
        )

        do {
            _ = try await tools.inspectMedia(at: sourceURL)
            XCTFail("Expected source access rejection")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .sourceAccessDenied(sourceURL))
            XCTAssertEqual(
                ApplicationAgentToolFailure(error: error),
                ApplicationAgentToolFailure(
                    code: .sourceAccessDenied,
                    message: "Access to the source has not been approved in the app: clip.mov."
                )
            )
        }

        XCTAssertEqual(
            ApplicationAgentToolFailure(error: ApplicationJobError.unknownJob(unknownJob)).code,
            .unknownJob
        )
        XCTAssertEqual(
            ApplicationAgentToolFailure(error: CocoaError(.fileReadUnknown)).code,
            .internalError
        )
    }

    func testAgentToolsPlanSubmitGetAndCancelUseSharedJobService() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        let outputDirectory = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: sourceURL)
        let instant = Date(timeIntervalSince1970: 1_800_123_456)
        let service = ApplicationJobService(fileAccessAuthorizer: .unrestricted)
        let tools = ApplicationAgentTools(
            jobService: service,
            fileAccessAuthorizer: .unrestricted,
            now: { instant }
        )
        let input = ApplicationPlanConversionInput(
            requesterID: "mcp-client",
            sourceURLs: [sourceURL],
            destinationFolderURL: outputDirectory,
            presetID: .hevc,
            idempotencyKey: "agent-request-1"
        )

        let plan = try await tools.planConversion(input)
        XCTAssertEqual(plan.request.origin, .localAgent)
        XCTAssertEqual(plan.request.requesterID, "mcp-client")
        XCTAssertEqual(plan.request.capturedAt, instant)
        XCTAssertEqual(plan.createdAt, instant)
        XCTAssertEqual(plan.request.presetSettings.presetID, .hevc)

        let accepted = try await tools.submitConversion(planID: plan.id)
        let acceptedRecord = try await tools.getJob(jobID: accepted.record.id)
        XCTAssertEqual(acceptedRecord, accepted.record)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ApplicationJobAcceptance.self,
                from: JSONEncoder().encode(accepted)
            ),
            accepted
        )

        let cancelled = try await tools.cancelJob(jobID: accepted.record.id)
        XCTAssertEqual(cancelled.state, .cancelled)
        let cancelledRecord = try await tools.getJob(jobID: accepted.record.id)
        XCTAssertEqual(cancelledRecord.state, .cancelled)
    }

    func testAgentTransportDispatchesTypedToolsAndRejectsInvalidArguments() async throws {
        let dispatcher = ApplicationAgentRequestDispatcher(
            tools: ApplicationAgentTools(
                jobService: ApplicationJobService(fileAccessAuthorizer: .unrestricted),
                fileAccessAuthorizer: .unrestricted
            )
        )
        let listRequest = ApplicationAgentIPCRequest(tool: .listPresets)
        let listResponse = await dispatcher.response(to: listRequest)

        XCTAssertEqual(listResponse.requestID, listRequest.requestID)
        XCTAssertNil(listResponse.failure)
        guard case .array(let presets)? = listResponse.result else {
            return XCTFail("Expected a preset array")
        }
        XCTAssertEqual(presets.count, ApplicationPresetID.allCases.count)

        let invalidRequest = ApplicationAgentIPCRequest(
            tool: .inspectMedia,
            arguments: ["source_path": .string("relative.mov")]
        )
        let invalidResponse = await dispatcher.response(to: invalidRequest)
        XCTAssertNil(invalidResponse.result)
        XCTAssertEqual(invalidResponse.failure?.code, .invalidArguments)
        XCTAssertEqual(
            invalidResponse.failure?.message,
            "source_path must be an absolute local path."
        )

        let unexpectedArgumentResponse = await dispatcher.response(to: ApplicationAgentIPCRequest(
            tool: .listPresets,
            arguments: ["ignored": .bool(true)]
        ))
        XCTAssertEqual(unexpectedArgumentResponse.failure?.code, .invalidArguments)
        XCTAssertEqual(
            unexpectedArgumentResponse.failure?.message,
            "Unexpected argument: ignored."
        )

        let encoded = try JSONEncoder().encode(listResponse)
        XCTAssertEqual(
            try JSONDecoder().decode(ApplicationAgentIPCResponse.self, from: encoded),
            listResponse
        )
    }

    func testAgentMessagePortRoundTripKeepsRequestIdentity() throws {
        let portName = "com.aagedal.tests.agent.\(UUID().uuidString)"
        let server = ApplicationAgentIPCServer(
            portName: portName,
            dispatcher: ApplicationAgentRequestDispatcher(
                tools: ApplicationAgentTools(
                    jobService: ApplicationJobService(fileAccessAuthorizer: .unrestricted),
                    fileAccessAuthorizer: .unrestricted
                )
            )
        )
        try server.start()
        defer { server.stop() }

        let request = ApplicationAgentIPCRequest(tool: .listPresets)
        let response = try ApplicationAgentIPCClient(portName: portName).send(
            request,
            receiveTimeout: 10
        )

        XCTAssertEqual(response.requestID, request.requestID)
        XCTAssertNil(response.failure)
        guard case .array(let presets)? = response.result else {
            return XCTFail("Expected a preset array")
        }
        XCTAssertEqual(presets.count, ApplicationPresetID.allCases.count)

        server.stop()
        XCTAssertFalse(server.isRunning)
        try server.start()
        let restartedResponse = try ApplicationAgentIPCClient(portName: portName).send(
            request,
            receiveTimeout: 10
        )
        XCTAssertEqual(restartedResponse.requestID, request.requestID)
        XCTAssertNil(restartedResponse.failure)
    }

    private func makeRequest(
        schemaVersion: Int = ApplicationConversionRequest.currentSchemaVersion,
        requestID: UUID = UUID(),
        origin: ApplicationJobOrigin = .localAgent,
        requesterID: String = "codex",
        sourceURLs: [URL]? = nil,
        destinationFolderURL: URL? = nil,
        presetID: ApplicationPresetID = .h264,
        presetSettings: ApplicationPresetSettings? = nil,
        executionSettings: ApplicationRequestExecutionSettings? = nil,
        idempotencyKey: String? = "request-1",
        capturedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        defaults: UserDefaults = .standard
    ) -> ApplicationConversionRequest {
        ApplicationConversionRequest(
            schemaVersion: schemaVersion,
            requestID: requestID,
            origin: origin,
            requesterID: requesterID,
            sourceURLs: sourceURLs ?? [source],
            destinationFolderURL: destinationFolderURL ?? destination,
            presetID: presetID,
            presetSettings: presetSettings,
            executionSettings: executionSettings,
            idempotencyKey: idempotencyKey,
            capturedAt: capturedAt,
            defaults: defaults
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "ApplicationJobContractTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplicationJobContractTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeExecutingService(
        harness: ApplicationJobExecutorHarness
    ) -> ApplicationJobService {
        ApplicationJobService(
            fileAccessAuthorizer: .unrestricted,
            executor: ApplicationJobExecutor(
                execute: { jobID, plan, progress in
                    await harness.execute(jobID: jobID, plan: plan, progress: progress)
                },
                cancel: { jobID in
                    await harness.cancel(jobID: jobID)
                }
            )
        )
    }

    private func waitForRecord(
        service: ApplicationJobService,
        jobID: ApplicationJobID,
        state: ApplicationJobState
    ) async throws -> ApplicationJobRecord {
        for _ in 0..<200 {
            if let record = try await service.record(for: jobID), record.state == state {
                return record
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for job \(jobID) to reach \(state.rawValue)")
        let lastRecord = try await service.record(for: jobID)
        return try XCTUnwrap(lastRecord)
    }
}

private final class ApplicationAgentDefaultsFixture: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

private actor ApplicationFFmpegRunnerHarness {
    struct Snapshot: Sendable {
        let preset: ExportPreset
        let outputURL: URL
        let ffmpegArguments: [String]
        let audioOnlyFormat: AudioOnlyFormat?
        let keepsSubtitles: Bool
        let includeDateTag: Bool
        let manualTimecode: String?
        let commentPrefix: String?
    }

    private let blocksFirstRun: Bool
    private var recordedSnapshots: [Snapshot] = []
    private var cancellationCount = 0
    private var cancellationRequested = false
    private var firstRunContinuation: CheckedContinuation<Void, Never>?

    init(blocksFirstRun: Bool = false) {
        self.blocksFirstRun = blocksFirstRun
    }

    func run(
        conversion: ApplicationFFmpegConversion,
        progress: ApplicationFFmpegProgressSink
    ) async -> ApplicationFFmpegRunResult {
        let manualTimecode: String? = if case .manual(let value)? = conversion.request.timecodeConfig?.mode {
            value
        } else {
            nil
        }
        recordedSnapshots.append(Snapshot(
            preset: conversion.request.preset,
            outputURL: conversion.request.outputURL,
            ffmpegArguments: conversion.audioOnlySettings?.ffmpegArguments
                ?? conversion.codecSettings?.ffmpegArguments
                ?? [],
            audioOnlyFormat: conversion.audioOnlySettings?.format,
            keepsSubtitles: conversion.subtitleSettings.keepSubtitles,
            includeDateTag: conversion.request.includeDateTag,
            manualTimecode: manualTimecode,
            commentPrefix: conversion.commentSettings?.prefix
        ))
        progress.send(0.5, status: "Encoding")
        if blocksFirstRun, recordedSnapshots.count == 1, !cancellationRequested {
            await withCheckedContinuation { continuation in
                if cancellationRequested {
                    continuation.resume()
                } else {
                    firstRunContinuation = continuation
                }
            }
        }
        return cancellationRequested ? .failed("Conversion cancelled") : .succeeded
    }

    func cancel() {
        cancellationCount += 1
        cancellationRequested = true
        firstRunContinuation?.resume()
        firstRunContinuation = nil
    }

    func snapshots() -> [Snapshot] {
        recordedSnapshots
    }

    func cancelCount() -> Int {
        cancellationCount
    }

    func runCount() -> Int {
        recordedSnapshots.count
    }
}

private actor ApplicationJobExecutorHarness {
    struct Snapshot: Sendable {
        let startedIDs: [ApplicationJobID]
        let cancelledIDs: Set<ApplicationJobID>
        let maximumConcurrentExecutions: Int
    }

    private let blocksFirstExecution: Bool
    private var startedIDs: [ApplicationJobID] = []
    private var cancelledIDs: Set<ApplicationJobID> = []
    private var activeExecutions = 0
    private var maximumConcurrentExecutions = 0
    private var firstExecutionContinuation: CheckedContinuation<Void, Never>?
    private var firstExecutionReleaseRequested = false

    init(blocksFirstExecution: Bool) {
        self.blocksFirstExecution = blocksFirstExecution
    }

    func execute(
        jobID: ApplicationJobID,
        plan: ApplicationConversionPlan,
        progress: ApplicationJobProgressReporter
    ) async -> ApplicationJobExecutionResult {
        startedIDs.append(jobID)
        activeExecutions += 1
        maximumConcurrentExecutions = max(maximumConcurrentExecutions, activeExecutions)
        await progress.report(ApplicationJobProgressUpdate(progress: 0.5, stage: "Encoding"))
        if blocksFirstExecution, startedIDs.count == 1 {
            await withCheckedContinuation { continuation in
                if firstExecutionReleaseRequested || cancelledIDs.contains(jobID) {
                    continuation.resume()
                } else {
                    firstExecutionContinuation = continuation
                }
            }
        }
        activeExecutions -= 1
        if cancelledIDs.contains(jobID) {
            return .cancelled(diagnostic: "Cancelled by requester")
        }
        return .succeeded(outputURLs: plan.outputs.map(\.outputURL))
    }

    func cancel(jobID: ApplicationJobID) {
        cancelledIDs.insert(jobID)
        firstExecutionContinuation?.resume()
        firstExecutionContinuation = nil
    }

    func releaseFirstExecution() {
        firstExecutionReleaseRequested = true
        firstExecutionContinuation?.resume()
        firstExecutionContinuation = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(
            startedIDs: startedIDs,
            cancelledIDs: cancelledIDs,
            maximumConcurrentExecutions: maximumConcurrentExecutions
        )
    }
}

private final class ApplicationJobLeaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var activeCount: Int {
        lock.withLock { count }
    }

    func acquire() -> ApplicationFileAccessLease {
        lock.withLock { count += 1 }
        return ApplicationFileAccessLease { [weak self] in
            self?.lock.withLock { self?.count -= 1 }
        }
    }
}
