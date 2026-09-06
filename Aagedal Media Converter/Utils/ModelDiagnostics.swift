// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct ModelDiagnostic: Identifiable, Sendable {
    let id: String
    let name: String
    let path: URL?
    let available: Bool

    var message: String {
        available
            ? String(localized: "Local model files are available. Model compatibility has not been tested.")
            : String(localized: "The selected model is missing, empty, or unreadable. Download or select it in Transcription settings.")
    }
}

/// Inspects local resources without loading a model, launching a helper, or downloading files.
enum ModelDiagnostics {
    static func fileIsAvailable(at url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else { return false }
        return FileManager.default.isReadableFile(atPath: resolved.path)
    }

    /// A cache marker alone is insufficient: its snapshot must contain readable
    /// configuration and weights. Read the small ref with a strict size bound.
    static func cacheIsAvailable(at url: URL) -> Bool {
        let ref = url.appendingPathComponent("refs/main")
        guard fileIsAvailable(at: ref),
              let handle = try? FileHandle(forReadingFrom: ref) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 257), data.count <= 256,
              let raw = String(data: data, encoding: .utf8) else { return false }
        let revision = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !revision.isEmpty, revision != ".", revision != "..",
              revision.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0) }) else { return false }
        let snapshot = url.appendingPathComponent("snapshots").appendingPathComponent(revision)
        return fileIsAvailable(at: snapshot.appendingPathComponent("config.json"))
            && fileIsAvailable(at: snapshot.appendingPathComponent("model.safetensors"))
    }

    static func selectedModels() -> [ModelDiagnostic] {
        let whisper = WhisperModelManager.shared
        let whisperModel = whisper.getSelectedModel()
        let whisperURL = whisperModel.isCustom ? whisper.customModelURL() : whisper.modelPath(for: whisperModel)
        var scoped = false
        if whisperModel.isCustom, let whisperURL {
            scoped = SecurityScopedBookmarkManager.shared.startAccessingSecurityScopedResource(for: whisperURL)
        }
        defer {
            if scoped, let whisperURL {
                SecurityScopedBookmarkManager.shared.stopAccessingSecurityScopedResource(for: whisperURL)
            }
        }
        let parakeet = ParakeetModelManager.shared
        let parakeetModel = parakeet.getSelectedModel()
        let parakeetURL = parakeet.modelCachePath(for: parakeetModel)
        return [
            ModelDiagnostic(id: "whisper-model", name: "Whisper — \(whisperModel.displayName)",
                            path: whisperURL, available: whisperURL.map(fileIsAvailable) ?? false),
            ModelDiagnostic(id: "parakeet-model", name: "Parakeet — \(parakeetModel.displayName)",
                            path: parakeetURL, available: cacheIsAvailable(at: parakeetURL))
        ]
    }
}
