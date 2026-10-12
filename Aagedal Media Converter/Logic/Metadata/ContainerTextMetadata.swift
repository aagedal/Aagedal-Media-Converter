// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation

/// Keeps text tags distinct where the main metadata parser combines them.
struct ContainerTextMetadata: Sendable, Equatable {
    var description: String?
    var comment: String?
    var sourceURL: String?
    var title: String?
    var artist: String?

    static func webURL(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains(where: { $0.isWhitespace }),
              let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false else { return nil }
        return value
    }

    mutating func apply(name: String, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch name.uppercased() {
        case "DESCRIPTION": description = description ?? value
        case "SYNOPSIS": break  // Used as a fallback after DESCRIPTION.
        case "COMMENT", "COMMENTS": comment = comment ?? trimmed
        case "PURL", "SOURCE_URL", "WEBPAGE_URL": sourceURL = sourceURL ?? Self.webURL(trimmed)
        case "TITLE": title = title ?? trimmed
        case "ARTIST", "AUTHOR": artist = artist ?? trimmed
        default: break
        }
    }

    static func read(from url: URL) async -> Self {
        if ["mkv", "webm"].contains(url.pathExtension.lowercased()) {
            return await Task.detached(priority: .utility) {
                (try? MatroskaTextTagReader.read(url)) ?? Self()
            }.value
        }
        guard ["mp4", "mov", "m4v", "m4a", "mp3", "flac", "ogg", "opus", "oga", "wav", "aiff", "aif"].contains(url.pathExtension.lowercased()) else { return Self() }
        let customKeys = await Task.detached(priority: .utility) {
            (try? QuickTimeTextTagKeys.read(url)) ?? [:]
        }.value
        let asset = AVURLAsset(url: url)
        var result = Self()
        var synopsis: String?
        var legacyDescription = false
        do {
            for format in try await asset.load(.availableMetadataFormats) {
                for item in try await asset.loadMetadata(for: format) {
                    guard let value = try? await item.load(.stringValue) else { continue }
                    let index = (item.key as? NSNumber)?.intValue
                    let key = ((item.key as? String) ?? index.flatMap { customKeys[$0] } ?? "").lowercased()
                    let identifier = item.identifier?.rawValue.lowercased() ?? ""
                    let commonKey = item.commonKey?.rawValue.lowercased()
                    if ["purl", "source_url", "webpage_url"].contains(key) || identifier.hasSuffix("/purl") {
                        result.apply(name: "PURL", value: value)
                    } else if ["comment", "comments", "©cmt"].contains(key) || identifier.hasSuffix("/comm") || identifier.hasSuffix("/%a9cmt") || identifier.hasSuffix("comment") || identifier.hasSuffix("comments") {
                        result.apply(name: "COMMENT", value: value)
                    } else if ["ldes", "synopsis"].contains(key) || identifier.hasSuffix("/ldes") || identifier.hasSuffix("synopsis") {
                        synopsis = synopsis ?? value
                    } else if ["description", "desc", "©des"].contains(key) || identifier.hasSuffix("/desc") || identifier.hasSuffix("/%a9des") || identifier.hasSuffix("description") {
                        result.apply(name: "DESCRIPTION", value: value)
                        legacyDescription = legacyDescription || identifier == "udta/%a9des"
                    } else if key == "title" || commonKey == "title" || identifier.hasSuffix("/%a9nam") {
                        result.apply(name: "TITLE", value: value)
                    } else if key == "artist" || commonKey == "artist" || identifier.hasSuffix("/%a9art") {
                        result.apply(name: "ARTIST", value: value)
                    }
                }
            }
        } catch { /* Supplementary tags must not prevent the primary probe. */ }
        result.description = result.description ?? synopsis
        // FFmpeg's legacy MOV mode mirrors comment into the ©des atom.
        if legacyDescription, result.description == result.comment { result.description = nil }
        result.sourceURL = result.sourceURL ?? Self.webURL(result.comment)
        return result
    }
}

/// AVFoundation exposes mdta values under numeric keys. Resolve those indices
/// from the bounded `keys` atom, without reading video/audio payloads.
private enum QuickTimeTextTagKeys {
    static func read(_ url: URL) throws -> [Int: String] {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        var remaining = 100_000

        func number(_ data: Data) -> UInt64 {
            data.reduce(0) { ($0 << 8) | UInt64($1) }
        }

        func walk(start: UInt64, end: UInt64, depth: Int) throws -> [Int: String] {
            guard depth < 5 else { return [:] }
            var offset = start
            while offset <= end, end - offset >= 8, remaining > 0 {
                remaining -= 1
                try file.seek(toOffset: offset)
                guard let header = try file.read(upToCount: 8), header.count == 8 else { return [:] }
                var size = number(header.prefix(4))
                let type = String(data: header.suffix(4), encoding: .ascii)
                var headerSize: UInt64 = 8
                if size == 1 {
                    guard let extended = try file.read(upToCount: 8), extended.count == 8 else { return [:] }
                    size = number(extended)
                    headerSize = 16
                } else if size == 0 { size = end - offset }
                guard size >= headerSize, size <= end - offset else { return [:] }
                let payload = offset + headerSize
                let atomEnd = offset + size
                if type == "keys", size - headerSize <= 4 * 1024 * 1024 {
                    guard let data = try file.read(upToCount: Int(size - headerSize)), data.count >= 8 else { return [:] }
                    let count = number(data[4..<8])
                    guard count <= 10_000 else { return [:] }
                    var position = 8
                    var keys: [Int: String] = [:]
                    for index in 0..<Int(count) {
                        guard data.count - position >= 8 else { return [:] }
                        let entrySize = number(data[position..<position + 4])
                        guard entrySize >= 8, entrySize <= UInt64(data.count - position) else { return [:] }
                        let entryEnd = position + Int(entrySize)
                        if String(data: data[position + 4..<position + 8], encoding: .ascii) == "mdta" {
                            keys[index + 1] = String(data: data[position + 8..<entryEnd], encoding: .utf8)
                        }
                        position = entryEnd
                    }
                    return keys
                }
                if ["moov", "udta", "meta"].contains(type ?? "") {
                    let childStart = payload + (type == "meta" ? 4 : 0)
                    if childStart <= atomEnd {
                        let keys = try walk(start: childStart, end: atomEnd, depth: depth + 1)
                        if !keys.isEmpty { return keys }
                    }
                }
                offset = atomEnd
            }
            return [:]
        }
        return try walk(start: 0, end: length, depth: 0)
    }
}

/// Seeks over media payloads and reads only bounded Segment-level text tags.
private enum MatroskaTextTagReader {
    private struct Element {
        let id: UInt64
        let start: UInt64
        let end: UInt64
    }

    static func read(_ url: URL) throws -> ContainerTextMetadata {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        var result = ContainerTextMetadata()
        var synopsis: String?
        var elementsLeft = 100_000
        var textBytesLeft: UInt64 = 8 * 1024 * 1024

        func integer(id: Bool) throws -> (UInt64, Bool)? {
            guard let first = try file.read(upToCount: 1)?.first, first != 0 else { return nil }
            let width = first.leadingZeroBitCount + 1
            guard width <= (id ? 4 : 8) else { return nil }
            var value = UInt64(id ? first : first & (0xff >> width))
            var unknown = !id && (first & (0xff >> width)) == (0xff >> width)
            for _ in 1..<width {
                guard let byte = try file.read(upToCount: 1)?.first else { return nil }
                value = (value << 8) | UInt64(byte)
                unknown = unknown && byte == 0xff
            }
            return (value, unknown)
        }

        func element(at offset: UInt64, end: UInt64) throws -> Element? {
            guard offset < end, elementsLeft > 0 else { return nil }
            elementsLeft -= 1
            try file.seek(toOffset: offset)
            guard let (id, _) = try integer(id: true),
                  let (size, unknown) = try integer(id: false) else { return nil }
            let start = try file.offset()
            guard start <= end, unknown || size <= end - start else { return nil }
            // Unknown-length media clusters cannot be skipped safely.
            guard !unknown || id == 0x18538067 else { return nil }
            return Element(id: id, start: start, end: unknown ? end : start + size)
        }

        func children(_ parent: Element) throws -> [Element] {
            var offset = parent.start
            var children: [Element] = []
            while let child = try element(at: offset, end: parent.end) {
                children.append(child)
                offset = child.end
            }
            return children
        }

        func text(_ element: Element) throws -> String? {
            let size = element.end - element.start
            guard size <= textBytesLeft else { return nil }
            textBytesLeft -= size
            try file.seek(toOffset: element.start)
            guard let data = try file.read(upToCount: Int(size)), data.count == Int(size) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        var offset: UInt64 = 0
        while let top = try element(at: offset, end: length) {
            offset = top.end
            guard top.id == 0x18538067 else { continue }
            for tags in try children(top) where tags.id == 0x1254C367 {
                for tag in try children(tags) where tag.id == 0x7373 {
                    let entries = try children(tag)
                    // Track/chapter/attachment/edition tags are not file-level metadata.
                    var targeted = false
                    for targets in entries where targets.id == 0x63C0 {
                        let targetIDs: Set<UInt64> = [0x63C5, 0x63C4, 0x63C6, 0x63C9]
                        let targetFields = try children(targets)
                        targeted = targeted || targetFields.contains { targetIDs.contains($0.id) }
                    }
                    guard !targeted else { continue }
                    for simple in entries where simple.id == 0x67C8 {
                        let fields = try children(simple)
                        guard let nameElement = fields.first(where: { $0.id == 0x45A3 }),
                              let valueElement = fields.first(where: { $0.id == 0x4487 }),
                              let name = try text(nameElement), let value = try text(valueElement) else { continue }
                        if name.uppercased() == "SYNOPSIS" { synopsis = synopsis ?? value }
                        result.apply(name: name, value: value)
                    }
                }
            }
        }
        result.description = result.description ?? synopsis
        result.sourceURL = result.sourceURL ?? ContainerTextMetadata.webURL(result.comment)
        return result
    }
}
