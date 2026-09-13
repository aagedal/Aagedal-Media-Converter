// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Versioned identifiers exposed at the application boundary. These values stay
/// independent of localized preset names and mutable user-facing labels.
enum ApplicationPresetID: String, CaseIterable, Codable, Sendable {
    case h264 = "h264"
    case hevc = "hevc"
    case proRes = "prores"
    case proxy = "proxy"
    case audioOnly = "audio_only"
    case streamCopy = "stream_copy"

    var exportPreset: ExportPreset {
        switch self {
        case .h264: .h264
        case .hevc: .h265
        case .proRes: .prores
        case .proxy: .proxy
        case .audioOnly: .audioOnly
        case .streamCopy: .streamCopy
        }
    }
}

enum ApplicationJobOrigin: String, Codable, Sendable {
    case manual
    case appIntent = "app_intent"
    case localAgent = "local_agent"
}

/// Stable, transport-facing identifiers for the resolved settings that affect an
/// accepted conversion. They deliberately do not reuse localized UI raw values.
enum ApplicationContainerID: String, Codable, Sendable {
    case source
    case mp4
    case mov
    case mkv
    case mxf
    case wav
    case m4a
    case flac
}

enum ApplicationVideoEncoderID: String, Codable, Sendable {
    case libx264
    case libx265
    case h264VideoToolbox = "h264_videotoolbox"
    case hevcVideoToolbox = "hevc_videotoolbox"
    case proResVideoToolbox = "prores_videotoolbox"
    case dnxhd
    case streamCopy = "stream_copy"
}

enum ApplicationVideoProfileID: String, Codable, Sendable {
    case h264High = "h264_high"
    case hevcMain10 = "hevc_main10"
    case proResProxy = "prores_proxy"
    case proResLT = "prores_lt"
    case proRes422 = "prores_422"
    case proResHQ = "prores_hq"
    case proRes4444 = "prores_4444"
    case proRes4444XQ = "prores_4444_xq"
    case dnxhrLB = "dnxhr_lb"
}

enum ApplicationAudioCodecID: String, Codable, Sendable {
    case aac
    case opus
    case pcm16 = "pcm_s16le"
    case pcm24 = "pcm_s24le"
    case pcm32 = "pcm_s32le"
    case flac
    case streamCopy = "stream_copy"
}

enum ApplicationSpecialCharacterRemovalModeID: String, Codable, Sendable {
    case off
    case loose
    case strict
}

struct ApplicationVideoSettings: Codable, Equatable, Sendable {
    let encoderID: ApplicationVideoEncoderID
    let profileID: ApplicationVideoProfileID?
    let quality: Int?
    let bitrate: String?
    let speed: String?
    let maximumHeight: Int?
}

struct ApplicationAudioSettings: Codable, Equatable, Sendable {
    let codecID: ApplicationAudioCodecID
    let bitrate: String?
}

struct ApplicationFileNameSettings: Codable, Equatable, Sendable {
    let processingEnabled: Bool
    let replaceSpaces: Bool
    let replaceScandinavianCharacters: Bool
    let specialCharacterRemovalMode: ApplicationSpecialCharacterRemovalModeID
    let includePresetSuffix: Bool
    let customTemplateEnabled: Bool
    let template: String
    let dateFormat: String
    let counterPadding: Int
    let counterStart: Int
    let presetSuffix: String

    private enum CodingKeys: String, CodingKey {
        case processingEnabled
        case replaceSpaces
        case replaceScandinavianCharacters
        case specialCharacterRemovalMode
        case includePresetSuffix
        case customTemplateEnabled
        case template
        case dateFormat
        case counterPadding
        case counterStart
        case presetSuffix
    }

    init(preset: ExportPreset, defaults: UserDefaults) {
        let settings = FileNameSettings(defaults: defaults).snapshot
        let context = FileNameTemplateContext(preset: preset, defaults: defaults)
        processingEnabled = settings.isEnabled
        replaceSpaces = settings.replaceSpaces
        replaceScandinavianCharacters = settings.replaceScandinavianCharacters
        specialCharacterRemovalMode = switch settings.specialCharacterRemovalMode {
        case .off: .off
        case .loose: .loose
        case .strict: .strict
        }
        includePresetSuffix = settings.includePresetSuffix
        customTemplateEnabled = settings.customTemplateEnabled
        template = settings.template
        dateFormat = settings.dateFormat
        counterPadding = settings.counterPadding
        counterStart = defaults.object(forKey: AppConstants.customFileNameCounterValueKey) as? Int
            ?? AppConstants.defaultCustomFileNameCounterValue
        presetSuffix = context.presetSuffix
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        processingEnabled = try values.decode(Bool.self, forKey: .processingEnabled)
        replaceSpaces = try values.decode(Bool.self, forKey: .replaceSpaces)
        replaceScandinavianCharacters = try values.decode(Bool.self, forKey: .replaceScandinavianCharacters)
        specialCharacterRemovalMode = try values.decode(
            ApplicationSpecialCharacterRemovalModeID.self,
            forKey: .specialCharacterRemovalMode
        )
        includePresetSuffix = try values.decode(Bool.self, forKey: .includePresetSuffix)
        customTemplateEnabled = try values.decode(Bool.self, forKey: .customTemplateEnabled)
        template = try values.decode(String.self, forKey: .template)
        dateFormat = try values.decode(String.self, forKey: .dateFormat)
        counterPadding = try values.decode(Int.self, forKey: .counterPadding)
        counterStart = try values.decodeIfPresent(Int.self, forKey: .counterStart)
            ?? AppConstants.defaultCustomFileNameCounterValue
        presetSuffix = try values.decode(String.self, forKey: .presetSuffix)
    }

    fileprivate var fileNamePreferences: FileNamePreferences {
        let removalMode: SpecialCharacterRemovalMode = switch specialCharacterRemovalMode {
        case .off: .off
        case .loose: .loose
        case .strict: .strict
        }
        return FileNamePreferences(
            isEnabled: processingEnabled,
            replaceSpaces: replaceSpaces,
            replaceScandinavianCharacters: replaceScandinavianCharacters,
            specialCharacterRemovalMode: removalMode,
            includePresetSuffix: includePresetSuffix,
            customTemplateEnabled: customTemplateEnabled,
            template: template,
            dateFormat: dateFormat,
            counterPadding: counterPadding
        )
    }
}

/// An immutable semantic snapshot of the mutable preferences behind a supported
/// preset. A request keeps this value through planning and execution, so a later
/// Settings change cannot silently alter already accepted work.
struct ApplicationPresetSettings: Codable, Equatable, Sendable {
    let presetID: ApplicationPresetID
    let containerID: ApplicationContainerID
    let video: ApplicationVideoSettings?
    let audio: ApplicationAudioSettings?
    let preserveMetadata: Bool
    let keepSubtitles: Bool
    let fileName: ApplicationFileNameSettings

    init(presetID: ApplicationPresetID, defaults: UserDefaults = .standard) {
        let preset = presetID.exportPreset
        self.presetID = presetID
        preserveMetadata = defaults.bool(forKey: AppConstants.preserveMetadataPreferenceKey)
        keepSubtitles = preset != .streamCopy
            && preset != .audioOnly
            && defaults.bool(forKey: AppConstants.keepSubtitlesKey)
        fileName = ApplicationFileNameSettings(preset: preset, defaults: defaults)

        switch presetID {
        case .h264:
            let container = Self.codecContainer(
                defaults.string(forKey: AppConstants.h264ContainerKey),
                fallback: AppConstants.defaultH264Container
            )
            let encoder = H264Encoder(
                rawValue: defaults.string(forKey: AppConstants.h264EncoderKey)
                    ?? AppConstants.defaultH264Encoder
            ) ?? .software
            let resolution = CodecResolutionLimit(
                rawValue: defaults.string(forKey: AppConstants.h264ResolutionLimitKey)
                    ?? AppConstants.defaultH264ResolutionLimit
            ) ?? .unlimited
            let audio = Self.codecAudio(
                formatRaw: defaults.string(forKey: AppConstants.h264AudioFormatKey),
                fallbackFormat: AppConstants.defaultH264AudioFormat,
                bitrateRaw: defaults.string(forKey: AppConstants.h264AudioBitrateKey),
                fallbackBitrate: AppConstants.defaultH264AudioBitrate,
                container: container
            )
            containerID = Self.containerID(container)
            video = ApplicationVideoSettings(
                encoderID: encoder == .hardware ? .h264VideoToolbox : .libx264,
                profileID: .h264High,
                quality: encoder == .software ? Self.codecQuality(
                    defaults.string(forKey: AppConstants.h264QualityKey),
                    fallback: AppConstants.defaultH264Quality
                ).crfValue : nil,
                bitrate: encoder == .hardware
                    ? defaults.string(forKey: AppConstants.h264BitrateKey) ?? AppConstants.defaultH264Bitrate
                    : nil,
                speed: encoder == .software
                    ? Self.encodingSpeed(
                        defaults.string(forKey: AppConstants.h264SpeedKey),
                        fallback: AppConstants.defaultH264Speed
                    ).ffmpegPreset
                    : nil,
                maximumHeight: resolution.maxHeight
            )
            self.audio = audio
        case .hevc:
            let container = Self.codecContainer(
                defaults.string(forKey: AppConstants.h265ContainerKey),
                fallback: AppConstants.defaultH265Container
            )
            let encoder = H265Encoder(
                rawValue: defaults.string(forKey: AppConstants.h265EncoderKey)
                    ?? AppConstants.defaultH265Encoder
            ) ?? .software
            let resolution = CodecResolutionLimit(
                rawValue: defaults.string(forKey: AppConstants.h265ResolutionLimitKey)
                    ?? AppConstants.defaultH265ResolutionLimit
            ) ?? .unlimited
            let audio = Self.codecAudio(
                formatRaw: defaults.string(forKey: AppConstants.h265AudioFormatKey),
                fallbackFormat: AppConstants.defaultH265AudioFormat,
                bitrateRaw: defaults.string(forKey: AppConstants.h265AudioBitrateKey),
                fallbackBitrate: AppConstants.defaultH265AudioBitrate,
                container: container
            )
            containerID = Self.containerID(container)
            video = ApplicationVideoSettings(
                encoderID: encoder == .hardware ? .hevcVideoToolbox : .libx265,
                profileID: .hevcMain10,
                quality: encoder == .software ? Self.codecQuality(
                    defaults.string(forKey: AppConstants.h265QualityKey),
                    fallback: AppConstants.defaultH265Quality
                ).crfValue : nil,
                bitrate: encoder == .hardware
                    ? defaults.string(forKey: AppConstants.h265BitrateKey) ?? AppConstants.defaultH265Bitrate
                    : nil,
                speed: encoder == .software
                    ? Self.encodingSpeed(
                        defaults.string(forKey: AppConstants.h265SpeedKey),
                        fallback: AppConstants.defaultH265Speed
                    ).ffmpegPreset
                    : nil,
                maximumHeight: resolution.maxHeight
            )
            self.audio = audio
        case .proRes:
            let profile = ProResProfile(
                rawValue: defaults.string(forKey: AppConstants.proResProfileKey)
                    ?? ProResProfile.standard.rawValue
            ) ?? .standard
            containerID = .mov
            video = ApplicationVideoSettings(
                encoderID: .proResVideoToolbox,
                profileID: Self.proResProfileID(profile),
                quality: nil,
                bitrate: nil,
                speed: nil,
                maximumHeight: nil
            )
            audio = ApplicationAudioSettings(codecID: .pcm24, bitrate: nil)
        case .proxy:
            let codec = ProxyCodec(
                rawValue: defaults.string(forKey: AppConstants.proxyCodecKey)
                    ?? AppConstants.defaultProxyCodec
            ) ?? .hevc
            let resolution = ProxyResolutionLimit(
                rawValue: defaults.string(forKey: AppConstants.proxyResolutionLimitKey)
                    ?? AppConstants.defaultProxyResolutionLimit
            ) ?? .r1080
            containerID = codec == .dnxhd ? .mxf : .mov
            video = ApplicationVideoSettings(
                encoderID: Self.proxyEncoderID(codec),
                profileID: Self.proxyProfileID(codec),
                quality: nil,
                bitrate: codec == .hevc ? resolution.bitrate : nil,
                speed: nil,
                maximumHeight: resolution.maxHeight
            )
            audio = ApplicationAudioSettings(codecID: .pcm24, bitrate: nil)
        case .audioOnly:
            let settings = AudioOnlySettings(defaults: defaults)
            containerID = Self.audioContainerID(settings.format)
            video = nil
            audio = Self.audioOnlySettings(settings)
        case .streamCopy:
            let container = StreamCopyContainer(
                rawValue: defaults.string(forKey: AppConstants.streamCopyContainerKey)
                    ?? AppConstants.defaultStreamCopyContainer
            ) ?? .keepCurrent
            containerID = Self.streamCopyContainerID(container)
            video = ApplicationVideoSettings(
                encoderID: .streamCopy,
                profileID: nil,
                quality: nil,
                bitrate: nil,
                speed: nil,
                maximumHeight: nil
            )
            audio = ApplicationAudioSettings(codecID: .streamCopy, bitrate: nil)
        }
    }

    private static func codecContainer(_ raw: String?, fallback: String) -> CodecContainer {
        CodecContainer(rawValue: raw ?? fallback) ?? .mp4
    }

    private static func containerID(_ container: CodecContainer) -> ApplicationContainerID {
        switch container {
        case .mp4: .mp4
        case .mov: .mov
        case .mkv: .mkv
        }
    }

    private static func codecQuality(_ raw: String?, fallback: String) -> CodecQualityLevel {
        CodecQualityLevel(rawValue: raw ?? fallback)
            ?? CodecQualityLevel(rawValue: fallback)
            ?? .good
    }

    private static func encodingSpeed(_ raw: String?, fallback: String) -> EncodingSpeed {
        EncodingSpeed(rawValue: raw ?? fallback) ?? .medium
    }

    private static func codecAudio(
        formatRaw: String?,
        fallbackFormat: String,
        bitrateRaw: String?,
        fallbackBitrate: String,
        container: CodecContainer
    ) -> ApplicationAudioSettings {
        var format = CodecAudioFormat(rawValue: formatRaw ?? fallbackFormat) ?? .aac
        if format == .opus && container != .mkv { format = .aac }
        let bitrate = AudioBitrate(rawValue: bitrateRaw ?? fallbackBitrate) ?? .k192
        return ApplicationAudioSettings(
            codecID: audioCodecID(format),
            bitrate: format.requiresBitrate ? bitrate.ffmpegValue : nil
        )
    }

    private static func audioCodecID(_ format: CodecAudioFormat) -> ApplicationAudioCodecID {
        switch format {
        case .aac: .aac
        case .opus: .opus
        case .pcm16: .pcm16
        case .pcm24: .pcm24
        case .pcm32: .pcm32
        }
    }

    private static func proResProfileID(_ profile: ProResProfile) -> ApplicationVideoProfileID {
        switch profile {
        case .proxy: .proResProxy
        case .lt: .proResLT
        case .standard: .proRes422
        case .hq: .proResHQ
        case .fourFourFourFour: .proRes4444
        case .fourFourFourFourXQ: .proRes4444XQ
        }
    }

    private static func proxyEncoderID(_ codec: ProxyCodec) -> ApplicationVideoEncoderID {
        switch codec {
        case .hevc: .hevcVideoToolbox
        case .prores: .proResVideoToolbox
        case .dnxhd: .dnxhd
        }
    }

    private static func proxyProfileID(_ codec: ProxyCodec) -> ApplicationVideoProfileID {
        switch codec {
        case .hevc: .hevcMain10
        case .prores: .proResProxy
        case .dnxhd: .dnxhrLB
        }
    }

    private static func audioContainerID(_ format: AudioOnlyFormat) -> ApplicationContainerID {
        switch format {
        case .wav: .wav
        case .aac: .m4a
        case .mp4: .mp4
        case .flac: .flac
        }
    }

    private static func audioOnlySettings(_ settings: AudioOnlySettings) -> ApplicationAudioSettings {
        switch settings.format {
        case .wav:
            let codec: ApplicationAudioCodecID = switch settings.bitDepth {
            case .pcm16: .pcm16
            case .pcm24: .pcm24
            case .pcm32: .pcm32
            }
            return ApplicationAudioSettings(codecID: codec, bitrate: nil)
        case .aac:
            return ApplicationAudioSettings(codecID: .aac, bitrate: settings.aacBitrate.ffmpegValue)
        case .mp4:
            let codec: ApplicationAudioCodecID = switch settings.mp4Codec {
            case .aac: .aac
            case .pcm16: .pcm16
            case .pcm24: .pcm24
            case .pcm32: .pcm32
            }
            return ApplicationAudioSettings(
                codecID: codec,
                bitrate: settings.mp4Codec.requiresBitrate ? settings.mp4Bitrate.ffmpegValue : nil
            )
        case .flac:
            return ApplicationAudioSettings(codecID: .flac, bitrate: nil)
        }
    }

    private static func streamCopyContainerID(_ container: StreamCopyContainer) -> ApplicationContainerID {
        switch container {
        case .keepCurrent: .source
        case .mov: .mov
        case .mp4: .mp4
        case .mkv: .mkv
        }
    }
}

struct ApplicationJobID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = UUID(uuidString: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a UUID job identifier."
            )
        }
        self.init(value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString.lowercased())
    }

    var description: String { rawValue.uuidString.lowercased() }
}

/// A transport-neutral request accepted by the shared application job boundary.
/// More conversion overrides will be added only after the feasibility matrix has
/// established which settings can be represented and validated reliably.
struct ApplicationConversionRequest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let requestID: UUID
    let origin: ApplicationJobOrigin
    let requesterID: String
    let sourceURLs: [URL]
    let destinationFolderURL: URL
    let presetID: ApplicationPresetID
    let presetSettings: ApplicationPresetSettings
    let idempotencyKey: String?
    let capturedAt: Date

    init(
        schemaVersion: Int = currentSchemaVersion,
        requestID: UUID = UUID(),
        origin: ApplicationJobOrigin,
        requesterID: String,
        sourceURLs: [URL],
        destinationFolderURL: URL,
        presetID: ApplicationPresetID,
        presetSettings: ApplicationPresetSettings? = nil,
        idempotencyKey: String? = nil,
        capturedAt: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.origin = origin
        self.requesterID = requesterID
        self.sourceURLs = sourceURLs
        self.destinationFolderURL = destinationFolderURL
        self.presetID = presetID
        self.presetSettings = presetSettings
            ?? ApplicationPresetSettings(presetID: presetID, defaults: defaults)
        self.idempotencyKey = idempotencyKey
        self.capturedAt = capturedAt
    }

    fileprivate func hasSamePayload(as other: Self) -> Bool {
        schemaVersion == other.schemaVersion
            && origin == other.origin
            && requesterID == other.requesterID
            && sourceURLs == other.sourceURLs
            && destinationFolderURL == other.destinationFolderURL
            && presetID == other.presetID
            && presetSettings == other.presetSettings
    }
}

enum ApplicationJobState: String, CaseIterable, Codable, Sendable {
    case queued
    case running
    case cancelling
    case succeeded
    case failed
    case cancelled
    case interrupted

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled, .interrupted: true
        case .queued, .running, .cancelling: false
        }
    }
}

struct ApplicationJobRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: ApplicationJobID
    let request: ApplicationConversionRequest
    let createdAt: Date
    var updatedAt: Date
    var state: ApplicationJobState
    var stage: String?
    var progress: Double?
    var outputURLs: [URL]
    var diagnostic: String?
}

struct ApplicationJobAcceptance: Equatable, Sendable {
    let record: ApplicationJobRecord
    let wasAlreadyAccepted: Bool
}

enum ApplicationJobError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidRequesterID
    case noSources
    case duplicateSource(URL)
    case nonFileURL(URL)
    case invalidIdempotencyKey
    case presetSettingsMismatch
    case idempotencyConflict
    case unknownJob(ApplicationJobID)
    case invalidTransition(from: ApplicationJobState, to: ApplicationJobState)
    case invalidProgress(Double)
    case unknownPlan(ApplicationPlanID)
    case expiredPlan(ApplicationPlanID)
    case sourceUnavailable(URL)
    case sourceChanged(URL)
    case unsupportedSourceExtension(URL)
    case duplicateOutput(URL)
    case outputCollision(URL)

    var code: ApplicationJobErrorCode {
        switch self {
        case .unsupportedSchema: .unsupportedSchema
        case .invalidRequesterID: .invalidRequesterID
        case .noSources: .noSources
        case .duplicateSource: .duplicateSource
        case .nonFileURL: .nonFileURL
        case .invalidIdempotencyKey: .invalidIdempotencyKey
        case .presetSettingsMismatch: .presetSettingsMismatch
        case .idempotencyConflict: .idempotencyConflict
        case .unknownJob: .unknownJob
        case .invalidTransition: .invalidTransition
        case .invalidProgress: .invalidProgress
        case .unknownPlan: .unknownPlan
        case .expiredPlan: .expiredPlan
        case .sourceUnavailable: .sourceUnavailable
        case .sourceChanged: .sourceChanged
        case .unsupportedSourceExtension: .unsupportedSourceExtension
        case .duplicateOutput: .duplicateOutput
        case .outputCollision: .outputCollision
        }
    }
}

/// Stable machine-readable error identifiers. Human-readable and localized
/// recovery text belongs at the UI or protocol adapter layer.
enum ApplicationJobErrorCode: String, Codable, Sendable {
    case unsupportedSchema = "unsupported_schema"
    case invalidRequesterID = "invalid_requester_id"
    case noSources = "no_sources"
    case duplicateSource = "duplicate_source"
    case nonFileURL = "non_file_url"
    case invalidIdempotencyKey = "invalid_idempotency_key"
    case presetSettingsMismatch = "preset_settings_mismatch"
    case idempotencyConflict = "idempotency_conflict"
    case unknownJob = "unknown_job"
    case invalidTransition = "invalid_transition"
    case invalidProgress = "invalid_progress"
    case unknownPlan = "unknown_plan"
    case expiredPlan = "expired_plan"
    case sourceUnavailable = "source_unavailable"
    case sourceChanged = "source_changed"
    case unsupportedSourceExtension = "unsupported_source_extension"
    case duplicateOutput = "duplicate_output"
    case outputCollision = "output_collision"
}

/// Owns stable identities and lifecycle state before work is attached to a view.
/// Persistence and conversion execution are deliberately separate follow-up
/// layers; the registry can therefore be tested without starting helper tools.
actor ApplicationJobRegistry {
    private struct IdempotencyIdentity: Hashable, Sendable {
        let requesterID: String
        let key: String
    }

    private struct AcceptedRequest: Sendable {
        let jobID: ApplicationJobID
        let request: ApplicationConversionRequest
    }

    private var records: [ApplicationJobID: ApplicationJobRecord] = [:]
    private var orderedIDs: [ApplicationJobID] = []
    private var acceptedRequests: [IdempotencyIdentity: AcceptedRequest] = [:]

    func accept(
        _ request: ApplicationConversionRequest,
        now: Date = Date()
    ) throws -> ApplicationJobAcceptance {
        try Self.validate(request)

        if let record = try acceptedRecord(for: request) {
            return ApplicationJobAcceptance(record: record, wasAlreadyAccepted: true)
        }

        let jobID = ApplicationJobID()
        let record = ApplicationJobRecord(
            schemaVersion: ApplicationConversionRequest.currentSchemaVersion,
            id: jobID,
            request: request,
            createdAt: now,
            updatedAt: now,
            state: .queued,
            stage: nil,
            progress: nil,
            outputURLs: [],
            diagnostic: nil
        )
        records[jobID] = record
        orderedIDs.append(jobID)
        if let key = request.idempotencyKey {
            acceptedRequests[IdempotencyIdentity(requesterID: request.requesterID, key: key)] =
                AcceptedRequest(jobID: jobID, request: request)
        }
        return ApplicationJobAcceptance(record: record, wasAlreadyAccepted: false)
    }

    func acceptedRecord(for request: ApplicationConversionRequest) throws -> ApplicationJobRecord? {
        try Self.validate(request)
        guard let key = request.idempotencyKey else { return nil }
        let identity = IdempotencyIdentity(requesterID: request.requesterID, key: key)
        guard let accepted = acceptedRequests[identity] else { return nil }
        guard accepted.request.hasSamePayload(as: request) else {
            throw ApplicationJobError.idempotencyConflict
        }
        guard let record = records[accepted.jobID] else {
            preconditionFailure("An idempotency record must reference an accepted job.")
        }
        return record
    }

    func record(for jobID: ApplicationJobID) -> ApplicationJobRecord? {
        records[jobID]
    }

    func allRecords() -> [ApplicationJobRecord] {
        orderedIDs.compactMap { records[$0] }
    }

    @discardableResult
    func transition(
        _ jobID: ApplicationJobID,
        to newState: ApplicationJobState,
        outputURLs: [URL] = [],
        diagnostic: String? = nil,
        now: Date = Date()
    ) throws -> ApplicationJobRecord {
        guard var record = records[jobID] else {
            throw ApplicationJobError.unknownJob(jobID)
        }
        guard Self.canTransition(from: record.state, to: newState) else {
            throw ApplicationJobError.invalidTransition(from: record.state, to: newState)
        }
        record.state = newState
        record.updatedAt = now
        record.outputURLs = outputURLs
        record.diagnostic = diagnostic
        if newState == .succeeded { record.progress = 1 }
        records[jobID] = record
        return record
    }

    /// Queued jobs have no helper to drain, so cancellation is immediately
    /// terminal. Running jobs first become cancelling and remain observable there
    /// until their execution owner confirms that helpers have drained.
    @discardableResult
    func requestCancellation(
        _ jobID: ApplicationJobID,
        now: Date = Date()
    ) throws -> ApplicationJobRecord {
        guard let record = records[jobID] else {
            throw ApplicationJobError.unknownJob(jobID)
        }
        switch record.state {
        case .queued:
            return try transition(jobID, to: .cancelled, now: now)
        case .running:
            return try transition(jobID, to: .cancelling, now: now)
        case .cancelling:
            return record
        case .succeeded, .failed, .cancelled, .interrupted:
            throw ApplicationJobError.invalidTransition(from: record.state, to: .cancelling)
        }
    }

    @discardableResult
    func updateProgress(
        _ jobID: ApplicationJobID,
        progress: Double?,
        stage: String?,
        now: Date = Date()
    ) throws -> ApplicationJobRecord {
        if let progress, !(0...1).contains(progress) {
            throw ApplicationJobError.invalidProgress(progress)
        }
        guard var record = records[jobID] else {
            throw ApplicationJobError.unknownJob(jobID)
        }
        guard record.state == .running || record.state == .cancelling else {
            throw ApplicationJobError.invalidTransition(from: record.state, to: record.state)
        }
        record.progress = progress
        record.stage = stage
        record.updatedAt = now
        records[jobID] = record
        return record
    }

    /// Called after restoring persisted records. Incomplete work is made terminal
    /// and visible instead of being restarted without user intent.
    @discardableResult
    func interruptInFlightJobs(
        diagnostic: String,
        now: Date = Date()
    ) -> [ApplicationJobRecord] {
        var interrupted: [ApplicationJobRecord] = []
        for jobID in orderedIDs {
            guard var record = records[jobID], !record.state.isTerminal else { continue }
            record.state = .interrupted
            record.updatedAt = now
            record.diagnostic = diagnostic
            records[jobID] = record
            interrupted.append(record)
        }
        return interrupted
    }

    static func validate(_ request: ApplicationConversionRequest) throws {
        guard request.schemaVersion == ApplicationConversionRequest.currentSchemaVersion else {
            throw ApplicationJobError.unsupportedSchema(request.schemaVersion)
        }
        let requesterID = request.requesterID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedRequesterCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard requesterID == request.requesterID,
              !requesterID.isEmpty,
              requesterID.count <= 64,
              requesterID.unicodeScalars.allSatisfy(allowedRequesterCharacters.contains) else {
            throw ApplicationJobError.invalidRequesterID
        }
        guard !request.sourceURLs.isEmpty else { throw ApplicationJobError.noSources }
        var sources = Set<URL>()
        for sourceURL in request.sourceURLs {
            guard sourceURL.isFileURL else { throw ApplicationJobError.nonFileURL(sourceURL) }
            guard sources.insert(sourceURL.standardizedFileURL).inserted else {
                throw ApplicationJobError.duplicateSource(sourceURL)
            }
        }
        guard request.destinationFolderURL.isFileURL else {
            throw ApplicationJobError.nonFileURL(request.destinationFolderURL)
        }
        guard request.presetID == request.presetSettings.presetID else {
            throw ApplicationJobError.presetSettingsMismatch
        }
        if let key = request.idempotencyKey {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == trimmed,
                  !key.isEmpty,
                  key.count <= 128,
                  key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw ApplicationJobError.invalidIdempotencyKey
            }
        }
    }

    private static func canTransition(
        from current: ApplicationJobState,
        to next: ApplicationJobState
    ) -> Bool {
        switch (current, next) {
        case (.queued, .running), (.queued, .cancelled), (.queued, .failed), (.queued, .interrupted),
             (.running, .cancelling), (.running, .succeeded), (.running, .failed),
             (.running, .cancelled), (.running, .interrupted),
             (.cancelling, .cancelled), (.cancelling, .failed), (.cancelling, .interrupted):
            true
        default:
            false
        }
    }
}

struct ApplicationPlanID: Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = UUID(uuidString: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a UUID plan identifier."
            )
        }
        self.init(value)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString.lowercased())
    }

    var description: String { rawValue.uuidString.lowercased() }
}

struct ApplicationSourceIdentity: Codable, Equatable, Sendable {
    let url: URL
    let fileSize: Int64
    let modificationDate: Date?
    let fileIdentifier: String?
}

struct ApplicationPlannedOutput: Codable, Equatable, Sendable {
    let sourceURL: URL
    let outputURL: URL
}

enum ApplicationPlanWarningCode: String, Codable, Sendable {
    case outputAlreadyExists = "output_already_exists"
}

struct ApplicationPlanWarning: Codable, Equatable, Sendable {
    let code: ApplicationPlanWarningCode
    let url: URL
}

struct ApplicationConversionPlan: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let id: ApplicationPlanID
    let request: ApplicationConversionRequest
    let createdAt: Date
    let expiresAt: Date
    let sources: [ApplicationSourceIdentity]
    let outputs: [ApplicationPlannedOutput]
    let warnings: [ApplicationPlanWarning]
}

/// Owns transport-neutral plans, submit-time validation, output reservations, and
/// job lifecycle state. Conversion execution remains a separate adapter so this
/// boundary can be exercised without SwiftUI bindings or helper processes.
actor ApplicationJobService {
    typealias SourceIdentityProvider = @Sendable (URL) throws -> ApplicationSourceIdentity
    typealias ItemExistsProvider = @Sendable (URL) -> Bool

    static let shared = ApplicationJobService()

    private let registry: ApplicationJobRegistry
    private let sourceIdentityProvider: SourceIdentityProvider
    private let itemExists: ItemExistsProvider
    private let planLifetime: TimeInterval
    private var plans: [ApplicationPlanID: ApplicationConversionPlan] = [:]
    private var submittedPlans: [ApplicationPlanID: ApplicationJobAcceptance] = [:]
    private var reservedOutputs: [URL: ApplicationJobID] = [:]
    private var outputsByJob: [ApplicationJobID: Set<URL>] = [:]

    init(
        registry: ApplicationJobRegistry = ApplicationJobRegistry(),
        planLifetime: TimeInterval = 15 * 60,
        sourceIdentityProvider: SourceIdentityProvider? = nil,
        itemExists: @escaping ItemExistsProvider = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.registry = registry
        self.planLifetime = planLifetime
        self.sourceIdentityProvider = sourceIdentityProvider ?? Self.liveSourceIdentity
        self.itemExists = itemExists
    }

    func plan(
        _ request: ApplicationConversionRequest,
        now: Date = Date()
    ) throws -> ApplicationConversionPlan {
        try ApplicationJobRegistry.validate(request)
        let sources = try request.sourceURLs.map { try sourceIdentityProvider($0.standardizedFileURL) }
        let outputs = try Self.plannedOutputs(for: request)

        var uniqueOutputs = Set<URL>()
        for output in outputs {
            let normalized = output.outputURL.standardizedFileURL
            guard uniqueOutputs.insert(normalized).inserted else {
                throw ApplicationJobError.duplicateOutput(output.outputURL)
            }
        }

        let warnings = outputs.compactMap { output in
            itemExists(output.outputURL)
                ? ApplicationPlanWarning(code: .outputAlreadyExists, url: output.outputURL)
                : nil
        }
        let plan = ApplicationConversionPlan(
            schemaVersion: ApplicationConversionPlan.currentSchemaVersion,
            id: ApplicationPlanID(),
            request: request,
            createdAt: now,
            expiresAt: now.addingTimeInterval(planLifetime),
            sources: sources,
            outputs: outputs,
            warnings: warnings
        )
        plans[plan.id] = plan
        return plan
    }

    /// Rechecks source identity and output ownership immediately before accepting
    /// work. Retrying a plan that was already submitted returns its original job.
    func submit(
        planID: ApplicationPlanID,
        now: Date = Date()
    ) async throws -> ApplicationJobAcceptance {
        if let accepted = submittedPlans[planID] {
            let currentRecord = await registry.record(for: accepted.record.id) ?? accepted.record
            return ApplicationJobAcceptance(record: currentRecord, wasAlreadyAccepted: true)
        }
        guard let plan = plans[planID] else {
            throw ApplicationJobError.unknownPlan(planID)
        }
        if let record = try await registry.acceptedRecord(for: plan.request) {
            let accepted = ApplicationJobAcceptance(record: record, wasAlreadyAccepted: true)
            submittedPlans[planID] = accepted
            return accepted
        }
        guard now <= plan.expiresAt else {
            throw ApplicationJobError.expiredPlan(planID)
        }

        for captured in plan.sources {
            let current: ApplicationSourceIdentity
            do {
                current = try sourceIdentityProvider(captured.url)
            } catch {
                throw ApplicationJobError.sourceUnavailable(captured.url)
            }
            guard current == captured else {
                throw ApplicationJobError.sourceChanged(captured.url)
            }
        }

        for output in plan.outputs {
            let normalized = output.outputURL.standardizedFileURL
            guard !itemExists(output.outputURL), reservedOutputs[normalized] == nil else {
                throw ApplicationJobError.outputCollision(output.outputURL)
            }
        }

        let accepted = try await registry.accept(plan.request, now: now)
        let normalizedOutputs = Set(plan.outputs.map { $0.outputURL.standardizedFileURL })
        for output in normalizedOutputs {
            reservedOutputs[output] = accepted.record.id
        }
        outputsByJob[accepted.record.id, default: []].formUnion(normalizedOutputs)
        submittedPlans[planID] = accepted
        return accepted
    }

    func plan(for planID: ApplicationPlanID) -> ApplicationConversionPlan? {
        plans[planID]
    }

    func record(for jobID: ApplicationJobID) async -> ApplicationJobRecord? {
        await registry.record(for: jobID)
    }

    func allRecords() async -> [ApplicationJobRecord] {
        await registry.allRecords()
    }

    @discardableResult
    func transition(
        _ jobID: ApplicationJobID,
        to state: ApplicationJobState,
        outputURLs: [URL] = [],
        diagnostic: String? = nil,
        now: Date = Date()
    ) async throws -> ApplicationJobRecord {
        let record = try await registry.transition(
            jobID, to: state, outputURLs: outputURLs, diagnostic: diagnostic, now: now
        )
        if state.isTerminal {
            releaseOutputReservations(for: jobID)
        }
        return record
    }

    @discardableResult
    func requestCancellation(
        _ jobID: ApplicationJobID,
        now: Date = Date()
    ) async throws -> ApplicationJobRecord {
        let record = try await registry.requestCancellation(jobID, now: now)
        if record.state.isTerminal {
            releaseOutputReservations(for: jobID)
        }
        return record
    }

    @discardableResult
    func updateProgress(
        _ jobID: ApplicationJobID,
        progress: Double?,
        stage: String?,
        now: Date = Date()
    ) async throws -> ApplicationJobRecord {
        try await registry.updateProgress(jobID, progress: progress, stage: stage, now: now)
    }

    @discardableResult
    func interruptInFlightJobs(
        diagnostic: String,
        now: Date = Date()
    ) async -> [ApplicationJobRecord] {
        let interrupted = await registry.interruptInFlightJobs(diagnostic: diagnostic, now: now)
        for record in interrupted {
            releaseOutputReservations(for: record.id)
        }
        return interrupted
    }

    private func releaseOutputReservations(for jobID: ApplicationJobID) {
        guard let outputs = outputsByJob.removeValue(forKey: jobID) else { return }
        for output in outputs where reservedOutputs[output] == jobID {
            reservedOutputs.removeValue(forKey: output)
        }
    }

    private static func plannedOutputs(
        for request: ApplicationConversionRequest
    ) throws -> [ApplicationPlannedOutput] {
        let naming = request.presetSettings.fileName
        let preferences = naming.fileNamePreferences
        let context = FileNameTemplateContext(
            presetSuffix: naming.presetSuffix,
            resolution: request.presetSettings.video?.maximumHeight.map { "\($0)p" } ?? "",
            framerate: ""
        )

        return try request.sourceURLs.enumerated().map { index, sourceURL in
            let counterResult = naming.counterStart.addingReportingOverflow(index)
            let counter = counterResult.overflow ? Int.max : counterResult.partialValue
            let baseName = FileNameProcessor.outputBaseName(
                inputURL: sourceURL,
                counter: counter,
                preset: request.presetID.exportPreset,
                settings: preferences,
                context: context,
                date: request.capturedAt
            )
            let fileExtension = try outputExtension(
                for: request.presetSettings.containerID,
                sourceURL: sourceURL
            )
            let fileName = fileExtension.isEmpty ? baseName : "\(baseName).\(fileExtension)"
            return ApplicationPlannedOutput(
                sourceURL: sourceURL,
                outputURL: request.destinationFolderURL.appendingPathComponent(fileName)
            )
        }
    }

    private static func outputExtension(
        for containerID: ApplicationContainerID,
        sourceURL: URL
    ) throws -> String {
        guard containerID == .source else { return containerID.rawValue }
        let sourceExtension = sourceURL.pathExtension.lowercased()
        guard !sourceExtension.isEmpty else {
            throw ApplicationJobError.unsupportedSourceExtension(sourceURL)
        }
        return sourceExtension
    }

    private static func liveSourceIdentity(for url: URL) throws -> ApplicationSourceIdentity {
        do {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
                .fileResourceIdentifierKey
            ])
            guard values.isRegularFile == true, let fileSize = values.fileSize else {
                throw ApplicationJobError.sourceUnavailable(url)
            }
            return ApplicationSourceIdentity(
                url: url.standardizedFileURL,
                fileSize: Int64(fileSize),
                modificationDate: values.contentModificationDate,
                fileIdentifier: values.fileResourceIdentifier.map { String(describing: $0) }
            )
        } catch let error as ApplicationJobError {
            throw error
        } catch {
            throw ApplicationJobError.sourceUnavailable(url)
        }
    }
}
