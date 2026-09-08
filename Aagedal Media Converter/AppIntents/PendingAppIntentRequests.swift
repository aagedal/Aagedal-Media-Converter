// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

import Foundation

/// Buffers App Intent hand-off requests so they survive a cold launch.
///
/// When an App Intent runs with `openAppWhenRun = true`, the system launches the
/// app and calls `perform()` — but the SwiftUI window (and the
/// `NotificationCenter` receivers in `ContentView`) may not exist yet, so a
/// notification posted from `perform()` can be dropped on the floor.
///
/// To avoid losing the request, intents go through ``submit(name:object:userInfo:)``,
/// which both posts the notification live (handled immediately when a window is
/// already up) **and** buffers it keyed by a `requestID`. Once a window's
/// receivers come online, `ContentView` calls ``drain()`` to replay anything that
/// wasn't already consumed. The live handler calls ``consume(id:)`` when it
/// processes a request, so nothing runs twice:
///
/// - Window already open → live post is handled and the id consumed; `drain()`
///   later finds nothing.
/// - No window yet → live post is dropped, the request stays buffered, and
///   `drain()` replays it when the window appears.
///
/// All access happens on the main actor (intents post inside `MainActor.run`,
/// handlers and `drain()` run on the main thread), so the storage needs no extra
/// locking.
@MainActor
final class PendingAppIntentRequests {
    static let shared = PendingAppIntentRequests()
    private let post: (Notification) -> Void

    init(post: @escaping (Notification) -> Void = { NotificationCenter.default.post($0) }) {
        self.post = post
    }

    private struct Request {
        let name: Notification.Name
        let object: Any?
        let userInfo: [AnyHashable: Any]
    }

    private var pending: [UUID: Request] = [:]
    private var pendingOrder: [UUID] = []

    /// The userInfo key under which callers must place a `UUID` request id.
    static let requestIDKey = "requestID"

    /// Buffer a request (keyed by its `requestID`) and post it live. If the
    /// userInfo carries no `requestID`, the request is posted without buffering.
    func submit(name: Notification.Name, object: Any?, userInfo: [AnyHashable: Any]) {
        if let id = userInfo[Self.requestIDKey] as? UUID {
            if pending[id] == nil { pendingOrder.append(id) }
            pending[id] = Request(name: name, object: object, userInfo: userInfo)
        }
        post(Notification(name: name, object: object, userInfo: userInfo))
    }

    /// Mark a request handled so a later ``drain()`` won't replay it. Called by
    /// the live notification handler.
    func consume(id: UUID) {
        pending.removeValue(forKey: id)
        pendingOrder.removeAll { $0 == id }
    }

    /// Replay and clear any requests not yet consumed. Called once a window's
    /// receivers are attached (e.g. from `ContentView`'s `onAppear`).
    func drain() {
        guard !pending.isEmpty else { return }
        let requests = pendingOrder.compactMap { pending[$0] }
        pending.removeAll()
        pendingOrder.removeAll()
        for request in requests {
            post(Notification(name: request.name, object: request.object, userInfo: request.userInfo))
        }
    }
}
