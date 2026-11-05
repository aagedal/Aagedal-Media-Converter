// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation
import OSLog

/// Panasonic P2 cards store each clip as separate OP-Atom MXF files: one for the
/// video (`CONTENTS/VIDEO/<clip>.MXF`) and one per audio channel
/// (`CONTENTS/AUDIO/<clip>00.MXF`, `01`, …), described by `CONTENTS/CLIP/<clip>.XML`.
/// ffmpeg can't open them as one source, so each shot is stream-copied into a
/// single Matroska file holding the video and every audio channel, and the queue
/// uses that file like any other. Shots split across several clips (spanned
/// recordings, even across cards) are joined in the same pass.
///
/// Matroska, because the MOV muxer drops the field order of H.264 (interlaced
/// AVC-Intra would then skip deinterlacing) and the MXF muxer rejects
/// AVC-Intra frame sizes on stream copy.
enum P2CardImporter {
    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "P2CardImporter")

    struct Clip: Sendable, Equatable {
        var name: String
        var globalClipID: String
        var videoURL: URL?
        var audioURLs: [URL]
        var startTimecode: String?
        var recordingDate: Date?
        /// Set when the clip is one part of a spanned shot.
        var shotID: String?
        var offsetInShot: Int
        /// The next part of a spanned shot, when the metadata names it.
        var nextClipID: String? = nil
    }

    struct Shot: Sendable, Equatable {
        /// Ordered by position in the shot.
        var clips: [Clip]

        var name: String { clips[0].name }

        /// Stable across imports, so a re-imported card reuses the rewrapped file.
        var cacheKey: String { "P2-\(clips[0].globalClipID)-\(clips.count)" }

        var sourceURLs: [URL] { clips.flatMap { ($0.videoURL.map { [$0] } ?? []) + $0.audioURLs } }

        /// Whether parts of a spanned recording are missing, such as a card that
        /// wasn't imported with the others. Its parts are still joined.
        var isMissingParts: Bool {
            guard clips[0].shotID != nil else { return false }
            if clips[0].offsetInShot != 0 { return true }
            for (clip, next) in zip(clips, clips.dropFirst()) {
                if let nextID = clip.nextClipID, nextID != next.globalClipID { return true }
            }
            return clips[clips.count - 1].nextClipID != nil
        }

        /// The card holding the first clip (essence files are at `CONTENTS/<kind>/<file>`).
        var cardRoot: URL? {
            (clips[0].videoURL ?? clips[0].audioURLs.first)?
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        }
    }

    enum RewrapError: LocalizedError {
        case ffmpegMissing
        case noEssence(String)
        case insufficientSpace(String)
        case failed(String, String)

        var errorDescription: String? {
            switch self {
            case .ffmpegMissing: "ffmpeg was not found."
            case .noEssence(let name): "\(name) has no video or audio files."
            case .insufficientSpace(let name): "Not enough free disk space to prepare \(name)."
            case .failed(let name, let diagnostic): "Couldn't prepare \(name): \(diagnostic)"
            }
        }
    }

    // MARK: - Card detection

    /// Whether `url` is the root of a P2 card (the folder that holds `CONTENTS`).
    static func isCardRoot(_ url: URL) -> Bool {
        let contents = url.appendingPathComponent("CONTENTS", isDirectory: true)
        return isDirectory(contents.appendingPathComponent("CLIP", isDirectory: true))
            && (isDirectory(contents.appendingPathComponent("VIDEO", isDirectory: true))
                || isDirectory(contents.appendingPathComponent("AUDIO", isDirectory: true)))
    }

    /// The card root for a card folder, its `CONTENTS` folder, or any file in it.
    /// Files next to `CONTENTS`, such as other media in a folder holding a copied
    /// card, are not on the card.
    static func cardRoot(containing url: URL) -> URL? {
        // Lower-cased like the file system: a copied card may name the folder `Contents`.
        let path = url.standardizedFileURL.path.lowercased()
        var candidate = url.standardizedFileURL
        // A file on the card is at most three levels below the root (CONTENTS/VIDEO/file).
        for _ in 0..<4 {
            if isCardRoot(candidate) {
                let contents = candidate.appendingPathComponent("CONTENTS", isDirectory: true).path.lowercased()
                return path == candidate.path.lowercased() || path == contents || path.hasPrefix(contents + "/")
                    ? candidate : nil
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
        }
        return nil
    }

    /// The clip a file on the card belongs to. Audio and voice-memo files append a
    /// two-digit channel or memo number to the clip name.
    static func clipName(forFileAt url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        switch url.deletingLastPathComponent().lastPathComponent.uppercased() {
        case "AUDIO", "VOICE":
            return base.count > 2 ? String(base.dropLast(2)) : base
        default:
            return base
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Parsing

    /// Reads every clip described in the card's `CONTENTS/CLIP` folder.
    static func clips(onCard root: URL) -> [Clip] {
        let contents = root.appendingPathComponent("CONTENTS", isDirectory: true)
        let clipFolder = contents.appendingPathComponent("CLIP", isDirectory: true)
        guard let xmlURLs = try? FileManager.default.contentsOfDirectory(
            at: clipFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return xmlURLs
            .filter { $0.pathExtension.lowercased() == "xml" }
            .compactMap { xmlURL in
                guard let data = try? Data(contentsOf: xmlURL),
                      let parsed = ClipXMLParser.parse(data) else {
                    logger.warning("Skipping unreadable P2 clip metadata \(xmlURL.lastPathComponent, privacy: .public)")
                    return nil
                }
                let name = parsed.clipName ?? xmlURL.deletingPathExtension().lastPathComponent
                let video = contents.appendingPathComponent("VIDEO/\(name).MXF")
                // Channels are numbered from 00 without gaps; stop at the first missing one.
                var audio: [URL] = []
                for channel in 0..<max(parsed.audioCount, 0) {
                    let url = contents.appendingPathComponent(String(format: "AUDIO/%@%02d.MXF", name, channel))
                    guard FileManager.default.fileExists(atPath: url.path) else { break }
                    audio.append(url)
                }
                return Clip(
                    name: name,
                    globalClipID: parsed.globalClipID ?? name,
                    videoURL: parsed.hasVideo && FileManager.default.fileExists(atPath: video.path) ? video : nil,
                    audioURLs: audio,
                    startTimecode: parsed.startTimecode,
                    recordingDate: parsed.recordingDate,
                    shotID: parsed.shotID,
                    offsetInShot: parsed.offsetInShot ?? 0,
                    nextClipID: parsed.nextClipID
                )
            }
    }

    /// Joins the parts of spanned shots and orders shots by clip name, which P2
    /// cameras number in recording order.
    static func shots(from clips: [Clip]) -> [Shot] {
        var shots: [Shot] = []
        var indexByShotID: [String: Int] = [:]
        for clip in clips {
            if let shotID = clip.shotID, let index = indexByShotID[shotID] {
                // The same clip can appear twice when a card is imported alongside a copy of itself.
                guard !shots[index].clips.contains(where: { $0.globalClipID == clip.globalClipID }) else { continue }
                shots[index].clips.append(clip)
            } else {
                if let shotID = clip.shotID { indexByShotID[shotID] = shots.count }
                shots.append(Shot(clips: [clip]))
            }
        }
        for index in shots.indices {
            shots[index].clips.sort { $0.offsetInShot < $1.offsetInShot }
        }
        return shots.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Import

    /// Replaces files that belong to P2 cards with one rewrapped file per shot,
    /// placed where the card's first file was. Only shots with at least one file
    /// in `urls` are included, so dropping a single clip doesn't import the whole
    /// card. Other URLs pass through unchanged, and so do card files whose clip
    /// metadata can't be read. Shots that can't be rewrapped are left out and
    /// reported in the progress overlay.
    static func resolveCards(in urls: [URL]) async -> [URL] {
        enum Entry { case file(URL), card(URL) }

        var entries: [Entry] = []
        var requestedClips: [URL: Set<String>] = [:]
        var requestedFiles: [URL: [URL]] = [:]
        var rootByFolder: [String: URL?] = [:]
        for url in urls {
            let folder = url.deletingLastPathComponent().path
            let root: URL?
            if let cached = rootByFolder[folder] {
                root = cached
            } else {
                root = cardRoot(containing: url)
                rootByFolder[folder] = root
            }
            guard let root else {
                entries.append(.file(url))
                continue
            }
            if requestedClips[root] == nil { entries.append(.card(root)) }
            requestedClips[root, default: []].insert(clipName(forFileAt: url).uppercased())
            requestedFiles[root, default: []].append(url)
        }
        guard !requestedClips.isEmpty else { return urls }

        // Group across cards so a shot spanned over two cards is joined. It is
        // placed with the card holding its first clip.
        let cardRoots = entries.compactMap { if case .card(let root) = $0 { root } else { nil } }
        var allClips: [Clip] = []
        var cardByClipID: [String: URL] = [:]
        var unreadFiles: [URL: [URL]] = [:]
        for root in cardRoots {
            let cardClips = clips(onCard: root)
            let names = Set(cardClips.map { $0.name.uppercased() })
            unreadFiles[root] = requestedFiles[root]?.filter { !names.contains(clipName(forFileAt: $0).uppercased()) }
            for clip in cardClips where cardByClipID[clip.globalClipID] == nil {
                cardByClipID[clip.globalClipID] = root
                allClips.append(clip)
            }
        }
        let wanted = shots(from: allClips).filter { shot in
            shot.clips.contains { clip in
                cardByClipID[clip.globalClipID].flatMap { requestedClips[$0] }?.contains(clip.name.uppercased()) == true
            }
        }
        if unreadFiles.values.contains(where: { !$0.isEmpty }) {
            logger.warning("P2 clip metadata missing or unreadable; adding those card files as they are")
            await P2ImportProgress.shared.showFailure("Some P2 clip metadata couldn't be read. Those files were added as they are.")
        }

        let incomplete = wanted.filter(\.isMissingParts).map(\.name)
        if !incomplete.isEmpty {
            logger.warning("P2 shots missing parts: \(incomplete.joined(separator: ", "), privacy: .public)")
            await P2ImportProgress.shared.showFailure(incomplete.count == 1
                ? "P2 clip \(incomplete[0]) is missing part of its recording. Import all of its cards together to join it."
                : "P2 clips \(incomplete.joined(separator: ", ")) are missing parts of their recordings. Import all of their cards together to join them.")
        }

        let rewrapped = wanted.isEmpty ? [] : await rewrapWithProgress(wanted)

        var urlsByCard: [URL: [URL]] = [:]
        for (shot, url) in zip(wanted, rewrapped) {
            guard let url, let root = cardByClipID[shot.clips[0].globalClipID] else { continue }
            urlsByCard[root, default: []].append(url)
        }
        return entries.flatMap { entry -> [URL] in
            switch entry {
            case .file(let url): [url]
            case .card(let root): (urlsByCard[root] ?? []) + (unreadFiles[root] ?? [])
            }
        }
    }

    /// Rewraps the shots one by one with progress and cancellation in the overlay.
    /// Returns the rewrapped file for each shot, or nil when it failed or was cancelled.
    private static func rewrapWithProgress(_ shots: [Shot]) async -> [URL?] {
        let sizes = shots.map { shot in
            shot.sourceURLs.reduce(Int64(0)) { total, url in
                total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        let totalBytes = max(sizes.reduce(0, +), 1)

        // Check the whole import up front, so a large card doesn't fill the disk shot by shot.
        let neededBytes = zip(shots, sizes).reduce(Int64(0)) { total, pair in
            FileManager.default.fileExists(atPath: P2ClipRewrapper.outputURL(for: pair.0).path) ? total : total + pair.1
        }
        try? FileManager.default.createDirectory(at: AppConstants.p2ClipsDirectory, withIntermediateDirectories: true)
        if let available = try? AppConstants.p2ClipsDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
            available < neededBytes + P2ClipRewrapper.spaceMargin {
            let needed = ByteCountFormatter.string(fromByteCount: neededBytes, countStyle: .file)
            let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            logger.error("Not enough space to prepare P2 clips: need \(needed, privacy: .public), \(free, privacy: .public) free")
            await P2ImportProgress.shared.showFailure("Not enough free disk space to prepare the P2 clips (\(needed) needed, \(free) free).")
            return shots.map { _ in nil }
        }

        let token = UUID()
        let work = Task<[URL?], Never> {
            var results: [URL?] = []
            var failures: [String] = []
            var doneBytes: Int64 = 0
            for (index, shot) in shots.enumerated() {
                guard !Task.isCancelled else {
                    results.append(nil)
                    continue
                }
                let message = shots.count == 1
                    ? "Preparing P2 clip \(shot.name)…"
                    : "Preparing P2 clip \(index + 1) of \(shots.count) (\(shot.name))…"
                let base = doneBytes
                await P2ImportProgress.shared.update(token, message: message, fraction: Double(base) / Double(totalBytes))
                do {
                    let url = try await P2ClipRewrapper.shared.rewrap(shot) { written in
                        let fraction = Double(base + min(written, sizes[index])) / Double(totalBytes)
                        Task { @MainActor in P2ImportProgress.shared.update(token, fraction: fraction) }
                    }
                    results.append(url)
                } catch is CancellationError {
                    results.append(nil)
                } catch {
                    logger.error("P2 rewrap failed for \(shot.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    failures.append(shot.name)
                    results.append(nil)
                }
                doneBytes += sizes[index]
            }
            if !failures.isEmpty {
                let names = failures.joined(separator: ", ")
                await P2ImportProgress.shared.showFailure(
                    failures.count == 1 ? "Couldn't prepare P2 clip \(names)." : "Couldn't prepare P2 clips \(names)."
                )
            }
            return results
        }

        await P2ImportProgress.shared.begin(token, weight: totalBytes, cancel: { work.cancel() })
        let results = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        await P2ImportProgress.shared.end(token)
        return results
    }
}

// MARK: - Rewrapping

/// Rewraps P2 shots into `AppConstants.p2ClipsDirectory`. Requests for a shot that
/// is already being rewrapped join that work instead of starting a second ffmpeg,
/// which stops only when every request for it is cancelled.
///
/// Not in the preview cache: its default "Delete on launch" policy would remove
/// clips that a restored session or a re-queued history entry still points at.
actor P2ClipRewrapper {
    static let shared = P2ClipRewrapper()

    private static let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "P2CardImporter")
    private static let timeout: Duration = .seconds(6 * 60 * 60)
    /// Rewrapped shots unused for this long are removed at launch.
    private static let retention: TimeInterval = 7 * 24 * 60 * 60
    /// Free space kept beyond a rewrap's size.
    static let spaceMargin: Int64 = 512 * 1024 * 1024
    /// Holds the path of the card a shot came from, next to its rewrapped file.
    private static let cardMarkerName = ".card"

    private struct InFlight {
        let task: Task<URL, Error>
        var waiters: Int
    }

    private var inFlight: [String: InFlight] = [:]
    private let runner: any SubprocessRunning = SubprocessRunner()

    static func outputURL(for shot: P2CardImporter.Shot) -> URL {
        AppConstants.p2ClipsDirectory
            .appendingPathComponent(shot.cacheKey, isDirectory: true)
            .appendingPathComponent("\(shot.name).mkv")
    }

    /// `progress` receives the number of bytes written so far.
    func rewrap(_ shot: P2CardImporter.Shot, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let output = Self.outputURL(for: shot)
        if FileManager.default.fileExists(atPath: output.path) {
            Self.markUsed(output, cardRoot: shot.cardRoot)
            return output
        }
        let key = shot.cacheKey
        let task: Task<URL, Error>
        if let existing = inFlight[key] {
            task = existing.task
            inFlight[key]?.waiters += 1
        } else {
            let runner = self.runner
            task = Task { try await Self.perform(shot, to: output, runner: runner, progress: progress) }
            inFlight[key] = InFlight(task: task, waiters: 1)
        }
        defer { if inFlight[key]?.task == task { inFlight[key] = nil } }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            Task { await self.withdraw(from: task, key: key) }
        }
    }

    /// A request was cancelled; stop the rewrap once no request still wants it.
    private func withdraw(from task: Task<URL, Error>, key: String) {
        guard inFlight[key]?.task == task else { return }
        inFlight[key]?.waiters -= 1
        if inFlight[key]?.waiters ?? 0 <= 0 {
            // Forget it now, so a request arriving before ffmpeg exits starts a new rewrap
            // instead of joining this cancelled one.
            inFlight[key] = nil
            task.cancel()
        }
    }

    private static func perform(
        _ shot: P2CardImporter.Shot,
        to output: URL,
        runner: any SubprocessRunning,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else { throw P2CardImporter.RewrapError.ffmpegMissing }

        let hasVideo = shot.clips.allSatisfy { $0.videoURL != nil }
        // Every part of a spanned shot must contribute each channel; use the channels all parts have.
        let channelCount = shot.clips.map(\.audioURLs.count).min() ?? 0
        guard hasVideo || channelCount > 0 else { throw P2CardImporter.RewrapError.noEssence(shot.name) }

        let directory = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sourceBytes = shot.sourceURLs.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        if let available = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, available < sourceBytes + spaceMargin {
            throw P2CardImporter.RewrapError.insufficientSpace(shot.name)
        }

        var listFiles: [URL] = []
        let partial = directory.appendingPathComponent("\(shot.name).partial.mkv")
        defer {
            for url in listFiles { try? FileManager.default.removeItem(at: url) }
        }

        // One input per stream. Spanned shots read each stream through the concat demuxer.
        func input(_ sources: [URL], label: String) throws -> [String] {
            guard sources.count > 1 else { return ["-i", sources[0].path] }
            let list = directory.appendingPathComponent("\(label).ffconcat")
            let lines = sources.map { "file '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" }
            try (["ffconcat version 1.0"] + lines).joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
            listFiles.append(list)
            return ["-f", "concat", "-safe", "0", "-i", list.path]
        }

        var arguments = ["-y", "-nostdin", "-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1"]
        var maps: [String] = []
        var inputIndex = 0
        if hasVideo {
            arguments += try input(shot.clips.compactMap(\.videoURL), label: "video")
            maps += ["-map", "\(inputIndex):v:0"]
            inputIndex += 1
        }
        for channel in 0..<channelCount {
            arguments += try input(shot.clips.map { $0.audioURLs[channel] }, label: "audio\(channel)")
            maps += ["-map", "\(inputIndex):a:0"]
            inputIndex += 1
        }
        arguments += maps + ["-c", "copy"]
        if let timecode = shot.clips[0].startTimecode,
           timecode.range(of: #"^\d{2}:\d{2}:\d{2}[:;.]\d{2}$"#, options: .regularExpression) != nil {
            arguments += ["-timecode", timecode]
        }
        if let date = shot.clips[0].recordingDate {
            arguments += ["-metadata", "creation_time=\(date.ISO8601Format())"]
        }
        arguments += ["-f", "matroska", partial.path]

        let request = SubprocessRequest(
            executableURL: URL(fileURLWithPath: ffmpegPath),
            arguments: arguments,
            timeout: timeout,
            standardOutputCaptureLimit: 0,
            standardErrorCaptureLimit: 64 * 1024
        )
        logger.info("Rewrapping P2 shot \(shot.name, privacy: .public) (\(shot.clips.count) clip(s), \(channelCount) audio channel(s))")

        let result: SubprocessResult
        // A `-progress` line can be split across output chunks; keep the unfinished end.
        let unfinishedLine = OSAllocatedUnfairLock(initialState: "")
        do {
            result = try await runner.run(request) { chunk in
                // `-progress` reports blocks of key=value lines; use the latest total_size.
                guard chunk.stream == .standardOutput, let text = String(data: chunk.data, encoding: .utf8) else { return }
                let lines = unfinishedLine.withLock { unfinished in
                    var lines = (unfinished + text).components(separatedBy: "\n")
                    unfinished = lines.removeLast()
                    return lines
                }
                guard let line = lines.last(where: { $0.hasPrefix("total_size=") }),
                      let bytes = Int64(line.dropFirst("total_size=".count)) else { return }
                progress(bytes)
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        guard result.succeeded, !Task.isCancelled else {
            try? FileManager.default.removeItem(at: partial)
            try Task.checkCancellation()
            let diagnostic = result.standardErrorText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw P2CardImporter.RewrapError.failed(shot.name, diagnostic.isEmpty ? "ffmpeg exited with status \(result.terminationStatus)" : diagnostic)
        }

        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: partial, to: output)
        if let date = shot.clips[0].recordingDate {
            try? FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: output.path)
        }
        markUsed(output, cardRoot: shot.cardRoot)
        return output
    }

    /// Records where the shot came from, and touches the shot folder, whose modification
    /// date is when it was last imported; `removeStale` reads it. A card already recorded
    /// is kept while it still holds the shot, so importing a backup copy of the card later
    /// doesn't move where earlier queue items save.
    private static func markUsed(_ output: URL, cardRoot: URL?) {
        let directory = output.deletingLastPathComponent()
        if let cardRoot, Self.cardRoot(forRewrap: output) == nil {
            try? cardRoot.path.write(
                to: directory.appendingPathComponent(cardMarkerName), atomically: true, encoding: .utf8
            )
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
    }

    /// Whether `url` is in the rewrapped-shot folder.
    nonisolated static func isRewrap(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(AppConstants.p2ClipsDirectory.standardizedFileURL.path + "/")
    }

    /// The card folder a rewrapped shot came from, if it is still there. "Save next to
    /// original" saves there, not in the rewrap folder that `removeStale` cleans out.
    nonisolated static func cardRoot(forRewrap url: URL) -> URL? {
        guard isRewrap(url),
              let path = try? String(
                  contentsOf: url.deletingLastPathComponent().appendingPathComponent(cardMarkerName), encoding: .utf8
              ),
              !path.isEmpty
        else { return nil }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard P2CardImporter.isCardRoot(root), card(root, holds: url) else { return nil }
        return root
    }

    /// Whether the card at `root` still holds the shot rewrapped to `url`, and is not a
    /// different card mounted at the same path. Compares the first clip's global clip ID
    /// with the one in the shot folder's name (`P2-<id>-<count>`).
    private nonisolated static func card(_ root: URL, holds url: URL) -> Bool {
        let folder = url.deletingLastPathComponent().lastPathComponent
        guard folder.hasPrefix("P2-"), let dash = folder.lastIndex(of: "-"),
              dash > folder.index(folder.startIndex, offsetBy: 2) else { return false }
        let clipID = String(folder[folder.index(folder.startIndex, offsetBy: 3)..<dash])
        let clipName = url.deletingPathExtension().lastPathComponent
        let xml = root.appendingPathComponent("CONTENTS/CLIP/\(clipName).XML")
        guard let data = try? Data(contentsOf: xml), let parsed = ClipXMLParser.parse(data) else { return false }
        return (parsed.globalClipID ?? clipName) == clipID
    }

    /// Removes shots not imported for `retention`, including partial files left by
    /// a quit mid-rewrap (a newer rewrap of the shot overwrites those). Run at launch.
    nonisolated static func removeStale(now: Date = Date()) {
        let fileManager = FileManager.default
        guard let shots = try? fileManager.contentsOfDirectory(
            at: AppConstants.p2ClipsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for shot in shots {
            let modified = (try? shot.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, now.timeIntervalSince(modified) >= retention else { continue }
            try? fileManager.removeItem(at: shot)
            logger.info("Removed unused P2 rewrap \(shot.lastPathComponent, privacy: .public)")
        }
    }
}

// MARK: - Progress

/// Progress of P2 rewrapping, shown as an overlay over the queue.
@MainActor @Observable
final class P2ImportProgress {
    static let shared = P2ImportProgress()

    private(set) var message: String?
    private(set) var fraction: Double?
    private(set) var failureMessage: String?
    var isActive: Bool { !imports.isEmpty }

    private struct Import {
        var message: String
        var fraction: Double
        /// Bytes to rewrap, so a large import counts for more of the shared bar.
        let weight: Double
        let cancel: @Sendable () -> Void
    }

    /// One per running import; the overlay stays until all of them end.
    private var imports: [UUID: Import] = [:]
    /// The import whose message is shown: the one updated most recently.
    private var shownImport: UUID?
    private var failureDismissTask: Task<Void, Never>?

    @discardableResult
    func begin(_ token: UUID = UUID(), weight: Int64 = 1, cancel: @escaping @Sendable () -> Void) -> UUID {
        imports[token] = Import(message: "Preparing P2 clips…", fraction: 0, weight: Double(max(weight, 1)), cancel: cancel)
        shownImport = token
        refresh()
        return token
    }

    /// Updates for an import that hasn't begun or has ended are ignored.
    func update(_ token: UUID, message: String? = nil, fraction: Double) {
        guard var entry = imports[token] else { return }
        if let message {
            entry.message = message
            shownImport = token
        }
        entry.fraction = max(entry.fraction, min(fraction, 1))
        imports[token] = entry
        refresh()
    }

    func end(_ token: UUID) {
        imports[token] = nil
        if shownImport == token { shownImport = imports.keys.first }
        refresh()
    }

    /// Cancels every running import.
    func cancel() {
        for entry in imports.values { entry.cancel() }
    }

    /// The bar shows the combined progress of all running imports, weighted by size.
    private func refresh() {
        guard !imports.isEmpty else {
            message = nil
            fraction = nil
            return
        }
        let total = imports.values.reduce(0) { $0 + $1.weight }
        fraction = imports.values.reduce(0) { $0 + $1.fraction * $1.weight } / total
        message = shownImport.flatMap { imports[$0]?.message }
    }

    /// Shown for a few seconds; a message arriving meanwhile is added below the current one.
    func showFailure(_ message: String) {
        if let current = failureMessage, current != message {
            failureMessage = current + "\n" + message
        } else {
            failureMessage = message
        }
        failureDismissTask?.cancel()
        failureDismissTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            failureMessage = nil
        }
    }
}

// MARK: - Clip XML

/// Reads the fields the importer needs from a P2 clip metadata file
/// (`urn:schemas-Professional-Plug-in:P2:ClipMetadata`).
private final class ClipXMLParser: NSObject, XMLParserDelegate {
    struct Result {
        var clipName: String?
        var globalClipID: String?
        var hasVideo = false
        var audioCount = 0
        var startTimecode: String?
        var recordingDate: Date?
        var shotID: String?
        var offsetInShot: Int?
        var nextClipID: String?
    }

    private var result = Result()
    private var path: [String] = []
    private var text = ""
    private var creationDate: Date?

    static func parse(_ data: Data) -> Result? {
        let delegate = ClipXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.path.isEmpty else { return nil }
        var result = delegate.result
        result.recordingDate = result.recordingDate ?? delegate.creationDate
        return result
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        path.append(elementName)
        text = ""
        if path.suffix(2) == ["EssenceList", "Video"] { result.hasVideo = true }
        if path.suffix(2) == ["EssenceList", "Audio"] { result.audioCount += 1 }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = path.dropLast().last
        if !value.isEmpty {
            switch (parent, elementName) {
            case ("ClipContent", "ClipName"): result.clipName = value
            case ("ClipContent", "GlobalClipID"): result.globalClipID = value
            case ("Video", "StartTimecode"): result.startTimecode = value
            case ("Shoot", "StartDate"): result.recordingDate = Self.date(value)
            case ("Access", "CreationDate"): creationDate = Self.date(value)
            case ("Relation", "GlobalShotID"): result.shotID = value
            case ("Relation", "OffsetInShot"): result.offsetInShot = Int(value)
            case ("Next", "GlobalClipID"): result.nextClipID = value
            default: break
            }
        }
        path.removeLast()
        text = ""
    }

    /// P2 writes offsets such as `2016-02-13T22:50:38+00:00`.
    private static func date(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}
