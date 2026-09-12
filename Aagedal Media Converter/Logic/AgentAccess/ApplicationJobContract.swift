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
        idempotencyKey: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.origin = origin
        self.requesterID = requesterID
        self.sourceURLs = sourceURLs
        self.destinationFolderURL = destinationFolderURL
        self.presetID = presetID
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
    case idempotencyConflict
    case unknownJob(ApplicationJobID)
    case invalidTransition(from: ApplicationJobState, to: ApplicationJobState)
    case invalidProgress(Double)

    var code: ApplicationJobErrorCode {
        switch self {
        case .unsupportedSchema: .unsupportedSchema
        case .invalidRequesterID: .invalidRequesterID
        case .noSources: .noSources
        case .duplicateSource: .duplicateSource
        case .nonFileURL: .nonFileURL
        case .invalidIdempotencyKey: .invalidIdempotencyKey
        case .idempotencyConflict: .idempotencyConflict
        case .unknownJob: .unknownJob
        case .invalidTransition: .invalidTransition
        case .invalidProgress: .invalidProgress
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
    case idempotencyConflict = "idempotency_conflict"
    case unknownJob = "unknown_job"
    case invalidTransition = "invalid_transition"
    case invalidProgress = "invalid_progress"
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

        if let key = request.idempotencyKey {
            let identity = IdempotencyIdentity(requesterID: request.requesterID, key: key)
            if let accepted = acceptedRequests[identity] {
                guard accepted.request.hasSamePayload(as: request) else {
                    throw ApplicationJobError.idempotencyConflict
                }
                guard let record = records[accepted.jobID] else {
                    preconditionFailure("An idempotency record must reference an accepted job.")
                }
                return ApplicationJobAcceptance(record: record, wasAlreadyAccepted: true)
            }
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

    private static func validate(_ request: ApplicationConversionRequest) throws {
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
