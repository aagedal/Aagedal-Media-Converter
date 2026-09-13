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

        let service = ApplicationJobService()
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

        let expiringService = ApplicationJobService(planLifetime: 10)
        let expiredPlan = try await expiringService.plan(request, now: now)
        do {
            _ = try await expiringService.submit(planID: expiredPlan.id, now: now.addingTimeInterval(11))
            XCTFail("Expected an expired plan to be rejected")
        } catch {
            XCTAssertEqual(error as? ApplicationJobError, .expiredPlan(expiredPlan.id))
        }

        let changedSourceService = ApplicationJobService()
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

        let service = ApplicationJobService()
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
        let service = ApplicationJobService()
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
        let records = await service.allRecords()
        XCTAssertEqual(records.count, 1)
    }

    func testSubmitRejectsAnOutputCreatedAfterPlanning() async throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("input.mov")
        try Data("source".utf8).write(to: sourceURL)
        let service = ApplicationJobService()
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
            _ = try await ApplicationJobService().plan(request)
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

    private func makeRequest(
        schemaVersion: Int = ApplicationConversionRequest.currentSchemaVersion,
        requestID: UUID = UUID(),
        origin: ApplicationJobOrigin = .localAgent,
        requesterID: String = "codex",
        sourceURLs: [URL]? = nil,
        destinationFolderURL: URL? = nil,
        presetID: ApplicationPresetID = .h264,
        presetSettings: ApplicationPresetSettings? = nil,
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
}
