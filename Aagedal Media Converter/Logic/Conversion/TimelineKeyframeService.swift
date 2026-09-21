// Aagedal Media Converter
// Copyright 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import AVFoundation
import Foundation

/// Sync samples are seek candidates; they do not prove a closed GOP or exact copy boundary.
struct TimelineKeyframeScan: Sendable {
    enum Status: Sendable { case complete, partial, unavailable }
    let times: [Double]
    /// Attempted bounded region. Only `complete` establishes coverage of this region;
    /// partial results establish no coverage, and other source regions remain unknown.
    let scannedRange: ClosedRange<Double>?
    let status: Status
    var sourceIdentity: TimelineKeyframeService.SourceIdentity? = nil
}

/// Bounded native discovery for formats AVFoundation can read. This deliberately does not
/// fall back to decoding or an unbundled ffprobe. Unsupported formats remain unavailable.
actor TimelineKeyframeService {
    static let shared = TimelineKeyframeService()
    static let maximumScanDuration = 120.0
    private var cache: [CacheKey: TimelineKeyframeScan] = [:]
    private var cacheOrder: [CacheKey] = []

    struct SourceIdentity: Hashable, Sendable {
        let path: String
        let resourceIdentifier: String
        let size: Int
        let modified: Date

        static func read(_ url: URL) -> Self? {
            // URL resource values may be cached on a reused URL instance. Re-read
            // filesystem identity so replacing a file in place invalidates prior scans.
            var freshURL = url
            freshURL.removeAllCachedResourceValues()
            guard let values = try? freshURL.resourceValues(forKeys: [
                .fileResourceIdentifierKey, .fileSizeKey, .contentModificationDateKey, .isRegularFileKey
            ]), values.isRegularFile == true,
                  let identifier = values.fileResourceIdentifier,
                  let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
            return Self(path: url.standardizedFileURL.path,
                        resourceIdentifier: String(describing: identifier), size: size, modified: modified)
        }
    }

    private struct CacheKey: Hashable {
        let source: SourceIdentity
        let track: Int
        let start: Double
        let end: Double
    }

    static func boundedRange(_ requested: ClosedRange<Double>, duration: Double) -> ClosedRange<Double>? {
        guard duration.isFinite, duration > 0,
              requested.lowerBound.isFinite, requested.upperBound.isFinite else { return nil }
        let start = max(0, min(duration, floor(requested.lowerBound / 5) * 5))
        let end = max(start, min(duration, ceil(requested.upperBound / 5) * 5))
        guard end > start else { return nil }
        if end - start <= maximumScanDuration { return start...end }
        let midpoint = start + (end - start) / 2
        return (midpoint - maximumScanDuration / 2)...(midpoint + maximumScanDuration / 2)
    }

    func scan(url: URL, videoTrackOrdinal: Int = 0, range: ClosedRange<Double>,
              duration: Double) async throws -> TimelineKeyframeScan {
        try Task.checkCancellation()
        guard videoTrackOrdinal >= 0, let bounded = Self.boundedRange(range, duration: duration) else {
            return TimelineKeyframeScan(times: [], scannedRange: nil, status: .unavailable)
        }
        let access = SecurityScopedBookmarkManager.shared.startAccessing(url: url)
        defer { SecurityScopedBookmarkManager.shared.stopAccessing(access) }
        let identity = SourceIdentity.read(url)
        let key = identity.map { CacheKey(source: $0, track: videoTrackOrdinal,
                                         start: bounded.lowerBound, end: bounded.upperBound) }
        if let key, let cached = cache[key] {
            try Task.checkCancellation()
            return cached
        }
        let cancellation = ReaderCancellation()
        let task = Task.detached(priority: .utility) {
            try await Self.read(url: url, trackOrdinal: videoTrackOrdinal, range: bounded, cancellation: cancellation)
        }
        var result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            cancellation.cancel()
        }
        try Task.checkCancellation()
        guard SourceIdentity.read(url) == identity else {
            return TimelineKeyframeScan(times: [], scannedRange: nil, status: .unavailable)
        }
        result.sourceIdentity = identity
        // Do not preserve failures, interrupted scans, or a file changed during inspection.
        if let key, result.status == .complete, SourceIdentity.read(url) == identity {
            cache[key] = result
            cacheOrder.removeAll { $0 == key }
            cacheOrder.append(key)
            while cacheOrder.count > 32 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        }
        return result
    }

    /// Expand a local search when either neighboring candidate is still unknown.
    func scan(url: URL, videoTrackOrdinal: Int = 0, around time: Double,
              duration: Double) async throws -> TimelineKeyframeScan {
        guard time.isFinite, duration.isFinite, duration > 0 else {
            return TimelineKeyframeScan(times: [], scannedRange: nil, status: .unavailable)
        }
        let point = min(duration, max(0, time))
        let initial = try await scan(url: url, videoTrackOrdinal: videoTrackOrdinal,
                                     range: max(0, point - 15)...min(duration, point + 15), duration: duration)
        guard initial.status == .complete, let scanned = initial.scannedRange else { return initial }
        let lacksPrevious = scanned.lowerBound > 0 && !initial.times.contains(where: { $0 <= point })
        let lacksNext = scanned.upperBound < duration.nextDown && !initial.times.contains(where: { $0 >= point })
        guard lacksPrevious || lacksNext else { return initial }
        return try await scan(url: url, videoTrackOrdinal: videoTrackOrdinal,
                              range: max(0, point - 60)...min(duration, point + 60), duration: duration)
    }

    private static func read(url: URL, trackOrdinal: Int,
                             range: ClosedRange<Double>, cancellation: ReaderCancellation) async throws -> TimelineKeyframeScan {
        let asset = AVURLAsset(url: url)
        // CMTimeRange ends are exclusive. Do not claim that a keyframe exactly
        // at the requested upper boundary has been inspected by this reader.
        let coverage = range.lowerBound...range.upperBound.nextDown
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            try Task.checkCancellation()
            guard tracks.indices.contains(trackOrdinal) else {
                return TimelineKeyframeScan(times: [], scannedRange: nil, status: .unavailable)
            }
            let reader = try AVAssetReader(asset: asset)
            cancellation.install(reader)
            defer { cancellation.clear() }
            try Task.checkCancellation()
            reader.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 600_000),
                                          duration: CMTime(seconds: range.upperBound - range.lowerBound,
                                                           preferredTimescale: 600_000))
            let output = AVAssetReaderTrackOutput(track: tracks[trackOrdinal], outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                return TimelineKeyframeScan(times: [], scannedRange: nil, status: .unavailable)
            }
            reader.add(output)
            guard reader.startReading() else {
                return TimelineKeyframeScan(times: [], scannedRange: nil, status: .unavailable)
            }
            defer { if reader.status == .reading { reader.cancelReading() } }
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            let watchdog = Task {
                do { try await Task.sleep(for: .seconds(8)); cancellation.cancel() } catch {}
            }
            defer { watchdog.cancel() }
            var times: [Double] = []
            var samples = 0
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                samples += 1
                guard samples <= 100_000, ContinuousClock.now < deadline else {
                    return TimelineKeyframeScan(times: Array(Set(times)).sorted(), scannedRange: coverage, status: .partial)
                }
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
                let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
                // AVFoundation provides asset-timeline times, matching the preview and trim UI.
                // Subtracting track.timeRange.start would incorrectly move delayed video to zero.
                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if !notSync, time.isFinite, coverage.contains(time) { times.append(time) }
            }
            try Task.checkCancellation()
            return TimelineKeyframeScan(times: Array(Set(times)).sorted(), scannedRange: coverage,
                                        status: reader.status == .completed ? .complete : .partial)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return TimelineKeyframeScan(times: [], scannedRange: nil, status: .unavailable)
        }
    }
}

/// AVAssetReader cancellation must also reach an active compressed-sample read.
private final class ReaderCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var reader: AVAssetReader?
    private var cancelled = false

    func install(_ reader: AVAssetReader) {
        lock.lock()
        self.reader = reader
        let cancelNow = cancelled
        lock.unlock()
        if cancelNow { reader.cancelReading() }
    }

    func clear() {
        lock.lock()
        reader = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = reader
        lock.unlock()
        current?.cancelReading()
    }
}
