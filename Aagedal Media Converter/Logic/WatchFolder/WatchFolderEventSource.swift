// Aagedal Media Converter
// Copyright © 2026 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreServices
import Foundation

/// Wakes the watch-folder monitor early. A signal that arrives while nobody waits is kept,
/// so a change during a scan triggers one more scan instead of being lost.
actor WatchFolderWakeSignal {
    private var hasPendingSignal = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waitID: UInt64 = 0

    func signal() {
        if let continuation {
            self.continuation = nil
            continuation.resume()
        } else {
            hasPendingSignal = true
        }
    }

    /// Returns after a signal, the timeout, or cancellation, whichever comes first.
    func wait(timeout: Duration) async {
        if hasPendingSignal {
            hasPendingSignal = false
            return
        }
        guard !Task.isCancelled else { return }
        waitID &+= 1
        let id = waitID
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.finishWait(id)
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.finishWait(id) }
        }
    }

    private func finishWait(_ id: UInt64) {
        guard id == waitID, let continuation else { return }
        self.continuation = nil
        continuation.resume()
    }
}

/// FSEvents stream for a watch folder and everything below it. Events only mean "look
/// again": the scan decides what changed, so coalesced or dropped events are harmless.
/// Network volumes do not report changes made by other machines, which is why the
/// monitor keeps a polling fallback.
final class WatchFolderEventSource {
    private final class Handler: Sendable {
        let onChange: @Sendable () -> Void
        init(_ onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    }

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.aagedal.MediaConverter.WatchFolderEvents", qos: .utility)

    /// Returns nil when FSEvents cannot watch the path; the monitor then polls.
    init?(path: String, latency: TimeInterval = 1.0, onChange: @escaping @Sendable () -> Void) {
        // The stream owns a reference to the handler and releases it once invalidated, so a
        // callback already queued when `stop()` runs still finds a live handler.
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(Handler(onChange)).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<Handler>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit {
        stop()
    }
}
