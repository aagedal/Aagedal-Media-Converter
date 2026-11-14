// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreML
import CryptoKit
import Foundation
import OSLog

/// A downloadable word aligner: a wav2vec2 CTC model for one language,
/// converted to Core ML by `scripts/convert-wav2vec2-coreml.py`.
struct WordAlignerModel: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    /// Whisper language codes the model aligns.
    let languages: [String]
    let sourceRepository: String
    let license: String
    let archiveSHA256: String
    let archiveBytes: Int64

    var downloadURL: URL {
        AppConstants.wordAlignerDownloadBaseURL.appendingPathComponent("\(id).zip")
    }

    var sourceURL: URL { URL(string: "https://huggingface.co/\(sourceRepository)")! }

    static let allModels: [WordAlignerModel] = [
        WordAlignerModel(
            id: "nb-bokmaal-300m",
            displayName: "Norwegian Bokmål (NbAiLab wav2vec2 300M)",
            languages: ["no", "nb"],
            sourceRepository: "NbAiLab/nb-wav2vec2-300m-bokmaal-v2",
            license: "Apache-2.0",
            archiveSHA256: "0c4e1ffb1669d65f7e931804a8a35a3208ea7f188910f4081c3fd37a4026d962",
            archiveBytes: 584_328_647
        ),
        WordAlignerModel(
            id: "nn-nynorsk-300m",
            displayName: "Norwegian Nynorsk (NbAiLab wav2vec2 300M)",
            languages: ["nn"],
            sourceRepository: "NbAiLab/nb-wav2vec2-300m-nynorsk",
            license: "Apache-2.0",
            archiveSHA256: "c2eb5171009a499729f08af38d51b8332bfb250e6256223f4fd8e4be5ac5afb9",
            archiveBytes: 584_434_843
        ),
        WordAlignerModel(
            id: "sv-voxrex-large",
            displayName: "Swedish (KBLab VoxRex wav2vec2)",
            languages: ["sv"],
            sourceRepository: "KBLab/wav2vec2-large-voxrex-swedish",
            license: "CC0-1.0",
            archiveSHA256: "636fe7f3fc57cefbb8e585d29e40796c2c85842246df855cf28870e4eac74a25",
            archiveBytes: 584_398_895
        ),
        WordAlignerModel(
            id: "en-base-960h",
            displayName: "English (wav2vec2 base 960h)",
            languages: ["en"],
            sourceRepository: "facebook/wav2vec2-base-960h",
            license: "Apache-2.0",
            archiveSHA256: "abc050fa89f6e1555872d0ee13b13e5d412839921087bb619375465d3c68500d",
            archiveBytes: 175_081_458
        ),
    ]

    static func model(forLanguage language: String) -> WordAlignerModel? {
        let code = TranscriptLanguage.normalized(language)
        return allModels.first { $0.languages.contains(code) }
    }
}

enum WordAlignerModelError: LocalizedError {
    case checksumMismatch
    case invalidArchive
    case unavailable
    case unknownModel

    var errorDescription: String? {
        switch self {
        case .checksumMismatch:
            return String(localized: "The downloaded aligner does not match its published checksum.")
        case .invalidArchive:
            return String(localized: "The aligner archive does not contain a Core ML model and manifest.")
        case .unavailable:
            return String(localized: "This aligner has not been published yet.")
        case .unknownModel:
            return String(localized: "This archive is not one of the app's word aligners.")
        }
    }
}

/// Installs aligners under Application Support. Each lives in its own folder
/// holding the compiled Core ML model and `aligner.json`.
actor WordAlignerModelManager {
    static let shared = WordAlignerModelManager()

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "WordAlignerModelManager")
    nonisolated let modelsDirectory: URL
    private let operationFactory: WhisperModelDownloadOperationFactory
    private var activeDownloads: [String: any WhisperModelDownloadOperation] = [:]

    init(
        modelsDirectory: URL = AppConstants.wordAlignerModelsDirectory,
        operationFactory: @escaping WhisperModelDownloadOperationFactory = { url, bytes in
            URLSessionWhisperModelDownloadOperation(sourceURL: url, expectedByteCount: bytes)
        }
    ) {
        self.modelsDirectory = modelsDirectory
        self.operationFactory = operationFactory
    }

    nonisolated func directory(for model: WordAlignerModel) -> URL {
        modelsDirectory.appendingPathComponent(model.id, isDirectory: true)
    }

    nonisolated func isInstalled(_ model: WordAlignerModel) -> Bool {
        let directory = directory(for: model)
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(Wav2Vec2WordAligner.manifestFileName).path
        ) && FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(Wav2Vec2WordAligner.modelFileName).path
        )
    }

    /// The installed aligner for a Whisper language code, if any.
    nonisolated func installedDirectory(forLanguage language: String) -> URL? {
        guard let model = WordAlignerModel.model(forLanguage: language), isInstalled(model) else { return nil }
        return directory(for: model)
    }

    func download(_ model: WordAlignerModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !model.archiveSHA256.isEmpty else { throw WordAlignerModelError.unavailable }
        guard activeDownloads[model.id] == nil, !isInstalled(model) else { return }
        let operation = operationFactory(model.downloadURL, model.archiveBytes)
        activeDownloads[model.id] = operation
        defer { activeDownloads.removeValue(forKey: model.id) }

        let archive = try await withTaskCancellationHandler {
            try await operation.run { progress($0 * 0.9) }
        } onCancel: {
            operation.cancel()
        }
        defer { try? FileManager.default.removeItem(at: archive) }
        guard try Self.sha256(of: archive) == model.archiveSHA256 else {
            throw WordAlignerModelError.checksumMismatch
        }
        let installedModel = try await install(archive: archive)
        guard installedModel == model else {
            try? delete(installedModel)
            throw WordAlignerModelError.unknownModel
        }
        progress(1)
    }

    func cancelDownload(_ model: WordAlignerModel) {
        activeDownloads.removeValue(forKey: model.id)?.cancel()
    }

    /// Installs a zip produced by the conversion script, compiling the Core ML
    /// package for this Mac. Also used to install an aligner from a local file;
    /// the manifest names which aligner it is.
    @discardableResult
    func install(archive: URL) async throws -> WordAlignerModel {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("aligner-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let unzip = try await SubprocessRunner().run(SubprocessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archive.path, staging.path],
            timeout: .seconds(10 * 60),
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 16 * 1024
        ))
        guard unzip.succeeded else { throw WordAlignerModelError.invalidArchive }

        guard let manifestURL = fileManager.enumerator(at: staging, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL })
            .first(where: { $0.lastPathComponent == Wav2Vec2WordAligner.manifestFileName }) else {
            throw WordAlignerModelError.invalidArchive
        }
        let folder = manifestURL.deletingLastPathComponent()
        let package = folder.appendingPathComponent("Wav2Vec2CTC.mlpackage")
        guard fileManager.fileExists(atPath: package.path),
              let manifest = try? JSONDecoder().decode(WordAlignerManifest.self, from: Data(contentsOf: manifestURL)) else {
            throw WordAlignerModelError.invalidArchive
        }
        guard let model = WordAlignerModel.allModels.first(where: { $0.id == manifest.id }) else {
            throw WordAlignerModelError.unknownModel
        }
        let compiled = try await MLModel.compileModel(at: package)
        defer { try? fileManager.removeItem(at: compiled) }

        let installing = staging.appendingPathComponent("install", isDirectory: true)
        try fileManager.createDirectory(at: installing, withIntermediateDirectories: true)
        try fileManager.moveItem(at: compiled, to: installing.appendingPathComponent(Wav2Vec2WordAligner.modelFileName))
        try fileManager.copyItem(at: manifestURL, to: installing.appendingPathComponent(Wav2Vec2WordAligner.manifestFileName))

        try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let destination = directory(for: model)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: installing, to: destination)
        logger.info("Installed word aligner \(model.id, privacy: .public)")
        return model
    }

    func delete(_ model: WordAlignerModel) throws {
        let destination = directory(for: model)
        guard FileManager.default.fileExists(atPath: destination.path) else { return }
        try FileManager.default.removeItem(at: destination)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
