// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreML
import CryptoKit
import Foundation
import OSLog

/// How an aligner's weights are stored. 8-bit weights halve the download and
/// place words within 20 ms of the float16 originals.
enum WordAlignerPrecision: String, CaseIterable, Sendable {
    case int8
    case float16

    /// Appended to the aligner's id to name its archive.
    var archiveSuffix: String {
        switch self {
        case .int8: return ""
        case .float16: return "-float16"
        }
    }
}

struct WordAlignerArchive: Hashable, Sendable {
    let sha256: String
    let bytes: Int64
}

/// A downloadable word aligner: a wav2vec2 CTC model for one language,
/// converted to Core ML by `scripts/convert-wav2vec2-coreml.py`.
struct WordAlignerModel: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    /// Whisper language codes the model aligns.
    let languages: [String]
    let sourceRepository: String
    let license: String
    /// Published archives; a precision without one cannot be downloaded.
    let archives: [WordAlignerPrecision: WordAlignerArchive]

    func downloadURL(_ precision: WordAlignerPrecision) -> URL {
        AppConstants.wordAlignerDownloadBaseURL.appendingPathComponent("\(id)\(precision.archiveSuffix).zip")
    }

    /// The precision of a published archive with this checksum.
    func precision(ofArchiveSHA256 sha256: String) -> WordAlignerPrecision? {
        archives.first { $0.value.sha256 == sha256 }?.key
    }

    var sourceURL: URL { URL(string: "https://huggingface.co/\(sourceRepository)")! }

    static let allModels: [WordAlignerModel] = [
        WordAlignerModel(
            id: "nb-bokmaal-300m",
            displayName: "Norwegian Bokmål (NbAiLab wav2vec2 300M)",
            languages: ["no", "nb"],
            sourceRepository: "NbAiLab/nb-wav2vec2-300m-bokmaal-v2",
            license: "Apache-2.0",
            archives: [
                .int8: WordAlignerArchive(
                    sha256: "cccc3c1e0e5a108248980362a38bd0032ea56bc83e809750be96e65258029c68", bytes: 271_942_807),
                .float16: WordAlignerArchive(
                    sha256: "0c4e1ffb1669d65f7e931804a8a35a3208ea7f188910f4081c3fd37a4026d962", bytes: 584_328_647),
            ]
        ),
        WordAlignerModel(
            id: "nn-nynorsk-300m",
            displayName: "Norwegian Nynorsk (NbAiLab wav2vec2 300M)",
            languages: ["nn"],
            sourceRepository: "NbAiLab/nb-wav2vec2-300m-nynorsk",
            license: "Apache-2.0",
            archives: [
                .int8: WordAlignerArchive(
                    sha256: "21e540c8364569989fd2b550b3176c83a89528833f4916888f668872ddbebd34", bytes: 271_234_759),
                .float16: WordAlignerArchive(
                    sha256: "c2eb5171009a499729f08af38d51b8332bfb250e6256223f4fd8e4be5ac5afb9", bytes: 584_434_843),
            ]
        ),
        WordAlignerModel(
            id: "sv-voxrex-large",
            displayName: "Swedish (KBLab VoxRex wav2vec2)",
            languages: ["sv"],
            sourceRepository: "KBLab/wav2vec2-large-voxrex-swedish",
            license: "CC0-1.0",
            archives: [
                .int8: WordAlignerArchive(
                    sha256: "62c9bb3a1f8991c08538990644bf249143eb8b5ea306d3b7008fad456250495d", bytes: 271_284_155),
                .float16: WordAlignerArchive(
                    sha256: "636fe7f3fc57cefbb8e585d29e40796c2c85842246df855cf28870e4eac74a25", bytes: 584_398_895),
            ]
        ),
        WordAlignerModel(
            id: "en-base-960h",
            displayName: "English (wav2vec2 base 960h)",
            languages: ["en"],
            sourceRepository: "facebook/wav2vec2-base-960h",
            license: "Apache-2.0",
            archives: [
                .int8: WordAlignerArchive(
                    sha256: "505604db5921b0cd12ce650a00c74358dd97bd6928b067c52778e47ede857e4e", bytes: 80_572_858),
                .float16: WordAlignerArchive(
                    sha256: "abc050fa89f6e1555872d0ee13b13e5d412839921087bb619375465d3c68500d", bytes: 175_081_458),
            ]
        ),
        WordAlignerModel(
            id: "de-xlsr53-large",
            displayName: "German (wav2vec2 XLSR-53 large)",
            languages: ["de"],
            sourceRepository: "jonatasgrosman/wav2vec2-large-xlsr-53-german",
            license: "Apache-2.0",
            archives: [
                .int8: WordAlignerArchive(
                    sha256: "f56dbdeff0786b8e53034284aa87ad7e0c4d336bda27dee926d97c880bb2bd34", bytes: 273_723_848),
                .float16: WordAlignerArchive(
                    sha256: "45e53b7bacc33f57d0a2979c93e1e20a57d2faa57083eb94484dece610e95f80", bytes: 583_437_774),
            ]
        ),
        WordAlignerModel(
            id: "es-xlsr53-large",
            displayName: "Spanish (wav2vec2 XLSR-53 large)",
            languages: ["es"],
            sourceRepository: "jonatasgrosman/wav2vec2-large-xlsr-53-spanish",
            license: "Apache-2.0",
            archives: [
                .int8: WordAlignerArchive(
                    sha256: "493ca98c9ba59ea5440eb652f77fb5131aaa16ed7b33257cb6fdb5e015a4c8ac", bytes: 273_736_022),
                .float16: WordAlignerArchive(
                    sha256: "d25ee3e1bbd539e636e7997da4ad8db2db8c264e12627a8330acc718f60e9bec", bytes: 583_433_890),
            ]
        ),
        WordAlignerModel(
            id: "fr-xlsr53-large",
            displayName: "French (wav2vec2 XLSR-53 large)",
            languages: ["fr"],
            sourceRepository: "jonatasgrosman/wav2vec2-large-xlsr-53-french",
            license: "Apache-2.0",
            archives: [
                .int8: WordAlignerArchive(
                    sha256: "bdbb9c69815ae1489d62349ba34affc2552c655e9bc06d673eff2896141a57f8", bytes: 273_763_357),
                .float16: WordAlignerArchive(
                    sha256: "65509c12ab23bc73e33c9594a9e7c9ed06238a4af4edc66d060cf3581a28cd9a", bytes: 583_468_606),
            ]
        ),
        WordAlignerModel(
            id: "it-xlsr53-large",
            displayName: "Italian (wav2vec2 XLSR-53 large)",
            languages: ["it"],
            sourceRepository: "jonatasgrosman/wav2vec2-large-xlsr-53-italian",
            license: "Apache-2.0",
            archives: [
                .int8: WordAlignerArchive(
                    sha256: "2925d35b3dabaca0ad3fc4a3ab8b7e579242624d63368cc0a3aa9ebf969e6dac", bytes: 273_755_073),
                .float16: WordAlignerArchive(
                    sha256: "e89a02b40580abb6502aa4ac8feb272f91302976f3b5095c2b453d54ec685345", bytes: 583_448_222),
            ]
        ),
        WordAlignerModel(
            id: "pt-xlsr53-large",
            displayName: "Portuguese (wav2vec2 XLSR-53 large)",
            languages: ["pt"],
            sourceRepository: "jonatasgrosman/wav2vec2-large-xlsr-53-portuguese",
            license: "Apache-2.0",
            archives: [
                .int8: WordAlignerArchive(
                    sha256: "5dae55a5df9fe0ba703721fafa86ee1e6b19cca3b258b534428238d6b81b0275", bytes: 273_510_538),
                .float16: WordAlignerArchive(
                    sha256: "5a461efe607695605e70e6633fdb05c63cfbf550f21a8aa1676ff5150c336a3b", bytes: 583_451_586),
            ]
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

    /// Records which archive an installed aligner came from.
    nonisolated static let precisionFileName = "precision"

    nonisolated func isInstalled(_ model: WordAlignerModel) -> Bool {
        let directory = directory(for: model)
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(Wav2Vec2WordAligner.manifestFileName).path
        ) && FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(Wav2Vec2WordAligner.modelFileName).path
        )
    }

    /// The precision of an installed aligner; nil when it is not installed or
    /// came from an archive the app does not know.
    nonisolated func installedPrecision(_ model: WordAlignerModel) -> WordAlignerPrecision? {
        guard isInstalled(model),
              let raw = try? String(
                  contentsOf: directory(for: model).appendingPathComponent(Self.precisionFileName), encoding: .utf8
              ) else { return nil }
        return WordAlignerPrecision(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The installed aligner for a Whisper language code, if any.
    nonisolated func installedDirectory(forLanguage language: String) -> URL? {
        guard let model = WordAlignerModel.model(forLanguage: language), isInstalled(model) else { return nil }
        return directory(for: model)
    }

    /// Downloads and installs an aligner, replacing one of another precision.
    func download(
        _ model: WordAlignerModel, precision: WordAlignerPrecision, progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let published = model.archives[precision] else { throw WordAlignerModelError.unavailable }
        guard activeDownloads[model.id] == nil, installedPrecision(model) != precision else { return }
        let operation = operationFactory(model.downloadURL(precision), published.bytes)
        activeDownloads[model.id] = operation
        defer { activeDownloads.removeValue(forKey: model.id) }

        let archive = try await withTaskCancellationHandler {
            try await operation.run { progress($0 * 0.9) }
        } onCancel: {
            operation.cancel()
        }
        defer { try? FileManager.default.removeItem(at: archive) }
        guard try Self.sha256(of: archive) == published.sha256 else {
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
        let precision = model.precision(ofArchiveSHA256: try Self.sha256(of: archive))
        let compiled = try await MLModel.compileModel(at: package)
        defer { try? fileManager.removeItem(at: compiled) }

        let installing = staging.appendingPathComponent("install", isDirectory: true)
        try fileManager.createDirectory(at: installing, withIntermediateDirectories: true)
        try fileManager.moveItem(at: compiled, to: installing.appendingPathComponent(Wav2Vec2WordAligner.modelFileName))
        try fileManager.copyItem(at: manifestURL, to: installing.appendingPathComponent(Wav2Vec2WordAligner.manifestFileName))
        if let precision {
            try Data(precision.rawValue.utf8).write(to: installing.appendingPathComponent(Self.precisionFileName))
        }

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
