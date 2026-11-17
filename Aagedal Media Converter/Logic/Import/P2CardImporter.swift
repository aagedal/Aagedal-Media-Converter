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
/// ffmpeg can't open them as one source, so each shot is rewrapped into a single
/// OP1a MXF file holding the video and every audio channel, and the queue uses
/// that file like any other MXF camera clip: Stream Copy keeps it MXF, or writes
/// MOV, MP4 or MKV when that container is chosen. Shots split across several
/// clips (spanned recordings, even across cards) are joined in the same pass.
///
/// bmxtranswrap does the rewrap: it keeps the AVC-Intra class labels, field
/// order and timecode. A shot it can't read is stream-copied by ffmpeg into
/// Matroska instead, because ffmpeg's MOV muxer drops the field order of H.264
/// (interlaced AVC-Intra would then skip deinterlacing).
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

    /// Picks one card for each clip, by global clip ID. A clip on several cards (a card
    /// and its copy) goes with a card it was picked from, so picking different clips from
    /// each card keeps all of them. `requestedClips` holds upper-cased clip names per card.
    static func assignCards(
        _ clipsByCard: [(root: URL, clips: [Clip])],
        requestedClips: [URL: Set<String>]
    ) -> (clips: [Clip], cardByClipID: [String: URL]) {
        var allClips: [Clip] = []
        var cardByClipID: [String: URL] = [:]
        for picked in [true, false] {
            for (root, cardClips) in clipsByCard {
                for clip in cardClips where cardByClipID[clip.globalClipID] == nil
                    && (requestedClips[root]?.contains(clip.name.uppercased()) == true) == picked {
                    cardByClipID[clip.globalClipID] = root
                    allClips.append(clip)
                }
            }
        }
        return (allClips, cardByClipID)
    }

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
        var unreadFiles: [URL: [URL]] = [:]
        var clipsByCard: [(root: URL, clips: [Clip])] = []
        for root in cardRoots {
            let cardClips = clips(onCard: root)
            let names = Set(cardClips.map { $0.name.uppercased() })
            unreadFiles[root] = requestedFiles[root]?.filter { !names.contains(clipName(forFileAt: $0).uppercased()) }
            clipsByCard.append((root, cardClips))
        }
        let (allClips, cardByClipID) = assignCards(clipsByCard, requestedClips: requestedClips)
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
            P2ClipRewrapper.cachedRewrap(for: pair.0) != nil ? total : total + pair.1
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
        // The work waits until the import has begun, or the overlay ignores its first message.
        let (begun, begunContinuation) = AsyncStream<Void>.makeStream()
        let work = Task<[URL?], Never> {
            for await _ in begun {}
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
        begunContinuation.finish()
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
    /// Rewrapped shots unused for this long are removed at launch. As long as the
    /// restore-last-session offer, so a restored queue still finds its shots.
    static let retention: TimeInterval = max(7 * 24 * 60 * 60, LastSessionStore.pendingLifetime)
    /// Free space kept beyond a rewrap's size.
    static let spaceMargin: Int64 = 512 * 1024 * 1024
    /// Holds the path of the card a shot came from, next to its rewrapped file.
    private static let cardMarkerName = ".card"
    /// Marks a Matroska rewrap made because bmx couldn't make an MXF. 4.7 wrote Matroska
    /// for every shot at the same path, without this marker; those are redone as MXF.
    private static let matroskaFallbackMarkerName = ".matroska-fallback"
    /// Written when an MXF replaces a 4.7 Matroska rewrap. A restored session or history
    /// entry may still point at the Matroska, so `removeStale` removes it only `retention`
    /// after this marker was written, like a shot no longer imported.
    private static let supersededMarkerName = ".matroska-superseded"

    private struct InFlight {
        let task: Task<URL, Error>
        var waiters: Int
    }

    private var inFlight: [String: InFlight] = [:]
    /// Cancelled rewraps whose ffmpeg may still be running. They own the shot's partial and
    /// list files until they end, so a new rewrap of the shot waits for them.
    private var stopping: [String: Task<URL, Error>] = [:]
    private let runner: any SubprocessRunning = SubprocessRunner()

    /// The OP1a MXF rewrap. Older versions wrote Matroska only; such a shot is rewrapped again.
    static func outputURL(for shot: P2CardImporter.Shot) -> URL {
        AppConstants.p2ClipsDirectory
            .appendingPathComponent(shot.cacheKey, isDirectory: true)
            .appendingPathComponent("\(shot.name).mxf")
    }

    /// The Matroska rewrap, for shots bmxtranswrap can't read.
    static func matroskaOutputURL(for shot: P2CardImporter.Shot) -> URL {
        outputURL(for: shot).deletingPathExtension().appendingPathExtension("mkv")
    }

    /// A finished rewrap of the shot: its MXF, or the Matroska made because bmx couldn't
    /// make one. Audio-only shots always go to Matroska, so 4.7's rewrap of one is kept.
    nonisolated static func cachedRewrap(for shot: P2CardImporter.Shot) -> URL? {
        let fileManager = FileManager.default
        let output = outputURL(for: shot)
        if fileManager.fileExists(atPath: output.path) { return output }
        let matroska = matroskaOutputURL(for: shot)
        guard fileManager.fileExists(atPath: matroska.path) else { return nil }
        let marker = output.deletingLastPathComponent().appendingPathComponent(matroskaFallbackMarkerName)
        let hasVideo = shot.clips.allSatisfy { $0.videoURL != nil }
        return !hasVideo || fileManager.fileExists(atPath: marker.path) ? matroska : nil
    }

    /// `progress` receives about how many bytes have been written so far.
    func rewrap(_ shot: P2CardImporter.Shot, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        if let cached = Self.cachedRewrap(for: shot) {
            Self.markUsed(cached, cardRoot: shot.cardRoot)
            return cached
        }
        let key = shot.cacheKey
        let task: Task<URL, Error>
        if let existing = inFlight[key] {
            task = existing.task
            inFlight[key]?.waiters += 1
        } else {
            let runner = self.runner
            let previous = stopping[key]
            task = Task {
                // A cancel that came after the move leaves a finished file; use it.
                if let url = try? await previous?.value { return url }
                try Task.checkCancellation()
                return try await Self.perform(shot, runner: runner, progress: progress)
            }
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
            // instead of joining this cancelled one. That rewrap waits for this one to end.
            inFlight[key] = nil
            stopping[key] = task
            task.cancel()
            Task {
                _ = try? await task.value
                if self.stopping[key] == task { self.stopping[key] = nil }
            }
        }
    }

    private static func perform(
        _ shot: P2CardImporter.Shot,
        runner: any SubprocessRunning,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        let hasVideo = shot.clips.allSatisfy { $0.videoURL != nil }
        // Every part of a spanned shot must contribute each channel; use the channels all parts have.
        let channelCount = shot.clips.map(\.audioURLs.count).min() ?? 0
        guard hasVideo || channelCount > 0 else { throw P2CardImporter.RewrapError.noEssence(shot.name) }

        // A cancelled rewrap this one waited for may have finished it.
        if let cached = cachedRewrap(for: shot) {
            markUsed(cached, cardRoot: shot.cardRoot)
            return cached
        }
        let output = outputURL(for: shot)
        let directory = output.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let matroska = matroskaOutputURL(for: shot)

        let sourceBytes = shot.sourceURLs.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        if let available = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, available < sourceBytes + spaceMargin {
            throw P2CardImporter.RewrapError.insufficientSpace(shot.name)
        }

        // bmx needs a picture track for the timecode rate; audio-only shots go to Matroska.
        if hasVideo, let bmxPath = BinaryPathResolver.bmxtranswrapPath {
            do {
                let partial = directory.appendingPathComponent("\(shot.name).partial.mxf")
                logger.info("Rewrapping P2 shot \(shot.name, privacy: .public) to MXF (\(shot.clips.count) clip(s), \(channelCount) audio channel(s))")
                try await run(
                    SubprocessRequest(
                        executableURL: URL(fileURLWithPath: bmxPath),
                        arguments: bmxArguments(for: shot, channelCount: channelCount, output: partial),
                        timeout: timeout,
                        standardOutputCaptureLimit: 0,
                        standardErrorCaptureLimit: 64 * 1024
                    ),
                    shot: shot, partial: partial, runner: runner,
                    // `-p` reports `12.3%`; scale it to the bytes read so far.
                    report: { line in
                        guard line.hasSuffix("%"),
                              let percent = Double(line.dropLast().trimmingCharacters(in: .whitespaces)) else { return nil }
                        return Int64(Double(sourceBytes) * min(max(percent, 0), 100) / 100)
                    },
                    progress: progress
                )
                let url = try finish(shot, partial: partial, output: output)
                if FileManager.default.fileExists(atPath: matroska.path) {
                    FileManager.default.createFile(
                        atPath: directory.appendingPathComponent(supersededMarkerName).path, contents: nil
                    )
                }
                return url
            } catch {
                try Task.checkCancellation()
                logger.warning("bmxtranswrap couldn't rewrap P2 shot \(shot.name, privacy: .public), using Matroska: \(error.localizedDescription, privacy: .public)")
            }
        }

        // bmx failed, so 4.7's Matroska rewrap is what this shot gets; keep it.
        if FileManager.default.fileExists(atPath: matroska.path) {
            markMatroskaFallback(matroska)
            markUsed(matroska, cardRoot: shot.cardRoot)
            return matroska
        }
        guard let ffmpegPath = BinaryPathResolver.ffmpegPath else { throw P2CardImporter.RewrapError.ffmpegMissing }

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
        if let timecode = startTimecode(of: shot) {
            arguments += ["-timecode", timecode]
        }
        if let date = shot.clips[0].recordingDate {
            arguments += ["-metadata", "creation_time=\(date.ISO8601Format())"]
        }
        arguments += ["-f", "matroska", partial.path]

        logger.info("Rewrapping P2 shot \(shot.name, privacy: .public) to Matroska (\(shot.clips.count) clip(s), \(channelCount) audio channel(s))")
        try await run(
            SubprocessRequest(
                executableURL: URL(fileURLWithPath: ffmpegPath),
                arguments: arguments,
                timeout: timeout,
                standardOutputCaptureLimit: 0,
                standardErrorCaptureLimit: 64 * 1024
            ),
            shot: shot, partial: partial, runner: runner,
            // `-progress` reports blocks of key=value lines; use the latest total_size.
            report: { line in
                line.hasPrefix("total_size=") ? Int64(line.dropFirst("total_size=".count)) : nil
            },
            progress: progress
        )
        let url = try finish(shot, partial: partial, output: matroska)
        markMatroskaFallback(url)
        return url
    }

    private static func markMatroskaFallback(_ matroska: URL) {
        FileManager.default.createFile(
            atPath: matroska.deletingLastPathComponent().appendingPathComponent(matroskaFallbackMarkerName).path,
            contents: nil
        )
    }

    /// bmxtranswrap reads the clips of a shot in order (`--no-reorder`) and joins them
    /// with its sequence reader; the video and audio files of one clip share a package.
    nonisolated static func bmxArguments(for shot: P2CardImporter.Shot, channelCount: Int, output: URL) -> [String] {
        var arguments = ["-p", "-t", "op1a", "--no-reorder", "--clip", shot.name]
        // The sequence reader starts discontinuous parts at 00:00:00:00; keep the first clip's.
        if let timecode = startTimecode(of: shot) { arguments += ["-y", timecode] }
        if let date = shot.clips[0].recordingDate {
            // `YYYY-MM-DDThh:mm:ss:qm`, with qm in 1/250 s.
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss':00'"
            arguments += ["--create-date", formatter.string(from: date)]
        }
        arguments += ["-o", output.path]
        for clip in shot.clips {
            arguments += (clip.videoURL.map { [$0.path] } ?? []) + clip.audioURLs.prefix(channelCount).map(\.path)
        }
        return arguments
    }

    /// The first clip's start timecode, when it is in `hh:mm:ss:ff` form (`;` or `.` for drop frame).
    private nonisolated static func startTimecode(of shot: P2CardImporter.Shot) -> String? {
        guard let timecode = shot.clips[0].startTimecode,
              timecode.range(of: #"^\d{2}:\d{2}:\d{2}[:;.]\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return timecode
    }

    /// Runs a rewrap into `partial`, passing the latest progress line that `report` turns
    /// into bytes on to `progress`. Removes `partial` unless the tool succeeds.
    private static func run(
        _ request: SubprocessRequest,
        shot: P2CardImporter.Shot,
        partial: URL,
        runner: any SubprocessRunning,
        report: @escaping @Sendable (String) -> Int64?,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
        let result: SubprocessResult
        // A progress line can be split across output chunks; keep the unfinished end.
        let unfinishedLine = OSAllocatedUnfairLock(initialState: "")
        do {
            result = try await runner.run(request) { chunk in
                guard chunk.stream == .standardOutput, let text = String(data: chunk.data, encoding: .utf8) else { return }
                // ffmpeg ends lines with `\n`, bmx's progress with `\r`.
                let lines = unfinishedLine.withLock { unfinished in
                    var lines = (unfinished + text).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                        .map(String.init)
                    unfinished = lines.removeLast()
                    return lines
                }
                guard let bytes = lines.reversed().lazy.compactMap(report).first else { return }
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
            throw P2CardImporter.RewrapError.failed(shot.name, diagnostic.isEmpty ? "\(request.executableURL.lastPathComponent) exited with status \(result.terminationStatus)" : diagnostic)
        }
    }

    private static func finish(_ shot: P2CardImporter.Shot, partial: URL, output: URL) throws -> URL {
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

    /// When the camera recorded a rewrapped shot, from its clip metadata on the card. The
    /// MXF rewrap doesn't carry it in a form the metadata probe reads.
    nonisolated static func recordingDate(forRewrap url: URL) -> Date? {
        guard let root = cardRoot(forRewrap: url) else { return nil }
        let xml = root.appendingPathComponent("CONTENTS/CLIP/\(url.deletingPathExtension().lastPathComponent).XML")
        return (try? Data(contentsOf: xml)).flatMap(ClipXMLParser.parse)?.recordingDate
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
    /// a quit mid-rewrap (a newer rewrap of the shot overwrites those), and 4.7 Matroska
    /// rewraps an MXF replaced that long ago. Run at launch.
    /// On the actor, so it can't remove a shot that an import is reusing or rewrapping.
    func removeStale(now: Date = Date()) {
        Self.removeStale(in: AppConstants.p2ClipsDirectory, now: now, keeping: Set(inFlight.keys).union(stopping.keys))
    }

    nonisolated static func removeStale(in directory: URL, now: Date, keeping busy: Set<String> = []) {
        let fileManager = FileManager.default
        guard let shots = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for shot in shots where !busy.contains(shot.lastPathComponent) {
            let modified = (try? shot.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) >= retention {
                try? fileManager.removeItem(at: shot)
                logger.info("Removed unused P2 rewrap \(shot.lastPathComponent, privacy: .public)")
                continue
            }
            let marker = shot.appendingPathComponent(supersededMarkerName)
            guard let superseded = (try? fileManager.attributesOfItem(atPath: marker.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(superseded) >= retention else { continue }
            let files = (try? fileManager.contentsOfDirectory(at: shot, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "mkv" {
                try? fileManager.removeItem(at: file)
                logger.info("Removed superseded Matroska P2 rewrap \(file.lastPathComponent, privacy: .public)")
            }
            try? fileManager.removeItem(at: marker)
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
