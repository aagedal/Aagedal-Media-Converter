// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Creates headless virtual displays via Apple's private CGVirtualDisplay API
// (declared in CGVirtualDisplay+Private.h). A virtual display gets a real
// CGDirectDisplayID, so it shows up in SCShareableContent automatically and is
// captured by ScreenCaptureManager like any physical display — letting the user
// record a window/feed off-screen without it occupying a real monitor.
//
// All private-API use is isolated here and guarded by a runtime availability
// check, so the rest of the app is unaffected if Apple ever changes these
// classes: the feature simply reports itself unavailable.

import Foundation
import CoreGraphics
import OSLog

/// Sendable hand-off box so the (non-Sendable) display + settings can be passed
/// to the background queue that runs the blocking `applySettings:` call. The
/// objects are built on the main actor and only touched by that operation until
/// it returns. The background closure retains this box even when its caller has
/// already timed out, so the unchecked conformance is sound.
private final class VirtualDisplayApplyBox: @unchecked Sendable {
    let display: CGVirtualDisplay
    let settings: CGVirtualDisplaySettings
    init(display: CGVirtualDisplay, settings: CGVirtualDisplaySettings) {
        self.display = display
        self.settings = settings
    }
}

/// Resolves an asynchronous caller from either a blocking operation or a deadline
/// without waiting for the losing operation. This differs from a task group: task
/// groups implicitly join every child before returning, which cannot bound a call
/// that is blocked in synchronous system IPC and does not observe cancellation.
enum BlockingOperationDeadline {
    static func run<Result: Sendable>(
        timeout: Duration,
        timeoutResult: Result,
        operation: @escaping @Sendable () -> Result
    ) async -> Result {
        let resolution = BlockingOperationResolution<Result>()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                resolution.install(continuation)

                guard !Task.isCancelled else {
                    resolution.resolve(timeoutResult)
                    return
                }

                DispatchQueue.global(qos: .userInitiated).async {
                    resolution.resolve(operation())
                }

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    resolution.resolve(timeoutResult)
                }
                resolution.installTimeoutTask(timeoutTask)
            }
        } onCancel: {
            resolution.resolve(timeoutResult)
        }
    }
}

private final class BlockingOperationResolution<Result: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result, Never>?
    private var resolvedResult: Result?
    private var isResolved = false
    private var timeoutTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<Result, Never>) {
        let result = lock.withLock { () -> Result? in
            if isResolved {
                return resolvedResult
            }
            self.continuation = continuation
            return nil
        }

        if let result {
            continuation.resume(returning: result)
        }
    }

    func installTimeoutTask(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock { () -> Bool in
            if isResolved {
                return true
            }
            timeoutTask = task
            return false
        }

        if shouldCancel {
            task.cancel()
        }
    }

    func resolve(_ result: Result) {
        let pending = lock.withLock {
            guard !isResolved else {
                return (
                    continuation: Optional<CheckedContinuation<Result, Never>>.none,
                    timeoutTask: Optional<Task<Void, Never>>.none
                )
            }

            isResolved = true
            resolvedResult = result
            let pending = (continuation, timeoutTask)
            continuation = nil
            timeoutTask = nil
            return pending
        }

        pending.timeoutTask?.cancel()
        pending.continuation?.resume(returning: result)
    }
}

@MainActor
final class VirtualDisplayManager: ObservableObject {
    static let shared = VirtualDisplayManager()

    struct ActiveDisplay: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let name: String
        let width: Int
        let height: Int
    }

    /// Virtual displays currently alive, in creation order. Drives the UI.
    @Published private(set) var activeDisplays: [ActiveDisplay] = []
    /// Last failure message, surfaced to the UI when a create fails.
    @Published var lastError: String?

    /// Strong references keep the displays alive — releasing a `CGVirtualDisplay`
    /// instance destroys the display immediately.
    private var handles: [CGDirectDisplayID: CGVirtualDisplay] = [:]

    private let logger = Logger(subsystem: "com.aagedal.MediaConverter", category: "VirtualDisplay")

    private init() {}

    /// Whether the private CGVirtualDisplay classes are present on this system.
    static var isSupported: Bool {
        NSClassFromString("CGVirtualDisplay") != nil
            && NSClassFromString("CGVirtualDisplayDescriptor") != nil
            && NSClassFromString("CGVirtualDisplayMode") != nil
            && NSClassFromString("CGVirtualDisplaySettings") != nil
    }

    /// True if the given display id is one of our virtual displays.
    func isVirtual(_ id: CGDirectDisplayID) -> Bool {
        handles[id] != nil
    }

    /// A friendly default name for a virtual display of the given size.
    static func defaultName(width: Int, height: Int) -> String {
        "Aagedal Virtual \(width)×\(height)"
    }

    /// Create a pixel-perfect (standard-DPI) virtual display at the given size.
    /// Returns its CGDirectDisplayID on success, or nil (with `lastError` set).
    @discardableResult
    func create(width: Int, height: Int, refreshRate: Double = 60, name: String? = nil) async -> CGDirectDisplayID? {
        guard Self.isSupported else {
            lastError = "Virtual displays aren’t available on this version of macOS."
            return nil
        }
        guard width >= 2, height >= 2 else {
            lastError = "Resolution is too small for a virtual display."
            return nil
        }

        let displayName = name ?? Self.defaultName(width: width, height: height)

        // Build the descriptor. vendorID must be non-zero or creation fails.
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.vendorID = 0x0610
        descriptor.productID = 0x1AE5
        descriptor.serialNum = 0x0001
        descriptor.name = displayName
        let pointsPerInch = 110.0 // typical desktop density; physical size is cosmetic for SDR capture
        descriptor.sizeInMillimeters = CGSize(
            width: Double(width) / pointsPerInch * 25.4,
            height: Double(height) / pointsPerInch * 25.4
        )
        descriptor.maxPixelsWide = UInt32(width)
        descriptor.maxPixelsHigh = UInt32(height)
        // sRGB primaries + D65 white point.
        descriptor.redPrimary = CGPoint(x: 0.640, y: 0.330)
        descriptor.greenPrimary = CGPoint(x: 0.300, y: 0.600)
        descriptor.bluePrimary = CGPoint(x: 0.150, y: 0.060)
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        descriptor.queue = DispatchQueue(label: "com.aagedal.MediaConverter.virtualDisplay")

        // Must be created on the main thread (we are @MainActor) — background returns nil.
        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            lastError = "Couldn’t create the virtual display."
            return nil
        }

        // A single SDR mode at native resolution — what you capture is exactly these pixels.
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = false
        guard let mode = CGVirtualDisplayMode(width: UInt(width), height: UInt(height), refreshRate: refreshRate) else {
            lastError = "Couldn’t configure the virtual display mode."
            return nil
        }
        settings.modes = [mode]

        // applySettings blocks on WindowServer IPC; run it off the main thread with a timeout.
        let box = VirtualDisplayApplyBox(display: display, settings: settings)
        let applied = await Self.applySettings(box, timeoutSeconds: 10)
        guard applied else {
            lastError = "The virtual display didn’t respond in time."
            return nil
        }

        let id = display.displayID
        guard id != 0 else {
            lastError = "The virtual display didn’t return a valid id."
            return nil
        }

        handles[id] = display

        // macOS puts a freshly created virtual display into a mirror set (pinned
        // on top of the main display). Convert it to an extended desktop so the
        // user can drag a window onto it and record it independently. Give the
        // display a moment to settle before reconfiguring.
        try? await Task.sleep(nanoseconds: 200_000_000)
        ensureExtended(id)

        activeDisplays.append(ActiveDisplay(id: id, name: displayName, width: width, height: height))
        lastError = nil
        logger.info("Created virtual display \(id, privacy: .public) (\(width)×\(height))")
        return id
    }

    /// Ensure the display is an extended desktop, not a mirror. A new virtual
    /// display defaults into a mirror set; switching its mirror master to the
    /// null display detaches it into the extended desktop. Scoped to the session
    /// so it doesn't persist into the user's saved display preferences.
    private func ensureExtended(_ id: CGDirectDisplayID) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
        if CGCompleteDisplayConfiguration(config, .forSession) != .success {
            CGCancelDisplayConfiguration(config)
            logger.error("Couldn’t switch virtual display \(id, privacy: .public) to extended mode")
        }
    }

    /// Destroy a virtual display (no-op if it isn't one of ours).
    func destroy(_ id: CGDirectDisplayID) {
        guard handles[id] != nil else { return }
        handles[id] = nil // dropping the reference destroys the display
        activeDisplays.removeAll { $0.id == id }
        logger.info("Destroyed virtual display \(id, privacy: .public)")
    }

    /// Destroy all virtual displays. Call on app termination so none linger.
    func destroyAll() {
        guard !handles.isEmpty else { return }
        handles.removeAll()
        activeDisplays.removeAll()
        logger.info("Destroyed all virtual displays")
    }

    // MARK: - Lifetime Policy

    /// Whether virtual displays persist until the app quits. When false (the default), they are
    /// "ephemeral": torn down as soon as they leave the recording grid or record mode closes.
    /// See `AppConstants.captureKeepVirtualDisplaysAliveKey`.
    var keepAliveForAppLifetime: Bool {
        UserDefaults.standard.bool(forKey: AppConstants.captureKeepVirtualDisplaysAliveKey)
    }

    /// Destroy a virtual display because it was removed from the recording grid — but only under the
    /// default ephemeral policy. A no-op when the user opted to keep displays alive for the app's
    /// lifetime, or when the id isn't one of ours.
    func destroyIfEphemeral(_ id: CGDirectDisplayID) {
        guard !keepAliveForAppLifetime else { return }
        destroy(id)
    }

    /// Tear down all virtual displays because record mode closed — but only under the default
    /// ephemeral policy. A no-op when the user opted to keep displays alive for the app's lifetime.
    func destroyAllIfEphemeral() {
        guard !keepAliveForAppLifetime else { return }
        destroyAll()
    }

    /// Runs the blocking `applySettings:` on a background queue, racing it
    /// against a timeout. Returns the apply result, or false if it timed out.
    private nonisolated static func applySettings(_ box: VirtualDisplayApplyBox, timeoutSeconds: Double) async -> Bool {
        await BlockingOperationDeadline.run(
            timeout: .seconds(timeoutSeconds),
            timeoutResult: false
        ) {
            box.display.apply(box.settings)
        }
    }
}
